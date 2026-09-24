import Foundation

public struct Change: Hashable, Sendable {
    public var pid: String
    public var field: Field
    public var old: String
    public var new: String
    public init(pid: String, field: Field, old: String, new: String) {
        self.pid = pid; self.field = field; self.old = old; self.new = new
    }
}

/// How the HK, CN, JP and KR stores name songs, by catalog ID. The English stores translate Chinese,
/// Japanese and Korean names; HK/CN keep Chinese originals (HK in Traditional, CN in Simplified),
/// JP keeps Japanese ones and KR Korean ones.
public struct Answers: Sendable {
    public var hk: [UInt64: Listing] = [:], cn: [UInt64: Listing] = [:], jp: [UInt64: Listing] = [:], kr: [UInt64: Listing] = [:]
    public init() {}
}

public enum Planner {
    static let artistFields: [Field] = [.artist, .albumArtist]

    /// Original-language names for one song. `home` is true when they come from JP or KR (see below).
    public static func originals(current: [Field: String], hk: Listing?, cn: Listing?, jp: Listing?, kr: Listing?)
        -> (values: [Field: String], home: Bool)
    {
        func text(_ l: Listing?, _ f: Field) -> String { l?.values[f] ?? "" }
        let zhTitles = text(hk, .name) + text(cn, .name)
        // Japanese song: HK/CN show a romaji/English title but an Asian artist name, and JP's title has
        // hiragana or kanji. Katakana alone doesn't count: JP spells Western titles in katakana too.
        // ponytail: misses Japanese songs with katakana-only titles or Latin-named artists (they stay as-is).
        let japanese = text(jp, .name).hasHiraganaOrKanji && (text(hk, .artist) + text(cn, .artist)).hasCJK && !zhTitles.hasCJK
        // Korean song: every store but KR shows it in English; KR has the Hangul original.
        let korean = !japanese && (text(kr, .name) + text(kr, .album)).hasHangul && !zhTitles.hasCJK
        var out: [Field: String] = [:]
        for (f, cur) in current {
            let v = japanese ? jp?.values[f] : korean ? kr?.values[f] : original(cur, hk: hk?.values[f], cn: cn?.values[f], jp: jp?.values[f])
            if let v, worthChanging(cur, v) { out[f] = v }
        }
        return (out, japanese || korean)
    }

    /// Chinese-song rule for one field, or nil to leave `current`.
    /// If HK or CN shows `current` as-is, it isn't a translation. Otherwise take the majority, which keeps
    /// each song's own script. Ties go to HK, then CN (JP writes Western artists in katakana).
    static func original(_ current: String, hk: String?, cn: String?, jp: String?) -> String? {
        if current == hk || current == cn { return nil }
        let best = mostCommon([hk, cn, jp].compactMap { $0 }.filter { !$0.isEmpty })
        return best == current ? nil : best
    }

    /// Only undo translations into CJK. A name already written in CJK with no Latin letters is original
    /// (逢いたくていま), while digit-only ones like 831 are English-store names (八三夭). Never just swap
    /// Simplified and Traditional.
    static func worthChanging(_ current: String, _ new: String) -> Bool {
        let alreadyOriginal = current.hasCJK && !current.hasLatinLetter
        guard new != current, new.hasCJK, !alreadyOriginal else { return false }
        let a = Array(new.unicodeScalars), b = Array(current.unicodeScalars)
        return !(a.count == b.count && zip(a, b).allSatisfy { $0 == $1 || ($0.isCJK && $1.isCJK) })
    }

    /// Every rename worth making. `knownArtists` (old -> new, from earlier runs) keeps artist names consistent.
    public static func plan(_ tracks: [Track], _ a: Answers, knownArtists: [String: String] = [:]) -> [Change] {
        var changes: [Change] = [], cjkArtists = Set<String>()
        var votes: [String: (home: [String], rest: [String])] = [:]
        for t in tracks where t.genre != "Classical" {  // works get retitled in every market's language
            let id = t.catalogID
            let (new, home) = originals(current: t.values, hk: a.hk[id], cn: a.cn[id], jp: a.jp[id], kr: a.kr[id])
            for f in [Field.name, .album] { if let v = new[f], let cur = t.values[f] { changes.append(Change(pid: t.pid, field: f, old: cur, new: v)) } }
            if ((new[.name] ?? t.values[.name] ?? "") + (new[.album] ?? t.values[.album] ?? "")).hasCJK {
                for f in artistFields { if let cur = t.values[f] { cjkArtists.insert(cur) } }
            }
            for f in artistFields { if let v = new[f], let cur = t.values[f] {
                if home { votes[cur, default: ([], [])].home.append(v) } else { votes[cur, default: ([], [])].rest.append(v) }
            } }
        }
        // One spelling per artist so they don't split in two (JP's/KR's if they have Japanese/Korean songs:
        // HK calls sakanaction 魚韻 and BTS 防彈少年團), and only for artists with CJK songs: HK also renames
        // Maroon 5 魔力紅樂團. "Various Artists" is a label, not an artist (HK calls every compilation 群星).
        var renamed = knownArtists
        for (cur, v) in votes where renamed[cur] == nil && cjkArtists.contains(cur) && cur != "Various Artists" {
            renamed[cur] = mostCommon(v.home.isEmpty ? v.rest : v.home)
        }
        for t in tracks { for f in artistFields {
            if let cur = t.values[f], let v = renamed[cur], v != cur { changes.append(Change(pid: t.pid, field: f, old: cur, new: v)) }
        } }
        return changes
    }

    /// Most frequent value; ties go to whichever came first.
    public static func mostCommon(_ xs: [String]) -> String? {
        var counts: [String: Int] = [:]
        for x in xs { counts[x, default: 0] += 1 }
        return xs.max { counts[$0]! < counts[$1]! || (counts[$0]! == counts[$1]! && xs.firstIndex(of: $0)! > xs.firstIndex(of: $1)!) }
    }
}

extension Unicode.Scalar {
    var isCJK: Bool {  // kana, hanzi/kanji, hangul
        switch value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF66...0xFF9F: return true
        default: return false
        }
    }
}

extension Unicode.Scalar {
    var isLatinLetter: Bool {  // A–Z, a–z and accented Latin (é, ō, ü…)
        switch value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF: return true
        default: return false
        }
    }
}

extension String {
    var hasCJK: Bool { unicodeScalars.contains { $0.isCJK } }
    var hasLatinLetter: Bool { unicodeScalars.contains { $0.isLatinLetter } }
    var hasHiraganaOrKanji: Bool { unicodeScalars.contains { (0x3040...0x309F).contains($0.value) || (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) } }
    var hasHangul: Bool { unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) } }
}
