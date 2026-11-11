//
//  SettingsView.swift
//  PatreonTV
//
//  App settings: language, mature content, autoplay, collections, launch tab,
//  comment order and sign out.
//

import NukeUI
import SwiftUI

struct SettingsView: View {

    @Environment(AuthStore.self) private var auth
    @State private var prefs = ContentPreferences.shared
    @State private var cacheSize: Int?
    @State private var isClearingCache = false
    @State private var freedBytes: Int?
    @State private var showClearCacheDialog = false
    @FocusState private var languageFocused: Bool
    @FocusState private var autoplayRowFocused: Bool
    @FocusState private var cacheRowFocused: Bool

    private let settingsControlWidth: CGFloat = 1100

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let third = max(0, proxy.size.width / 3)

                HStack(spacing: 0) {
                    profileColumn
                        .frame(
                            width: third,
                            height: proxy.size.height,
                            alignment: .center
                        )

                    ScrollView(.vertical, showsIndicators: false) {
                        optionsColumn
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    }
                    .frame(width: third * 2, height: proxy.size.height)
                }
                .background(PatreonColors.background.ignoresSafeArea())
            }
        }
        .task {
            cacheSize = await AppCache.size()
        }
    }

    @ViewBuilder
    private var profileColumn: some View {
        if let user = auth.currentUser {
            VStack(alignment: .center, spacing: 20) {
                avatar(for: user)

                VStack(alignment: .center, spacing: 6) {
                    Text(user.attributes.fullName ?? L10n.string("Signed in"))
                        .font(.title)
                        .foregroundStyle(PatreonColors.primaryText)
                        .multilineTextAlignment(.center)
                    if let email = user.attributes.email {
                        Text(email)
                            .foregroundStyle(PatreonColors.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                }

                versionFooter
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var optionsColumn: some View {
        @Bindable var prefs = prefs

        return VStack(alignment: .center, spacing: 28) {
            languageSection

            SettingsToggleRow(
                title: "Show mature content",
                detail: "Reveal creators and posts flagged as NSFW.",
                isOn: $prefs.showMatureContent
            )

            SettingsToggleRow(
                title: "Show Continue Collection",
                detail: "Show the collection you opened most recently on Home.",
                isOn: $prefs.showContinueCollection
            )

            SettingsToggleRow(
                title: "Oldest episodes first",
                detail: "Open a collection's episodes oldest-first; off lists newest first.",
                isOn: $prefs.collectionOldestFirst
            )

            SettingsToggleRow(
                title: "Series mode for collections",
                detail: "Play a collection from its oldest unfinished episode, even if you watched a newer one last.",
                isOn: $prefs.collectionSeriesMode
            )

            autoplayRow

            initialTabSection
            videoQualitySection
            commentOrderSection
            cacheRow
            signOutButton
        }
        .frame(width: settingsControlWidth, alignment: .center)
    }

    /// Cache size and a way to free it. Sits just above Sign Out; the
    /// destructive "and history" variant is behind the dialog.
    private var cacheRow: some View {
        Button {
            showClearCacheDialog = true
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clear cache")
                        .foregroundStyle(
                            cacheRowFocused ? Color.black : PatreonColors.primaryText
                        )
                    Text(cacheDetail)
                        .font(.caption)
                        .foregroundStyle(
                            cacheRowFocused
                                ? Color.black.opacity(0.7)
                                : PatreonColors.secondaryText
                        )
                }

                Spacer()

                if isClearingCache {
                    ProgressView()
                } else {
                    Text(cacheSizeText)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(
                            cacheRowFocused ? Color.black : PatreonColors.tertiaryText
                        )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .frame(width: settingsControlWidth)
        .focused($cacheRowFocused)
        .disabled(isClearingCache)
        .accessibilityLabel(Text(L10n.format("format.clearCacheAccessibility", cacheSizeText)))
        .confirmationDialog(
            "Clear cache?",
            isPresented: $showClearCacheDialog,
            titleVisibility: .visible
        ) {
            Button("Clear cache") {
                Task { await clearCache(history: false) }
            }
            Button("Clear cache and history", role: .destructive) {
                Task { await clearCache(history: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached images and posts are always removed. You can also delete your viewing history.")
        }
    }

    private var cacheDetail: String {
        if let freedBytes {
            return L10n.format("format.cacheFreed", byteText(freedBytes))
        }
        return L10n.string("Removes cached images and posts stored on this Apple TV.")
    }

    private var cacheSizeText: String {
        guard let cacheSize else { return L10n.string("Calculating…") }
        return byteText(cacheSize)
    }

    private func clearCache(history: Bool) async {
        guard !isClearingCache else { return }
        isClearingCache = true

        let freed = await AppCache.clear()
        if history {
            PlaybackProgressStore.shared.clearAll()
            RecentCollectionsStore.shared.clearAll()
        }

        cacheSize = await AppCache.size()
        isClearingCache = false
        freedBytes = freed

        try? await Task.sleep(for: .seconds(5))
        freedBytes = nil
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var signOutButton: some View {
        Button {
            Task { await auth.signOut() }
        } label: {
            Text("Sign Out")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 48)
                .padding(.vertical, 20)
        }
        .buttonStyle(.borderedProminent)
        .tint(PatreonColors.brand)
        .padding(.top, 8)
    }

    private var versionFooter: some View {
        Text("PatreonTV \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            .font(.footnote)
            .foregroundStyle(PatreonColors.tertiaryText)
            .padding(.top, 8)
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Language")
                .foregroundStyle(PatreonColors.primaryText)
            Text("The app language. Defaults to your Apple TV language.")
                .font(.caption)
                .foregroundStyle(PatreonColors.secondaryText)

            Menu {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        prefs.language = language
                    } label: {
                        if language == prefs.language {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }
            } label: {
                GeometryReader { proxy in
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .foregroundStyle(languageFocused ? Color.black : PatreonColors.primaryText)
                        MarqueeText(
                            text: prefs.language.displayName,
                            font: .body.weight(.medium),
                            color: languageFocused ? .black : PatreonColors.primaryText,
                            availableWidth: max(0, proxy.size.width - 70),
                            isActive: languageFocused
                        )
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 46)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .frame(width: settingsControlWidth)
            .focused($languageFocused)
            .accessibilityLabel(Text("Language"))
        }
        .frame(maxWidth: settingsControlWidth, alignment: .leading)
    }

    private var autoplayRow: some View {
        NavigationLink {
            AutoplaySettingsView()
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Autoplay next")
                        .foregroundStyle(
                            autoplayRowFocused ? Color.black : PatreonColors.primaryText
                        )
                    Text("Choose where playback advances to the next post automatically.")
                        .font(.caption)
                        .foregroundStyle(
                            autoplayRowFocused
                                ? Color.black.opacity(0.7)
                                : PatreonColors.secondaryText
                        )
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(
                        autoplayRowFocused ? Color.black : PatreonColors.tertiaryText
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .frame(width: settingsControlWidth)
        .focused($autoplayRowFocused)
    }

    private var initialTabSection: some View {
        @Bindable var prefs = prefs

        return VStack(alignment: .leading, spacing: 12) {
            Text("Initial tab")
                .foregroundStyle(PatreonColors.primaryText)
            Text("Which tab opens when PatreonTV launches.")
                .font(.caption)
                .foregroundStyle(PatreonColors.secondaryText)
            SettingsChoiceRow(
                options: ContentPreferences.InitialTab.allCases,
                label: { $0.title },
                selection: $prefs.initialTab
            )
        }
        .frame(maxWidth: settingsControlWidth, alignment: .leading)
    }

    private var videoQualitySection: some View {
        @Bindable var prefs = prefs

        return VStack(alignment: .leading, spacing: 12) {
            Text("Video quality")
                .foregroundStyle(PatreonColors.primaryText)
            Text("Maximum always plays the best version available. Automatic lets the player adapt to your connection.")
                .font(.caption)
                .foregroundStyle(PatreonColors.secondaryText)
            SettingsChoiceRow(
                options: ContentPreferences.VideoQuality.allCases,
                label: { $0.title },
                selection: $prefs.videoQuality
            )
        }
        .frame(maxWidth: settingsControlWidth, alignment: .leading)
    }

    private var commentOrderSection: some View {
        @Bindable var prefs = prefs

        return VStack(alignment: .leading, spacing: 12) {
            Text("Comment order")
                .foregroundStyle(PatreonColors.primaryText)
            Text("How a post's comments open. The comments screen can still reorder them for that visit.")
                .font(.caption)
                .foregroundStyle(PatreonColors.secondaryText)
            SettingsChoiceRow(
                options: CommentSort.allCases,
                label: { $0.title },
                selection: $prefs.commentSort
            )
        }
        .frame(maxWidth: settingsControlWidth, alignment: .leading)
    }

    private func avatar(for user: PatreonUser) -> some View {
        LazyImage(url: user.attributes.imageURL ?? user.attributes.thumbURL) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    PatreonColors.cardSurface
                    Image(systemName: "person.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(PatreonColors.tertiaryText)
                }
            }
        }
        .frame(width: 180, height: 180)
        .clipShape(Circle())
    }
}
