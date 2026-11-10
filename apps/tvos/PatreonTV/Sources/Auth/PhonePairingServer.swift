//
//  PhonePairingServer.swift
//  PatreonTV
//
//  Phone ↔ Apple TV pairing over the local network, with no server in between.
//
//  While the sign-in screen is visible, the TV serves one small web page on the
//  LAN and shows its address as a QR code:
//
//      http://<tv-ip>:<port>/p/<token>#k=<one-time pad>
//
//  • <token> (128 random bits) is the only path the server answers. Anything
//    else gets a 404, so another device on the network can't find the form.
//  • The pad (128 random bytes) sits in the URL fragment, which browsers never
//    send over the network. The page XORs the session cookie with it before
//    POSTing, so even someone sniffing the Wi-Fi only sees random bytes
//    (one-time pad: each pairing screen draws a fresh one).
//  • The server stops as soon as a session is accepted, when the sign-in
//    screen goes away, after a few failed attempts, or after 10 minutes.
//
//  It's still cookie authentication — this only replaces typing the cookie
//  with the Siri Remote.
//

import Foundation
import Network
import Security
import os.log

final class PhonePairingServer: @unchecked Sendable {

    /// Verifies a session ID. Returns nil when accepted, or a message to show
    /// on the phone when rejected.
    typealias Handler = @Sendable (String) async -> String?

    /// The address to encode in the QR code.
    private(set) var pairingURL: URL?

    private let queue = DispatchQueue(label: "PatreonTV.PhonePairing")
    private let log = Logger(subsystem: "com.patreontv.PatreonTV", category: "Pairing")
    private let token = PhonePairingServer.randomBytes(16).base64URL
    private let pad = PhonePairingServer.randomBytes(128)
    private let handler: Handler

    private var listener: NWListener?
    private var attempts = 0
    private var finished = false

    static let maxAttempts = 5
    static let lifetime: TimeInterval = 600
    static let maxRequestSize = 16_384

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening and returns the pairing URL, or nil when the TV has no
    /// usable local network address (e.g. not connected).
    func start() async -> URL? {
        guard let address = Self.localIPv4Address() else {
            log.error("No local IPv4 address; phone pairing unavailable")
            return nil
        }

        let port: UInt16? = await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    let listener = try NWListener(using: parameters)
                    let once = ResumeOnce()
                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            if once.claim() { continuation.resume(returning: listener.port?.rawValue) }
                        case .failed(let error):
                            self?.log.error("Pairing listener failed: \(String(describing: error))")
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

        guard let port else { return nil }
        let url = URL(string: "http://\(address):\(port)/p/\(token)#k=\(pad.base64URL)")
        queue.sync { pairingURL = url }
        queue.asyncAfter(deadline: .now() + Self.lifetime) { [weak self] in self?.stopOnQueue() }
        return url
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func stopOnQueue() {
        finished = true
        listener?.cancel()
        listener = nil
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
        guard !finished, path == "/p/\(token)" else {
            return respond(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }

        switch request.method {
        case "GET":
            respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(PairingPage.html.utf8))
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

        // Body: hex(cookie XOR pad)
        let hex = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cipher = Data(hex: hex), !cipher.isEmpty, cipher.count <= pad.count else {
            return respondJSON(connection, ok: false, message: "bad_request")
        }
        let plain = Data(zip(cipher, pad).map { $0 ^ $1 })
        guard let raw = String(data: plain, encoding: .utf8), let sessionID = SessionIDParser.parse(raw) else {
            return respondJSON(connection, ok: false, message: "bad_request")
        }

        let handler = self.handler
        Task {
            let failure = await handler(sessionID)
            self.queue.async {
                if failure == nil {
                    self.log.info("Session received from phone and accepted")
                    self.respondJSON(connection, ok: true, message: nil)
                    // Let the response go out before closing the listener.
                    self.queue.asyncAfter(deadline: .now() + 1) { self.stopOnQueue() }
                } else {
                    self.respondJSON(connection, ok: false, message: failure)
                }
            }
        }
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

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
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

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
