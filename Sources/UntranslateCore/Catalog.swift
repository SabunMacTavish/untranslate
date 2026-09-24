import Foundation

/// How one Apple Music store names a song.
public struct Listing: Hashable, Sendable {
    public var values: [Field: String]
    public var collectionID: UInt64
    public var artwork: URL?  // 100x100 cover
    public init(values: [Field: String], collectionID: UInt64, artwork: URL? = nil) {
        self.values = values; self.collectionID = collectionID; self.artwork = artwork
    }
}

public enum CatalogError: LocalizedError {
    case unavailable
    public var errorDescription: String? { "Apple's music catalog isn't answering right now. Try again in a minute." }
}

/// Apple's public iTunes Search/Lookup API. It allows roughly 20 requests a minute, so requests draw from a
/// token bucket: a search's handful of requests goes out at once, a whole-library scan gets paced.
public actor Catalog {
    public static let shared = Catalog()

    private var tokens = 10.0
    private var refilled = Date()
    private var cache: [String: [UInt64: Listing?]] = [:]  // store -> id -> listing (nil: store doesn't carry it)

    /// How `store` ("hk", "jp", ...) names each ID; IDs the store doesn't carry are left out.
    public func lookup(_ ids: [UInt64], store: String, progress: (@Sendable (Int) -> Void)? = nil) async throws -> [UInt64: Listing] {
        var known = cache[store, default: [:]]
        let missing = Array(Set(ids.filter { known[$0] == nil }))
        for start in stride(from: 0, to: missing.count, by: 150) {
            let batch = missing[start..<min(start + 150, missing.count)]
            let url = URL(string: "https://itunes.apple.com/lookup?country=\(store)&id=" + batch.map(String.init).joined(separator: ","))!
            var found: [UInt64: Listing] = [:]
            for x in try await fetch(url) { if let (id, l) = Self.listing(x) { found[id] = l } }
            for id in batch { known[id] = .some(found[id]) }
            cache[store] = known
            progress?(min(start + 150, missing.count))
        }
        return ids.reduce(into: [:]) { out, id in if let l = known[id] ?? nil { out[id] = l } }
    }

    /// Song search in one store, best matches first.
    public func search(_ term: String, store: String, limit: Int = 25) async throws -> [(UInt64, Listing)] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: term), .init(name: "country", value: store),
                        .init(name: "entity", value: "song"), .init(name: "limit", value: String(limit))]
        return try await fetch(c.url!).compactMap(Self.listing)
    }

    private func fetch(_ url: URL) async throws -> [[String: Any]] {
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(20 * attempt) * 1_000_000_000) }  // throttled: back off
            try await takeToken()
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { continue }
            return results
        }
        throw CatalogError.unavailable
    }

    private func takeToken() async throws {
        let perSecond = 1.0 / 3.2, capacity = 10.0  // ponytail: fixed pacing; tune if Apple changes the limit
        tokens = min(capacity, tokens + Date().timeIntervalSince(refilled) * perSecond)
        refilled = Date()
        if tokens < 1 {
            try await Task.sleep(nanoseconds: UInt64((1 - tokens) / perSecond * 1_000_000_000))
            tokens = 1
            refilled = Date()
        }
        tokens -= 1
    }

    static func listing(_ x: [String: Any]) -> (UInt64, Listing)? {
        guard x["wrapperType"] as? String == "track", let id = (x["trackId"] as? NSNumber)?.uint64Value else { return nil }
        let artist = x["artistName"] as? String
        var v: [Field: String] = [:]
        v[.name] = x["trackName"] as? String
        v[.album] = x["collectionName"] as? String
        v[.artist] = artist
        v[.albumArtist] = x["collectionArtistName"] as? String ?? artist
        return (id, Listing(values: v, collectionID: (x["collectionId"] as? NSNumber)?.uint64Value ?? 0,
                            artwork: (x["artworkUrl100"] as? String).flatMap(URL.init(string:))))
    }
}
