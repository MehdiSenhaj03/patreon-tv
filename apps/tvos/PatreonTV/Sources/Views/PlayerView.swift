//
//  PlayerView.swift
//  PatreonTV
//
//  Full-screen native AVPlayerViewController for tvOS. Handles Mux HLS,
//  Patreon-hosted MP4, and any AVPlayer-compatible URL.
//

import AVFoundation
import AVKit
import Foundation
import SwiftUI
import os.log

struct PlayerView: UIViewControllerRepresentable {

    let source: MediaPlaybackSource
    let title: String
    let postID: String
    let resumeSeconds: Double?
    /// Optional context for the info panel, chapter markers, and richer
    /// swipe-down metadata. Playback works without them.
    var post: Post? = nil
    var campaign: Campaign? = nil
    var duration: Double? = nil
    /// Called on the main actor when the player item fails (e.g. an expired
    /// Mux token after pausing overnight). The presenter should dismiss the
    /// player and offer a retry, which re-fetches a fresh URL.
    var onPlaybackFailure: ((String) -> Void)? = nil
    /// Called on the main actor when the item plays to its end, with the
    /// coordinator's `postID` so the presenter can ignore a stale end from a
    /// previous episode. The presenter can show an Up Next overlay or dismiss.
    var onPlaybackEnded: ((String) -> Void)? = nil
    /// Called on the main actor roughly once a second once the item enters its
    /// final `upNextLeadSeconds`, with the coordinator's `postID` and the
    /// seconds still remaining. Lets the presenter show the Up Next card ahead
    /// of the end (ignoring stale ticks from a previous episode).
    var onUpNextTick: ((String, Double) -> Void)? = nil
    /// Whether the native Up Next action buttons (Next / Cancel) are
    /// visible. AVKit owns their focus, so they're reliably selectable.
    var upNextActive: Bool = false
    /// Tapped "Next".
    var onPlayNext: (() -> Void)? = nil
    /// Tapped "Cancel".
    var onCancelUpNext: (() -> Void)? = nil
    /// Episodes of the collection this post belongs to (for the player's
    /// Episodes info tab). Empty hides the tab.
    var episodes: [Post] = []
    /// Called on the main actor when an episode is chosen from the tab.
    var onSelectEpisode: ((String) -> Void)? = nil

    /// Seconds before the end at which the Up Next card starts appearing.
    static let upNextLeadSeconds: Double = 15

    func makeCoordinator() -> Coordinator {
        Coordinator(
            postID: postID,
            onFailure: onPlaybackFailure,
            onEnded: onPlaybackEnded,
            onUpNextTick: onUpNextTick
        )
    }

    func makeUIViewController(context: Context) -> PlayerHostViewController {
        let host = PlayerHostViewController()
        host.configure(
            postID: postID,
            source: source,
            title: title,
            resumeSeconds: resumeSeconds,
            post: post,
            campaign: campaign,
            duration: duration,
            episodes: episodes,
            onSelectEpisode: onSelectEpisode,
            coordinator: context.coordinator
        )
        return host
    }

    func updateUIViewController(_ host: PlayerHostViewController, context: Context) {
        host.updateUpNext(isActive: upNextActive, onPlay: onPlayNext, onCancel: onCancelUpNext)
    }

