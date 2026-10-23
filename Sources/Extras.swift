import AppKit
import Observation
import SwiftUI

// MARK: - Svuota Cestino

/// Cestini dell'utente: ~/.Trash e quelli dei dischi esterni.
func trashDirs() -> [String] {
    var dirs = [HOME + "/.Trash"]
    for v in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
        let t = "/Volumes/\(v)/.Trashes/\(getuid())"
        if FileManager.default.fileExists(atPath: t) { dirs.append(t) }
    }
    return dirs
}

func trashSize() -> Int64 { trashDirs().reduce(0) { $0 + duTotal($1) } }

/// Svuota davvero (definitivo). Ritorna elementi eliminati, falliti e byte liberati.
func emptyAllTrash() -> (done: Int, failed: Int, freed: Int64) {
    let before = freeSpace()
    var done = 0, failed = 0
    for dir in trashDirs() {
        for e in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where e != ".DS_Store" {
            if (try? FileManager.default.removeItem(atPath: dir + "/" + e)) != nil { done += 1 } else { failed += 1 }
        }
    }
    let freed = max(freeSpace() - before, 0)
    logLine("SVUOTA_CESTINO \(done) elementi, \(failed) non eliminati, liberati \(fmt(freed))")
    return (done, failed, freed)
}

// MARK: - Pulizia rapida

struct QuickItem: Identifiable {
    enum Action { case trashContents(String), command(String), emptyTrash }
    let id: String, label: String, detail: String, symbol: String, color: Color, action: Action
    var size: Int64? = nil
    var on: Bool
    var state = 0  // 0 da fare, 1 in corso, 2 fatto, 3 errore
}

@MainActor @Observable final class QuickCleanModel {
    var items: [QuickItem] = []
    var running = false
    var finished = false
    var freed: Int64 = 0

    var total: Int64 { items.filter(\.on).reduce(0) { $0 + ($1.size ?? 0) } }

    func prepare(_ store: Store) {
        finished = false; freed = 0
        func cat(_ id: String, on: Bool = true) -> QuickItem? {
            guard let c = store.categories.first(where: { $0.id == id }) else { return nil }
            return QuickItem(id: id, label: c.label, detail: c.note, symbol: c.symbol, color: c.color, action: .trashContents(c.path), size: c.size, on: on)
        }
        items = [cat("caches"), cat("logs"), cat("derived"), cat("npm"), cat("gradle"), cat("devsupport", on: false)].compactMap { $0 }
        items.append(QuickItem(id: "brew", label: "Homebrew", detail: "Versioni vecchie e download", symbol: "mug.fill", color: .orange,
                               action: .command("brew cleanup --prune=all -s"), on: true))
        items.append(QuickItem(id: "simctl", label: "Simulatori non disponibili", detail: "Quelli senza più un runtime", symbol: "iphone", color: .teal,
                               action: .command("xcrun simctl delete unavailable"), on: true))
        items.append(QuickItem(id: "trash", label: "Svuota il Cestino", detail: "Rende definitiva la pulizia e libera davvero lo spazio",
                               symbol: "trash.fill", color: .red, action: .emptyTrash, on: true))
        let paths = items.compactMap { if case .trashContents(let p) = $0.action { $0.size == nil ? p : nil } else { nil } }
        Task {
            let t = await Task.detached { trashSize() }.value
            if let i = items.firstIndex(where: { $0.id == "trash" }) { items[i].size = t }
            if !paths.isEmpty {
                let s = await Task.detached { parallelSizes(paths) }.value
                for (p, sz) in s { if let i = items.firstIndex(where: { if case .trashContents(p) = $0.action { true } else { false } }) { items[i].size = sz } }
            }
        }
    }

    func run(_ store: Store) {
        running = true
        let before = freeSpace()
        Task {
            for i in items.indices where items[i].on {
                withAnimation(.spring) { items[i].state = 1 }
                let item = items[i]
                let ok: Bool = await Task.detached {
                    switch item.action {
                    case .trashContents(let dir):
                        let kids = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }
                        return moveToTrash(kids).errors.count < max(kids.count, 1)
                    case .command(let c):
                        return shi(c).code == 0
                    case .emptyTrash:
                        return emptyAllTrash().failed == 0
                    }
                }.value
                withAnimation(.spring) { items[i].state = ok ? 2 : 3 }
            }
            freed = max(freeSpace() - before, 0)
            logLine("PULIZIA_RAPIDA liberati \(fmt(freed))")
            running = false
            withAnimation(.spring) { finished = true }
            store.refreshDisk()
            store.loadCategories()
            store.celebrate(freed, "Pulizia rapida completata")
        }
    }
}

