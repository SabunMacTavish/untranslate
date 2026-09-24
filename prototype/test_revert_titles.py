"""Run: python3 test_revert_titles.py"""
import struct, subprocess, tempfile, zlib
from pathlib import Path

import revert_titles as rt


def boma_str(kind, s):
    b = s.encode("utf-16-le")
    return b"boma" + struct.pack("<8I", 20, 36 + len(b), kind, 0, 1, len(b), 0, 0) + b


def boma_ids(catalog_id):
    b = bytearray(384)
    b[:16] = b"boma" + struct.pack("<3I", 20, 384, 1)
    struct.pack_into("<Q", b, 324, catalog_id)
    return bytes(b)


def fake_library(path, pid, catalog_id, name, album, artist):
    recs = [boma_str(2, name), boma_str(3, album), boma_str(4, artist), boma_str(0x1B, artist), boma_ids(catalog_id)]
    itma = b"itma" + struct.pack("<3IQ", 24, 24 + sum(map(len, recs)), len(recs), pid) + b"".join(recs)
    ltma = b"ltma" + struct.pack("<2I", 12, 1)
    other = b"hsma" + struct.pack("<4I", 20, 0, 3, 20)  # an unrelated section before the tracks
    tracks = b"hsma" + struct.pack("<4I", 20, 0, 1, 20 + len(ltma) + len(itma)) + ltma + itma
    z = zlib.compress(other + tracks)
    enc = subprocess.run(["openssl", "enc", "-e", "-aes-128-ecb", "-nopad", "-K", b"BHUILuilfghuila3".hex()],
                         input=z[:32], capture_output=True, check=True).stdout
    header = bytearray(160)
    header[:12] = b"hfma" + struct.pack("<2I", 160, 160 + len(z))
    struct.pack_into("<I", header, 0x54, 32)  # only the first 32 payload bytes are encrypted
    path.write_bytes(bytes(header) + enc + z[32:])


with tempfile.TemporaryDirectory() as d:
    p = Path(d) / "Library.musicdb"
    fake_library(p, 0x24D6BFEFAF4EAFB0, 1721464906, "Sunny Day", "Yeh, Hwei-Mei", "Jay Chou")
    assert rt.read_tracks(p) == [{"pid": "24D6BFEFAF4EAFB0", "id": 1721464906, "name": "Sunny Day",
                                  "album": "Yeh, Hwei-Mei", "artist": "Jay Chou", "albumArtist": "Jay Chou"}]

o = rt.original  # (current, hk, cn, jp)
assert o("Half-beast Human", "半獸人", None, "半獸人") == "半獸人"
assert o("Step Aside", "擱淺", "搁浅", None) == "擱淺"             # Traditional/Simplified tie -> HK
assert o("Anhe Bridge", "安和橋", "安和桥", "安和桥") == "安和桥"   # mainland original stays Simplified
assert o("六层楼", "六層樓", "六层楼", None) is None                # already original, CN shows it as-is
assert o("Jay Chou", "周杰倫", None, "Jay Chou") == "周杰倫"
assert o("Adele", "Adele", None, "アデル") is None                  # JP katakana never wins
assert o("Model", "模特", "模特", "Model") == "模特"
assert o("Kaiba", None, None, None) is None

w = rt.worth_changing
assert w("Half-beast Human", "半獸人")
assert w("(……The Little Shepherd) [feat. 微光古樂集]", "(……小小牧羊人) [feat. 微光古樂集]")
assert not w("Forever Daze", "FOREVER DAZE")          # only undo translations out of CJK
assert not w("如果月亮会说话", "如果月亮會說話")          # never just swap Simplified/Traditional


def track(pid, name, album, artist, genre="Pop"):
    return {"pid": pid, "id": pid, "name": name, "album": album, "artist": artist, "albumArtist": artist, "genre": genre}


def store(name, album, artist):
    return {"name": name, "album": album, "artist": artist, "albumArtist": artist}


tracks = [track(1, "Sunny Day", "Yeh, Hwei-Mei", "Jay Chou"),
          track(2, "Mojito", "Mojito - Single", "Jay Chou"),
          track(3, "Memories", "Memories - Single", "Maroon 5"),
          track(4, "Yoru No Odoriko", "834.194", "sakanaction"),
          track(5, "Believer", "Evolve", "Imagine Dragons"),
          track(6, "Nocturne No. 1", "Chopin: The Nocturnes", "Maria Joao Pires", "Classical"),
          track(7, "Lights", "華燈初上 影集原聲帶", "Various Artists")]
hk = {1: store("晴天", "葉惠美", "周杰倫"), 2: store("Mojito", "Mojito - Single", "周杰倫"),
      3: store("Memories", "Memories - Single", "魔力紅樂團"), 4: store("Yoru No Odoriko", "834.194", "魚韻"),
      5: store("Believer", "Evolve", "Imagine Dragons"), 6: store("Nocturne No. 1", "Chopin: The Nocturnes", "皮耶絲"),
      7: store("華燈初上", "華燈初上 影集原聲帶", "群星")}
jp = {1: store("晴天", "葉惠美", "Jay Chou"), 3: store("Memories", "Memories - Single", "マルーン5"),
      4: store("夜の踊り子", "834.194", "サカナクション"), 5: store("ビリーヴァー", "エヴォルヴ", "イマジン・ドラゴンズ"),
      6: store("夜想曲 第1番", "ショパン:夜想曲全集", "マリア・ジョアオ・ピリス")}
got = sorted(map(tuple, rt.plan(tracks, [hk, {}, jp])))
assert got == sorted([(1, "name", "Sunny Day", "晴天"), (1, "album", "Yeh, Hwei-Mei", "葉惠美"),
                      (1, "artist", "Jay Chou", "周杰倫"), (1, "albumArtist", "Jay Chou", "周杰倫"),
                      (2, "artist", "Jay Chou", "周杰倫"), (2, "albumArtist", "Jay Chou", "周杰倫"),  # one spelling per artist
                      (4, "name", "Yoru No Odoriko", "夜の踊り子"),  # Japanese song: JP has the original
                      (4, "artist", "sakanaction", "サカナクション"), (4, "albumArtist", "sakanaction", "サカナクション"),
                      (7, "name", "Lights", "華燈初上"),  # but "Various Artists" stays
                      ]), got  # Maroon 5, katakana Believer and the classical track are left alone
print("ok")
