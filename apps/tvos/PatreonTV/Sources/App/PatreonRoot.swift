//
//  PatreonRoot.swift
//  PatreonTV
//
//  The whole app as one view, so it can run standalone (PatreonTVApp) or be
//  embedded in a host app (e.g. a hub that bundles several tvOS apps).
//

import SwiftUI

public struct PatreonRoot: View {

    @State private var authStore = AuthStore()
    @State private var router = DeepLinkRouter()
    @State private var preferences = ContentPreferences.shared

    private let exitApp: (() -> Void)?

    /// - Parameter exitApp: called when Menu/Back is pressed at the app's top
    ///   level. Only set by a host app; standalone, tvOS returns to the Home Screen.
    public init(exitApp: (() -> Void)? = nil) {
        self.exitApp = exitApp
    }

    public var body: some View {
        content
            .environment(authStore)
            .environment(router)
            .environment(\.locale, preferences.language.locale)
            .environment(\.exitApp, exitApp)
            .onOpenURL { url in
                router.handle(url: url)
            }
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if GalleryConfig.isActive {
            // Storybook-style capture mode (see GalleryHostView / capture-screens.sh).
            GalleryHostView()
        } else {
            RootView().task { await authStore.restoreSession() }
        }
        #else
        RootView().task { await authStore.restoreSession() }
        #endif
    }
}

private struct ExitAppKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by a host app; see `PatreonRoot.init(exitApp:)`.
    var exitApp: (() -> Void)? {
        get { self[ExitAppKey.self] }
        set { self[ExitAppKey.self] = newValue }
    }
}
