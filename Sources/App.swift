import AppKit
import Charts
import SwiftUI

@main enum Entry {
    static func main() {
        UserDefaults.standard.register(defaults: ["menuBar": true, "alertOn": true, "alertGB": 30])
        if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
        if let i = CommandLine.arguments.firstIndex(of: "--render-map"), CommandLine.arguments.count > i + 2 {
            // verifica senza interfaccia: disegna la mappa a raggiera di una cartella in un PNG
            let dir = CommandLine.arguments[i + 1], out = CommandLine.arguments[i + 2]
            MainActor.assumeIsolated {
                let store = Store()
                store.sizes = duTree(dir)
                store.path = dir
                store.items = listDir(dir, sizes: store.sizes) ?? []
                let view = SunburstView(preset: sunburstArcs(root: dir, items: store.items, sizes: store.sizes))
                    .environment(store).frame(width: 900, height: 600).background(Color(white: 0.12)).environment(\.colorScheme, .dark)
                let r = ImageRenderer(content: view)
                r.scale = 2
                try? r.nsImage.flatMap { NSBitmapImageRep(data: $0.tiffRepresentation!)?.representation(using: .png, properties: [:]) }?
                    .write(to: URL(fileURLWithPath: out))
                print("mappa: \(store.items.count) voci, \(sunburstArcs(root: dir, items: store.items, sizes: store.sizes).count) archi -> \(out)")
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), CommandLine.arguments.count > i + 1 {
            // verifica senza interfaccia: notch aperto, notch con attività, festa
            let dir = CommandLine.arguments[i + 1]
            MainActor.assumeIsolated {
                let store = Store()
                store.refreshDisk()
                if let last = store.history.last { for j in store.categories.indices { store.categories[j].size = last.cats[store.categories[j].id] } }
                let notch = CGSize(width: 185, height: 32)
                @MainActor func save<V: View>(_ v: V, _ name: String, _ size: CGSize) {
                    let r = ImageRenderer(content: v.environment(store).frame(width: size.width, height: size.height)
                        .background(Color(white: 0.85)).environment(\.colorScheme, .dark))
                    r.scale = 2
                    try? r.nsImage.flatMap { NSBitmapImageRep(data: $0.tiffRepresentation!)?.representation(using: .png, properties: [:]) }?
                        .write(to: URL(fileURLWithPath: dir + "/" + name))
                }
                save(NotchView(notch: notch, state: NotchState(expanded: true)), "notch-aperto.png", CGSize(width: 520, height: 240))
                store.notchFlash = NotchFlash(symbol: "checkmark.circle.fill", text: "+12,4 GB liberi", color: .green)
                save(NotchView(notch: notch, state: NotchState()), "notch-attivita.png", CGSize(width: 520, height: 80))
                store.notchFlash = nil
                store.scanning = true
                save(NotchView(notch: notch, state: NotchState()), "notch-scansione.png", CGSize(width: 520, height: 60))
                store.scanning = false
                save(CelebrationOverlay(bytes: 12_400_000_000, title: "Pulizia rapida completata").background(Color(white: 0.15)),
                     "festa.png", CGSize(width: 700, height: 420))
                save(QuickCleanSheet().background(Color(white: 0.15)), "pulizia-rapida.png", CGSize(width: 520, height: 560))
                print("ok")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--autoclean") {  // lanciato da launchd (Pulizia programmata)
            let r = runAutoclean(loadAutoclean())
            notify("Pulizia programmata", "Liberati \(fmt(r.freed)) · \(r.report)")
            Thread.sleep(forTimeInterval: 2)  // lascia partire la notifica
            exit(0)
        }
        if CommandLine.arguments.contains("--diag") {
            let out = ["~/.Trash", "~/Library/Mail", "~/Library/Safari", "~/Library/Containers/com.apple.mail"].map { p -> String in
                do { return "OK  \(p): \(try FileManager.default.contentsOfDirectory(atPath: expand(p)).count) voci" }
                catch { return "NO  \(p): \(error.localizedDescription)" }
            }.joined(separator: "\n")
            try? (Bundle.main.bundlePath + "\n" + out).write(toFile: "/tmp/macsweep-diag.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        MacSweepApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // con l'icona nella barra dei menu l'app resta viva (fotografie e avvisi)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !UserDefaults.standard.bool(forKey: "menuBar") }
}

struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = Store()
    @AppStorage("menuBar") private var menuBar = true

    var body: some Scene {
        WindowGroup("MacSweep", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    store.start()
                    NotchController.shared.start(store: store)
                }
        }
        .defaultSize(width: 1220, height: 800)

        MenuBarExtra(isInserted: $menuBar) {
            MenuBarView().environment(store)
        } label: {
            Text("\(Image(systemName: store.lowSpace ? "exclamationmark.triangle.fill" : "internaldrive")) \(store.free / 1_000_000_000) GB")
        }
        .menuBarExtraStyle(.window)
    }
}

extension Page {
    var color: Color {
        switch self {
        case .overview: .blue
        case .history: .teal
        case .explore: .cyan
        case .big: .orange
        case .downloads: .indigo
        case .volumes: .gray
        case .toolchains: .green
        case .brew: .orange
        case .git: .purple
        case .browsers: .blue
        case .performance: .pink
        case .updates: .cyan
        case .battery: .green
        case .dev: .purple
        case .docker: .blue
        case .sims: .green
        case .ai: .pink
        case .vms: .brown
        case .apps: .red
        case .startup: .yellow
        case .maint: .gray
        case .log: .mint
        }
    }
}

struct ContentView: View {
    @Environment(Store.self) private var s

    var body: some View {
        @Bindable var s = s
        NavigationSplitView {
            List(selection: $s.page) {
                ForEach(Page.sections, id: \.0) { title, pages in
                    Section(title) {
                        ForEach(pages) { p in
                            Label {
                                Text(p.rawValue)
                            } icon: {
                                IconBadge(symbol: p.icon, color: p.color, size: 22)
                            }
                            .badge(badge(p))
                            .tag(p)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 230)
        } detail: {
            ZStack {
            Group {
                switch s.page ?? .overview {
                case .overview: OverviewView()
                case .history: HistoryView()
                case .explore: ExploreView()
                case .downloads: DownloadsView()
                case .volumes: VolumesView()
                case .toolchains: ToolsView()
                case .brew: BrewView()
                case .git: GitView()
                case .browsers: BrowsersView()
                case .performance: PerformanceView()
                case .updates: UpdatesView()
                case .battery: BatteryView()
                case .docker: DockerView()
                case .sims: SimsView()
                case .ai: AIView()
                case .vms: VMView()
                case .startup: StartupView()
                case .log: LogView()
                case .apps: UninstallView()
                case .big: BigFilesView()
                case .dev: DevJunkView()
                case .maint: MaintenanceView()
                }
            }
            .id(s.page)
            .transition(.opacity.combined(with: .offset(y: 10)))
            }
            .animation(.easeOut(duration: 0.22), value: s.page)
            .toolbar(removing: .title)
            .overlay(alignment: .bottom) { Toast(text: s.status) }
            .animation(.spring(duration: 0.35), value: s.status)
            .overlay { if let c = s.celebration { CelebrationOverlay(bytes: c.bytes, title: c.title).id(c.id) } }
            .sheet(isPresented: $s.showQuickClean) { QuickCleanSheet().environment(s) }
        }
    }

    func badge(_ p: Page) -> Text? {
        switch p {
        case .overview: s.cleanable > 0 ? Text(fmt(s.cleanable)) : nil
        case .dev: s.devSearched ? Text(fmt(s.dev.reduce(0) { $0 + $1.size })) : nil
        default: nil
        }
    }
}

// MARK: - Componenti

/// Icona colorata in quadrato arrotondato, stile Impostazioni di Sistema.
struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .shadow(color: color.opacity(0.3), radius: 2, y: 1)
    }
}

struct SizeBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 6
    @State private var grown = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.gradient).frame(width: max(height, g.size.width * min(1, grown ? fraction : 0)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.5), value: fraction)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { grown = true } }
    }
}

