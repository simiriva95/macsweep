import AppKit
import SwiftUI

// MARK: - Riga semplice (senza dimensione)

struct SimpleRow<Trailing: View>: View {
    let icon: RowIcon
    let title: String
    var subtitle = ""
    var pills: [(String, Color)] = []
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            switch icon {
            case .file(let p): FileIcon(path: p, size: 30)
            case .symbol(let s, let c): IconBadge(symbol: s, color: c, size: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    ForEach(pills.indices, id: \.self) { i in Pill(text: pills[i].0, color: pills[i].1) }
                }
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Mappa a raggiera (Esplora)

struct SunArc: Identifiable {
    var id: String { path }
    let path: String, name: String, size: Int64, depth: Int, start: Double, end: Double, color: Color, isDir: Bool
}

/// Anelli: 1 = contenuto della cartella (file e cartelle), 2-3 = sottocartelle dalla cache di du.
func sunburstArcs(root: String, items: [Item], sizes: [String: Int64]) -> [SunArc] {
    let total = Double(max(sizes[root] ?? items.reduce(0) { $0 + $1.size }, 1))
    let base = root.split(separator: "/").count
    let prefix = root == "/" ? "/" : root + "/"
    var kids: [String: [(String, Int64)]] = [:]
    for (k, v) in sizes where k.hasPrefix(prefix) && v > 0 {
        let d = k.split(separator: "/").count - base
        if d == 2 || d == 3 { kids[(k as NSString).deletingLastPathComponent, default: []].append((k, v)) }
    }
    let minSpan = 0.008  // ~0,5°: sotto non si vede né si clicca
    var arcs: [SunArc] = []
    func children(_ parent: String, _ parentSize: Int64, _ start: Double, _ span: Double, _ depth: Int, _ color: Color) {
        guard depth <= 3, parentSize > 0 else { return }
        var a = start
        for (p, sz) in (kids[parent] ?? []).sorted(by: { $0.1 > $1.1 }) {
            let s = span * Double(sz) / Double(parentSize)
            if s < minSpan { break }
            arcs.append(SunArc(path: p, name: (p as NSString).lastPathComponent, size: sz, depth: depth, start: a, end: a + s, color: color, isDir: true))
            children(p, sz, a, s, depth + 1, color)
            a += s
        }
    }
    var a = -Double.pi / 2
    for (i, it) in items.filter({ $0.size > 0 }).enumerated() {
        let s = 2 * Double.pi * Double(it.size) / total
        if s < minSpan { break }
        let color = i < PALETTE.count ? PALETTE[i] : Color.gray
        arcs.append(SunArc(path: it.path, name: it.name, size: it.size, depth: 1, start: a, end: a + s, color: color, isDir: it.isDir))
        if it.isDir { children(it.path, it.size, a, s, 2, color) }
        a += s
    }
    return arcs
}

struct SunburstView: View {
    @Environment(Store.self) private var s
    @State private var arcs: [SunArc]
    @State private var hovered: SunArc? = nil

    init(preset: [SunArc] = []) { _arcs = State(initialValue: preset) }

    let inner: Double = 70, ring: Double = 64

    var body: some View {
        GeometryReader { g in
            let d = min(g.size.height - 40, g.size.width - 320, 2 * (inner + 3 * ring))
            let scale = max(d, 200) / (2 * (inner + 3 * ring))
            HStack(spacing: 24) {
                ZStack {
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        for arc in arcs {
                            let r0 = (inner + Double(arc.depth - 1) * ring) * scale, r1 = r0 + ring * scale - 2
                            var path = Path()
                            path.addArc(center: c, radius: r1, startAngle: .radians(arc.start), endAngle: .radians(arc.end), clockwise: false)
                            path.addArc(center: c, radius: r0, startAngle: .radians(arc.end), endAngle: .radians(arc.start), clockwise: true)
                            path.closeSubpath()
                            let hot = hovered?.path == arc.path || (hovered.map { arc.path.hasPrefix($0.path + "/") } ?? false)
                            let alpha = [1.0, 0.72, 0.48][arc.depth - 1] * (hovered == nil || hot ? 1 : 0.45)
                            ctx.fill(path, with: .color(arc.color.opacity(alpha)))
                            ctx.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1)
                        }
                    }
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hovered = hit(p, size: CGSize(width: d, height: d), scale: scale) } else { hovered = nil }
                    }
                    .gesture(SpatialTapGesture().onEnded { e in
                        if let a = hit(e.location, size: CGSize(width: d, height: d), scale: scale), a.isDir { s.explore(a.path) }
                    })
                    VStack(spacing: 2) {
                        Text(hovered?.name ?? (s.path == "/" ? "Disco" : (s.path as NSString).lastPathComponent))
                            .font(.headline).lineLimit(2).multilineTextAlignment(.center)
                        Text(fmt(hovered?.size ?? s.sizes[s.path] ?? s.items.reduce(0) { $0 + $1.size }))
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        if hovered?.isDir == true { Text("clic per entrare").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .frame(width: inner * 1.7 * scale)
                    .allowsHitTesting(false)
                }
                .frame(width: d, height: d)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Più grandi").font(.headline)
                    ForEach(arcs.filter { $0.depth == 1 }.prefix(10)) { a in
                        HStack(spacing: 8) {
                            Circle().fill(a.color).frame(width: 9, height: 9)
                            Text(a.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(fmt(a.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                        .onTapGesture { if a.isDir { s.explore(a.path) } }
                        .onHover { hovered = $0 ? a : nil }
                    }
                    Spacer()
                    Text("Anello interno: questa cartella. Anelli esterni: le sottocartelle. Clic su una fetta per entrare.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .task(id: "\(s.path)|\(s.items.count)|\(s.sizes[s.path] ?? 0)") {
            let (root, items, sizes) = (s.path, s.items, s.sizes)
            arcs = await Task.detached { sunburstArcs(root: root, items: items, sizes: sizes) }.value
        }
    }

    func hit(_ p: CGPoint, size: CGSize, scale: Double) -> SunArc? {
        let dx = p.x - size.width / 2, dy = p.y - size.height / 2
        let r = (dx * dx + dy * dy).squareRoot() / scale
        guard r > inner else { return nil }
        let depth = Int((r - inner) / ring) + 1
        guard depth <= 3 else { return nil }
        var a = atan2(dy, dx)
        if a < -Double.pi / 2 { a += 2 * Double.pi }
        return arcs.first { $0.depth == depth && a >= $0.start && a < $0.end }
    }
}

// MARK: - Browser e privacy

struct BrowsersView: View {
    @Environment(Store.self) private var s

    var body: some View {
        let m = s.browsers
        VStack(spacing: 0) {
            PageHeader(page: .browsers, subtitle: "Cache, cronologia e cookie, browser per browser") {
                if m.loading { ProgressView().controlSize(.small) }
                Button("Aggiorna", systemImage: "arrow.clockwise") { m.load() }.keyboardShortcut("r")
            }
            Divider()
            if m.loading && m.browsers.isEmpty {
                Loading(text: "Misuro i dati dei browser…")
            } else if m.browsers.isEmpty {
                ContentUnavailableView("Nessun browser trovato", systemImage: "globe").frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)], spacing: 14) {
                        ForEach(m.browsers) { b in card(b) }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear { if !m.loaded && !m.loading { m.load() } }
    }

    func card(_ b: BrowserInfo) -> some View {
        let m = s.browsers
        let sel = b.parts.filter { m.selected.contains("\(b.bundleId)/\($0.id)") }.reduce(0) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FileIcon(path: b.appPath, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(b.name).font(.headline)
                        if b.running { Pill(text: "Aperto", symbol: "circle.fill", color: .green) }
                    }
                    Text("\(fmt(b.parts.reduce(0) { $0 + $1.size })) di dati").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(b.parts) { p in
                let key = "\(b.bundleId)/\(p.id)"
                Toggle(isOn: Binding(get: { m.selected.contains(key) }, set: { if $0 { m.selected.insert(key) } else { m.selected.remove(key) } })) {
                    HStack(spacing: 8) {
                        IconBadge(symbol: p.symbol, color: p.id == "cache" ? .orange : p.id == "history" ? .blue : .purple, size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.label).fontWeight(.medium)
                            if !p.warning.isEmpty { Text(p.warning).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        Text(fmt(p.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(p.paths.isEmpty)
            }
            Button("Pulisci selezionati (\(fmt(sel)))", systemImage: "sparkles") { m.clean(b, store: s) }
                .buttonStyle(.borderedProminent)
                .disabled(sel == 0)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(b.name)
    }
}

// MARK: - Prestazioni

struct PerformanceView: View {
    @Environment(Store.self) private var s
    @State private var byCPU = true

    var body: some View {
        let m = s.perf
        let procs = m.procs.sorted { byCPU ? $0.cpu > $1.cpu : $0.mem > $1.mem }.prefix(30)
        let top = Double(m.procs.map(\.mem).max() ?? 1)
        VStack(spacing: 0) {
            PageHeader(page: .performance, subtitle: "Memoria, CPU e le app che le usano · aggiornato ogni 2 secondi") {
                Picker("", selection: $byCPU) {
                    Text("Per CPU").tag(true)
                    Text("Per memoria").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(alignment: .top, spacing: 14) {
                memoryCard(m.mem)
                cpuCard(m.cpu)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(procs)) { g in
                        ResourceRow(icon: g.appPath.map { .file($0) } ?? .symbol("terminal.fill", .gray), title: g.name,
                                    subtitle: g.pids.count > 1 ? "\(g.pids.count) processi" : "PID \(g.pids[0])",
                                    pills: g.cpu >= 50 ? [("CPU alta", .red)] : [],
                                    dateText: String(format: "%.1f%% CPU", g.cpu), size: g.mem, sizeText: fmtMem(g.mem), top: top, color: .pink) {
                            IconAction(symbol: "xmark.circle", help: "Chiudi", color: .red) { m.quit(g, store: s) }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .task {
            while !Task.isCancelled {
                m.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func memoryCard(_ mem: MemStats) -> some View {
        let parts: [(String, Int64, Color)] = [("App", mem.app, .blue), ("Kernel", mem.wired, .orange), ("Compressa", mem.compressed, .purple),
                                               ("In cache", mem.cached, .gray.opacity(0.6))]
        let pressure: (String, Color) = mem.pressure >= 4 ? ("Critica", .red) : mem.pressure == 2 ? ("Alta", .orange) : ("Normale", .green)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconBadge(symbol: "memorychip.fill", color: .blue, size: 30)
                Text("Memoria").font(.headline)
                Spacer()
                Pill(text: "Pressione: \(pressure.0.lowercased())", color: pressure.1)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(fmtMem(mem.used)).font(.system(size: 26, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Text("usati su \(fmtMem(mem.total))").foregroundStyle(.secondary)
            }
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3).fill(parts[i].2.gradient)
                            .frame(width: max(2, g.size.width * Double(parts[i].1) / Double(max(mem.total, 1))))
                    }
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                }
            }
            .frame(height: 12)
            HStack(spacing: 12) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(parts[i].2).frame(width: 7, height: 7)
                        Text("\(parts[i].0) \(fmtMem(parts[i].1))")
                    }
                }
                if mem.swap > 0 { Text("Swap \(fmtMem(mem.swap))").foregroundStyle(.orange) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    func cpuCard(_ cpu: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconBadge(symbol: "cpu", color: .pink, size: 30)
                Text("CPU").font(.headline)
            }
            Text(cpu, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            SizeBar(fraction: cpu, color: cpu > 0.8 ? .red : .pink, height: 12)
            Text("Acceso da \(Duration.seconds(ProcessInfo.processInfo.systemUptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 260, alignment: .leading).card()
    }
}

// MARK: - Aggiornamenti

struct UpdatesView: View {
    @Environment(Store.self) private var s

    var body: some View {
        let m = s.updates
        VStack(spacing: 0) {
            PageHeader(page: .updates, subtitle: m.busy.map { "Aggiorno \($0)…" } ?? "Strumenti di sviluppo, Homebrew, App Store e macOS") {
                if m.loading || m.busy != nil { ProgressView().controlSize(.small) }
                Button("Controlla online", systemImage: "arrow.clockwise") { m.load(refreshIndex: true) }
                    .keyboardShortcut("r").disabled(m.busy != nil)
                    .help("Aggiorna l'elenco di Homebrew (brew update) e ricontrolla")
                Button("Aggiorna tutto", systemImage: "arrow.down.circle.fill") { m.upgrade(m.dev + m.brew + (m.mas ?? []), store: s) }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.busy != nil || (m.dev.isEmpty && m.brew.isEmpty && (m.mas ?? []).isEmpty))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ListSection(title: "Strumenti di sviluppo",
                                detail: m.loadingDev ? "controllo npm, pnpm, bun, Rust, uv, Node…" : m.dev.isEmpty ? "tutto aggiornato" : "\(m.dev.count) da aggiornare") {
                        if m.loadingDev && m.dev.isEmpty { ProgressView().controlSize(.small).padding(.leading, 10) }
                        ForEach(m.dev) { u in
                            SimpleRow(icon: .symbol(devIcon(u).0, devIcon(u).1), title: u.name, subtitle: "\(u.from) → \(u.to)",
                                      pills: [(u.cmd, .gray)]) {
                                Button("Aggiorna", systemImage: "arrow.down.circle") { m.upgrade([u], store: s) }
                                    .disabled(m.busy != nil)
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.spring, value: m.dev.map(\.id))
                    ListSection(title: "Homebrew", detail: m.loaded ? (m.brew.isEmpty ? "tutto aggiornato" : "\(m.brew.count) da aggiornare") : "") {
                        if m.loading && !m.loaded { ProgressView().padding(.leading, 10) }
                        ForEach(m.brew) { u in row(u, icon: u.kind == .cask ? .symbol("app.badge.fill", .orange) : .symbol("mug.fill", .orange)) }
                    }
                    ListSection(title: "App Store") {
                        if let mas = m.mas {
                            if mas.isEmpty { Text("Tutto aggiornato").foregroundStyle(.secondary).padding(.leading, 10) }
                            ForEach(mas) { u in row(u, icon: .symbol("bag.fill", .blue)) }
                        } else if m.loaded {
                            SimpleRow(icon: .symbol("bag.fill", .blue), title: "Serve mas per leggere gli aggiornamenti App Store",
                                      subtitle: "Piccolo strumento ufficiale da riga di comando, si installa con Homebrew") {
                                Button("Installa mas") { m.installMas(store: s) }.disabled(m.busy != nil)
                                Button("Apri App Store") { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) }
                            }
                        }
                    }
                    ListSection(title: "macOS") {
                        if m.loadingMacOS {
                            HStack { ProgressView().controlSize(.small); Text("Controllo Aggiornamento Software…").foregroundStyle(.secondary) }
                                .padding(.leading, 10)
                        } else if m.macos.isEmpty {
                            Text("Nessun aggiornamento di sistema").foregroundStyle(.secondary).padding(.leading, 10)
                        }
                        ForEach(m.macos) { u in
                            SimpleRow(icon: .symbol("laptopcomputer", .gray), title: u.name, subtitle: "Versione \(u.to)") {
                                Button("Apri Aggiornamento Software") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
                                }
                            }
                        }
                    }
                    if !m.output.isEmpty {
                        ListSection(title: "Output") {
                            Text(m.output).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .onAppear { if !m.loaded && !m.loading { m.load() } }
    }

    func devIcon(_ u: UpdateItem) -> (String, Color) {
        let k = u.key.lowercased()
        return k.hasPrefix("npm:") ? ("cube.fill", .red) : k.contains("pnpm") ? ("cube.transparent.fill", .yellow)
            : k.contains("bun") ? ("bolt.fill", .pink) : k.hasPrefix("rust") ? ("gearshape.2.fill", .orange)
            : k == "uv" ? ("bolt.horizontal.fill", .purple) : k.contains("node") ? ("hexagon.fill", .green)
            : k.contains("claude") ? ("sparkles", .orange) : ("hammer.fill", .blue)
    }

    func row(_ u: UpdateItem, icon: RowIcon) -> some View {
        SimpleRow(icon: icon, title: u.name, subtitle: "\(u.from) → \(u.to)", pills: [(u.kind.rawValue, .gray)]) {
            Button("Aggiorna", systemImage: "arrow.down.circle") { s.updates.upgrade([u], store: s) }
                .disabled(s.updates.busy != nil)
        }
    }
}

// MARK: - Versioni strumenti

struct ToolsView: View {
    @Environment(Store.self) private var s

    var body: some View {
        let m = s.tools
        let unused = m.tools.filter { !$0.inUse && $0.editable }
        let top = Double(m.tools.map(\.size).max() ?? 1)
        VStack(spacing: 0) {
            PageHeader(page: .toolchains, subtitle: m.loaded ? "\(m.tools.count) versioni · \(fmt(unused.reduce(0) { $0 + $1.size })) in versioni non in uso"
                                                             : "Node, Python, Ruby, Rust, Java, Go, Gradle, Android") {
                if m.loading { ProgressView().controlSize(.small) }
                Button("Cestina non in uso", systemImage: "trash") {
                    s.trash(unused.map(\.path), known: Dictionary(uniqueKeysWithValues: unused.map { ($0.path, $0.size) })) { _ in m.load() }
                }
                .disabled(unused.isEmpty)
                Button("Aggiorna", systemImage: "arrow.clockwise") { m.load() }.keyboardShortcut("r")
            }
            Divider()
            if m.loading && m.tools.isEmpty {
                Loading(text: "Cerco le versioni installate…")
            } else if m.tools.isEmpty {
                ContentUnavailableView("Nessun gestore di versioni trovato", systemImage: "square.stack.3d.up").frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(Set(m.tools.map(\.tool))).sorted(), id: \.self) { tool in
                            let list = m.tools.filter { $0.tool == tool }.sorted { compareVersions($1.version, $0.version) }
                            ListSection(title: tool, detail: "\(list.count) · \(fmt(list.reduce(0) { $0 + $1.size }))") {
                                ForEach(list) { t in
                                    ResourceRow(icon: .symbol(t.symbol, t.color), title: t.version, subtitle: tilde(t.path),
                                                pills: t.inUse ? [("In uso", .green)] : !t.editable ? [("Sistema", .gray)] : [],
                                                size: t.size, top: top, color: t.color) {
                                        revealAction(t.path)
                                        IconAction(symbol: "trash", help: "Sposta nel Cestino", color: .red) {
                                            s.trash([t.path], known: [t.path: t.size]) { _ in m.load() }
                                        }
                                        .disabled(t.inUse || !t.editable)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
        .onAppear { if !m.loaded && !m.loading { m.load() } }
    }
}

// MARK: - Homebrew

struct BrewView: View {
    @Environment(Store.self) private var s
    @State private var filter = "all"

    var body: some View {
        let m = s.brew
        let list = m.pkgs.filter {
            switch filter {
            case "request": !$0.isCask && $0.onRequest
            case "deps": !$0.isCask && !$0.onRequest
            case "casks": $0.isCask
            case "orphans": $0.orphan
            default: true
            }
        }
        let top = Double(m.pkgs.map(\.size).max() ?? 1)
        let orphans = m.pkgs.filter(\.orphan)
        VStack(spacing: 0) {
            PageHeader(page: .brew, subtitle: m.loaded ? "\(m.pkgs.count) pacchetti · \(fmt(m.pkgs.reduce(0) { $0 + $1.size }))" : "Pacchetti e app installati con Homebrew") {
                if m.loading || m.busy { ProgressView().controlSize(.small) }
                Button("Rimuovi orfani (\(orphans.count))", systemImage: "trash") { m.autoremove(store: s) }
                    .disabled(orphans.isEmpty || m.busy)
                Button("Aggiorna", systemImage: "arrow.clockwise") { m.load() }.keyboardShortcut("r")
            }
            Picker("", selection: $filter) {
                Text("Tutti").tag("all")
                Text("Installati da te").tag("request")
                Text("Dipendenze").tag("deps")
                Text("App").tag("casks")
                Text("Orfani").tag("orphans")
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.bottom, 10)
            Divider()
            if m.loading && m.pkgs.isEmpty {
                Loading(text: "Leggo i pacchetti Homebrew…")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { p in
                            let app = p.paths.first { $0.hasSuffix(".app") }
                            ResourceRow(icon: app.map { .file($0) } ?? .symbol("mug.fill", .orange), title: p.name, subtitle: p.desc,
                                        pills: pills(p), size: p.size, top: top, color: .orange) {
                                IconAction(symbol: "trash", help: "Disinstalla (definitivo)", color: .red) { m.uninstall(p, store: s) }
                                    .disabled(m.busy)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .onAppear { if !m.loaded && !m.loading { m.load() } }
    }

    func pills(_ p: BrewPackage) -> [(String, Color)] {
        var r: [(String, Color)] = [(p.version, .gray)]
        if p.orphan { r.append(("Orfano", .orange)) }
        if !p.usedBy.isEmpty { r.append(("Usato da \(p.usedBy.count)", .blue)) }
        if !p.isCask && !p.onRequest && !p.orphan { r.append(("Dipendenza", .gray)) }
        return r
    }
}

// MARK: - Repository Git

struct GitView: View {
    @Environment(Store.self) private var s

    var body: some View {
        let m = s.git
        let top = Double(m.repos.map(\.gitSize).max() ?? 1)
        VStack(spacing: 0) {
            PageHeader(page: .git, subtitle: m.searched ? "\(m.repos.count) repository · \(fmt(m.repos.reduce(0) { $0 + $1.gitSize })) in .git · \(m.repos.filter(\.needsGC).count) da compattare"
                                                        : "Cartelle .git pesanti e branch già unite") {
                if m.loading { ProgressView().controlSize(.small) }
                Button(m.searched ? "Cerca di nuovo" : "Cerca nella home", systemImage: "magnifyingglass") { m.load() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r").disabled(m.loading)
            }
            Divider()
            if m.loading && m.repos.isEmpty {
                Loading(text: "Cerco i repository…")
            } else if !m.searched {
                ContentUnavailableView {
                    Label("Repository Git", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Trova i repository nella home, quanto pesa la loro cartella .git,\nquali vanno compattati e quali branch sono già state unite.")
                } actions: {
                    Button("Cerca nella home") { m.load() }.buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(m.repos) { r in
                            ResourceRow(icon: .symbol("arrow.triangle.branch", .purple), title: r.name,
                                        subtitle: tilde(r.path) + (r.branch.isEmpty ? "" : " · \(r.branch)"),
                                        pills: (r.needsGC ? [("Da compattare", Color.orange)] : []) + (r.merged.isEmpty ? [] : [("\(r.merged.count) branch unite", .blue)]),
                                        dateText: "commit " + relative(r.lastCommit), size: r.gitSize, top: top, color: .purple) {
                                if m.busy == r.path {
                                    ProgressView().controlSize(.small)
                                } else {
                                    IconAction(symbol: "arrow.down.right.and.arrow.up.left", help: "Compatta (git gc)") { m.gc(r, store: s) }
                                    IconAction(symbol: "scissors", help: "Elimina branch unite", color: .red) { m.deleteMerged(r, store: s) }
                                        .disabled(r.merged.isEmpty)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
    }
}

// MARK: - Batteria

struct BatteryView: View {
    @State private var b = BatteryInfo()
    @State private var loaded = false

    var healthText: String {
        switch b.health {
        case "Good": "Buona"
        case "Normal": "Normale"
        case "Fair": "Discreta"
        case "Poor": "Da sostituire"
        case "Service Recommended": "Assistenza consigliata"
        default: b.health
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .battery, subtitle: "Salute, cicli di carica e capacità residua") {
                Button("Aggiorna", systemImage: "arrow.clockwise") { load() }.keyboardShortcut("r")
            }
            Divider()
            if !loaded {
                Loading(text: "Leggo la batteria…")
            } else if !b.present {
                ContentUnavailableView("Questo Mac non ha una batteria", systemImage: "powerplug").frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        HStack(spacing: 28) {
                            ZStack {
                                Circle().stroke(.quaternary, lineWidth: 16)
                                Circle().trim(from: 0, to: Double(b.maxCapacity) / 100)
                                    .stroke((b.maxCapacity >= 80 ? Color.green : b.maxCapacity >= 70 ? .orange : .red).gradient,
                                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                VStack(spacing: 0) {
                                    Text("\(b.maxCapacity)%").font(.system(size: 34, weight: .bold, design: .rounded))
                                    Text("capacità").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 150, height: 150)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Condizione: \(healthText)").font(.title2.weight(.bold))
                                Text(b.maxCapacity >= 80
                                     ? "La batteria tiene ancora più dell'80% della capacità originale: va bene così."
                                     : "Sotto l'80% l'autonomia cala in modo evidente: valuta la sostituzione.")
                                    .foregroundStyle(.secondary)
                                if b.charging || b.plugged {
                                    Pill(text: b.charging ? "In carica" : b.full ? "Carica completa" : "Alimentatore collegato", symbol: "bolt.fill", color: .green)
                                }
                            }
                            Spacer()
                        }
                        .padding(20).card()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                            stat("Cicli di carica", "\(b.cycles) / \(b.designCycles)", "arrow.triangle.2.circlepath", .blue,
                                 fraction: Double(b.cycles) / Double(max(b.designCycles, 1)))
                            stat("Carica attuale", "\(b.charge)%", "battery.75percent", .green, fraction: Double(b.charge) / 100)
                            stat("Capacità reale", b.design > 0 ? "\(b.rawMax) / \(b.design) mAh" : "—", "bolt.fill", .orange,
                                 fraction: b.design > 0 ? Double(b.rawMax) / Double(b.design) : nil)
                            stat("Temperatura", b.temperature > 0 ? String(format: "%.1f °C", b.temperature) : "—", "thermometer.medium",
                                 b.temperature > 40 ? .red : .teal, fraction: nil)
                            stat("Alimentatore", b.plugged ? (b.adapterWatts >= 5 ? "\(b.adapterWatts) W" : "Collegato") : "Non collegato",
                                 "powerplug.fill", .gray, fraction: nil)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear { if !loaded { load() } }
    }

    func load() {
        Task {
            b = await Task.detached { loadBattery() }.value
            loaded = true
        }
    }

    func stat(_ title: String, _ value: String, _ symbol: String, _ color: Color, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconBadge(symbol: symbol, color: color, size: 26)
                Text(title).font(.callout).foregroundStyle(.secondary)
            }
            Text(value).font(.system(.title3, design: .rounded).weight(.bold))
            if let fraction { SizeBar(fraction: fraction, color: color) }
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading).card()
    }
}

// MARK: - Dischi esterni

struct VolumesView: View {
    @Environment(Store.self) private var s

    var body: some View {
        let m = s.volumes
        VStack(spacing: 0) {
            PageHeader(page: .volumes, subtitle: "Spazio, file nascosti di macOS ed espulsione") {
                if m.loading { ProgressView().controlSize(.small) }
                Button("Aggiorna", systemImage: "arrow.clockwise") { m.load() }.keyboardShortcut("r")
            }
            Divider()
            if m.loaded && m.volumes.isEmpty {
                ContentUnavailableView("Nessun disco esterno collegato", systemImage: "externaldrive",
                                       description: Text("Collega un disco o una chiavetta e premi Aggiorna.")).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14)], spacing: 14) {
                        ForEach(m.volumes) { v in card(v) }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear { if !m.loaded && !m.loading { m.load() } }
    }

    func card(_ v: VolumeInfo) -> some View {
        let m = s.volumes
        let used = max(v.total - v.free, 0)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FileIcon(path: v.path, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(v.name).font(.headline)
                        if !v.local { Pill(text: "Rete", color: .blue) }
                    }
                    Text(v.format).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if v.removable {
                    Button("Espelli", systemImage: "eject.fill") { m.eject(v, store: s) }.disabled(m.busy == v.path)
                }
            }
            SizeBar(fraction: Double(used) / Double(max(v.total, 1)), color: .gray, height: 10)
            Text("\(fmt(v.free)) liberi su \(fmt(v.total))").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Esplora", systemImage: "folder") { s.explore(v.path) }
                Spacer()
                if m.busy == v.path {
                    ProgressView().controlSize(.small)
                } else if v.junkScanned {
                    Text("\(v.junkFiles.count) file nascosti · \(fmt(v.junkSize))").font(.callout).foregroundStyle(.secondary)
                    Button("Elimina", systemImage: "trash") { m.cleanJunk(v, store: s) }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(v.junkFiles.isEmpty)
                } else {
                    Button("Cerca file nascosti di macOS", systemImage: "magnifyingglass") { m.scanJunk(v) }
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(v.name)
    }
}