    static func dismantleUIViewController(_ host: PlayerHostViewController, coordinator: Coordinator) {
        // While the video floats in PiP the player must outlive this screen:
        // detaching would stop progress tracking and drop the delegate that
        // restores full screen. The PiP session keeps the host alive instead.
        if host.isPictureInPictureActive {
            coordinator.setDetached(true)
            host.detachFromScreen()
            return
        }
        coordinator.detach()
        host.playerViewController.player?.pause()
        host.teardown()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        let postID: String
        private let onFailure: ((String) -> Void)?
        private let onEnded: ((String) -> Void)?
        private let onUpNextTick: ((String, Double) -> Void)?
        private var timeObserver: Any?
        private var upNextObserver: Any?
        private var statusObserver: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?
        private weak var player: AVPlayer?
        /// True while the video floats in PiP with no screen owning it. Progress
        /// keeps being recorded; only the UI-facing callbacks stop.
        private(set) var isDetached = false
        private let log = Logger(subsystem: "com.patreontv.PatreonTV", category: "Player")

        init(
            postID: String,
            onFailure: ((String) -> Void)? = nil,
            onEnded: ((String) -> Void)? = nil,
            onUpNextTick: ((String, Double) -> Void)? = nil
        ) {
            self.postID = postID
            self.onFailure = onFailure
            self.onEnded = onEnded
            self.onUpNextTick = onUpNextTick
        }

        func attach(player: AVPlayer, item: AVPlayerItem) {            self.player = player

            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard let self else { return }
                Task { @MainActor in
                    switch item.status {
                    case .readyToPlay:
                        self.log.info("Player ready for post \(self.postID)")
                    case .failed:
                        self.log.error(
                            "Player failed for post \(self.postID): \(String(describing: item.error))"
                        )
                        // Media URLs are token-signed with ~24h expiry, so a
                        // long pause can kill the stream. Surface it instead of
                        // leaving a silent black screen.
                        guard !self.isDetached else { return }
                        self.onFailure?(
                            item.error?.localizedDescription
                                ?? L10n.string("The video stopped playing. Its link may have expired — try again.")
                        )
                    default:
                        break
                    }
                }
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.log.info("Playback finished for post \(self.postID)")
                    self.markFinished()
                    guard !self.isDetached else { return }
                    self.onEnded?(self.postID)
                }
            }

            let interval = CMTime(seconds: 5, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak self, weak player] time in
                guard let self, let player else { return }
                MainActor.assumeIsolated {
                    self.recordProgress(player: player, time: time)
                }
            }

            // Fast tick for the Up Next window (last `upNextLeadSeconds`).
            let upNextInterval = CMTime(seconds: 1, preferredTimescale: 600)
            upNextObserver = player.addPeriodicTimeObserver(
                forInterval: upNextInterval,
                queue: .main
            ) { [weak self, weak player] _ in
                guard let self, let player else { return }
                MainActor.assumeIsolated {
                    self.reportUpNextTick(player: player)
                }
            }
        }

        /// Fire `onUpNextTick(postID, remaining)` while the item is within its
        /// final `PlayerView.upNextLeadSeconds`. Requires `remaining > 0` so a
        /// tick frozen at the end of a previous item can't re-open the card.
        private func reportUpNextTick(player: AVPlayer) {
            let duration = player.currentItem?.duration.seconds ?? 0
            let position = player.currentTime().seconds
            guard duration.isFinite, duration > 0, position.isFinite else { return }
            let remaining = duration - position
            guard remaining > 0, remaining <= PlayerView.upNextLeadSeconds else { return }
            guard !isDetached else { return }
            onUpNextTick?(postID, remaining)
        }

        /// Called when the video starts floating in PiP without a screen: keep
        /// recording progress, but stop driving the post screen's UI.
        func setDetached(_ detached: Bool) {
            isDetached = detached
        }

        func detach() {
            statusObserver?.invalidate()
            statusObserver = nil
            if let obs = endObserver {
                NotificationCenter.default.removeObserver(obs)
                endObserver = nil
            }
            if let obs = timeObserver {
                player?.removeTimeObserver(obs)
                timeObserver = nil
            }
            if let obs = upNextObserver {
                player?.removeTimeObserver(obs)
                upNextObserver = nil
            }
            if let player {
                let position = player.currentTime().seconds
                let duration = player.currentItem?.duration.seconds ?? 0
                if position.isFinite, duration.isFinite, duration > 0 {
                    PlaybackProgressStore.shared.record(PlaybackProgress(
                        postID: postID,
                        positionSeconds: position,
                        durationSeconds: duration,
                        lastUpdated: Date()
                    ))
                }
            }
        }

        /// Record the post at 100% so it counts as finished and drops out of
        /// Continue Watching.
        private func markFinished() {
            guard let duration = player?.currentItem?.duration.seconds,
                  duration.isFinite, duration > 0
            else { return }
            PlaybackProgressStore.shared.record(PlaybackProgress(
                postID: postID,
                positionSeconds: duration,
                durationSeconds: duration,
                lastUpdated: Date()
            ))
        }

        private func recordProgress(player: AVPlayer, time: CMTime) {
            let position = time.seconds
            let duration = player.currentItem?.duration.seconds ?? 0
            guard position.isFinite, duration.isFinite, duration > 0 else { return }
            PlaybackProgressStore.shared.record(PlaybackProgress(
                postID: postID,
                positionSeconds: position,
                durationSeconds: duration,
                lastUpdated: Date()
            ))
        }
    }
}

