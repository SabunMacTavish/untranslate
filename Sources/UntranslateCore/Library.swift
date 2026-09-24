import CommonCrypto
import Foundation

/// Song properties Untranslate can rename. Raw values are the Music app's scripting names.
public enum Field: String, CaseIterable, Codable, Sendable {
    case name, album, artist, albumArtist
}

public struct Track: Hashable, Sendable {
    public var pid: String            // persistent ID, as Music's AppleScript prints it
    public var catalogID: UInt64      // Apple Music catalog ID, 0 for songs not from Apple Music
    public var albumID: UInt64 = 0    // catalog ID of its album
    public var values: [Field: String]
    public var genre: String?

    public init(pid: String, catalogID: UInt64, albumID: UInt64 = 0, values: [Field: String], genre: String? = nil) {
        self.pid = pid; self.catalogID = catalogID; self.albumID = albumID; self.values = values; self.genre = genre
    }
}

public enum LibraryError: LocalizedError {
    case notFound(URL)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let url): return "Couldn't find the Music library at \(url.path)."
        case .unsupported(let what): return "This version of Music stores its library in a way this app doesn't understand yet (\(what))."
        }
    }
}

/// Reads Music's own library file. The format is undocumented; the layout here was found by inspection
/// (Music 1.7, macOS 27) and every step checks it, so a different layout fails instead of guessing.
public enum MusicLibrary {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Music/Music Library.musiclibrary/Library.musicdb")
    }

    public static func read(_ url: URL = defaultURL) throws -> [Track] {
        guard let data = try? Data(contentsOf: url) else { throw LibraryError.notFound(url) }
        return try parse(decode([UInt8](data)))
    }

    /// 'hfma' header, then a zlib stream whose first `cryptLen` bytes are AES-128-ECB encrypted
    /// with the long-known iTunes/Music library key.
    static func decode(_ d: [UInt8]) throws -> [UInt8] {
        let r = Reader(d)
        let headerLen = try r.u32(4)
        guard try r.tag(0) == "hfma", headerLen <= d.count else { throw LibraryError.unsupported("header") }
        let body = Array(d[headerLen...])
        let n = min(try r.u32(0x54), body.count) / 16 * 16
        return try inflate(aesDecrypt(Array(body[..<n])) + body[n...])
    }

    static func parse(_ raw: [UInt8]) throws -> [Track] {
        let r = Reader(raw)
        var i = 0
        while try r.u32(i + 12) != 1 {  // 'hsma' sections; kind 1 is the track list
            guard try r.tag(i) == "hsma" else { throw LibraryError.unsupported("sections") }
            i += try r.u32(i + 16)
        }
        guard try r.tag(i) == "hsma" else { throw LibraryError.unsupported("sections") }
        i += try r.u32(i + 4)
        guard try r.tag(i) == "ltma" else { throw LibraryError.unsupported("track list") }
        let count = try r.u32(i + 8)
        i += try r.u32(i + 4)

        var tracks: [Track] = []
        tracks.reserveCapacity(count)
        for _ in 0..<count {
            guard try r.tag(i) == "itma" else { throw LibraryError.unsupported("track") }
            let headerLen = try r.u32(i + 4), size = try r.u32(i + 8), records = try r.u32(i + 12)
            var track = Track(pid: String(format: "%016llX", try r.u64(i + 16)), catalogID: 0, values: [:])
            var j = i + headerLen
            for _ in 0..<records {  // 'boma' records: strings, and kind 1 holds the catalog IDs
                let len = try r.u32(j + 8), kind = try r.u32(j + 12)
                guard try r.tag(j) == "boma", len >= 16 else { throw LibraryError.unsupported("track record") }
                switch kind {
                case 1: (track.catalogID, track.albumID) = (try r.u64(j + 324), try r.u64(j + 180))
                case 2, 3, 4, 5, 0x1B:
                    let s = try r.string(j)
                    switch kind {
                    case 2: track.values[.name] = s
                    case 3: track.values[.album] = s
                    case 4: track.values[.artist] = s
                    case 0x1B: track.values[.albumArtist] = s
                    default: track.genre = s
                    }
                default: break
                }
                j += len
            }
            tracks.append(track)
            i += size
        }
        return tracks
    }

    static func aesDecrypt(_ input: [UInt8]) throws -> [UInt8] {
        let key = Array("BHUILuilfghuila3".utf8)
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, input, input.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw LibraryError.unsupported("encryption") }
        return out
    }

    /// zlib stream -> bytes. Apple's .zlib is raw DEFLATE, so skip the 2-byte zlib header.
    static func inflate(_ z: [UInt8]) throws -> [UInt8] {
        guard z.count > 2, z[0] & 0x0F == 8,
              let out = try? (Data(z[2...]) as NSData).decompressed(using: .zlib) as Data
        else { throw LibraryError.unsupported("compression") }
        return [UInt8](out)
    }
}

/// Bounds-checked little-endian reads, so a malformed file throws instead of crashing.
struct Reader {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }

    func check(_ o: Int, _ n: Int) throws { guard o >= 0, o + n <= b.count else { throw LibraryError.unsupported("truncated") } }
    func u32(_ o: Int) throws -> Int {
        try check(o, 4)
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }
    func u64(_ o: Int) throws -> UInt64 {
        try check(o, 8)
        return (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * $1) }
    }
    func tag(_ o: Int) throws -> String {
        try check(o, 4)
        return String(decoding: b[o..<o + 4], as: UTF8.self)
    }
    /// String record: encoding at +20 (1 = UTF-16LE, else UTF-8), byte length at +24, text at +36.
    func string(_ o: Int) throws -> String {
        let enc = try u32(o + 20), n = try u32(o + 24)
        try check(o + 36, n)
        guard let s = String(data: Data(b[(o + 36)..<(o + 36 + n)]), encoding: enc == 1 ? .utf16LittleEndian : .utf8)
        else { throw LibraryError.unsupported("text") }
        return s
    }
}
