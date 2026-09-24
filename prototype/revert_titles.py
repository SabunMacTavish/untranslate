#!/usr/bin/env python3
"""Put Apple Music's English-translated song, album and artist names back to the originals.

  python3 revert_titles.py           preview: writes changes.tsv, changes nothing
  python3 revert_titles.py --apply   write changes.tsv into Music (old names saved to undo.tsv)
  python3 revert_titles.py --undo    put back the old names from undo.tsv

Reads each song's Apple Music ID from Music's library file, then asks the iTunes Lookup API
how the HK, CN and JP stores name it: the English stores translate Chinese and Japanese
names, HK/CN keep Chinese originals, JP keeps Japanese ones.
"""
import collections, csv, json, re, struct, subprocess, sys, time, urllib.request, zlib
from pathlib import Path

LIBRARY = Path.home() / "Music/Music/Music Library.musiclibrary/Library.musicdb"
PLAN = Path(__file__).resolve().with_name("changes.tsv")
UNDO = PLAN.with_name("undo.tsv")
FIELDS = {2: "name", 3: "album", 4: "artist", 0x1B: "albumArtist"}  # library string kind -> Music property
STRINGS = {**FIELDS, 5: "genre"}  # genre is read, never written
ARTISTS = ("artist", "albumArtist")
HEADER = ["persistent_id", "field", "current", "original"]
CJK = re.compile(r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff\uff66-\uff9f]")  # kana, hanzi/kanji, hangul
HIRAGANA_KANJI = re.compile(r"[\u3040-\u309f\u3400-\u4dbf\u4e00-\u9fff]")


def read_tracks(path=LIBRARY):
    """Songs in Music's library file. The format is undocumented: layout found by inspection (Music 1.7)."""
    data = path.read_bytes()
    header_len, = struct.unpack_from("<I", data, 4)
    crypt_len, = struct.unpack_from("<I", data, 0x54)
    body = data[header_len:]
    n = min(crypt_len, len(body)) // 16 * 16  # only the start of the payload is encrypted
    head = subprocess.run(["openssl", "enc", "-d", "-aes-128-ecb", "-nopad", "-K", b"BHUILuilfghuila3".hex()],
                          input=body[:n], capture_output=True, check=True).stdout
    raw = zlib.decompress(head + body[n:])

    i = 0
    while True:  # sections: 'hsma' header, kind 1 is the track list
        assert raw[i:i + 4] == b"hsma", "unexpected library format"
        kind, size = struct.unpack_from("<2I", raw, i + 12)
        if kind == 1:
            break
        i += size
    i += struct.unpack_from("<I", raw, i + 4)[0]
    assert raw[i:i + 4] == b"ltma", "unexpected library format"
    header_len, count = struct.unpack_from("<2I", raw, i + 4)
    i += header_len

    tracks = []
    for _ in range(count):
        assert raw[i:i + 4] == b"itma", "unexpected library format"
        header_len, size, nrec = struct.unpack_from("<3I", raw, i + 4)
        t = {"pid": "%016X" % struct.unpack_from("<Q", raw, i + 16)}
        j = i + header_len
        for _ in range(nrec):  # 'boma' records: strings and the catalog IDs
            _, rec_len, kind = struct.unpack_from("<3I", raw, j + 4)
            if kind in STRINGS:
                enc, strlen = struct.unpack_from("<2I", raw, j + 20)
                t[STRINGS[kind]] = raw[j + 36:j + 36 + strlen].decode("utf-16-le" if enc == 1 else "utf-8")
            elif kind == 1:
                t["id"], = struct.unpack_from("<Q", raw, j + 324)
            j += rec_len
        tracks.append(t)
        i += size
    return tracks


def lookup(ids, store):
    """{catalog id: {field: name}} as the given store shows it."""
    found = {}
    for k in range(0, len(ids), 150):
        url = f"https://itunes.apple.com/lookup?country={store}&id={','.join(map(str, ids[k:k + 150]))}"
        for attempt in range(4):
            time.sleep(2 + 30 * attempt)  # the API allows ~20 requests/minute
            try:
                with urllib.request.urlopen(url, timeout=30) as r:
                    results = json.load(r)["results"]
                break
            except (OSError, ValueError) as e:
                print(f"\n  {store}: {e}, retrying", file=sys.stderr)
        else:
            sys.exit(f"iTunes lookup keeps failing ({store}), try again later")
        for x in results:
            if x.get("wrapperType") == "track":
                found[x["trackId"]] = {"name": x.get("trackName"), "album": x.get("collectionName"),
                                       "artist": x.get("artistName"),
                                       "albumArtist": x.get("collectionArtistName", x.get("artistName"))}
        print(f"  {store} store: {min(k + 150, len(ids))}/{len(ids)}", end="\r", file=sys.stderr)
    print(file=sys.stderr)
    return found


