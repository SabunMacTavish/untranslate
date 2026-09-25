import Foundation

/// The whole job, used by the app window, auto mode and the command-line checks.
public enum Untranslator {
    public static let stores = ["hk", "cn", "jp", "kr"]

    /// Asks the four stores about every song and returns the renames worth making.
    public static func scan(_ tracks: [Track], fields: Set<Field> = Set(Field.allCases),
                            knownArtists: [String: String] = History.knownArtists(),
                            progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [Change] {
        let ids = Array(Set(tracks.map(\.catalogID).filter { $0 != 0 }))
        var a = Answers()
        for store in stores {
            let found = try await Catalog.shared.lookup(ids, store: store) { done in
                progress("Asking Apple's \(store.uppercased()) store… \(done) of \(ids.count) songs")
            }
            switch store { case "hk": a.hk = found; case "cn": a.cn = found; case "jp": a.jp = found; default: a.kr = found }
        }
        progress("Checking which songs are in your library…")
        let inLibrary = try MusicApp.librarySongs()
        return Planner.plan(tracks, a, knownArtists: knownArtists, inLibrary: inLibrary).filter { fields.contains($0.field) }
    }

    /// The song IDs come from an undocumented file. Before trusting them, check a sample against Apple's
    /// catalog: the album each ID belongs to should match the album ID stored next to it.
    public static func verifyIDs(_ tracks: [Track], storefront: String) async throws {
        let sample = Array(tracks.filter { $0.catalogID != 0 }.shuffled().prefix(100))
        guard !sample.isEmpty else { return }
        let found = try await Catalog.shared.lookup(sample.map(\.catalogID), store: storefront)
        let matches = sample.filter { t in found[t.catalogID]?.collectionID == t.albumID }.count
        guard found.count * 2 >= sample.count, matches * 2 >= found.count else {
            throw LibraryError.unsupported("song IDs don't match Apple's catalog")
        }
    }

    /// Renames in Music, re-merges albums that could have split, and logs everything for undo.
    public static func apply(_ changes: [Change], tracks: [Track], progress: ((String) -> Void)? = nil) throws -> MusicApp.Result {
        History.log(changes)
        var result = try MusicApp.apply(changes) { progress?("Renaming… \($0) of \(changes.count)") }
        for (album, artist) in albumsToMerge(changes, tracks: tracks) {
            progress?("Tidying album \(album)…")
            do { try MusicApp.mergeAlbum(album: album, albumArtist: artist) } catch { result.skipped.append("album \(album): \(error.localizedDescription)") }
        }
        return result
    }

    /// Albums that now mix songs renamed in this run with songs that already had the name (a new song
    /// added to an album renamed earlier). Music would show those as two albums. Groups that span
    /// several catalog albums are left alone so merging never joins two different releases.
    public static func albumsToMerge(_ changes: [Change], tracks: [Track]) -> [(String, String)] {
        var final: [String: [Field: String]] = [:]
        for c in changes where c.field == .album || c.field == .albumArtist { final[c.pid, default: [:]][c.field] = c.new }
        func key(_ t: Track) -> String? {
            guard let album = final[t.pid]?[.album] ?? t.values[.album], let artist = final[t.pid]?[.albumArtist] ?? t.values[.albumArtist] else { return nil }
            return album + "\u{1}" + artist
        }
        let touched = Set(tracks.filter { final[$0.pid] != nil }.compactMap(key))
        var groups: [String: [Track]] = [:]
        for t in tracks { if let k = key(t), touched.contains(k) { groups[k, default: []].append(t) } }
        return groups.filter { _, ts in ts.contains { final[$0.pid] == nil } && Set(ts.map(\.albumID)).count == 1 }
            .keys.sorted().map { k in let p = k.split(separator: "\u{1}", omittingEmptySubsequences: false); return (String(p[0]), String(p[1])) }
    }

    /// Auto mode: rename only songs not seen before. The first run just remembers what's there.
    public static func renameNewSongs(fields: Set<Field>) async throws -> Int {
        let tracks = try MusicLibrary.read()
        let seen = History.seen()
        guard !seen.isEmpty else { History.markSeen(tracks.map(\.pid)); return 0 }
        let new = tracks.filter { !seen.contains($0.pid) }
        guard !new.isEmpty else { return 0 }
        let changes = try await scan(new, fields: fields)
        let done = changes.isEmpty ? 0 : try apply(changes, tracks: tracks).done
        History.markSeen(new.map(\.pid))
        return done
    }

    /// Puts back every logged rename, newest first, where the name hasn't been changed since.
    public static func undoAll() throws -> MusicApp.Result {
        let reverted = History.logged().reversed().map { Change(pid: $0.pid, field: $0.field, old: $0.new, new: $0.old) }
        let result = try MusicApp.apply(Array(reverted))
        History.archiveLog()
        return result
    }

    // MARK: Search

    public struct Hit: Identifiable, Hashable, Sendable {
        public var id: UInt64
        public var name: String, artist: String, album: String
        public var collectionID: UInt64
        public var url: URL
        public var artwork: URL?
    }

    /// Searches the user's own store (it also matches original-language queries) and shows the results
    /// with the same original names the library gets.
    public static func search(_ term: String, storefront: String) async throws -> [Hit] {
        let results = try await Catalog.shared.search(term, store: storefront)
        let ids = results.map(\.0)
        var a = Answers()
        a.hk = try await Catalog.shared.lookup(ids, store: "hk")
        a.cn = try await Catalog.shared.lookup(ids, store: "cn")
        a.jp = try await Catalog.shared.lookup(ids, store: "jp")
        a.kr = try await Catalog.shared.lookup(ids, store: "kr")
        var hits = results.map { id, l in
            let o = Planner.originals(current: l.values, hk: a.hk[id], cn: a.cn[id], jp: a.jp[id], kr: a.kr[id]).values
            let name = o[.name] ?? l.values[.name] ?? "", album = o[.album] ?? l.values[.album] ?? ""
            let english = l.values[.artist] ?? ""
            // Same idea as the artist rule: only use an original artist name for a CJK song.
            let artist = (name + album).hasCJK ? o[.artist] ?? english : english
            return (english, Hit(id: id, name: name, artist: artist, album: album, collectionID: l.collectionID,
                                 url: URL(string: "music://music.apple.com/\(storefront)/album/\(l.collectionID)?i=\(id)")!,
                                 artwork: l.artwork))
        }
        // One spelling per artist, preferring what earlier renames used.
        let known = History.knownArtists()
        var spelling: [String: [String]] = [:]
        for (english, h) in hits where h.artist != english { spelling[english, default: []].append(h.artist) }
        for i in hits.indices {
            let english = hits[i].0
            if let s = known[english] ?? Planner.mostCommon(spelling[english] ?? []) { hits[i].1.artist = s }
        }
        return hits.map(\.1)
    }
}