// MARK: - Host view controller

/// Embeds `AVPlayerViewController` edge-to-edge. SwiftUI `fullScreenCover` +
/// bare `AVPlayerViewController` often lays out at zero width on tvOS.
@MainActor
final class PlayerHostViewController: UIViewController, AVPlayerViewControllerDelegate {

    let playerViewController = AVPlayerViewController()
    private var didConfigure = false
    /// Post being played, needed for the PiP session bookkeeping.
    private(set) var postID: String = ""
    /// Retained so progress keeps being recorded while PiP owns the video and
    /// the SwiftUI screen is gone.
    private var coordinator: PlayerView.Coordinator?
    /// True when the screen that started playback has been dismissed but the
    /// video is still floating in PiP.
    private(set) var isDetachedFromScreen = false
    /// System Picture in Picture state, kept in sync by the delegate so that
    /// dismissing the screen or leaving the app does not stop the floating
    /// video.
    private(set) var isPictureInPictureActive = false
    /// Strong reference: `AVAssetResourceLoader` holds its delegate weakly.
    private var assetResourceLoader: PatreonAssetResourceLoader?
    /// Same, for the loader that pins the HLS variant (video quality setting).
    private var qualityLoader: HLSQualityLoader?
    private let log = Logger(subsystem: "com.patreontv.PatreonTV", category: "Player")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        playerViewController.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        addChild(playerViewController)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerViewController.view)
        NSLayoutConstraint.activate([
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerViewController.didMove(toParent: self)
    }

    /// Native Up Next action buttons state.
    private var upNextActive = false
    private var onPlayNext: (() -> Void)?
    private var onCancelUpNext: (() -> Void)?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [playerViewController]
    }

    /// Show/hide the native Up Next action buttons (Next / Cancel).
    /// Only reassigns `contextualActions` when the active state flips, so
    /// AVKit's focus isn't reset while the card's countdown ticks.
    func updateUpNext(isActive: Bool, onPlay: (() -> Void)?, onCancel: (() -> Void)?) {
        onPlayNext = onPlay
        onCancelUpNext = onCancel
        guard isActive != upNextActive else { return }
        upNextActive = isActive
        playerViewController.contextualActions = isActive ? makeUpNextActions() : []
    }

    private func makeUpNextActions() -> [UIAction] {
        let cancel = UIAction(
            title: L10n.string("Cancel"),
            image: UIImage(systemName: "xmark")
        ) { [weak self] _ in self?.onCancelUpNext?() }
        let next = UIAction(
            title: L10n.string("Next"),
            image: UIImage(systemName: "forward.end.fill")
        ) { [weak self] _ in self?.onPlayNext?() }
        // "Next" last so it sits on the trailing edge and takes default focus.
        return [cancel, next]
    }

    /// Cancels in-flight authenticated requests and breaks the URLSession →
    /// delegate retain cycle. Called when the player is dismissed.
    func teardown() {
        assetResourceLoader?.invalidate()
        assetResourceLoader = nil
        NotificationCenter.default.removeObserver(self)
        // While PiP is running the system owns playback; leave the session
        // active or the floating video loses its audio.
        if !isPictureInPictureActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Picture in Picture

    /// PiP needs an active playback audio session. Without one AVKit does not
    /// offer the Picture in Picture control at all.
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            log.error("Audio session activation failed: \(String(describing: error))")
        }

        if !AVPictureInPictureController.isPictureInPictureSupported() {
            log.info("Picture in Picture is not supported on this device")
        }
    }

    /// The audio background mode PiP requires would otherwise let playback
    /// continue with no picture when the user leaves the app. PiP handles its
    /// own background playback, so only pause when it is not active.
    @objc private func handleDidEnterBackground() {
        guard !isPictureInPictureActive else { return }
        playerViewController.player?.pause()
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActive = true
        // The screen may be dismissed while the video floats; keep the host
        // (and this delegate) alive so the system can restore full screen.
        PictureInPictureSession.shared.adopt(host: self, postID: postID)
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActive = true
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActive = false
        log.error("Picture in Picture failed to start: \(error.localizedDescription, privacy: .public)")
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        isPictureInPictureActive = false
        // Closed from the PiP window (not restored to full screen): nothing is
        // presenting this player anymore, so stop it and free the session.
        guard isDetachedFromScreen,
              !PictureInPictureSession.shared.isRestoringFullScreen else { return }
        endSessionPlayback()
    }

    /// The full-screen cover is still presented when PiP stops, so there is
    /// nothing to rebuild; just let the system finish the transition.
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The screen that started playback may be long gone (the user kept
        // browsing the app or another app). Ask the app to present it again.
        if viewIfLoaded?.window == nil {
            PictureInPictureSession.shared.requestFullScreen()
        }
        completionHandler(true)
    }

    // MARK: - Detached (PiP) session

    /// Keep the player alive with no screen attached while the video floats.
    func detachFromScreen() {
        isDetachedFromScreen = true
        coordinator?.setDetached(true)
    }

    /// The floating player is back on screen: either the system restored it or
    /// the user pressed Play again on the same post.
    func reattach() {
        isDetachedFromScreen = false
        activateAudioSession()
    }

    /// Stop and release a player that outlived its screen in PiP.
    func endSessionPlayback() {
        coordinator?.detach()
        coordinator = nil
        playerViewController.player?.pause()
        playerViewController.player = nil
        teardown()
        PictureInPictureSession.shared.release(host: self)
    }

    func configure(
        postID: String,
        source: MediaPlaybackSource,
        title: String,
        resumeSeconds: Double?,
        post: Post? = nil,
        campaign: Campaign? = nil,
        duration: Double? = nil,
        episodes: [Post] = [],
        onSelectEpisode: ((String) -> Void)? = nil,
        coordinator: PlayerView.Coordinator
    ) {
        guard !didConfigure else { return }
        didConfigure = true

        self.postID = postID
        self.coordinator = coordinator

        activateAudioSession()

        // Both Mux and Patreon media URLs are self-signed with an expiring token
        // in the query string, so a plain asset streams them directly and
        // AVFoundation handles its own efficient byte-range fetching.
        //
        // Mux enforces a *playback restriction* on these assets: a valid,
        // unexpired signed token still 403s unless the request carries a
        // patreon.com Referer/Origin and a browser User-Agent (the old WebView
        // player sent these automatically; native AVPlayer sends none, which
        // silently broke video playback).
        log.info("Direct playback for \(source.url.absoluteString.prefix(120))")
        let playbackHeaders = [
            "Referer": "https://www.patreon.com/",
            "Origin": "https://www.patreon.com",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        ]
        // Video quality: unless set to Automatic, open HLS streams through a
        // loader that keeps only the chosen variant (see HLSQualityLoader).
        // First-party patreon.com manifests keep their cookie loader instead.
        let quality = ContentPreferences.shared.videoQuality
        var assetURL = source.url
        if quality != .automatic,
           source.kind == .video,
           !PatreonAssetResourceLoader.isPatreonHost(source.url.host),
           ["m3u8", "m3u"].contains(source.url.pathExtension.lowercased()),
           let wrapped = HLSQualityLoader.wrappedURL(for: source.url) {
            assetURL = wrapped
            log.info("Pinning HLS quality: \(quality.rawValue)")
        }

        let asset = AVURLAsset(
            url: assetURL,
            options: ["AVURLAssetHTTPHeaderFieldsKey": playbackHeaders]
        )

        if assetURL != source.url {
            let loader = HLSQualityLoader(maxHeight: quality.maxHeight, headers: playbackHeaders)
            qualityLoader = loader
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "com.patreontv.HLSQualityLoader"))
        }

        // Some posts (those with a preview) serve the full video through a
        // first-party manifest that authorises via the session cookie, not a
        // signed token. Route that through a loader that attaches the cookie
        // to patreon.com hosts only — never to the Mux CDN. See
        // PatreonAssetResourceLoader for the full rationale.
        if PatreonAssetResourceLoader.isPatreonHost(source.url.host),
           let sessionID = PatreonClient.shared.sessionID {
            let loader = PatreonAssetResourceLoader(sessionID: sessionID, headers: playbackHeaders)
            assetResourceLoader = loader
            asset.resourceLoader.setDelegate(
                loader,
                queue: DispatchQueue(label: "com.patreontv.PatreonAssetResourceLoader")
            )
        }

        let item = AVPlayerItem(asset: asset)
        item.externalMetadata = makeExternalMetadata(title: title, post: post, campaign: campaign)
        attachArtworkIfAvailable(to: item, post: post)
        attachChapterMarkers(to: item, post: post, duration: duration)

        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        playerViewController.player = player
        playerViewController.allowsPictureInPicturePlayback = true
        playerViewController.videoGravity = .resizeAspect

        configureEpisodesTab(
            episodes: episodes,
            currentPostID: post?.id ?? "",
            onSelectEpisode: onSelectEpisode
        )

        coordinator.attach(player: player, item: item)

        if let resume = resumeSeconds, resume > 5 {
            let target = CMTime(seconds: resume, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: CMTime.zero, toleranceAfter: CMTime.positiveInfinity) { _ in
                player.play()
            }
        } else {
            player.play()
        }
    }

    // MARK: - Metadata (powers the native swipe-down info panel)

    private func makeExternalMetadata(title: String, post: Post?, campaign: Campaign?) -> [AVMetadataItem] {
        var items = [makeMetadataItem(identifier: .commonIdentifierTitle, value: title)]

        // The transport bar's small line shows "date · subtitle", so the
        // subtitle stays just the channel. The Info body carries the title.
        if let creator = campaign?.attributes.name, !creator.isEmpty {
            items.append(makeMetadataItem(identifier: .iTunesMetadataTrackSubTitle, value: creator))
        }

        if let date = formattedPublishedDate(post?.attributes.publishedAt) {
            items.append(makeMetadataItem(identifier: .commonIdentifierCreationDate, value: date))
        }
        if let description = playerDescription(title: title, post: post) {
            items.append(makeMetadataItem(identifier: .commonIdentifierDescription, value: description))
        }

        return items
    }

    private func formattedPublishedDate(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        else { return nil }
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .locale(AppLanguage.current.locale)
        )
    }

    /// Fetch the poster asynchronously and append it as artwork metadata; the
    /// info panel shows it beside the title. Best-effort — never blocks playback.
    private func attachArtworkIfAvailable(to item: AVPlayerItem, post: Post?) {
        guard let url = post?.attributes.posterImageURL else { return }
        Task { [weak item] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let item
            else { return }
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = data as NSData
            artwork.dataType = kCMMetadataBaseDataType_JPEG as String
            artwork.extendedLanguageTag = "und"
            item.externalMetadata.append(artwork.copy() as! AVMetadataItem)
        }
    }

    // MARK: - Chapters

    /// Patreon has no chapter API, so we mine the description for a timestamp
    /// list and surface it as native navigation markers (transport-bar chapter
    /// skipping + the Chapters info tab).
    private func attachChapterMarkers(to item: AVPlayerItem, post: Post?, duration: Double?) {
        guard let post, let source = PostBody.source(post.attributes) else { return }
        let chapters = ChapterParser.chapters(fromHTML: source, duration: duration)
        guard !chapters.isEmpty else { return }

        log.info("Parsed \(chapters.count) chapters from post content")

        var groups: [AVTimedMetadataGroup] = []
        for (index, chapter) in chapters.enumerated() {
            let start = CMTime(seconds: chapter.startSeconds, preferredTimescale: 600)
            let endSeconds = index + 1 < chapters.count
                ? chapters[index + 1].startSeconds
                : (duration ?? chapter.startSeconds + 3600)
            let end = CMTime(seconds: max(endSeconds, chapter.startSeconds + 1), preferredTimescale: 600)
            let titleItem = makeMetadataItem(identifier: .commonIdentifierTitle, value: chapter.title)
            groups.append(AVTimedMetadataGroup(
                items: [titleItem],
                timeRange: CMTimeRange(start: start, end: end)
            ))
        }
        item.navigationMarkerGroups = [
            AVNavigationMarkersGroup(title: L10n.string("Chapters"), timedNavigationMarkers: groups)
        ]
    }

    // MARK: - Custom info panel

    /// "Episodes" tab in the swipe-down panel, listing the collection's
    /// episodes (focused on the one playing). The native Info tab carries the
    /// title, channel/date and description, so this is the only extra tab.
    private func configureEpisodesTab(
        episodes: [Post],
        currentPostID: String,
        onSelectEpisode: ((String) -> Void)?
    ) {
        guard episodes.count > 1, let onSelectEpisode else {
            playerViewController.customInfoViewControllers = []
            return
        }

        let episodesVC = UIHostingController(rootView: PlayerEpisodesView(
            episodes: episodes,
            currentPostID: currentPostID,
            onSelect: onSelectEpisode
        ))
        episodesVC.title = L10n.string("Episodes")
        episodesVC.preferredContentSize = CGSize(width: 0, height: 380)
        playerViewController.customInfoViewControllers = [episodesVC]
    }

    /// Info panel body: the title on its own line, then (when present) the
    /// post's text body. Falls back to whichever of the two exists.
    private func playerDescription(title: String, post: Post?) -> String? {
        let body = post.flatMap { post -> String? in
            if let body = PostBody.plainText(post.attributes), !body.isEmpty {
                return body
            }
            if let teaser = post.attributes.teaser, !teaser.isEmpty {
                return teaser
            }
            return nil
        }

        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (heading.isEmpty, body) {
        case (false, .some(let body)): return "\(heading)\n\n\(body)"
        case (false, .none): return heading
        case (true, .some(let body)): return body
        case (true, .none): return nil
        }
    }

    private func makeMetadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item.copy() as! AVMetadataItem
    }
}

// MARK: - Restored player

/// Presents the player host that outlived its screen in Picture in Picture.
/// Unlike `PlayerView`, it never creates a player: the same instance, at the
/// same position, comes back to full screen.
struct RestoredPlayerView: UIViewControllerRepresentable {

    let host: PlayerHostViewController

    func makeUIViewController(context: Context) -> PlayerHostViewController {
        host.reattach()
        return host
    }

    func updateUIViewController(_ host: PlayerHostViewController, context: Context) {
        // The post screen's Up Next surface is gone; keep the native bar clean.
        host.updateUpNext(isActive: false, onPlay: nil, onCancel: nil)
    }

    static func dismantleUIViewController(_ host: PlayerHostViewController, coordinator: ()) {
        // Back to PiP on the way out: keep the session running.
        if host.isPictureInPictureActive {
            host.detachFromScreen()
            return
        }
        host.endSessionPlayback()
    }
}
