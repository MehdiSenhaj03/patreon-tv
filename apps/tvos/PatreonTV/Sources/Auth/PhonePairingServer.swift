//
//  PhonePairingServer.swift
//  PatreonTV
//
//  Phone/computer ↔ Apple TV pairing over the local network, with no server in
//  between.
//
//  While the sign-in screen is visible, the TV serves a small web page on the
//  LAN. Two ways in:
//
//  • Phone: scan the QR code → http://<tv-ip>:<port>/<CODE>#pk=<TV public key>
//  • Computer: type http://<tv-ip>:<port> and enter the code shown on the TV.
//
//  Security:
//  • The 6-character code (≈1 billion combinations) is the only path that gets
//    the form; wrong codes are counted and the code is renewed after a few.
//  • The page encrypts the cookie before sending it: X25519 key agreement with
//    the TV's key (TweetNaCl in the page, CryptoKit here), SHA-512 keystream,
//    and a MAC so a modified message is rejected. Someone sniffing the Wi-Fi
//    sees only random bytes.
//  • From the QR code, the page also checks that the key it was served matches
//    the one in the URL fragment (never sent over the network), which defeats
//    a device on the LAN impersonating the TV.
//  • The server stops once a session is accepted or the screen goes away.
//
//  It's still cookie authentication: this only replaces typing the cookie with
//  the Siri Remote.
//

import CryptoKit
import Foundation
import Network
import os.log

final class PhonePairingServer: @unchecked Sendable {

    /// Verifies a session ID. Returns nil when accepted, or an error code for
    /// the page ("invalid", "network", "failed") when rejected.
    typealias Handler = @Sendable (String) async -> String?

    /// Progress shown on the TV, so the user can tell whether the phone or
    /// computer reached it at all.
    enum Event: Sendable {
        case pageOpened
        case verifying
        case codeChanged(String)
    }
    typealias EventHandler = @Sendable (Event) -> Void

    struct Endpoint: Sendable {
        let address: String
        let port: UInt16
        let code: String

        /// What to type on a computer.
        var shortURL: String { "http://\(address):\(port)" }
    }

    private let queue = DispatchQueue(label: "PatreonTV.PhonePairing")
    private let log = Logger(subsystem: "com.patreontv.PatreonTV", category: "Pairing")
    private let key = Curve25519.KeyAgreement.PrivateKey()
    private let handler: Handler
    private let onEvent: EventHandler

    private var listener: NWListener?
    private var code = PhonePairingServer.makeCode()
    private var wrongCodes = 0
    private var attempts = 0
    private var finished = false

    static let maxAttempts = 5
    static let maxWrongCodes = 10
    /// Same port every time when free, so the address to type stays the same.
    static let preferredPort: UInt16 = 47800
    static let maxRequestSize = 16_384
    /// No 0/O, 1/I/L: easy to read on a TV and to type.
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    init(onEvent: @escaping EventHandler = { _ in }, handler: @escaping Handler) {
        self.onEvent = onEvent
        self.handler = handler
    }

    var publicKey: Data { key.publicKey.rawRepresentation }

    /// Starts listening. Returns nil when the TV has no usable local network
    /// address (e.g. not connected) or the listener can't start.
    func start() async -> Endpoint? {
        guard let address = Self.localIPv4Address() else {
            log.error("No local IPv4 address; phone pairing unavailable")
            return nil
        }
        var port = await listen(on: NWEndpoint.Port(rawValue: Self.preferredPort))
        if port == nil { port = await listen(on: nil) }
        guard let port else { return nil }
        let code = queue.sync { self.code }
        return Endpoint(address: address, port: port, code: code)
    }

