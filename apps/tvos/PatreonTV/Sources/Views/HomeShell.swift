//
//  HomeShell.swift
//  PatreonTV
//
//  Top-level tab-bar shell shown when the user is signed in. Also handles
//  deep-link navigation (from the Top Shelf extension).
//
//  Follows tvOS design rules TAB-01 (top tab bar), TAB-03 (3–7 tabs),
//  TAB-04 (text labels), TAB-06 (persist selection).
//
//  Navigation is value-based throughout: every post/creator link pushes a
//  DeepLinkDestination, and each tab's NavigationStack registers the shared
//  destination table via .appNavigationDestinations(). Deep links inject into
//  the Home tab's path.
//

import SwiftUI

struct HomeShell: View {

    @Environment(AuthStore.self) private var auth
    @Environment(DeepLinkRouter.self) private var router
    @AppStorage("selected_tab") private var selectedTab: Tab = .home
    /// Re-render the shell when the app language changes so L10n-built labels
    /// (tab titles, menu titles) refresh immediately.
    @Environment(\.locale) private var locale
    /// Set when embedded in a host app: Back at the top level returns there.
    @Environment(\.exitApp) private var exitApp

    /// The tab the app opened on, resolved once at launch. Frozen so the
    /// first-element focus only applies to the launch tab (a later tab change
    /// doesn't steal focus), and so "Last used" lands focus on the restored tab.
    @State private var launchTab: Tab = HomeShell.resolvedLaunchTab()

    /// Guards the launch-time tab pin so re-appearing (deep links, returning
    /// from a detail screen) doesn't yank the user back to the configured tab.
    @State private var didResolveInitialTab = false

    /// Path used to push detail views from a deep link. Each tab has its own
    /// NavigationStack; we route deep links to the Home tab and push there.
    @State private var homePath: [DeepLinkDestination] = []