struct QuickCleanSheet: View {
    @Environment(Store.self) private var s
    @Environment(\.dismiss) private var dismiss
    @State private var m = QuickCleanModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconBadge(symbol: "sparkles", color: .purple, size: 44)
                    .symbolEffect(.bounce, value: m.finished)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pulizia rapida").font(.title2.weight(.bold))
                    Text(m.finished ? "Fatto: liberati \(fmt(m.freed))" : "Fino a \(fmt(m.total)) in un clic")
                        .foregroundStyle(m.finished ? .green : .secondary)
                        .contentTransition(.numericText())
                }
            }
            VStack(spacing: 6) {
                ForEach($m.items) { $item in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $item.on).toggleStyle(.checkbox).labelsHidden().disabled(m.running || m.finished)
                        IconBadge(symbol: item.symbol, color: item.color, size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.label).fontWeight(.medium)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.size.map(fmt) ?? (item.action.isCommand ? "" : "…")).monospacedDigit().foregroundStyle(.secondary)
                        Group {
                            switch item.state {
                            case 1: ProgressView().controlSize(.small)
                            case 2: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale.combined(with: .opacity))
                            case 3: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).transition(.scale)
                            default: Color.clear
                            }
                        }
                        .frame(width: 20)
                    }
                    .opacity(item.on ? 1 : 0.5)
                }
            }
            if m.items.first(where: { $0.id == "trash" })?.on == true {
                Label("Con \"Svuota il Cestino\" la pulizia è definitiva: anche quello che c'era già nel Cestino sparisce.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(m.finished ? "Chiudi" : "Annulla") { dismiss() }.keyboardShortcut(.cancelAction).disabled(m.running)
                if !m.finished {
                    Button(m.running ? "Pulizia in corso…" : "Pulisci \(fmt(m.total))") { m.run(s) }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .keyboardShortcut(.defaultAction)
                        .disabled(m.running || !m.items.contains(where: \.on))
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { m.prepare(s) }
    }
}

extension QuickItem.Action {
    var isCommand: Bool { if case .command = self { true } else { false } }
}

// MARK: - Festa

struct Confetti: View {
    let start = Date()
    private let pieces: [(x: Double, speed: Double, spin: Double, size: Double, color: Color, delay: Double)] = (0..<90).map { _ in
        (Double.random(in: 0...1), Double.random(in: 180...420), Double.random(in: -6...6), Double.random(in: 5...10),
         PALETTE.randomElement()!, Double.random(in: 0...0.5))
    }

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSince(start)
                for p in pieces {
                    let tt = max(t - p.delay, 0)
                    let y = -20 + p.speed * tt + 120 * tt * tt
                    guard y < size.height + 20 else { continue }
                    let x = p.x * size.width + sin(tt * 3 + p.x * 10) * 30
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.spin * tt))
                    c.opacity = max(0, 1 - tt / 3.2)
                    c.fill(Path(roundedRect: CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2), cornerRadius: 1.5),
                           with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct CelebrationOverlay: View {
    let bytes: Int64
    let title: String
    @State private var shown = false

    var body: some View {
        ZStack {
            Confetti()
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green.gradient)
                    .symbolEffect(.bounce, value: shown)
                Text(bytes > 0 ? "Hai liberato \(fmt(bytes))" : title).font(.system(size: 30, weight: .bold, design: .rounded))
                if bytes > 0 { Text(title).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 36).padding(.vertical, 26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { shown = true } }
    }
}

// MARK: - Strumenti di sviluppo

/// Comando in shell interattiva: nvm/npm/bun stanno nel PATH di .zshrc.
func shi(_ cmd: String) -> (out: String, code: Int32) { run(["/bin/zsh", "-lic", cmd], mergeErr: true) }

func jsonObject(in s: String) -> Any? {
    guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}") else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(s[a...b].utf8))
}

