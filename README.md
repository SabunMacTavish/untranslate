# Untranslate — for Apple Music

A small Mac menu-bar app that puts Chinese, Japanese and Korean songs in Apple Music back to their original names.

> **⚠️ Early alpha: use at your own risk.** Untranslate renames songs in your Apple Music library, and the changes sync to all your devices. Try it on a few songs first.
>
> Version 0.1.0 also renamed the albums of songs that are only in playlists (not added to your library), which can make the Music app freeze whenever your library changes. 0.1.1 leaves those albums alone.

If you use Apple Music in an English-language country (US, UK, Singapore, Malaysia, Australia…), Apple shows many Asian songs with English translations or romanized names: 周杰倫's 晴天 becomes "Sunny Day" by "Jay Chou", 잔나비's 주저하는 연인들을 위해 becomes "For Lovers Who Hesitate" by "JANNABI", サカナクション's 夜の踊り子 becomes "Yoru No Odoriko". There's no setting to turn this off, and Apple Music's own search shows the translated names too. Untranslate fixes your library and gives you a search that doesn't translate:

- **Fix names**: scans your library and playlists, shows every change in a list you can untick, then renames the songs in the Music app. Changes sync to your iPhone and other devices through Sync Library.
- **Rename new songs automatically** (optional): songs you add later get their original names a minute or so after they arrive.
- **Search in your own language**: press **⌘⇧M** anywhere (or use the menu bar) and search Apple Music in Chinese, Japanese, Korean or English. Results come back in the original language: 晴天 shows 晴天 by 周杰倫, 잔나비 shows 주저하는 연인들을 위해, 夜の踊り子 shows サカナクション, not the English versions. Use ↑/↓ and Return to open one in Music. The shortcut can be turned off in Settings.
- **Undo**: every rename is logged and can be put back.

Titles, albums and artist names can each be switched off in Settings.

## Install

1. Download `Untranslate.dmg` from [Releases](../../releases) and open it.
2. Drag **Untranslate** onto **Applications**, then eject the disk image.
3. Open Untranslate from Applications. macOS says it can't verify the app, because it isn't notarized (that needs a paid Apple developer account). Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, and confirm. You only do this once.
   (Comfortable with Terminal? `xattr -dr com.apple.quarantine /Applications/Untranslate.app` skips this step.)
4. Click the speech-bubble icon in the menu bar → **Fix names in my library…** → **Scan my library**.
5. The first time you rename, macOS asks whether Untranslate may control Music. Click **Allow**.

Needs macOS 14 or later. Tested on macOS 27 with Music 1.7. If your version of Music stores its library differently, the app says so and changes nothing.

## How it works

1. **Reads your library file** (`~/Music/Music/Music Library.musiclibrary/Library.musicdb`) to get each song's Apple Music ID. It only reads it; renames go through the Music app. Before trusting the IDs it checks a sample against Apple's catalog.
2. **Asks Apple how other countries name each song** through Apple's public [iTunes Search API](https://performance-partners.apple.com/search-api). The English stores translate; the others don't:
   - Hong Kong and China keep Chinese originals (Hong Kong in Traditional characters, China in Simplified). The app takes the majority across stores, so mainland songs stay Simplified and Taiwanese/Hong Kong ones stay Traditional.
   - Japan keeps Japanese originals (Hong Kong and China often romanize Japanese songs).
   - Korea keeps Korean originals (every other store shows Korean songs in English).
3. **Only undoes translations.** It never touches a name that's already written in Chinese, Japanese or Korean, never swaps Simplified and Traditional characters, never gives Western artists Chinese or Japanese names (Hong Kong calls Maroon 5 魔力紅樂團), leaves the album of songs that are only in playlists alone (Music can't sync a renamed album for those and slows down), leaves classical music alone (works are retitled in every country) and leaves "Various Artists" alone. Each artist gets one spelling across all their songs.
4. **Renames through the Music app** with AppleScript, and only changes a name if it still has the value it had when you scanned. Albums are kept together: Music splits an album when its songs are renamed at different times, so the app re-joins them.

Nothing about you or your library is sent anywhere except song IDs to Apple's own catalog. The app keeps its history in `~/Library/Application Support/Untranslate`.

## Limitations

- Japanese songs that Apple only lists in romanized form stay romanized.
- A few songs have Chinese names in the Hong Kong store that are translations themselves; you can untick them in the preview.
- Apple's catalog allows about 20 requests a minute, so a first scan of a big library takes a few minutes.
- Clicking a search result opens Apple's own page in Music, which still uses Apple's English names.

## Build from source

Needs the Xcode command line tools (`xcode-select --install`).

To keep macOS permissions across rebuilds, create a self-signed code-signing certificate named
`Untranslate Developer` (Keychain Access → Certificate Assistant → Create a Certificate…, type Code Signing).
The build script uses it when present; otherwise it signs ad-hoc and macOS treats every build as a new app.

```bash
swift build                          # debug build
swift run untranslate-check          # self-test
./scripts/build-app.sh               # build/Untranslate.app and build/Untranslate.dmg
```

`prototype/` holds the original Python script this app grew out of.

## License

Copyright © 2026 SabunMacTavish

Untranslate is free software under the [GNU Affero General Public License v3.0](LICENSE). You can use, study, change and share it; if you distribute a modified version, you have to release its source code under the same license. The copyright holder may also offer Untranslate under other terms.

Not affiliated with Apple. Apple Music is a trademark of Apple Inc.