/// Entrata morbida, sfalsata con `delay` (card in sequenza).
struct Appear: ViewModifier {
    let delay: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .scaleEffect(shown ? 1 : 0.97)
            .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(delay)) { shown = true } }
    }
}

extension View {
    func appear(delay: Double = 0) -> some View { modifier(Appear(delay: delay)) }
}

/// Icona vera del Finder per file/cartelle/app.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct Card: ViewModifier {
    var hover = false
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(hover ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(hover ? 0.14 : 0.07)))
            .shadow(color: .black.opacity(hover ? 0.18 : 0), radius: 12, y: 4)
            .scaleEffect(hover ? 1.012 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
    }
}

extension View {
    func card(hover: Bool = false) -> some View { modifier(Card(hover: hover)) }
}

struct Pill: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .green

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            let bad = text.hasPrefix("Errore") || text.contains("errori") || text.contains("saltati")
            HStack(spacing: 8) {
                Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(bad ? .orange : .green)
                Text(text).lineLimit(2)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.bold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

let PALETTE: [Color] = [.blue, .purple, .pink, .orange, .yellow, .green, .teal, .indigo]

func tilde(_ p: String) -> String { p.hasPrefix(HOME) ? "~" + p.dropFirst(HOME.count) : p }

/// Menu contestuale comune: Finder + Cestino.
@MainActor @ViewBuilder
func fileMenu(_ ids: Set<String>, _ s: Store) -> some View {
    Button("Mostra nel Finder", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
    }
    Button("Copia percorso", systemImage: "doc.on.doc") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ids.sorted().joined(separator: "\n"), forType: .string)
    }
    Divider()
    Button("Sposta nel Cestino", systemImage: "trash", role: .destructive) { s.trash(Array(ids)) }
}

