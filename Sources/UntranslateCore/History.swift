import Foundation

/// What Untranslate remembers, in ~/Library/Application Support/Untranslate:
/// seen.txt (songs already handled, one persistent ID per line) and changes.tsv (every rename, for undo).
public enum History {
    public static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Untranslate")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var seenURL: URL { folder.appendingPathComponent("seen.txt") }
    public static var logURL: URL { folder.appendingPathComponent("changes.tsv") }

    public static func seen() -> Set<String> {
        Set((try? String(contentsOf: seenURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [])
    }

    public static func markSeen(_ pids: some Sequence<String>) {
        let all = seen().union(pids)
        try? all.sorted().joined(separator: "\n").write(to: seenURL, atomically: true, encoding: .utf8)
    }

    /// Appends applied changes. Tabs/newlines can't appear in the TSV, so they're escaped.
    public static func log(_ changes: [Change]) {
        let date = ISO8601DateFormatter().string(from: Date())
        let lines = changes.map { ([date, $0.pid, $0.field.rawValue, $0.old, $0.new].map(escape).joined(separator: "\t")) + "\n" }
        if !FileManager.default.fileExists(atPath: logURL.path) { try? "date\tpersistent_id\tfield\told\tnew\n".write(to: logURL, atomically: true, encoding: .utf8) }
        guard let h = try? FileHandle(forWritingTo: logURL) else { return }
        h.seekToEndOfFile()
        h.write(Data(lines.joined().utf8))
        try? h.close()
    }

    public static func logged() -> [Change] {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map { unescape(String($0)) }
            guard c.count == 5, let f = Field(rawValue: c[2]) else { return nil }
            return Change(pid: c[1], field: f, old: c[3], new: c[4])
        }
    }

    /// Artist renames made so far (old -> new), so new songs by the same artist match.
    public static func knownArtists() -> [String: String] {
        logged().filter { $0.field == .artist || $0.field == .albumArtist }.reduce(into: [:]) { $0[$1.old] = $1.new }
    }

    /// After an undo the old renames shouldn't steer new ones, so the log is set aside.
    public static func archiveLog() {
        let dest = folder.appendingPathComponent("changes-undone-\(Int(Date().timeIntervalSince1970)).tsv")
        try? FileManager.default.moveItem(at: logURL, to: dest)
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n") }
    static func unescape(_ s: String) -> String {
        var out = "", it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            out.append(n == "t" ? "\t" : n == "n" ? "\n" : n)
        }
        return out
    }
}
