//
//  HLSQualityLoader.swift
//  PatreonTV
//
//  Forces a video quality on HLS streams.
//
//  AVPlayer picks the variant itself (adaptive bitrate): it starts low and
//  climbs, and may settle below the best rendition. There's no API to *force*
//  a variant, and Mux's own `min_resolution` / `max_resolution` modifiers
//  can't be added to Patreon's URLs (they're signed; modifiers would have to be
//  in the token). So we rewrite the master playlist instead: the asset is
//  opened through a custom scheme, this loader fetches the real master,
//  keeps only the chosen variant, makes every URI absolute and hands it back.
//  Variant playlists and segments then load directly over HTTPS, untouched.
//
//  If anything is unexpected (not a master playlist, parse failure), the
//  original playlist is returned and AVPlayer behaves as before.
//

import AVFoundation
import Foundation
import os.log

final class HLSQualityLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    private static let schemes = ["https": "ptvhls-https", "http": "ptvhls-http"]
    private let log = Logger(subsystem: "com.patreontv.PatreonTV", category: "Quality")

    /// Highest variant height allowed; nil = the best one available.
    private let maxHeight: Int?
    private let headers: [String: String]

    init(maxHeight: Int?, headers: [String: String]) {
        self.maxHeight = maxHeight
        self.headers = headers
        super.init()
    }

    /// The URL to give AVURLAsset so requests for the master go through us.
    static func wrappedURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let custom = schemes[scheme]
        else { return nil }
        components.scheme = custom
        return components.url
    }

    private static func unwrappedURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let original = schemes.first(where: { $0.value == scheme })?.key
        else { return nil }
        components.scheme = original
        return components.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, let real = Self.unwrappedURL(for: url) else {
            return false
        }

        var request = URLRequest(url: real)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let maxHeight = self.maxHeight
        let log = self.log
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let text = String(data: data, encoding: .utf8)
            else {
                log.error("Master playlist fetch failed: \(String(describing: error))")
                loadingRequest.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }

            let playlist = HLSQualityLoader.pin(text, baseURL: http.url ?? real, maxHeight: maxHeight)
                ?? HLSQualityLoader.absolutize(text, baseURL: http.url ?? real)
            let body = Data(playlist.utf8)

            if let info = loadingRequest.contentInformationRequest {
                info.contentType = "application/vnd.apple.mpegurl"
                info.contentLength = Int64(body.count)
                info.isByteRangeAccessSupported = true
            }
            if let dataRequest = loadingRequest.dataRequest {
                let start = min(Int(dataRequest.requestedOffset), body.count)
                let end = dataRequest.requestsAllDataToEndOfResource
                    ? body.count
                    : min(body.count, start + dataRequest.requestedLength)
                if start < end { dataRequest.respond(with: body.subdata(in: start..<end)) }
            }
            loadingRequest.finishLoading()
        }
        task.resume()
        return true
    }

    // MARK: - Playlist rewriting

    /// Keeps a single variant of a master playlist: the highest-bandwidth one
    /// whose height is ≤ `maxHeight` (any height when nil; the smallest one if
    /// none fits). Returns nil when `text` isn't a master playlist.
    static func pin(_ text: String, baseURL: URL, maxHeight: Int?) -> String? {
        let lines = text.components(separatedBy: .newlines)

        struct Variant { let infIndex: Int; let uriIndex: Int; let bandwidth: Int; let height: Int? }
        var variants: [Variant] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard let uriIndex = lines[(index + 1)...].firstIndex(where: {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            }) else { continue }
            variants.append(Variant(
                infIndex: index,
                uriIndex: uriIndex,
                bandwidth: Int(attribute("BANDWIDTH", in: line) ?? "") ?? 0,
                height: attribute("RESOLUTION", in: line)
                    .flatMap { $0.split(separator: "x").last }
                    .flatMap { Int($0) }
            ))
        }
        guard !variants.isEmpty else { return nil }

        let eligible = variants.filter { variant in
            guard let maxHeight, let height = variant.height else { return true }
            return height <= maxHeight
        }
        let chosen = eligible.max { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }
            ?? variants.min { ($0.height ?? 0, $0.bandwidth) < ($1.height ?? 0, $1.bandwidth) }
        guard let chosen else { return nil }

        var dropped = Set<Int>()
        for variant in variants where variant.infIndex != chosen.infIndex {
            dropped.insert(variant.infIndex)
            dropped.insert(variant.uriIndex)
        }
        let kept = lines.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        return absolutize(kept.joined(separator: "\n"), baseURL: baseURL)
    }

    /// Makes every URI absolute (plain URI lines and URI="…" attributes), since
    /// the playlist is now served from a custom scheme.
    static func absolutize(_ text: String, baseURL: URL) -> String {
        text.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            if !trimmed.hasPrefix("#") {
                return URL(string: trimmed, relativeTo: baseURL)?.absoluteString ?? line
            }
            guard let range = line.range(of: #"URI="([^"]*)""#, options: .regularExpression) else { return line }
            let value = String(line[range].dropFirst(5).dropLast())
            guard let absolute = URL(string: value, relativeTo: baseURL)?.absoluteString else { return line }
            return line.replacingCharacters(in: range, with: "URI=\"\(absolute)\"")
        }
        .joined(separator: "\n")
    }

    /// Value of an attribute in an `#EXT-X-…:A=1,B="x"` tag line.
    private static func attribute(_ name: String, in line: String) -> String? {
        // Anchor on ":" or "," so BANDWIDTH doesn't match AVERAGE-BANDWIDTH.
        guard let range = line.range(of: "[:,]\(name)=", options: .regularExpression) else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            return rest.dropFirst().split(separator: "\"", maxSplits: 1).first.map(String.init)
        }
        return rest.split(separator: ",", maxSplits: 1).first.map(String.init)
    }
}