// MARK: - Panoramica

struct Segment: Identifiable {
    let id: String, label: String, size: Int64, color: Color
}

struct OverviewView: View {
    @Environment(Store.self) private var s

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if s.needsFDA { fdaBanner }
                DiskHero()
                HStack(alignment: .bottom) {
                    SectionTitle(title: "Chi occupa cosa", subtitle: "Cache, build, backup e cartelle che crescono di nascosto")
                    Spacer()
                    if s.loadingCats { ProgressView().controlSize(.small) }
                    Button("Ricalcola", systemImage: "arrow.clockwise") { s.loadCategories(); s.refreshDisk() }
                        .keyboardShortcut("r")
                        .disabled(s.loadingCats)
                }
                let top = Double(max(s.categories.compactMap(\.size).max() ?? 1, 1))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach(Array(s.categories.enumerated()), id: \.element.id) { i, c in
                        CategoryCard(c: c, top: top).appear(delay: Double(i) * 0.035)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Panoramica")
    }

    var fdaBanner: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: "lock.shield.fill", color: .orange, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Serve l'Accesso completo al disco").font(.headline)
                Text("Senza, Cestino, Mail e alcuni container risultano vuoti.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Apri Impostazioni") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .card()
    }
}

struct DiskHero: View {
    @Environment(Store.self) private var s
    @State private var sweep = 0.0  // 0 -> 1: l'anello si riempie all'apertura
    @State private var sparkle = 0

    var segments: [Segment] {
        let used = max(s.total - s.free, 0)
        let known = s.categories.filter { ($0.size ?? 0) > 0 }.prefix(7)
        var segs = known.map { Segment(id: $0.id, label: $0.label, size: $0.size!, color: $0.color) }
        let rest = used - segs.reduce(0) { $0 + $1.size }
        if rest > 0 { segs.append(Segment(id: "other", label: "Sistema e altro", size: rest, color: .gray.opacity(0.55))) }
        segs.append(Segment(id: "free", label: "Libero", size: s.free, color: .primary.opacity(0.08)))
        return segs
    }

    /// Stesse fette, ma l'usato cresce con `sweep` e il resto è "libero".
    var animated: [Segment] {
        var segs = segments.filter { $0.id != "free" }.map { Segment(id: $0.id, label: $0.label, size: Int64(Double($0.size) * sweep), color: $0.color) }
        segs.append(Segment(id: "free", label: "Libero", size: max(s.total - segs.reduce(0) { $0 + $1.size }, 0), color: .primary.opacity(0.08)))
        return segs
    }

