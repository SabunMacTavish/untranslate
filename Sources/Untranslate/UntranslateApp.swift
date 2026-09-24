import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UntranslateCore

@main
struct UntranslateApp: App {
    // Created at launch, not lazily like @StateObject (which waits until the menu is first opened):
    // the ⌘⇧M shortcut and auto mode have to work before anyone clicks the menu-bar icon.
    private let model = AppModel()

    var body: some Scene {
        MenuBarExtra("Untranslate", systemImage: "character.bubble") {
            MenuView().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
        Window("Fix Names", id: "fix") { FixView().environmentObject(model) }
            .defaultSize(width: 920, height: 620)
        Window("Untranslate Settings", id: "settings") { SettingsView().environmentObject(model) }
            .windowResizability(.contentSize)
    }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, working(String), ready, applying(String), done(String), failed(String) }

    struct Row: Identifiable, Hashable {
        let change: Change
        let song: String
        var id: String { change.pid + change.field.rawValue }
    }

    // Search
    @Published var query = ""
    @Published var hits: [Untranslator.Hit] = []
    @Published var searchStatus: String?
    @Published var searching = false
    @Published var selection = 0  // highlighted result, moved with ↑/↓ or the mouse
    private var searchToken = 0
    private var lastQuery = ""

    // Fix names
    @Published var phase: Phase = .idle
    @Published var rows: [Row] = []
    @Published var excluded: Set<String> = []
    @Published var filter = ""
    @Published var skipped: [String] = []
    private var tracks: [Track] = []
    private var verified = false

    // Auto mode
    @Published var autoStatus: String?
    @Published var loginError: String?
    @Published var confirmUndo = false  // lives here: @State needs Xcode's macro plugin on the macOS 27 SDK
    @Published var shortcutError: String?
    private var hotKey: HotKey?
    private var lastModified: Date?
    private var busy = false
    private var timer: Timer?

