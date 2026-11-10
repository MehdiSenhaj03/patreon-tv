//
//  PatreonTVApp.swift
//  PatreonTV
//
//  App entry point. The app itself lives in PatreonRoot so it can also be
//  embedded in a host app.
//

import SwiftUI

@main
struct PatreonTVApp: App {
    var body: some Scene {
        WindowGroup {
            PatreonRoot()
        }
    }
}