def original(current, hk, cn, jp):
    """The original-language value for one field of a Chinese song, or None to leave `current` alone.

    If HK or CN shows `current` as-is, it isn't a translation. Otherwise take the majority,
    which keeps each song's own script: HK converts to Traditional, CN to Simplified, JP
    leaves Chinese alone. Ties go to HK, then CN (JP writes Western artists in katakana).
    """
    if current in (hk, cn):
        return None
    votes = collections.Counter(v for v in (hk, cn, jp) if v)
    best = votes.most_common(1)[0][0] if votes else None
    return best if best != current else None


def worth_changing(current, new):
    """Only undo translations out of CJK script; never just swap Simplified and Traditional."""
    if not new or new == current or not CJK.search(new):
        return False
    return not (len(new) == len(current) and all(a == b or (CJK.match(a) and CJK.match(b)) for a, b in zip(new, current)))


def plan(tracks, stores):
    """[persistent id, field, current, original] rows; `stores` are the HK, CN and JP lookups."""
    rows, cjk_artists = [], set()
    votes = collections.defaultdict(lambda: (collections.Counter(), collections.Counter()))  # (Japanese songs, rest)
    for t in tracks:
        if t.get("genre") == "Classical":  # works get retitled in every market's language, no single original
            continue
        hk, cn, jp = (s.get(t["id"], {}) for s in stores)
        # Japanese song: HK/CN show a romaji/English title but an Asian artist name, and JP's title has
        # hiragana or kanji. Katakana alone doesn't count: JP spells Western titles in katakana too.
        # ponytail: misses Japanese songs with katakana-only titles or Latin-named artists (they stay as-is).
        japanese = (HIRAGANA_KANJI.search(jp.get("name", "")) and CJK.search(hk.get("artist", "") + cn.get("artist", ""))
                    and not CJK.search(hk.get("name", "") + cn.get("name", "")))
        new = {}
        for f in FIELDS.values():
            if f in t:
                v = jp.get(f) if japanese else original(t[f], hk.get(f), cn.get(f), jp.get(f))
                new[f] = v if worth_changing(t[f], v) else None
        rows += [[t["pid"], f, t[f], new[f]] for f in ("name", "album") if new.get(f)]
        if CJK.search((new.get("name") or t.get("name", "")) + (new.get("album") or t.get("album", ""))):
            cjk_artists.update(t[f] for f in ARTISTS if f in t)
        for f in ARTISTS:
            if new.get(f):
                votes[t[f]][0 if japanese else 1][new[f]] += 1
    # One spelling per artist so they don't split in two (JP's if they have Japanese songs: HK calls
    # sakanaction 魚韻), and only for artists with CJK songs: HK also renames Maroon 5 魔力紅樂團.
    # "Various Artists" is a label, not an artist: HK calls every compilation 群星, Western ones too.
    renamed = {cur: (jv or rest).most_common(1)[0][0] for cur, (jv, rest) in votes.items()
               if cur in cjk_artists and cur != "Various Artists"}
    rows += [[t["pid"], f, t[f], renamed[t[f]]] for t in tracks for f in ARTISTS if t.get(f) in renamed]
    return rows


JXA = """
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


def write_to_music(rows):
    done = 0
    for k in range(0, len(rows), 500):
        r = subprocess.run(["osascript", "-l", "JavaScript", "-e", JXA, json.dumps(rows[k:k + 500])],
                           capture_output=True, text=True)
        if r.returncode:
            sys.exit(r.stderr.strip())
        res = json.loads(r.stdout)
        done += res["done"]
        for s in res["skipped"]:
            print("  skipped", s)
        print(f"  {min(k + 500, len(rows))}/{len(rows)}", end="\r", file=sys.stderr)
    print(file=sys.stderr)
    print(f"{done} of {len(rows)} names updated in Music.")


def load(path):
    with open(path, newline="", encoding="utf-8") as f:
        return [r for r in csv.reader(f, dialect="excel-tab") if r and r != HEADER]


def save(path, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        csv.writer(f, dialect="excel-tab").writerows([HEADER, *rows])


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--preview"
    if mode == "--apply":
        rows = load(PLAN)
        save(UNDO, (load(UNDO) if UNDO.exists() else []) + rows)  # append, so earlier runs stay undoable
        write_to_music(rows)
    elif mode == "--undo":
        write_to_music([[pid, f, new, old] for pid, f, old, new in reversed(load(UNDO))])
    elif mode == "--preview":
        tracks = [t for t in read_tracks() if t.get("id")]
        ids = sorted({t["id"] for t in tracks})
        rows = plan(tracks, [lookup(ids, s) for s in ("hk", "cn", "jp")])
        save(PLAN, rows)
        for f, n in collections.Counter(r[1] for r in rows).items():
            print(f"{n:5} {f}")
        for r in rows[:: max(1, len(rows) // 12)][:12]:
            print(f"      {r[2]}  ->  {r[3]}")
        print(f"Wrote {PLAN.name}. Delete any lines you don't want, then run with --apply.")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
