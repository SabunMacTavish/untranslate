import Foundation

public enum MusicAppError: LocalizedError {
    case script(String)
    public var errorDescription: String? {
        switch self {
        case .script(let msg) where msg.contains("-1743"):
            return "Untranslate isn't allowed to control Music. Turn it on in System Settings > Privacy & Security > Automation."
        case .script(let msg): return "Music didn't accept the change: \(msg)"
        }
    }
}

/// Talks to the Music app through AppleScript (osascript), which is how it renames songs.
public enum MusicApp {
    public struct Result: Sendable { public var done = 0; public var skipped: [String] = [] }

    /// Renames songs (library and playlist-only ones). A field only changes if it still has `old`,
    /// so edits made since the preview are never overwritten.
    public static func apply(_ changes: [Change], progress: ((Int) -> Void)? = nil) throws -> Result {
        var result = Result()
        for start in stride(from: 0, to: changes.count, by: 400) {
            let batch = changes[start..<min(start + 400, changes.count)].map { [$0.pid, $0.field.rawValue, $0.old, $0.new] }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: batch), as: UTF8.self)
            let out = try osascript(["-l", "JavaScript", "-e", renameJXA, json])
            let r = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] ?? [:]
            result.done += r["done"] as? Int ?? 0
            result.skipped += r["skipped"] as? [String] ?? []
            progress?(min(start + 400, changes.count))
        }
        return result
    }

    /// Music gives songs renamed at different times separate albums with the same name. Moving all of an
    /// album's library songs to a temporary name and back, one command each, puts them in one album again.
    public static func mergeAlbum(album: String, albumArtist: String) throws {
        _ = try osascript(["-e", mergeAppleScript, album, albumArtist])
    }

    static func osascript(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw MusicAppError.script(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }

    static let renameJXA = """
    function run(argv) {
      const rows = JSON.parse(argv[0]);  // [persistent id, property, from, to]
      const music = Application("Music"), where = {};  // persistent id -> [playlist, track id]
      for (const p of [music.libraryPlaylists[0], ...music.userPlaylists()]) {  // playlist-only songs too
        const tids = p.tracks.id();
        p.tracks.persistentID().forEach((pid, i) => { if (!(pid in where)) where[pid] = [p, tids[i]]; });
      }
      const out = {done: 0, skipped: []};
      for (const [pid, prop, from, to] of rows) {
        if (!(pid in where)) { out.skipped.push(`${pid}: no longer in Music`); continue; }
        const t = where[pid][0].tracks.byId(where[pid][1]);
        const now = t[prop]();
        if (now === to) continue;
        if (now !== from) { out.skipped.push(`${pid} ${prop}: is now "${now}", leaving it`); continue; }
        try { t[prop] = to; out.done++; } catch (e) { out.skipped.push(`${pid} ${prop}: ${e}`); }
      }
      return JSON.stringify(out);
    }
    """

    static let mergeAppleScript = """
    on run {theAlbum, theArtist}
      tell application "Music"
        set L to library playlist 1
        set tmp to theAlbum & " (merging)"
        set album of (every track of L whose album is theAlbum and album artist is theArtist) to tmp
        set album of (every track of L whose album is tmp and album artist is theArtist) to theAlbum
      end tell
    end run
    """
}
