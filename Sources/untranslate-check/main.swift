import CommonCrypto
import Foundation
import UntranslateCore

// Dev checks:
//   untranslate-check                          self-test (no network, no Music)
//   untranslate-check dump [Library.musicdb]   every song as TSV
//   untranslate-check parity <musicdb> <stores.json>   plan rows for given store answers
//   untranslate-check search <term> [store]    live search
//   untranslate-check verify                   check this Mac's library IDs against Apple's catalog
//   untranslate-check preview [store]          what a full scan would rename (read-only, ~6 min)

func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { print("FAIL line \(line): \(what)"); exit(1) }
}

func listing(_ name: String, _ album: String, _ artist: String) -> Listing {
    Listing(values: [.name: name, .album: album, .artist: artist, .albumArtist: artist], collectionID: 0)
}

func track(_ id: UInt64, _ name: String, _ album: String, _ artist: String, genre: String = "Pop", albumID: UInt64 = 0) -> Track {
    Track(pid: String(id), catalogID: id, albumID: albumID == 0 ? id : albumID,
          values: [.name: name, .album: album, .artist: artist, .albumArtist: artist], genre: genre)
}

func rows(_ cs: [Change]) -> Set<String> { Set(cs.map { "\($0.pid) \($0.field.rawValue) \($0.old) -> \($0.new)" }) }

/// A tiny Library.musicdb built the way Music writes one: header, then zlib data, first 32 bytes encrypted.
func fakeLibrary(pid: UInt64, catalogID: UInt64, name: String, album: String, artist: String) throws -> Data {
    func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    func text(_ kind: Int, _ s: String) -> [UInt8] {
        let b = [UInt8](s.data(using: .utf16LittleEndian)!)
        return Array("boma".utf8) + le32(20) + le32(36 + b.count) + le32(kind) + le32(0) + le32(1) + le32(b.count) + le32(0) + le32(0) + b
    }
    var ids = Array("boma".utf8) + le32(20) + le32(384) + le32(1) + [UInt8](repeating: 0, count: 368)
    ids.replaceSubrange(324..<332, with: le64(catalogID))
    let recs = [text(2, name), text(3, album), text(4, artist), text(0x1B, artist), ids]
    let itma = Array("itma".utf8) + le32(24) + le32(24 + recs.map(\.count).reduce(0, +)) + le32(recs.count) + le64(pid) + recs.flatMap { $0 }
    let ltma = Array("ltma".utf8) + le32(12) + le32(1)
    let other = Array("hsma".utf8) + le32(20) + le32(0) + le32(3) + le32(20)  // an unrelated section first
    let section = Array("hsma".utf8) + le32(20) + le32(0) + le32(1) + le32(20 + ltma.count + itma.count) + ltma + itma
    let z = [0x78, 0x9C] + [UInt8](try (Data(other + section) as NSData).compressed(using: .zlib) as Data)
    let key = Array("BHUILuilfghuila3".utf8)
    var enc = [UInt8](repeating: 0, count: 32), moved = 0
    _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, 16, nil, Array(z[..<32]), 32, &enc, 32, &moved)
    var header = Array("hfma".utf8) + le32(160) + le32(160 + z.count) + [UInt8](repeating: 0, count: 148)
    header.replaceSubrange(0x54..<0x58, with: le32(32))
    return Data(header + enc + z[32...])
}