func firstVersion(_ s: String) -> String {
    s.split(whereSeparator: { $0 == " " || $0 == "\n" }).first { $0.first?.isNumber == true || $0.hasPrefix("v") && $0.dropFirst().first?.isNumber == true }
        .map(String.init) ?? ""
}

func loadDevUpdates() -> [UpdateItem] {
    var out: [UpdateItem] = []
    let has = { (c: String) in shi("command -v \(c) >/dev/null && echo SI").out.contains("SI") }
    // pacchetti npm globali
    if has("npm"), let d = jsonObject(in: shi("npm outdated -g --json 2>/dev/null").out) as? [String: [String: Any]] {
        for (name, v) in d.sorted(by: { $0.key < $1.key }) {
            out.append(UpdateItem(kind: .dev, key: "npm:" + name, name: name + " (npm -g)", from: v["current"] as? String ?? "",
                                  to: v["latest"] as? String ?? "", cmd: "npm install -g \(shq(name))@latest"))
        }
    }
    // gestori aggiornati da sé
    func selfUpdating(_ tool: String, current: String, npmName: String, cmd: String) {
        let cur = firstVersion(current)
        let latest = shi("npm view \(npmName) version 2>/dev/null").out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
        if !cur.isEmpty, !latest.isEmpty, compareVersions(cur, latest) {
            out.append(UpdateItem(kind: .dev, key: tool, name: tool, from: cur, to: latest, cmd: cmd))
        }
    }
    if has("pnpm") { selfUpdating("pnpm", current: shi("pnpm --version").out, npmName: "pnpm", cmd: "pnpm self-update") }
    if has("bun") { selfUpdating("bun", current: shi("bun --version").out, npmName: "bun", cmd: "bun upgrade") }
    let claudePath = shi("command -v claude").out.trimmingCharacters(in: .whitespacesAndNewlines)
    if !claudePath.isEmpty && !claudePath.contains("/.nvm/") {  // se installato con npm lo copre già npm -g
        selfUpdating("Claude Code", current: shi("claude --version").out, npmName: "@anthropic-ai/claude-code", cmd: "claude update")
    }
    // Rust
    if has("rustup") {
        for line in shi("rustup check 2>&1").out.split(separator: "\n") where line.contains("update available") {
            let name = line.components(separatedBy: " - ").first ?? "rust"
            let vers = line.components(separatedBy: ": ").last?.components(separatedBy: " -> ") ?? []
            out.append(UpdateItem(kind: .dev, key: "rust:" + name, name: name.hasPrefix("rustup") ? "rustup" : "Rust \(name)",
                                  from: firstVersion(vers.first ?? ""), to: firstVersion(vers.last ?? ""), cmd: "rustup update"))
        }
    }
    // uv (installer standalone: si aggiorna da solo)
    let uvPath = shi("command -v uv").out.trimmingCharacters(in: .whitespacesAndNewlines)
    if uvPath.hasPrefix(HOME) {
        let cur = firstVersion(shi("uv --version").out)
        if let d = try? JSONSerialization.jsonObject(with: Data(run(["/usr/bin/curl", "-fsS", "--max-time", "8", "https://pypi.org/pypi/uv/json"]).out.utf8)) as? [String: Any],
           let latest = (d["info"] as? [String: Any])?["version"] as? String, compareVersions(cur, latest) {
            out.append(UpdateItem(kind: .dev, key: "uv", name: "uv", from: cur, to: latest, cmd: "uv self update"))
        }
    }
    // Node LTS (nvm)
    if FileManager.default.fileExists(atPath: HOME + "/.nvm/nvm.sh"),
       let index = try? JSONSerialization.jsonObject(with: Data(run(["/usr/bin/curl", "-fsS", "--max-time", "8", "https://nodejs.org/dist/index.json"]).out.utf8)) as? [[String: Any]],
       let lts = index.first(where: { !($0["lts"] is Bool) })?["version"] as? String {
        let installed = subdirs(HOME + "/.nvm/versions/node")
        let latestInstalled = installed.max(by: compareVersions) ?? ""
        if !installed.contains(lts), compareVersions(latestInstalled, lts) || !installed.contains(where: { $0.hasPrefix(lts.split(separator: ".").first.map(String.init) ?? "") }) {
            out.append(UpdateItem(kind: .dev, key: "node-lts", name: "Node.js LTS (nvm)", from: latestInstalled, to: lts,
                                  cmd: "source ~/.nvm/nvm.sh && nvm install --lts --reinstall-packages-from=default && nvm alias default 'lts/*'"))
        }
    }
    return out
}