    /// QR code target: the code plus the TV's public key in the fragment.
    func qrURL(for endpoint: Endpoint) -> URL? {
        URL(string: "\(endpoint.shortURL)/\(endpoint.code)#pk=\(publicKey.base64URL)")
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func stopOnQueue() {
        finished = true
        listener?.cancel()
        listener = nil
    }

    /// Starts the listener on `requested` (any free port when nil). Returns the
    /// bound port, or nil on failure.
    private func listen(on requested: NWEndpoint.Port?) async -> UInt16? {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    let listener = try requested.map { try NWListener(using: parameters, on: $0) }
                        ?? NWListener(using: parameters)
                    let once = ResumeOnce()
                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            if once.claim() { continuation.resume(returning: listener.port?.rawValue) }
                        case .failed(let error):
                            self?.log.error("Pairing listener failed: \(String(describing: error))")
                            listener.cancel()
                            if once.claim() { continuation.resume(returning: nil) }
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    self.log.error("Could not create pairing listener: \(String(describing: error))")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // Drop idle connections.
        queue.asyncAfter(deadline: .now() + 20) { connection.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > Self.maxRequestSize {
                return self.respond(connection, status: "413 Payload Too Large", type: "text/plain", body: Data())
            }
            if let request = HTTPRequest(buffer) {
                return self.handle(request, on: connection)
            }
            if isComplete || error != nil {
                return connection.cancel()
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path

        if finished {
            return respond(connection, status: "410 Gone", type: "text/html; charset=utf-8",
                           body: Data(PairingPage.codeEntry(state: .closed).utf8))
        }

        switch (request.method, path) {
        case ("GET", "/"):
            return respond(connection, status: "200 OK", type: "text/html; charset=utf-8",
                           body: Data(PairingPage.codeEntry(state: .initial).utf8))
        case ("GET", "/nacl.js"):
            return respond(connection, status: "200 OK", type: "text/javascript; charset=utf-8", body: Self.naclScript)
        case (_, "/favicon.ico"):
            return respond(connection, status: "404 Not Found", type: "text/plain", body: Data())
        default:
            break
        }

        // Everything else is /<CODE>.
        let candidate = Self.normalizeCode(String(path.dropFirst()))
        guard candidate == code else {
            wrongCodes += 1
            if wrongCodes >= Self.maxWrongCodes {
                wrongCodes = 0
                code = Self.makeCode()
                log.info("Too many wrong pairing codes; renewed the code")
                onEvent(.codeChanged(code))
            }
            return respond(connection, status: "404 Not Found", type: "text/html; charset=utf-8",
                           body: Data(PairingPage.codeEntry(state: .wrongCode).utf8))
        }

        switch request.method {
        case "GET":
            onEvent(.pageOpened)
            respond(connection, status: "200 OK", type: "text/html; charset=utf-8",
                    body: Data(PairingPage.form(publicKey: publicKey.base64EncodedString()).utf8))
        case "POST":
            receiveSession(request.body, on: connection)
        default:
            respond(connection, status: "405 Method Not Allowed", type: "text/plain", body: Data())
        }
    }

    private func receiveSession(_ body: Data, on connection: NWConnection) {
        attempts += 1
        guard attempts <= Self.maxAttempts else {
            stopOnQueue()
            return respondJSON(connection, ok: false, message: "too_many_attempts")
        }
        guard let raw = open(body), let sessionID = SessionIDParser.parse(raw) else {
            return respondJSON(connection, ok: false, message: "bad_request")
        }

        onEvent(.verifying)
        let handler = self.handler
        Task {
            let failure = await handler(sessionID)
            self.queue.async {
                if failure == nil {
                    self.log.info("Session received over the network and accepted")
                    self.respondJSON(connection, ok: true, message: nil)
                    // Let the response go out before closing the listener.
                    self.queue.asyncAfter(deadline: .now() + 1) { self.stopOnQueue() }
                } else {
                    self.respondJSON(connection, ok: false, message: failure)
                }
            }
        }
    }

    /// Decrypts `{"epk", "ct", "tag"}` (base64) sealed by the page. Mirrors
    /// `seal()` in PairingPage; returns nil if anything doesn't check out.
    private func open(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: String],
              let epk = object["epk"].flatMap({ Data(base64Encoded: $0) }),
              let ct = object["ct"].flatMap({ Data(base64Encoded: $0) }),
              let tag = object["tag"].flatMap({ Data(base64Encoded: $0) }),
              !ct.isEmpty, ct.count <= 4096,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk),
              let secret = try? key.sharedSecretFromKeyAgreement(with: peer)
        else { return nil }

        let shared = secret.withUnsafeBytes { Data($0) }
        func hash(_ parts: Data...) -> Data { Data(SHA512.hash(data: parts.reduce(Data(), +))) }

        let macKey = Data(hash(shared, Data("ptv-mac".utf8)).prefix(32))
        let expected = Data(hash(macKey, epk, ct).prefix(32))
        // Constant-time comparison.
        guard expected.count == tag.count, zip(expected, tag).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            log.error("Pairing message failed authentication")
            return nil
        }

        let cipher = [UInt8](ct)
        var plain = [UInt8]()
        plain.reserveCapacity(cipher.count)
        var block: UInt8 = 0
        while plain.count < cipher.count {
            let stream = [UInt8](hash(shared, Data("ptv-enc".utf8), Data([block])))
            for byte in stream where plain.count < cipher.count {
                plain.append(cipher[plain.count] ^ byte)
            }
            block &+= 1
        }
        return String(bytes: plain, encoding: .utf8)
    }

    private func respondJSON(_ connection: NWConnection, ok: Bool, message: String?) {
        var object: [String: Any] = ["ok": ok]
        if let message { object["message"] = message }
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        respond(connection, status: ok ? "200 OK" : "400 Bad Request", type: "application/json", body: body)
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Helpers

    /// TweetNaCl.js, shipped in the app bundle (see Resources/Pairing/README.md).
    private static let naclScript: Data = {
        guard let url = Bundle.main.url(forResource: "nacl-fast.min", withExtension: "js"),
              let data = try? Data(contentsOf: url)
        else { return Data("/* nacl missing */".utf8) }
        return data
    }()

    private static func makeCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// "k7m-q2p", "K7M Q2P" → "K7MQ2P"
    static func normalizeCode(_ raw: String) -> String {
        String((raw.removingPercentEncoding ?? raw).uppercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The TV's IPv4 address on Wi-Fi/Ethernet (en*), preferring private ranges.
    static func localIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(cString: entry.ifa_name)
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            candidates.append((name, address))
        }
        let isPrivate: (String) -> Bool = { $0.hasPrefix("192.168.") || $0.hasPrefix("10.") || $0.hasPrefix("172.") }
        return candidates.first { $0.name.hasPrefix("en") && isPrivate($0.address) }?.address
            ?? candidates.first { $0.name.hasPrefix("en") }?.address
            ?? candidates.first { isPrivate($0.address) }?.address
    }
}

/// Resumes a continuation at most once (listener state callbacks can repeat).
/// Only touched from the server's serial queue.
private final class ResumeOnce: @unchecked Sendable {
    private var done = false
    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}

/// Minimal HTTP/1.1 request parser: returns nil until the headers and the full
/// body (per Content-Length) have arrived.
private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    init?(_ data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }

        var length = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = separator.upperBound
        guard data.count - bodyStart >= length else { return nil }

        method = String(parts[0])
        path = String(parts[1])
        body = Data(data[bodyStart..<(bodyStart + length)])
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