func selfTest() throws {
    // Reading a library file.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("untranslate-test.musicdb")
    try fakeLibrary(pid: 0x24D6BFEFAF4EAFB0, catalogID: 1721464906, name: "Sunny Day", album: "Yeh, Hwei-Mei", artist: "Jay Chou").write(to: url)
    let read = try MusicLibrary.read(url)
    expect(read.count == 1 && read[0].pid == "24D6BFEFAF4EAFB0" && read[0].catalogID == 1721464906, "library header/IDs")
    expect(read[0].values == [.name: "Sunny Day", .album: "Yeh, Hwei-Mei", .artist: "Jay Chou", .albumArtist: "Jay Chou"], "library strings")

    // Naming rules.
    var a = Answers()
    let tracks = [
        track(1, "Sunny Day", "Yeh, Hwei-Mei", "Jay Chou"),
        track(2, "Mojito", "Mojito - Single", "Jay Chou"),
        track(3, "Memories", "Memories - Single", "Maroon 5"),
        track(4, "Yoru No Odoriko", "834.194", "sakanaction"),
        track(5, "Believer", "Evolve", "Imagine Dragons"),
        track(6, "Nocturne No. 1", "Chopin: The Nocturnes", "Maria Joao Pires", genre: "Classical"),
        track(7, "Lights", "華燈初上 影集原聲帶", "Various Artists"),
        track(8, "For Lovers Who Hesitate", "Legend", "JANNABI"),
        track(9, "Dynamite", "BE", "BTS"),
        track(10, "六层楼", "安和桥北", "Song Dongye"),
        track(11, "Model", "Model", "Li Ronghao"),
        track(13, "逢いたくていま", "JUST BALLADE", "MISIA"),
        track(14, "如果不是你", "隱形遊樂場", "831"),
    ]
    a.hk = [1: listing("晴天", "葉惠美", "周杰倫"), 2: listing("Mojito", "Mojito - Single", "周杰倫"),
            3: listing("Memories", "Memories - Single", "魔力紅樂團"), 4: listing("Yoru No Odoriko", "834.194", "魚韻"),
            5: listing("Believer", "Evolve", "Imagine Dragons"), 6: listing("Nocturne No. 1", "Chopin: The Nocturnes", "皮耶絲"),
            7: listing("華燈初上", "華燈初上 影集原聲帶", "群星"), 8: listing("For Lovers Who Hesitate", "Legend", "Jannabi"),
            9: listing("Dynamite", "BE", "防彈少年團"), 10: listing("六層樓", "安和橋北", "宋冬野"), 11: listing("模特", "模特", "李榮浩"),
            13: listing("再見你一次", "JUST BALLADE", "MISIA"), 14: listing("如果不是你", "隱形遊樂場", "八三夭")]
    a.cn = [10: listing("六层楼", "安和桥北", "宋冬野"), 11: listing("模特", "模特", "李荣浩"),
            13: listing("再见你一次", "JUST BALLADE", "MISIA")]
    a.jp = [1: listing("晴天", "葉惠美", "Jay Chou"), 3: listing("Memories", "Memories - Single", "マルーン5"),
            4: listing("夜の踊り子", "834.194", "サカナクション"), 5: listing("ビリーヴァー", "エヴォルヴ", "イマジン・ドラゴンズ"),
            6: listing("夜想曲 第1番", "ショパン:夜想曲全集", "マリア・ジョアオ・ピリス"), 11: listing("Model", "Model", "李荣浩"),
            13: listing("逢いたくていま", "JUST BALLADE", "MISIA")]
    a.kr = [8: listing("주저하는 연인들을 위해", "전설", "잔나비"), 9: listing("Dynamite", "BE", "방탄소년단")]
    let got = rows(Planner.plan(tracks, a, knownArtists: [:]))
    let want: Set<String> = [
        "1 name Sunny Day -> 晴天", "1 album Yeh, Hwei-Mei -> 葉惠美",
        "1 artist Jay Chou -> 周杰倫", "1 albumArtist Jay Chou -> 周杰倫",
        "2 artist Jay Chou -> 周杰倫", "2 albumArtist Jay Chou -> 周杰倫",  // one spelling per artist
        "4 name Yoru No Odoriko -> 夜の踊り子",                                // Japanese: JP has the original
        "4 artist sakanaction -> サカナクション", "4 albumArtist sakanaction -> サカナクション",
        "7 name Lights -> 華燈初上",                                           // "Various Artists" stays
        "8 name For Lovers Who Hesitate -> 주저하는 연인들을 위해", "8 album Legend -> 전설",  // Korean: KR has it
        "8 artist JANNABI -> 잔나비", "8 albumArtist JANNABI -> 잔나비",
        "10 artist Song Dongye -> 宋冬野", "10 albumArtist Song Dongye -> 宋冬野",  // title already original
        "11 name Model -> 模特", "11 album Model -> 模特",                    // CN+HK beat JP's English
        "11 artist Li Ronghao -> 李荣浩", "11 albumArtist Li Ronghao -> 李荣浩",
        "14 artist 831 -> 八三夭", "14 albumArtist 831 -> 八三夭",           // digit-only names aren't originals
    ]  // Maroon 5, katakana Believer, classical, BTS's English song, 六层楼's title (script swap) and 逢いたくていま (already original) are left alone
    expect(got == want, "plan:\n  missing \(want.subtracting(got))\n  extra \(got.subtracting(want))")

    // BTS with a Korean-titled song: KR's name beats HK's Chinese one.
    var b = a
    b.hk[12] = listing("Spring Day", "You Never Walk Alone", "防彈少年團")
    b.kr[12] = listing("봄날", "YOU NEVER WALK ALONE", "방탄소년단")
    let bts = rows(Planner.plan([tracks[8], track(12, "Spring Day", "You Never Walk Alone", "BTS")], b, knownArtists: [:]))
    expect(bts.contains("9 artist BTS -> 방탄소년단") && bts.contains("12 name Spring Day -> 봄날"), "Korean artist name \(bts)")

    // Songs only in playlists keep their album and album artist (renaming them makes Music freeze later),
    // but still get their title and artist renamed.
    let playlistOnly = rows(Planner.plan([tracks[0]], a, knownArtists: [:], inLibrary: []))
    expect(playlistOnly == ["1 name Sunny Day -> 晴天", "1 artist Jay Chou -> 周杰倫"], "playlist-only \(playlistOnly)")
    let inLib = rows(Planner.plan([tracks[0]], a, knownArtists: [:], inLibrary: ["1"]))
    expect(inLib.contains("1 album Yeh, Hwei-Mei -> 葉惠美") && inLib.contains("1 albumArtist Jay Chou -> 周杰倫"), "library song \(inLib)")

    // Earlier renames steer new songs, even English-titled ones.
    let known = rows(Planner.plan([track(20, "Mojito", "Mojito - Single", "Jay Chou")], Answers(), knownArtists: ["Jay Chou": "周杰倫"]))
    expect(known == ["20 artist Jay Chou -> 周杰倫", "20 albumArtist Jay Chou -> 周杰倫"], "known artists \(known)")

    // Album merging: only when new songs join an album renamed earlier, never across different releases.
    let old = track(30, "半島鐵盒", "八度空間", "周杰倫", albumID: 99), new = track(31, "Half-beast Human", "The Eight Dimensions", "Jay Chou", albumID: 99)
    let moves = [Change(pid: "31", field: .album, old: "The Eight Dimensions", new: "八度空間"),
                 Change(pid: "31", field: .albumArtist, old: "Jay Chou", new: "周杰倫")]
    expect(Untranslator.albumsToMerge(moves, tracks: [old, new]).map { "\($0.0)|\($0.1)" } == ["八度空間|周杰倫"], "merge new into old")
    expect(Untranslator.albumsToMerge(moves, tracks: [new]).isEmpty, "no merge when the whole album was renamed together")
    let otherRelease = track(32, "Intro", "八度空間", "周杰倫", albumID: 77)
    expect(Untranslator.albumsToMerge(moves, tracks: [old, new, otherRelease]).isEmpty, "never merge different releases")
    print("ok")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil:
    try selfTest()
case "dump":
    for t in try MusicLibrary.read(args.count > 1 ? URL(fileURLWithPath: args[1]) : MusicLibrary.defaultURL) {
        print(([t.pid, String(t.catalogID)] + Field.allCases.map { t.values[$0] ?? "" } + [t.genre ?? ""]).joined(separator: "\t"))
    }
case "parity":
    let tracks = try MusicLibrary.read(URL(fileURLWithPath: args[1])).filter { $0.catalogID != 0 }
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: [String: [String: String]]]
    func store(_ s: String) -> [UInt64: Listing] {
        (json[s] ?? [:]).reduce(into: [:]) { out, kv in
            out[UInt64(kv.key)!] = Listing(values: kv.value.reduce(into: [:]) { if let f = Field(rawValue: $1.key) { $0[f] = $1.value } }, collectionID: 0)
        }
    }
    var a = Answers()
    (a.hk, a.cn, a.jp, a.kr) = (store("hk"), store("cn"), store("jp"), store("kr"))
    for c in Planner.plan(tracks, a, knownArtists: [:]) { print([c.pid, c.field.rawValue, c.old, c.new].joined(separator: "\t")) }
case "search":
    for h in try await Untranslator.search(args[1], storefront: args.count > 2 ? args[2] : "us") {
        print("\(h.name) — \(h.artist) · \(h.album)    \(h.url)")
    }
case "preview":
    let tracks = try MusicLibrary.read()
    try await Untranslator.verifyIDs(tracks, storefront: args.count > 1 ? args[1] : "us")
    let changes = try await Untranslator.scan(tracks.filter { $0.catalogID != 0 }) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    for c in changes { print([c.pid, c.field.rawValue, c.old, c.new].joined(separator: "\t")) }
case "verify":
    try await Untranslator.verifyIDs(try MusicLibrary.read(), storefront: args.count > 1 ? args[1] : "us")
    print("IDs match Apple's catalog")
default:
    print("unknown command")
}