// MARK: - Notch

/// Dove sta il mouse -> cosa fare. Logica pura, così si testa senza schermo.
struct NotchZones {
    enum Intent { case open, close, stay }
    let hot: CGRect   // il notch (+ qualche punto): sosta qui = apri
    let open: CGRect  // il pannello aperto: uscirne = chiudi

    func decide(_ p: CGPoint, expanded: Bool) -> Intent {
        if expanded { return open.insetBy(dx: -8, dy: -8).contains(p) ? .stay : .close }
        return hot.contains(p) ? .open : .stay
    }

    static func make(screen: CGRect, notch: CGSize, open: CGSize) -> NotchZones {
        NotchZones(hot: CGRect(x: screen.midX - notch.width / 2 - 4, y: screen.maxY - notch.height, width: notch.width + 8, height: notch.height + 1),
                   open: CGRect(x: screen.midX - open.width / 2, y: screen.maxY - open.height, width: open.width, height: open.height))
    }
}

@MainActor @Observable final class NotchState {
    var expanded: Bool
    init(expanded: Bool = false) { self.expanded = expanded }
}

/// I pulsanti rispondono al primo clic anche se MacSweep non è l'app attiva.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pannello stile Dynamic Island. Finestra di dimensione fissa che lascia passare i clic quando è chiusa;
/// apre/chiude un monitor del mouse (sosta sul notch = apri, uscita o clic fuori = chiudi). Niente ridimensionamenti = niente sfarfallio.
@MainActor final class NotchController {
    static let shared = NotchController()
    static let panelSize = CGSize(width: 500, height: 250)  // un po' più grande dell'aperto: c'è l'ombra
    static let openSize = CGSize(width: 452, height: 210)

    let state = NotchState()
    private var panel: NSPanel?
    private weak var store: Store?
    private var zones: NotchZones?
    private var monitors: [Any] = []
    private var pendingOpen: Task<Void, Never>?
    private var pendingClose: Task<Void, Never>?

    func start(store: Store) {
        self.store = store
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchController.shared.update() }
        }
        update()
    }

    static var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } }

    func update() {
        guard UserDefaults.standard.object(forKey: "notch") as? Bool ?? true, let store, let screen = Self.notchScreen,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            panel?.orderOut(nil); panel = nil; zones = nil
            monitors.forEach(NSEvent.removeMonitor); monitors = []
            return
        }
        let notch = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        zones = .make(screen: screen.frame, notch: notch, open: Self.openSize)
        let size = Self.panelSize
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.isMovable = false
            p.acceptsMouseMovedEvents = true
            panel = p
        }
        panel?.ignoresMouseEvents = !state.expanded
        panel?.contentView = FirstClickHostingView(rootView: NotchView(notch: notch, state: state).environment(store))
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
        installMonitors()
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { e in MainActor.assumeIsolated { NotchController.shared.mouse(e) } }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: types, handler: { e in MainActor.assumeIsolated { NotchController.shared.mouse(e) }; return e }) {
            monitors.append(l)
        }
    }

    private func mouse(_ e: NSEvent) {
        guard let z = zones else { return }
        let p = NSEvent.mouseLocation
        if e.type == .leftMouseDown && state.expanded && !z.open.contains(p) { close(); return }
        switch z.decide(p, expanded: state.expanded) {
        case .open:
            guard pendingOpen == nil else { return }
            // sosta di 120 ms: passarci sopra per andare alla barra dei menu non lo apre
            pendingOpen = Task {
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled, z.hot.contains(NSEvent.mouseLocation) { open() }
                pendingOpen = nil
            }
        case .close:
            guard pendingClose == nil else { return }
            pendingClose = Task {
                try? await Task.sleep(for: .milliseconds(280))
                if !Task.isCancelled, z.decide(NSEvent.mouseLocation, expanded: true) == .close { close() }
                pendingClose = nil
            }
        case .stay:
            if state.expanded { pendingClose?.cancel(); pendingClose = nil } else { pendingOpen?.cancel(); pendingOpen = nil }
        }
    }

    func open() {
        guard !state.expanded, panel != nil else { return }
        panel?.ignoresMouseEvents = false
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) { state.expanded = true }
    }

    func close() {
        guard state.expanded else { return }
        pendingClose?.cancel(); pendingClose = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { state.expanded = false }
        panel?.ignoresMouseEvents = true  // da chiuso, i clic passano alla barra dei menu sotto
    }
}

struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        // angoli in alto "concavi" come il notch vero, in basso arrotondati
        let top: CGFloat = 6
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottomRadius, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottomRadius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottomRadius), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @Environment(Store.self) private var s
    let notch: CGSize
    let state: NotchState

    /// Da chiuso il notch non si allarga mai di lato (lì ci sono le icone della barra dei menu):
    /// i messaggi scendono sotto in una piccola goccia, le scansioni sono una linea sottile.
    var body: some View {
        let expanded = state.expanded
        let open = NotchController.openSize
        let flash = s.notchFlash
        let scanning = s.scanning || s.refreshing
        let w: CGFloat = expanded ? open.width - 12 : notch.width  // da chiuso mai più largo del notch
        let h: CGFloat = expanded ? open.height : flash != nil ? notch.height + 28 : scanning ? notch.height + 6 : notch.height
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: expanded ? 24 : flash != nil ? 16 : 10)
                    .fill(.black)
                    .frame(width: w + 12, height: h)
                    .shadow(color: .black.opacity(expanded ? 0.4 : 0), radius: 18, y: 8)
                if expanded {
                    expandedContent
                        .frame(width: w - 20, height: h)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.1)),
                                                removal: .opacity.animation(.easeIn(duration: 0.08))))
                } else if let f = flash {
                    HStack(spacing: 6) {
                        Image(systemName: f.symbol).foregroundStyle(f.color)
                        Text(f.text).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(width: w, height: 26)
                    .padding(.top, notch.height)
                    .transition(.opacity.combined(with: .offset(y: -6)))
                } else if scanning {
                    Capsule().fill(Color.blue.gradient)
                        .frame(width: notch.width * 0.5, height: 3)
                        .padding(.top, notch.height + 1)
                        .phaseAnimator([0.35, 1]) { v, phase in v.opacity(phase) } animation: { _ in .easeInOut(duration: 0.8) }
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: flash)
        .animation(.easeOut(duration: 0.3), value: scanning)
        .preferredColorScheme(.dark)
    }

    var expandedContent: some View {
        let used = max(s.total - s.free, 0)
        let trash = s.categories.first { $0.id == "trash" }?.size ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            Spacer().frame(height: notch.height - 6)
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 7)
                    Circle().trim(from: 0, to: Double(used) / Double(max(s.total, 1)))
                        .stroke((s.lowSpace ? Color.orange : .blue).gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "internaldrive.fill").foregroundStyle(.white.opacity(0.8))
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fmt(s.free)) liberi").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(s.scanning || s.refreshing ? "Scansione in corso · \(s.scanCount.formatted()) cartelle"
                         : "su \(fmt(s.total)) · RAM \(fmtMem(memStats().used))")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                }
                Spacer()
            }
            HStack(spacing: 8) {
                NotchButton(symbol: "trash.fill", title: s.emptyingTrash ? "Svuoto…" : trash > 0 ? "Svuota \(fmt(trash))" : "Cestino vuoto",
                            color: .red) { s.emptyTrash() }
                    .disabled(trash == 0 || s.emptyingTrash)
                NotchButton(symbol: "sparkles", title: "Pulizia rapida", color: .purple) { s.openMain(quickClean: true) }
                NotchButton(symbol: "macwindow", title: "Apri", color: .blue) { s.openMain() }
            }
        }
        .padding(.horizontal, 10)
    }
}

struct NotchButton: View {
    let symbol: String, title: String, color: Color
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            NotchController.shared.close()  // prima si chiude il pannello, poi l'azione (dialoghi, finestra)
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(color.opacity(hover && enabled ? 0.55 : 0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(hover && enabled ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.25)) { hover = h } }
    }
}
