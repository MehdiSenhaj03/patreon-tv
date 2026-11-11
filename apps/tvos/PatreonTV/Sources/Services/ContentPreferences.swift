//
//  ContentPreferences.swift
//  PatreonTV
//
//  User-facing content settings, persisted in UserDefaults: mature-content
//  gate, playback behavior, launch tab and default comment order.
//

import Foundation

@MainActor
@Observable
final class ContentPreferences {

    static let shared = ContentPreferences()

    /// Which tab the app opens on. `lastUsed` restores whichever tab the user
    /// had selected when they last quit; every other case pins that tab.
    enum InitialTab: String, CaseIterable, Identifiable {
        case home, creators, search, lastUsed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: L10n.string("Home")
            case .creators: L10n.string("Creators")
            case .search: L10n.string("Search")
            case .lastUsed: L10n.string("Last used")
            }
        }
    }

    /// Video quality for HLS streams. AVPlayer normally adapts on its own and
    /// tends to start low; the other choices pin a variant (HLSQualityLoader).
    enum VideoQuality: String, CaseIterable, Identifiable {
        case maximum, p1080, p720, automatic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .maximum: L10n.string("Maximum")
            case .p1080: "1080p"
            case .p720: "720p"
            case .automatic: L10n.string("Automatic")
            }
        }

        /// Highest variant height to keep; nil = the best available.
        var maxHeight: Int? {
            switch self {
            case .maximum, .automatic: nil
            case .p1080: 1080
            case .p720: 720
            }
        }
    }

    private let matureKey = "show_mature_content"
    private let autoplayNextKey = "autoplay_next"
    private let autoplayNewKey = "autoplay_new"
    private let autoplayContinueWatchingKey = "autoplay_continue_watching"
    private let autoplayChannelsKey = "autoplay_channels"
    private let autoplayCollectionsKey = "autoplay_collections"
    private let continueCollectionKey = "show_continue_collection"
    private let collectionOldestFirstKey = "collection_oldest_first"
    private let collectionSeriesModeKey = "collection_series_mode"
    private let initialTabKey = "initial_tab"
    private let commentSortKey = "comments_sort"
    private let videoQualityKey = "video_quality"

    /// When false (default), NSFW creators are hidden from Creators and Search.
    var showMatureContent: Bool {
        didSet { UserDefaults.standard.set(showMatureContent, forKey: matureKey) }
    }

    /// Master switch for automatic advance. The per-source switches below
    /// only apply while this is on.
    var autoplayNext: Bool {
        didSet { UserDefaults.standard.set(autoplayNext, forKey: autoplayNextKey) }
    }

    /// Auto-advance for the Home "Recent" shelf.
    var autoplayNew: Bool {
        didSet { UserDefaults.standard.set(autoplayNew, forKey: autoplayNewKey) }
    }

    /// Auto-advance for the "Continue Watching" shelf.
    var autoplayContinueWatching: Bool {
        didSet { UserDefaults.standard.set(autoplayContinueWatching, forKey: autoplayContinueWatchingKey) }
    }

    /// Auto-advance for creator pages and creator carousels.
    var autoplayChannels: Bool {
        didSet { UserDefaults.standard.set(autoplayChannels, forKey: autoplayChannelsKey) }
    }

    /// Auto-advance for collection episodes and Continue Collection.
    var autoplayCollections: Bool {
        didSet { UserDefaults.standard.set(autoplayCollections, forKey: autoplayCollectionsKey) }
    }

    func autoplayEnabled(for source: AutoplaySource) -> Bool {
        guard autoplayNext else { return false }
        switch source {
        case .new: return autoplayNew
        case .continueWatching: return autoplayContinueWatching
        case .channels: return autoplayChannels
        case .collections: return autoplayCollections
        }
    }

    /// When true (default), Home shows a "Continue Collection" shelf with the
    /// collection the user opened most recently.
    var showContinueCollection: Bool {
        didSet { UserDefaults.standard.set(showContinueCollection, forKey: continueCollectionKey) }
    }

    /// When true, a collection's episodes open oldest-first (ascending) by
    /// default; otherwise newest-first (descending). The on-screen toggle still
    /// overrides it for the session.
    var collectionOldestFirst: Bool {
        didSet { UserDefaults.standard.set(collectionOldestFirst, forKey: collectionOldestFirstKey) }
    }

    /// When true, a collection behaves like a TV series: Play always starts at
    /// the oldest episode that isn't finished (in progress or not started),
    /// instead of resuming the last one watched. Collections only — nothing
    /// else in the app changes.
    var collectionSeriesMode: Bool {
        didSet { UserDefaults.standard.set(collectionSeriesMode, forKey: collectionSeriesModeKey) }
    }

    /// Which tab to open on launch (default Home).
    var initialTab: InitialTab {
        didSet { UserDefaults.standard.set(initialTab.rawValue, forKey: initialTabKey) }
    }

    /// Default order for a post's comments (default Best). The on-screen sort
    /// menu still overrides it for the current visit.
    var commentSort: CommentSort {
        didSet { UserDefaults.standard.set(commentSort.rawValue, forKey: commentSortKey) }
    }

    /// Video quality (default Maximum).
    var videoQuality: VideoQuality {
        didSet { UserDefaults.standard.set(videoQuality.rawValue, forKey: videoQualityKey) }
    }

    /// App interface language. Resolved from the system on first launch, then
    /// user-selectable in Settings.
    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey) }
    }

    private init() {
        showMatureContent = UserDefaults.standard.bool(forKey: matureKey)

        autoplayNext = UserDefaults.standard.object(forKey: autoplayNextKey) as? Bool ?? true
        autoplayNew = UserDefaults.standard.object(forKey: autoplayNewKey) as? Bool ?? true
        autoplayContinueWatching = UserDefaults.standard.object(forKey: autoplayContinueWatchingKey) as? Bool ?? true
        autoplayChannels = UserDefaults.standard.object(forKey: autoplayChannelsKey) as? Bool ?? true
        autoplayCollections = UserDefaults.standard.object(forKey: autoplayCollectionsKey) as? Bool ?? true

        showContinueCollection = UserDefaults.standard.object(forKey: continueCollectionKey) as? Bool ?? true
        collectionOldestFirst = UserDefaults.standard.object(forKey: collectionOldestFirstKey) as? Bool ?? false
        collectionSeriesMode = UserDefaults.standard.object(forKey: collectionSeriesModeKey) as? Bool ?? false
        initialTab = InitialTab(rawValue: UserDefaults.standard.string(forKey: initialTabKey) ?? "") ?? .home
        commentSort = CommentSort(rawValue: UserDefaults.standard.string(forKey: commentSortKey) ?? "") ?? .best
        videoQuality = VideoQuality(rawValue: UserDefaults.standard.string(forKey: videoQualityKey) ?? "") ?? .maximum
        if let raw = UserDefaults.standard.string(forKey: AppLanguage.storageKey),
           let stored = AppLanguage(rawValue: raw) {
            language = stored
        } else {
            let resolved = AppLanguage.resolved(from: Locale.preferredLanguages)
            language = resolved
            UserDefaults.standard.set(resolved.rawValue, forKey: AppLanguage.storageKey)
        }
    }
}
