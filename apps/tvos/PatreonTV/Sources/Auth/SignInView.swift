//
//  SignInView.swift
//  PatreonTV
//
//  Sign-in. The TV has no browser, so the Patreon `session_id` cookie has to
//  come from elsewhere. Default path: scan a QR code with a phone and paste the
//  cookie on a page served by the TV itself (PhonePairingServer). Fallback:
//  type/paste it on the TV. Either way the session is validated against
//  Patreon and stored in the Keychain.
//

import SwiftUI

struct SignInView: View {

    /// True when the stored session was rejected mid-use.
    var sessionExpired: Bool = false

    @Environment(AuthStore.self) private var auth
    @State private var sessionID = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    /// Phone pairing: QR code shown by default, manual entry on request.
    @State private var pairingServer: PhonePairingServer?
    @State private var pairingURL: URL?
    @State private var pairingAddress: String?
    @State private var pairingUnavailable = false
    @State private var pairingProgress = PairingProgress()
    @State private var showManualEntry = false

    private var parsedSessionID: String? {
        SessionIDParser.parse(sessionID)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.05, green: 0, blue: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 64) {
                    if showManualEntry {
                        instructions
                            .frame(maxWidth: 680, alignment: .leading)
                        form
                            .frame(maxWidth: 700, alignment: .leading)
                    } else {
                        pairingCard
                        pairingSteps
                            .frame(maxWidth: 760, alignment: .leading)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
                .frame(maxWidth: 1500)
            }
        }
        .task { await startPairing() }
        .onDisappear { pairingServer?.stop() }
        .onChange(of: showManualEntry) { _, manual in
            guard manual else { return }
            // Focusing the field brings up the iPhone/iPad keyboard prompt,
            // which is the practical way to paste a long cookie value.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                fieldFocused = true
            }
        }
    }

    // MARK: - Phone pairing (default)

    private var pairingCard: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(.white)
                if let pairingURL {
                    PairingQRCode(url: pairingURL)
                        .padding(28)
                        .accessibilityLabel(Text("Pairing QR code"))
                } else if pairingUnavailable {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 64))
                        Text("No network connection")
                            .font(.headline)
                    }
                    .foregroundStyle(.black.opacity(0.6))
                } else {
                    ProgressView().tint(.black)
                }
            }
            .frame(width: 460, height: 460)

            if let pairingURL {
                Label(pairingProgress.message, systemImage: pairingProgress.symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(pairingProgress.stage == .waiting ? 0.6 : 0.95))
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: pairingProgress.stage)
            }
        }
    }

    /// Typing the address on a computer: the code is what lets it in.
    @ViewBuilder
    private var computerPairing: some View {
        if let pairingAddress, let code = pairingProgress.code {
            VStack(alignment: .leading, spacing: 14) {
                Label("On a computer", systemImage: "laptopcomputer")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text("Open")
                        .foregroundStyle(.white.opacity(0.7))
                    Text(pairingAddress)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                }
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text("then enter the code")
                        .foregroundStyle(.white.opacity(0.7))
                    Text(Self.spaced(code))
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.easeInOut, value: code)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    /// "K7MQ2P" → "K7M Q2P", easier to read across a room.
    private static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private var pairingSteps: some View {
        VStack(alignment: .leading, spacing: 28) {
            Image("PTVWordmark")
                .resizable()
                .scaledToFit()
                .frame(height: 84)
                .accessibilityLabel("PatreonTV")

            if sessionExpired {
                expiredBanner
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in with your phone")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                Text("No typing with the remote: your phone sends the session to this TV over your Wi-Fi.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                step(1, "Scan the QR code with your phone's camera (same Wi-Fi as the TV).")
                step(2, "Paste your Patreon session_id cookie on the page that opens.")
                step(3, "Tap Send: this TV signs in by itself.")
            }

            computerPairing

            Text("The page comes from this Apple TV, not from the Internet, and the cookie is encrypted before it is sent.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showManualEntry = true
            } label: {
                Label("Enter it on the TV instead", systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
        }
    }

    private var expiredBanner: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Your Patreon session expired. Send a fresh session ID to reconnect this TV.")
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.title3.weight(.medium))
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func startPairing() async {
        guard pairingServer == nil else { return }
        let progress = pairingProgress
        let server = PhonePairingServer(onEvent: { event in
            Task { @MainActor in progress.advance(to: event) }
        }) { [auth] sessionID in
            do {
                try await auth.completeSignIn(sessionID: sessionID)
                return nil
            } catch let error as SignInError {
                switch error {
                case .invalidSession: return "invalid"
                case .rateLimited, .network: return "network"
                case .unexpected: return "failed"
                }
            } catch {
                return "failed"
            }
        }
        pairingServer = server
        if let endpoint = await server.start() {
            pairingURL = server.qrURL(for: endpoint)
            pairingAddress = endpoint.shortURL
            pairingProgress.code = endpoint.code
        } else {
            pairingUnavailable = true
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image("PTVWordmark")
                .resizable()
                .scaledToFit()
                .frame(height: 96)
                .accessibilityLabel("PatreonTV")

            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in with Patreon")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white)
                Text("Paste your Patreon session ID to connect this TV.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }

            VStack(alignment: .leading, spacing: 12) {
                step(1, "On a computer, open your browser.")
                step(2, "Open the developer tools with F12 (⌥⌘I on Mac).")
                step(3, "Sign in at patreon.com.")
                step(4, "In the developer tools, open Application (Chrome) or Storage (Firefox/Safari) → Cookies → https://www.patreon.com.")
                step(5, "Copy the value of the session_id cookie.")
                step(6, "Paste it below using your iPhone/iPad keyboard, or type it with the Siri Remote.")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("HttpOnly cookie: it only appears in a desktop browser's developer tools. Signing out of that browser also signs out this TV.")
                Text("Treat it like a password. Settings → Sign Out removes it from this TV.")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)

            Button {
                showManualEntry = false
            } label: {
                Label("Use my phone instead", systemImage: "qrcode")
            }
            .buttonStyle(.bordered)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            if sessionExpired {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Your Patreon session expired. Paste a fresh session ID to reconnect this TV.")
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.title3.weight(.medium))
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .combine)
            }

            Text("Session ID")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.7))

            TextField("Paste the session_id value", text: $sessionID)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .padding(20)
                .background(PatreonColors.cardSurface, in: RoundedRectangle(cornerRadius: 12))
                .focused($fieldFocused)
                .onSubmit { Task { await submit() } }

            if let errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(errorMessage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.body)
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
            }

            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 12) {
                    if isSigningIn {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isSigningIn ? L10n.string("Signing in…") : L10n.string("Continue"))
                }
                .font(.title3.weight(.semibold))
                .frame(minWidth: 280)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(PatreonColors.brand)
            .disabled(parsedSessionID == nil || isSigningIn)

            VStack(alignment: .leading, spacing: 8) {
                Text("PatreonTV is not affiliated with Patreon.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))

                cookieWarning
            }
            .padding(.top, 8)
        }
        .padding(36)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 24))
    }

    /// Shown once, under the affiliation note. The Keychain keeps the cookie
    /// safe on the Apple TV; everything before it lands there is on the user.
    private var cookieWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(cookieWarningColor)
            Text("Handle this cookie carefully. Copy it on your own computer — not a shared or public one — and paste it straight into the Apple TV. Never send it through email, chat or cloud notes: anyone who gets it can access your Patreon account. PatreonTV stores it securely in the tvOS Keychain, but the steps in between are up to you.")
                .foregroundStyle(cookieWarningColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private var cookieWarningColor: Color {
        Color(red: 1, green: 0.45, blue: 0.45)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 26, height: 26)
                .background(PatreonColors.brand.opacity(0.9), in: Circle())
                .foregroundStyle(.white)

            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() async {
        guard let id = parsedSessionID, !isSigningIn else { return }

        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            try await auth.completeSignIn(sessionID: id)
        } catch {
            errorMessage = error.localizedDescription
            fieldFocused = true
        }
    }
}

/// What the TV knows about the phone side, shown under the QR code. Lets the
/// user tell "my phone can't reach the TV" from "Patreon refused the cookie".
@Observable
@MainActor
final class PairingProgress {
    enum Stage { case waiting, pageOpened, verifying }

    private(set) var stage: Stage = .waiting
    /// Code to type on a computer; renewed by the server after wrong guesses.
    var code: String?

    func advance(to event: PhonePairingServer.Event) {
        switch event {
        case .pageOpened: if stage == .waiting { stage = .pageOpened }
        case .verifying: stage = .verifying
        case .codeChanged(let newCode): code = newCode
        }
    }

    var message: String {
        switch stage {
        case .waiting: L10n.string("Waiting for your phone or computer…")
        case .pageOpened: L10n.string("Page opened, waiting for the cookie")
        case .verifying: L10n.string("Checking with Patreon…")
        }
    }

    var symbol: String {
        switch stage {
        case .waiting: "iphone.radiowaves.left.and.right"
        case .pageOpened: "checkmark.circle.fill"
        case .verifying: "hourglass"
        }
    }
}