    let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: ["storefront": Locale.current.region?.identifier.lowercased() ?? "us",
                                     "renameTitles": true, "renameAlbums": true, "renameArtists": true, "autoMode": false,
                                     "searchShortcut": true])
        updateHotKey()
        // ponytail: polls the library file's date every 30s; switch to FSEvents if that ever matters.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.autoTick() } }
    }

    var storefront: String { defaults.string(forKey: "storefront")?.lowercased().trimmingCharacters(in: .whitespaces) ?? "us" }

    var fields: Set<Field> {
        var f = Set<Field>()
        if defaults.bool(forKey: "renameTitles") { f.insert(.name) }
        if defaults.bool(forKey: "renameAlbums") { f.insert(.album) }
        if defaults.bool(forKey: "renameArtists") { f.formUnion([.artist, .albumArtist]) }
        return f
    }

    var autoMode: Bool {
        get { defaults.bool(forKey: "autoMode") }
        set { defaults.set(newValue, forKey: "autoMode"); objectWillChange.send(); if newValue { lastModified = nil; autoTick() } }
    }

    /// ⌘⇧M opens the search from anywhere.
    var searchShortcut: Bool {
        get { defaults.bool(forKey: "searchShortcut") }
        set { defaults.set(newValue, forKey: "searchShortcut"); updateHotKey(); objectWillChange.send() }
    }

    private func updateHotKey() {
        hotKey = nil
        guard searchShortcut else { shortcutError = nil; return }
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            Task { @MainActor in self?.openSearch() }
        }
        shortcutError = hotKey == nil ? "Couldn't set up ⌘⇧M." : nil
    }

    /// ⌘⇧M shows a Spotlight-style search window. (SwiftUI can't open its MenuBarExtra from code, and on
    /// macOS 27 clicking the status item programmatically does nothing, so the shortcut gets its own window.)
    func openSearch() {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        let p = panel ?? makePanel()
        panel = p
        if let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panelTop = f.maxY - f.height * 0.18
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - p.frame.width / 2, y: panelTop))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        func field(in v: NSView?) -> NSTextField? {
            guard let v else { return nil }
            return v as? NSTextField ?? v.subviews.lazy.compactMap { field(in: $0) }.first
        }
        if let f = field(in: p.contentView) { p.makeFirstResponder(f) }
    }

    private var panel: SearchPanel?
    private var panelTop: CGFloat = 0

    private func makePanel() -> SearchPanel {
        let p = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // opens on the current Space, even over full screen
        p.isMovableByWindowBackground = true
        // Close for real whenever it loses focus (another app, another Space, a click elsewhere), like Spotlight.
        // hidesOnDeactivate only hid it, so the next ⌘⇧M "closed" an invisible window.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak p] _ in
            p?.orderOut(nil)
        }
        let root = SearchView(large: true, onOpen: { [weak p] in p?.orderOut(nil) })
            .frame(width: 640)
            .modifier(PanelBackground())
            .environmentObject(self)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        // Attaching the controller shrinks the window to 0×0 until it's first drawn, which made the first
        // ⌘⇧M center a zero-width window (left edge at mid-screen). Size it to its content before positioning.
        p.setContentSize(host.view.fittingSize)
        // It resizes as results arrive; keep the top edge put so it grows downward.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { [weak self, weak p] _ in
            MainActor.assumeIsolated {
                guard let self, let p, p.frame.maxY != self.panelTop else { return }
                p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: self.panelTop))
                p.invalidateShadow()
            }
        }
        return p
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginError = nil }
            catch { loginError = "Couldn't change: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }

    // MARK: Search

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchToken += 1
        let token = searchToken
        guard !q.isEmpty else { hits = []; searchStatus = nil; lastQuery = ""; return }
        searching = true
        searchStatus = nil
        let sf = storefront
        Task {
            defer { if token == searchToken { searching = false } }
            do {
                let found = try await Untranslator.search(q, storefront: sf)
                guard token == searchToken else { return }
                hits = found
                selection = 0
                lastQuery = q
                searchStatus = found.isEmpty ? "Nothing found for “\(q)”. Try adding the artist's name." : nil
            } catch {
                guard token == searchToken else { return }
                searchStatus = error.localizedDescription
            }
        }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    struct SearchItem: Identifiable {
        let id: String, title: String, subtitle: String
        let artwork: URL?, url: URL, isAlbum: Bool
    }

    /// Songs first, then the albums they're on.
    var items: [SearchItem] {
        var seen = Set<UInt64>()
        let songs = hits.prefix(12).map {
            SearchItem(id: "s\($0.id)", title: $0.name, subtitle: "\($0.artist) · \($0.album)", artwork: $0.artwork, url: $0.url, isAlbum: false)
        }
        let albums = hits.filter { seen.insert($0.collectionID).inserted }.prefix(5).map {
            SearchItem(id: "a\($0.collectionID)", title: $0.album, subtitle: $0.artist, artwork: $0.artwork,
                       url: URL(string: "music://music.apple.com/\(storefront)/album/\($0.collectionID)")!, isAlbum: true)
        }
        return songs + albums
    }

    /// Return: open the highlighted result if the results are for what's typed, otherwise search.
    @discardableResult func submit() -> Bool {
        let items = self.items
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == lastQuery, items.indices.contains(selection) else {
            search()
            return false
        }
        open(items[selection].url)
        return true
    }

    func moveSelection(_ by: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + by, 0), items.count - 1)
    }

    // MARK: Fix names

    var shownRows: [Row] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return rows }
        return rows.filter { ($0.change.old + " " + $0.change.new + " " + $0.song).lowercased().contains(f) }
    }

    var chosenCount: Int { rows.count - excluded.count }

    func scan() {
        guard !busy else { phase = .failed("Busy renaming new songs. Try again in a moment."); return }
        busy = true
        phase = .working("Reading your Music library…")
        let sf = storefront, fields = self.fields
        Task {
            defer { busy = false }
            do {
                let tracks = try await Task.detached { try MusicLibrary.read() }.value
                if !verified {
                    phase = .working("Checking your library against Apple's catalog…")
                    try await Untranslator.verifyIDs(tracks, storefront: sf)
                    verified = true
                }
                let changes = try await Untranslator.scan(tracks.filter { $0.catalogID != 0 }, fields: fields) { msg in
                    Task { @MainActor in self.phase = .working(msg) }
                }
                let byPid = Dictionary(tracks.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
                rows = changes.map { c in
                    let t = byPid[c.pid]
                    return Row(change: c, song: "\(t?.values[.name] ?? "") — \(t?.values[.artist] ?? "")")
                }
                excluded = []
                skipped = []
                self.tracks = tracks
                if rows.isEmpty {
                    History.markSeen(tracks.map(\.pid))
                    phase = .done("Everything already has its original name.")
                } else {
                    phase = .ready
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func setIncluded(_ id: String, _ on: Bool) { if on { excluded.remove(id) } else { excluded.insert(id) } }
    func selectAll() { excluded = [] }
    func selectNone() { excluded = Set(rows.map(\.id)) }

    func apply() {
        let chosen = rows.filter { !excluded.contains($0.id) }.map(\.change)
        guard !chosen.isEmpty, !busy else { return }
        busy = true
        phase = .applying("Renaming…")
        let tracks = self.tracks
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached {
                    try Untranslator.apply(chosen, tracks: tracks) { msg in Task { @MainActor in self.phase = .applying(msg) } }
                }.value
                History.markSeen(tracks.map(\.pid))  // unticked ones count as decided, auto mode won't redo them
                rows = []
                skipped = result.skipped
                phase = .done("Renamed \(result.done) names. They sync to your other devices through Sync Library.")
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func undoAll() {
        guard !busy else { return }
        busy = true
        phase = .applying("Putting the old names back…")
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached { try Untranslator.undoAll() }.value
                skipped = result.skipped
                phase = .done("Put back \(result.done) names.")
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Auto mode

    /// Every 30s: if Music saved its library since last time (and has finished writing), rename new songs.
    func autoTick() {
        guard autoMode, !busy,
              let modified = (try? MusicLibrary.defaultURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified != lastModified, Date().timeIntervalSince(modified) > 10 else { return }
        busy = true
        let fields = self.fields
        Task {
            defer { busy = false }
            do {
                let n = try await Untranslator.renameNewSongs(fields: fields)
                lastModified = modified
                if n > 0 { autoStatus = "Renamed \(n) new names at \(Date().formatted(date: .omitted, time: .shortened))." }
            } catch {
                autoStatus = "Auto mode: \(error.localizedDescription)"  // retried at the next library change
            }
        }
    }
}

// MARK: - Menu bar

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchView()
            Divider()
            Button("Fix names in my library…") { show("fix") }
            Toggle("Rename new songs automatically", isOn: Binding(get: { model.autoMode }, set: { model.autoMode = $0 }))
            if let s = model.autoStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
            Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
            if let e = model.loginError { Text(e).font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Button("Settings…") { show("settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Search box and results, shared by the menu-bar popup (compact) and the ⌘⇧M window (large).
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    var large = false
    var onOpen: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if let status = model.searchStatus {
                if large { Divider() }
                Text(status).font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, large ? 18 : 4).padding(.vertical, 10)
            } else if !model.hits.isEmpty {
                if large { Divider() }
                results
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(large ? .title2 : .callout)
                .foregroundStyle(.secondary)
            TextField("Search Apple Music", text: $model.query)
                .textFieldStyle(.plain)
                .font(large ? .title2 : .body)
                .focusEffectDisabled()
                .onSubmit { if model.submit() { onOpen() } }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
            if model.searching {
                ProgressView().controlSize(.small)
            } else if !large, model.searchShortcut {
                Text("⌘⇧M").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, large ? 18 : 8)
        .padding(.vertical, large ? 16 : 6)
        .background {
            if !large { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary) }
        }
    }

    private var results: some View {
        let items = model.items
        let firstAlbum = items.firstIndex { $0.isAlbum }
        let rowHeight: CGFloat = large ? 54 : 44
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i == 0 { header("Songs") }
                        if i == firstAlbum { header("Albums") }
                        row(item, selected: i == model.selection)
                            .id(i)
                            .onHover { if $0 { model.selection = i } }
                            .onTapGesture { model.open(item.url); onOpen() }
                    }
                }
                .padding(.horizontal, large ? 8 : 0)
                .padding(.vertical, 6)
            }
            // A ScrollView has no height of its own; give it room for its rows (it scrolls past the cap).
            .frame(height: min(CGFloat(items.count) * rowHeight + 56, large ? 440 : 360))
            .onChange(of: model.selection) { proxy.scrollTo(model.selection) }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    private func row(_ item: AppModel.SearchItem, selected: Bool) -> some View {
        let side: CGFloat = large ? 40 : 32
        return HStack(spacing: 12) {
            AsyncImage(url: item.artwork) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: item.isAlbum ? "square.stack" : "music.note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(large ? .body.weight(.medium) : .callout).lineLimit(1)
                Text(item.subtitle).font(large ? .callout : .caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .help("Open in Music")
    }
}

/// Liquid Glass on macOS 26+, frosted material before that.
struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(.white.opacity(0.12)))
        }
    }
}

/// Borderless window that can take typing and closes on Esc.
final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

// MARK: - Fix names window

struct FixView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .idle:
                intro
            case .working(let msg), .applying(let msg):
                Spacer()
                HStack { Spacer(); ProgressView(msg); Spacer() }
                Spacer()
            case .ready:
                preview
            case .done(let msg):
                Text(msg).font(.title3)
                skippedList
                Button("Scan again") { model.scan() }
                Spacer()
            case .failed(let msg):
                Text(msg).foregroundStyle(.red)
                Button("Try again") { model.scan() }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 480)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Put songs back to their original names").font(.title2)
            Text("Apple Music shows Chinese, Japanese and Korean songs with English or romanized names in English-language stores. This app looks up how Apple's Hong Kong, China, Japan and Korea stores name each song in your library and playlists, then shows you every change before making it.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing changes until you press Rename. Scanning a big library takes a few minutes because Apple limits how fast its catalog can be asked.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Scan my library") { model.scan() }.keyboardShortcut(.defaultAction)
            Spacer()
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(model.chosenCount) of \(model.rows.count) changes selected")
                Spacer()
                TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Select all") { model.selectAll() }
                Button("Select none") { model.selectNone() }
            }
            Table(model.shownRows) {
                TableColumn("") { row in
                    Toggle("", isOn: Binding(get: { !model.excluded.contains(row.id) }, set: { model.setIncluded(row.id, $0) }))
                        .labelsHidden()
                }
                .width(24)
                TableColumn("What") { row in Text(label(row.change.field)) }.width(90)
                TableColumn("Now") { row in Text(row.change.old) }
                TableColumn("Original") { row in Text(row.change.new) }
                TableColumn("Song") { row in Text(row.song).foregroundStyle(.secondary) }
            }
            HStack {
                Text("Renames happen in the Music app and sync to your other devices. You can undo them all in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Rename \(model.chosenCount)") { model.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.chosenCount == 0)
            }
        }
    }

    @ViewBuilder private var skippedList: some View {
        if !model.skipped.isEmpty {
            Text("\(model.skipped.count) couldn't be changed (for example songs Apple no longer offers):").foregroundStyle(.secondary)
            List(model.skipped, id: \.self) { Text($0).font(.caption) }.frame(maxHeight: 200)
        }
    }

    private func label(_ f: Field) -> String {
        switch f { case .name: "Title"; case .album: "Album"; case .artist: "Artist"; case .albumArtist: "Album artist" }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("storefront") private var storefront = "us"
    @AppStorage("renameTitles") private var titles = true
    @AppStorage("renameAlbums") private var albums = true
    @AppStorage("renameArtists") private var artists = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                TextField("Your Apple Music country", text: $storefront, prompt: Text("us"))
                Text("Two-letter code, e.g. us, gb, sg, my, au. Search results open in this store.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("⌘⇧M opens search from anywhere", isOn: Binding(get: { model.searchShortcut }, set: { model.searchShortcut = $0 }))
                if let e = model.shortcutError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section("Rename") {
                Toggle("Song titles", isOn: $titles)
                Toggle("Album names", isOn: $albums)
                Toggle("Artist names (e.g. Jay Chou → 周杰倫, JANNABI → 잔나비)", isOn: $artists)
            }
            Section("History") {
                HStack {
                    Button("Show log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([History.logURL]) }
                    Button("Undo all renames…") { model.confirmUndo = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .confirmationDialog("Put back every name this app changed?", isPresented: $model.confirmUndo) {
            Button("Undo all renames", role: .destructive) {
                model.undoAll()
                openWindow(id: "fix")
            }
        } message: {
            Text("Names you've edited yourself since then are left alone.")
        }
    }
}

// MARK: - Global shortcut

/// A system-wide keyboard shortcut via Carbon's RegisterEventHotKey, which needs no special permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, _, me in
            Unmanaged<HotKey>.fromOpaque(me!).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x554E_5452), id: 1)  // 'UNTR'
        // Exclusive: fails (instead of silently losing) if another app already owns the shortcut.
        let registered = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard installed == noErr, registered == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