    var body: some View {
        let used = max(s.total - s.free, 0)
        let pct = s.total > 0 ? Double(used) / Double(s.total) * sweep : 0
        let trash = s.categories.first { $0.id == "trash" }?.size ?? 0
        HStack(alignment: .center, spacing: 32) {
            Chart(animated) { seg in
                SectorMark(angle: .value("Byte", seg.size), innerRadius: .ratio(0.64), angularInset: 1.2)
                    .cornerRadius(3)
                    .foregroundStyle(seg.color)
            }
            .chartLegend(.hidden)
            .frame(width: 190, height: 190)
            .overlay {
                VStack(spacing: 0) {
                    Text(pct, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("usato").font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Macintosh HD", systemImage: "internaldrive.fill")
                    .font(.headline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(fmt(s.free))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("liberi su \(fmt(s.total)) · \(fmt(used)) usati").foregroundStyle(.secondary)
                }
                if s.cleanable > 0 {
                    Pill(text: "Puoi liberare subito \(fmt(s.cleanable))", symbol: "sparkles")
                        .font(.callout)
                }
                HStack(spacing: 10) {
                    // ponytail: niente animazioni infinite, ridisegnano tutta la finestra (50% di CPU a riposo)
                    Button { s.showQuickClean = true } label: {
                        Label("Pulizia rapida", systemImage: "sparkles").symbolEffect(.bounce, value: sparkle)
                    }
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .onHover { if $0 { sparkle += 1 } }
                    if trash > 0 {
                        Button { s.emptyTrash() } label: { Label(s.emptyingTrash ? "Svuoto…" : "Svuota Cestino · \(fmt(trash))", systemImage: "trash") }
                            .buttonStyle(.bordered).tint(.red).disabled(s.emptyingTrash)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(segments) { seg in
                    HStack(spacing: 8) {
                        Circle().fill(seg.color).frame(width: 9, height: 9)
                        Text(seg.label).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(fmt(seg.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .frame(width: 250)
        }
        .padding(22)
        .card()
        .animation(.easeInOut(duration: 0.6), value: s.categories.map(\.size))
        .onAppear { withAnimation(.easeOut(duration: 1.1)) { sweep = 1 } }
    }
}

struct CategoryCard: View {
    @Environment(Store.self) private var s
    let c: Category
    let top: Double
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                IconBadge(symbol: c.symbol, color: c.color, size: 38)
                Spacer()
                if c.cleanable { Pill(text: "Pulibile", symbol: "sparkles") }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.label).font(.headline)
                Text(c.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Group {
                if let size = c.size {
                    Text(fmt(size)).contentTransition(.numericText())
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .frame(height: 30, alignment: .leading)
            SizeBar(fraction: Double(c.size ?? 0) / top, color: c.color)
            HStack {
                Button("Esplora", systemImage: "folder") { s.explore(c.path) }
                Spacer()
                if c.cleanable {
                    Button("Pulisci", systemImage: "trash") { s.clean(c) }
                        .buttonStyle(.borderedProminent)
                        .tint(c.color == .yellow ? .orange : c.color)
                        .disabled((c.size ?? 0) == 0)
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .card(hover: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - Esplora

struct ExploreView: View {
    @Environment(Store.self) private var s

    var body: some View {
        @Bindable var s = s
        let total = s.sizes[s.path] ?? s.items.reduce(0) { $0 + $1.size }
        let top = Double(max(s.items.first?.size ?? 1, 1))
        let topItems = Array(s.items.prefix(8).filter { $0.size > 0 })
        let colorOf = Dictionary(uniqueKeysWithValues: topItems.enumerated().map { ($1.path, PALETTE[$0]) })
        VStack(spacing: 0) {
            // intestazione cartella
            HStack(spacing: 14) {
                FileIcon(path: s.path, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.path == "/" ? "Disco" : (s.path as NSString).lastPathComponent)
                        .font(.title2.weight(.bold))
                    breadcrumb
                }
                Spacer()
                Picker("Vista", selection: $s.exploreMap) {
                    Label("Elenco", systemImage: "list.bullet").tag(false)
                    Label("Mappa", systemImage: "chart.pie.fill").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .padding(.trailing, 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(fmt(total)).font(.system(size: 26, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    Text("\(s.items.count) elementi").font(.callout).foregroundStyle(.secondary)
                    if s.refreshing {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("aggiorno… \(s.scanCount.formatted())").monospacedDigit()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    } else if let t = s.scanTimes[s.path] {
                        Text("scansione \(t.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

            // composizione: barra cliccabile delle 8 voci più grandi
            if !topItems.isEmpty && !s.scanning {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            ForEach(topItems) { i in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(colorOf[i.path]!.gradient)
                                    .frame(width: max(3, (g.size.width - 18) * Double(i.size) / Double(max(total, 1))))
                                    .help("\(i.name) — \(fmt(i.size))")
                                    .onTapGesture { if i.isDir { s.explore(i.path) } }
                            }
                            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                        }
                    }
                    .frame(height: 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(topItems) { i in
                                HStack(spacing: 5) {
                                    Circle().fill(colorOf[i.path]!).frame(width: 8, height: 8)
                                    Text(i.name).lineLimit(1)
                                    Text(fmt(i.size)).foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 14)
            }
            Divider()

            Table(s.items, selection: $s.selection) {
                TableColumn("Nome") { i in
                    HStack(spacing: 8) {
                        FileIcon(path: i.path, size: 20)
                        Text(i.name).lineLimit(1)
                    }
                }
                TableColumn("Dimensione") { i in
                    // cartelle sotto 1 MB non salvate in cache: si misurano quando ci entri
                    Text(i.isDir && s.sizes[i.path] == nil ? "< 1 MB" : fmt(i.size)).monospacedDigit().fontWeight(.medium)
                }
                .width(95)
                TableColumn("%") { i in
                    Text(Double(i.size) / Double(max(total, 1)), format: .percent.precision(.fractionLength(1)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("") { i in SizeBar(fraction: Double(i.size) / top, color: colorOf[i.path] ?? .gray) }
                    .width(min: 80, ideal: 200)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                fileMenu(ids, s)
            } primaryAction: { ids in
                if let id = ids.first, s.items.first(where: { $0.path == id })?.isDir == true { s.explore(id) }
            }
            .overlay {
                if s.scanning {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Scansione di \(tilde(s.path))…").font(.headline)
                        Text("\(s.scanCount.formatted()) cartelle analizzate")
                            .monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
                        Text("La prima volta su cartelle grandi può richiedere qualche minuto.\nPoi la navigazione è istantanea.")
                            .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if s.unreadable {
                    ContentUnavailableView("Cartella non leggibile", systemImage: "lock.fill",
                                           description: Text("Serve l'Accesso completo al disco per MacSweep."))
                }
            }
            .overlay {
                if s.exploreMap && !s.scanning && !s.unreadable {
                    SunburstView().background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .navigationTitle("Esplora")
        .toolbar {
            ToolbarItemGroup {
                Button("Su", systemImage: "arrow.up") { s.explore((s.path as NSString).deletingLastPathComponent) }
                    .disabled(s.path == "/")
                Button("Home", systemImage: "house") { s.explore(HOME) }
                Button("Applicazioni", systemImage: "square.grid.3x3") { s.explore("/Applications") }
                Button("Tutto il disco", systemImage: "internaldrive") { s.explore(DATA_VOL) }
                Button("Riscansiona", systemImage: "arrow.clockwise") { s.explore(s.path, rescan: true) }
                    .keyboardShortcut("r")
                Button("Cestina selezionati", systemImage: "trash") { s.trash(Array(s.selection)) }
                    .disabled(s.selection.isEmpty)
            }
        }
        .onAppear { if s.items.isEmpty && !s.scanning { s.explore(s.path) } }
    }

    var breadcrumb: some View {
        let parts = s.path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                Button("Disco") { s.explore("/") }.buttonStyle(.link)
                ForEach(parts.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(parts[i]) { s.explore("/" + parts[...i].joined(separator: "/")) }
                        .buttonStyle(.link)
                        .foregroundStyle(i == parts.count - 1 ? Color.primary : Color.accentColor)
                }
            }
            .font(.callout)
        }
    }
}

// MARK: - File grandi

struct BigFilesView: View {
    @Environment(Store.self) private var s
    @State private var selection = Set<String>()

    var body: some View {
        @Bindable var s = s
        let top = Double(max(s.big.first?.size ?? 1, 1))
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconBadge(symbol: "doc.badge.ellipsis", color: .orange, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("File grandi").font(.title2.weight(.bold))
                    Text(s.big.isEmpty ? "Cerca nella home via Spotlight" :
                            "\(s.big.count) file · \(fmt(s.big.reduce(0) { $0 + $1.size }))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Più grandi di").foregroundStyle(.secondary)
                Picker("", selection: $s.minMB) {
                    ForEach([100, 250, 500, 1000, 2000, 5000], id: \.self) { mb in
                        Text(mb >= 1000 ? "\(mb / 1000) GB" : "\(mb) MB").tag(mb)
                    }
                }
                .labelsHidden().fixedSize()
                .onChange(of: s.minMB) { s.loadBig() }
                if s.loadingBig { ProgressView().controlSize(.small) }
                Button("Cerca", systemImage: "magnifyingglass") { s.loadBig() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r")
            }
            .padding(20)
            Divider()
            Table(s.big, selection: $selection) {
                TableColumn("File") { i in
                    HStack(spacing: 10) {
                        let st = fileStyle(i.path)
                        IconBadge(symbol: st.symbol, color: st.color, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.name).lineLimit(1)
                            Text(tilde((i.path as NSString).deletingLastPathComponent))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 2)
                }
                TableColumn("Modificato") { i in
                    Text(i.date?.formatted(.relative(presentation: .named)) ?? "").foregroundStyle(.secondary)
                }
                .width(120)
                TableColumn("Dimensione") { i in Text(fmt(i.size)).monospacedDigit().fontWeight(.semibold) }.width(95)
                TableColumn("") { i in SizeBar(fraction: Double(i.size) / top, color: fileStyle(i.path).color) }.width(min: 60, ideal: 140)
            }
            .contextMenu(forSelectionType: String.self) { ids in fileMenu(ids, s) } primaryAction: { ids in
                NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
            }
            .overlay {
                if s.big.isEmpty && !s.loadingBig {
                    ContentUnavailableView("Nessun file sopra la soglia", systemImage: "checkmark.seal",
                                           description: Text("Prova una soglia più bassa."))
                }
            }
        }
        .navigationTitle("File grandi")
        .onAppear { if s.big.isEmpty { s.loadBig() } }
    }
}

// MARK: - Progetti dev

struct DevJunkView: View {
    @Environment(Store.self) private var s
    @State private var selection = Set<String>()

    var groups: [(kind: String, count: Int, size: Int64)] {
        Dictionary(grouping: s.dev, by: \.name)
            .map { ($0.key, $0.value.count, $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.2 > $1.2 }
    }

    var body: some View {
        let top = Double(max(s.dev.first?.size ?? 1, 1))
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconBadge(symbol: "hammer.fill", color: .purple, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Progetti dev").font(.title2.weight(.bold))
                    Text(s.devSearched ? "\(fmt(s.dev.reduce(0) { $0 + $1.size })) in \(s.dev.count) cartelle rigenerabili"
                                       : "node_modules, venv, target, Pods, .next… si rigenerano con install/build")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if s.loadingDev { ProgressView().controlSize(.small) }
                Button(s.devSearched ? "Cerca di nuovo" : "Cerca nella home", systemImage: "magnifyingglass") { s.loadDev() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r")
                    .disabled(s.loadingDev)
            }
            .padding(20)

            if s.devSearched && !groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(groups, id: \.kind) { g in
                            let st = devStyle(g.kind)
                            HStack(spacing: 10) {
                                IconBadge(symbol: st.symbol, color: st.color, size: 28)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(g.kind).font(.callout.weight(.semibold))
                                    Text("\(fmt(g.size)) · \(g.count)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .card()
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 14)
            }
            Divider()

            if s.dev.isEmpty {
                Group {
                    if s.loadingDev && s.dev.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text("Cerco nella home…").font(.headline)
                            Text("Può richiedere un minuto.").font(.callout).foregroundStyle(.secondary)
                        }
                    } else if !s.devSearched {
                        ContentUnavailableView {
                            Label("Cartelle rigenerabili", systemImage: "hammer")
                        } description: {
                            Text("Trova node_modules, ambienti Python, build Rust e Pods\nin tutti i tuoi progetti.")
                        } actions: {
                            Button("Cerca nella home") { s.loadDev() }.buttonStyle(.borderedProminent)
                        }
                    } else if s.dev.isEmpty {
                        ContentUnavailableView("Niente da pulire", systemImage: "checkmark.seal")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(s.dev, selection: $selection) {
                    TableColumn("Progetto") { i in
                        let parent = (i.path as NSString).deletingLastPathComponent
                        let st = devStyle(i.name)
                        HStack(spacing: 10) {
                            IconBadge(symbol: st.symbol, color: st.color, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((parent as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1)
                                Text(tilde(parent)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    TableColumn("Tipo") { i in Text(i.name).font(.callout.monospaced()).foregroundStyle(.secondary) }.width(110)
                    TableColumn("Dimensione") { i in Text(fmt(i.size)).monospacedDigit().fontWeight(.semibold) }.width(95)
                    TableColumn("") { i in SizeBar(fraction: Double(i.size) / top, color: devStyle(i.name).color) }.width(min: 60, ideal: 140)
                }
                .contextMenu(forSelectionType: String.self) { ids in fileMenu(ids, s) }
            }
        }
        .navigationTitle("Progetti dev")
    }
}

// MARK: - Manutenzione

struct MaintenanceView: View {
    @Environment(Store.self) private var s

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    IconBadge(symbol: "wrench.and.screwdriver.fill", color: .gray, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manutenzione").font(.title2.weight(.bold))
                        Text("Comandi di pulizia dei tool che usi. L'output resta qui sotto.").foregroundStyle(.secondary)
                    }
                }
                AutocleanCard()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(TASKS) { t in TaskCard(t: t) }
                }
                if let id = s.shownTask, let t = TASKS.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            IconBadge(symbol: t.symbol, color: t.color, size: 24)
                            Text(t.label).font(.headline)
                            Text(t.cmd).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Chiudi", systemImage: "xmark") { s.shownTask = nil }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                        ScrollView {
                            Text(s.results[id]?.output ?? "In corso…")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(height: 200)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(16)
                    .card()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(24)
            .animation(.easeOut(duration: 0.2), value: s.shownTask)
        }
        .navigationTitle("Manutenzione")
    }
}

struct TaskCard: View {
    @Environment(Store.self) private var s
    let t: MaintTask
    @State private var hover = false

    var body: some View {
        let result = s.results[t.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                IconBadge(symbol: t.symbol, color: t.color, size: 38)
                Spacer()
                if s.running == t.id {
                    ProgressView().controlSize(.small)
                } else if let result {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.title3).foregroundStyle(result.ok ? .green : .red)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(t.label).font(.headline)
                Text(t.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            Text(t.cmd).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            HStack {
                Button(s.running == t.id ? "In corso…" : "Esegui", systemImage: "play.fill") { s.runTask(t) }
                    .buttonStyle(.borderedProminent)
                    .tint(t.id == "emptytrash" ? .red : .accentColor)
                    .disabled(s.running != nil)
                Spacer()
                if let result {
                    if result.freed > 0 { Pill(text: "+\(fmt(result.freed))", symbol: "arrow.down") }
                    Button("Output") { s.shownTask = t.id }.buttonStyle(.link)
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .card(hover: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - Disinstalla

struct UninstallView: View {
    @Environment(Store.self) private var s
    @State private var query = ""
    @State private var sort = "size"

    var filtered: [AppInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? s.apps : s.apps.filter { $0.name.lowercased().contains(q) || $0.bundleId.lowercased().contains(q) }
        switch sort {
        case "name": return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case "used": return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        default: return list.sorted { $0.size > $1.size }
        }
    }

    var body: some View {
        @Bindable var s = s
        let list = filtered
        let top = Double(max(s.apps.map(\.size).max() ?? 1, 1))
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    IconBadge(symbol: "xmark.bin.fill", color: .red, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disinstalla programmi").font(.title2.weight(.bold))
                        Text(s.loadingApps && s.apps.isEmpty ? "Leggo le app installate…"
                                : "\(s.apps.count) app · \(fmt(s.apps.reduce(0) { $0 + $1.size }))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.loadingApps { ProgressView().controlSize(.small) }
                    Button("Aggiorna", systemImage: "arrow.clockwise") { s.loadApps() }
                        .keyboardShortcut("r")
                        .disabled(s.loadingApps)
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Cerca app", text: $query).textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button("", systemImage: "xmark.circle.fill") { query = "" }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Picker("Ordina", selection: $sort) {
                        Text("Più grandi").tag("size")
                        Text("Nome").tag("name")
                        Text("Meno usate").tag("used")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
                Divider()
                Table(list, selection: $s.selectedApp) {
                    TableColumn("App") { a in
                        HStack(spacing: 10) {
                            FileIcon(path: a.path, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).fontWeight(.medium).lineLimit(1)
                                Text(a.version.isEmpty ? "—" : "Versione \(a.version)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .width(min: 170, ideal: 200)
                    TableColumn("Ultimo uso") { a in
                        // nil = Spotlight non lo sa, non "mai usata"
                        Text(a.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                            .foregroundStyle(.secondary)
                            .help(a.lastUsed == nil ? "Spotlight non ha la data di ultimo uso" : "")
                    }
                    .width(95)
                    TableColumn("Dimensione") { a in Text(fmt(a.size)).monospacedDigit().fontWeight(.semibold) }.width(80)
                    TableColumn("") { a in SizeBar(fraction: Double(a.size) / top, color: .red) }.width(min: 36, ideal: 50)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Mostra nel Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
                    }
                }
                .overlay {
                    if s.loadingApps && s.apps.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text("Misuro le app installate…").font(.headline)
                        }
                    } else if !query.isEmpty && list.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            AppDetailView()
                .frame(width: 360)
                .frame(maxHeight: .infinity)
        }
        .onAppear { if s.apps.isEmpty && !s.loadingApps { s.loadApps() } }
        .onChange(of: s.selectedApp) { s.loadLeftovers() }
    }
}

struct AppDetailView: View {
    @Environment(Store.self) private var s

    var body: some View {
        if let app = s.apps.first(where: { $0.path == s.selectedApp }) {
            let extra = s.leftovers.filter { s.leftoverSel.contains($0.path) }.reduce(0) { $0 + $1.size }
            let running = !app.bundleId.isEmpty && !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId).isEmpty
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        FileIcon(path: app.path, size: 96)
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                        Text(app.name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                        Text(app.bundleId).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 6) {
                            if !app.version.isEmpty { Pill(text: "v\(app.version)", color: .blue) }
                            if app.fromAppStore { Pill(text: "App Store", symbol: "bag.fill", color: .blue) }
                            if running { Pill(text: "Aperta", symbol: "circle.fill", color: .green) }
                            if app.isSystem { Pill(text: "Sistema", symbol: "lock.fill", color: .gray) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)

                    HStack(spacing: 0) {
                        stat("App", app.size)
                        Divider()
                        stat("Residui", extra)
                        Divider()
                        stat("Totale", app.size + extra, strong: true)
                    }
                    .frame(height: 52)
                    .padding(.vertical, 8)
                    .card()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("File residui").font(.headline)
                            Spacer()
                            if s.loadingLeftovers { ProgressView().controlSize(.small) }
                            else { Text("\(s.leftoverSel.count) di \(s.leftovers.count)").font(.callout).foregroundStyle(.secondary) }
                        }
                        if s.leftovers.isEmpty && !s.loadingLeftovers {
                            Label("Nessun residuo trovato in ~/Library", systemImage: "checkmark.seal")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(s.leftovers) { item in
                            let st = leftoverStyle(item.path)
                            Toggle(isOn: Binding(
                                get: { s.leftoverSel.contains(item.path) },
                                set: { if $0 { s.leftoverSel.insert(item.path) } else { s.leftoverSel.remove(item.path) } }
                            )) {
                                HStack(spacing: 8) {
                                    IconBadge(symbol: st.symbol, color: st.color, size: 24)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(st.label).font(.callout.weight(.medium))
                                        Text(item.name).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 6)
                                    Text(fmt(item.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .help(tilde(item.path))
                            .contextMenu {
                                Button("Mostra nel Finder", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                                }
                            }
                        }
                    }
                    .padding(14)
                    .card()

                    VStack(spacing: 8) {
                        Button(role: .destructive) { s.uninstall(app) } label: {
                            Label("Disinstalla \(app.name)", systemImage: "trash.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                        .disabled(app.isSystem || s.loadingLeftovers)
                        Text(app.isSystem ? "App di sistema protetta da macOS: non si può rimuovere."
                                          : "Tutto va nel Cestino: puoi rimetterlo al suo posto finché non lo svuoti.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("Seleziona un'app", systemImage: "app.dashed",
                                   description: Text("Vedi quanto occupa e cosa lascia in giro,\npoi disinstallala con un clic."))
        }
    }

    func stat(_ label: String, _ v: Int64, strong: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(fmt(v))
                .font(.system(.title3, design: .rounded).weight(strong ? .bold : .semibold))
                .foregroundStyle(strong ? Color.red : Color.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }
}