    enum Tab: String, CaseIterable, Identifiable {
        case home, creators, search, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: L10n.string("Home")
            case .creators: L10n.string("Creators")
            case .search: L10n.string("Search")
            case .settings: L10n.string("Settings")
            }
        }
    }

    var body: some View {
        let _ = locale
        // Binding to the PiP session so a floating video can be brought back to
        // full screen no matter which tab the user is on.
        @Bindable var pip = PictureInPictureSession.shared

        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                HomeView(
                    onPlayPost: { playPost(id: $0, collectionID: nil, queue: $1, source: $2) },
                    onPlayCollection: { homePath.playCollection(collectionID: $0, postID: $1) },
                    focusFirstShelfCard: launchTab == .home && homePath.isEmpty
                )
                    .appNavigationDestinations(
                        onPlayPost: { playPost(id: $0, collectionID: $1, source: .channels) },
                        onPlayCollection: { homePath.playCollection(collectionID: $0, postID: $1) }
                    )
            }
            .tabItem { Label(Tab.home.title, systemImage: "house.fill") }
            .tag(Tab.home)

            CreatorsView(focusFirstCardOnEntry: launchTab == .creators)
                .tabItem { Label(Tab.creators.title, systemImage: "person.2.fill") }
                .tag(Tab.creators)

            SearchView()
                .tabItem { Label(Tab.search.title, systemImage: "magnifyingglass") }
                .tag(Tab.search)

            SettingsView()
                .tabItem { Label(Tab.settings.title, systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .background(PatreonColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { resolveInitialTab() }
        .onExitCommand(perform: exitApp)
        .overlay(alignment: .topLeading) {
            Image("PTVMark")
                .resizable()
                .scaledToFit()
                .frame(height: 52)
                .padding(.leading, 60)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .onChange(of: router.pending) { _, pending in
            guard let pending else { return }
            selectedTab = .home
            switch pending {
            case .post(let id, let autoplay):
                homePath = [.post(id: id, autoplay: autoplay, collectionID: nil, queue: nil, source: .channels)]
            case .creator(let id):
                homePath = [.creator(id: id)]
            }
            router.consume()
        }
        .fullScreenCover(isPresented: $pip.isRestoringFullScreen) {
            if let host = pip.host {
                RestoredPlayerView(host: host)
                    .ignoresSafeArea()
            }
        }
    }

    /// Pins the resolved launch tab, unless the user chose to resume the last
    /// one (in which case the selection already matches).
    private func resolveInitialTab() {
        guard !didResolveInitialTab else { return }
        didResolveInitialTab = true
        selectedTab = launchTab
    }

    /// Resolve the tab the app opens on, once: a tab pinned in Settings, or the
    /// persisted selection when the user chose "Last used".
    @MainActor
    private static func resolvedLaunchTab() -> Tab {
        switch ContentPreferences.shared.initialTab {
        case .home: .home
        case .creators: .creators
        case .search: .search
        case .lastUsed:
            Tab(rawValue: UserDefaults.standard.string(forKey: "selected_tab") ?? "") ?? .home
        }
    }

    /// Push the post and start playback immediately (remote Play button on a
    /// focused card). Appends so the back stack is preserved. `queue` is the
    /// ordered shelf the post was played from (Up Next follows it).
    private func playPost(
        id: String,
        collectionID: String?,
        queue: [String]? = nil,
        source: AutoplaySource
    ) {
        homePath.append(
            .post(id: id, autoplay: true, collectionID: collectionID, queue: queue, source: source)
        )
    }
}

/// NavigationDestination values are Codable + Hashable so NavigationStack can
/// persist them across launches.
enum DeepLinkDestination: Hashable, Codable {
    /// `queue` is the ordered list of playable post IDs from the shelf the post
    /// was opened from (left→right). Up Next follows it instead of the creator
    /// feed. Nil for deep links and non-shelf entry points.
    case post(id: String, autoplay: Bool, collectionID: String?, queue: [String]?, source: AutoplaySource)
    case creator(id: String)
    case collections(campaignID: String)
    case collectionSearch(campaignID: String, sort: CollectionSort)
    case collection(id: String, focusPostID: String?)
    case comments(postID: String, commentCount: Int?)
}

extension Array where Element == DeepLinkDestination {
    /// Push a collection and then its target episode, so backing out walks
    /// episode → post info → collection → the screen we came from.
    mutating func playCollection(collectionID: String, postID: String) {
        append(.collection(id: collectionID, focusPostID: postID))
        append(.post(id: postID, autoplay: true, collectionID: collectionID, queue: nil, source: .collections))
    }
}

/// Shared destination table. Every NavigationStack in the app registers this
/// so value-based links resolve identically in all tabs.
struct AppNavigationDestinations: ViewModifier {

    /// Supplied by each tab's stack so a Creator page can start playback within
    /// the *same* tab — it appends to that stack's path. Nil here means creator
    /// pages simply won't offer the remote-Play shortcut.
    var onPlayPost: ((String, String?) -> Void)? = nil
    /// Remote Play on a collection card. Args: collection, post.
    var onPlayCollection: ((String, String) -> Void)? = nil

    func body(content: Content) -> some View {
        content.navigationDestination(for: DeepLinkDestination.self) { dest in
            switch dest {
            case .post(let id, let autoplay, let collectionID, let queue, let source):
                PostDetailView(
                    postID: id,
                    autoplay: autoplay,
                    collectionID: collectionID,
                    queue: queue,
                    autoplaySource: source,
                    onPlayPost: onPlayPost
                )
            case .creator(let id):
                CreatorView(campaignID: id, membership: nil, onPlayPost: onPlayPost)
            case .collections(let campaignID):
                CollectionsView(campaignID: campaignID, onPlayCollection: onPlayCollection)
            case .collectionSearch(let campaignID, let sort):
                CollectionsSearchView(
                    campaignID: campaignID,
                    sort: sort,
                    onPlayCollection: onPlayCollection
                )
            case .collection(let id, let focusPostID):
                CollectionView(collectionID: id, focusPostID: focusPostID, onPlayPost: onPlayPost)
            case .comments(let postID, let commentCount):
                CommentsView(postID: postID, commentCount: commentCount)
            }
        }
    }
}

extension View {
    func appNavigationDestinations(
        onPlayPost: ((String, String?) -> Void)? = nil,
        onPlayCollection: ((String, String) -> Void)? = nil
    ) -> some View {
        modifier(AppNavigationDestinations(onPlayPost: onPlayPost, onPlayCollection: onPlayCollection))
    }
}
