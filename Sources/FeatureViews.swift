import AppKit
import Charts
import ServiceManagement
import SwiftUI

// MARK: - Componenti condivisi

struct PageHeader<Trailing: View>: View {
    let page: Page
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: page.icon, color: page.color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.rawValue).font(.title2.weight(.bold))
                Text(subtitle).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            trailing
        }
        .padding(20)
    }
}

enum RowIcon {
    case file(String)
    case symbol(String, Color)
}

struct ResourceRow<Actions: View>: View {
    let icon: RowIcon
    let title: String
    var subtitle = ""
    var pills: [(String, Color)] = []
    var dateText = ""
    let size: Int64
    var sizeText: String? = nil
    let top: Double
    var color: Color = .accentColor
    @ViewBuilder var actions: Actions
    @State private var hover = false

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
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(dateText).font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(width: 150, alignment: .trailing)
            Text(sizeText ?? fmt(size)).monospacedDigit().fontWeight(.semibold).frame(width: 82, alignment: .trailing)
            SizeBar(fraction: Double(size) / max(top, 1), color: color).frame(width: 70)
            HStack(spacing: 2) { actions }
                .buttonStyle(.borderless)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(hover ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)  // una riga = un elemento: VoiceOver (e i test) sanno a chi appartiene il pulsante
        .accessibilityLabel(title)
    }
}

struct IconAction: View {
    let symbol: String
    let help: String
    var color: Color = .secondary
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(enabled ? color : Color.secondary.opacity(0.35))
                .frame(width: 28, height: 26)
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

func revealAction(_ path: String) -> IconAction {
    IconAction(symbol: "folder", help: "Mostra nel Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

func relative(_ d: Date?) -> String { d.map { $0.formatted(.relative(presentation: .named)) } ?? "—" }

struct ListSection<Content: View>: View {
    let title: String
    var detail = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
            }
            .padding(.leading, 10).padding(.top, 14).padding(.bottom, 4)
            content
        }
    }
}

struct Loading: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(text).font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Andamento

struct HistoryView: View {
    @Environment(Store.self) private var s
    @AppStorage("menuBar") private var menuBar = true
    @AppStorage("alertOn") private var alertOn = true
    @AppStorage("alertGB") private var alertGB = 30
    @AppStorage("notch") private var notch = true
    @State private var days = 30
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let points = s.history.filter { $0.date >= Date().addingTimeInterval(-Double(days) * 86400) }
        let g = growth(s.history, days: days)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(page: .history, subtitle: "Spazio libero nel tempo e cosa sta crescendo") {
                    Button("Fotografa ora", systemImage: "camera") { s.loadCategories(); s.refreshDisk() }
                        .keyboardShortcut("r")
                        .disabled(s.loadingCats)
                }
                .padding(-20)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Spazio libero").font(.headline)
                        Spacer()
                        Picker("", selection: $days) {
                            Text("7 giorni").tag(7)
                            Text("30 giorni").tag(30)
                            Text("90 giorni").tag(90)
                            Text("Tutto").tag(3650)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    if points.count < 2 {
                        Label("MacSweep fotografa il disco una volta al giorno: il grafico si riempie dai prossimi giorni.",
                              systemImage: "calendar.badge.clock")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        Chart {
                            ForEach(points, id: \.date) { p in
                                AreaMark(x: .value("Giorno", p.date), y: .value("GB liberi", Double(p.free) / 1e9))
                                    .foregroundStyle(LinearGradient(colors: [.teal.opacity(0.35), .teal.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                LineMark(x: .value("Giorno", p.date), y: .value("GB liberi", Double(p.free) / 1e9))
                                    .foregroundStyle(.teal)
                                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                                PointMark(x: .value("Giorno", p.date), y: .value("GB liberi", Double(p.free) / 1e9))
                                    .foregroundStyle(.teal).symbolSize(18)
                            }
                            if alertOn {
                                RuleMark(y: .value("Soglia", alertGB))
                                    .foregroundStyle(.red.opacity(0.7))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                    .annotation(position: .top, alignment: .leading) {
                                        Text("soglia \(alertGB) GB").font(.caption2).foregroundStyle(.red)
                                    }
                            }
                        }
                        .chartYAxisLabel("GB liberi")
                        .frame(height: 220)
                    }
                }
                .padding(16).card()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Cosa è cambiato").font(.headline)
                        if let since = g.since { Text("dal \(since.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary) }
                        Spacer()
                        if g.since != nil {
                            Pill(text: g.freeDelta >= 0 ? "+\(fmt(g.freeDelta)) liberi" : "\(fmt(-g.freeDelta)) in meno",
                                 symbol: g.freeDelta >= 0 ? "arrow.up" : "arrow.down", color: g.freeDelta >= 0 ? .green : .red)
                        }
                    }
                    if g.rows.isEmpty {
                        Text(g.since == nil ? "Servono almeno due fotografie in giorni diversi." : "Nessuna variazione sopra i 50 MB.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(g.rows.prefix(12)) { r in
                        HStack(spacing: 10) {
                            IconBadge(symbol: r.symbol, color: r.color, size: 26)
                            Text(r.label).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Image(systemName: r.delta > 0 ? "arrow.up.right" : "arrow.down.right")
                                .foregroundStyle(r.delta > 0 ? .red : .green)
                            Text((r.delta > 0 ? "+" : "−") + fmt(abs(r.delta)))
                                .monospacedDigit().fontWeight(.semibold)
                                .foregroundStyle(r.delta > 0 ? .red : .green)
                                .frame(width: 90, alignment: .trailing)
                        }
                    }
                }
                .padding(16).card()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Avvisi e barra dei menu").font(.headline)
                    Toggle(isOn: $menuBar) {
                        Label("Mostra lo spazio libero nella barra dei menu", systemImage: "menubar.rectangle")
                    }
                    HStack {
                        Toggle(isOn: $alertOn) {
                            Label("Avvisami quando lo spazio libero scende sotto", systemImage: "bell.badge.fill")
                        }
                        Picker("", selection: $alertGB) {
                            ForEach([10, 20, 30, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                        }
                        .labelsHidden().fixedSize().disabled(!alertOn)
                    }
                    if NotchController.notchScreen != nil {
                        Toggle(isOn: $notch) {
                            Label("Pannello nel notch: spazio, scansioni e azioni rapide passandoci sopra", systemImage: "rectangle.topthird.inset.filled")
                        }
                        .onChange(of: notch) { NotchController.shared.update() }
                    }
                    Toggle(isOn: $atLogin) {
                        Label("Apri MacSweep all'accensione (così fotografa e avvisa sempre)", systemImage: "power")
                    }
                    .onChange(of: atLogin) {
                        do {
                            if atLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            s.flash("Errore: \(error.localizedDescription)")
                        }
                    }
                }
                .toggleStyle(.switch)
                .padding(16).card()
                .onChange(of: alertOn) { if alertOn { requestNotifications() } }
            }
            .padding(24)
        }
    }
}

// MARK: - Download e duplicati

struct DownloadsView: View {
    @Environment(Store.self) private var s
    @State private var mode = "installer"
    @State private var months = 6
    @State private var scope = HOME + "/Downloads"
    @State private var minMB = 10

    var body: some View {
        let m = s.downloads
        VStack(spacing: 0) {
            PageHeader(page: .downloads, subtitle: "Installer già usati, file dimenticati e copie doppie") {
                Picker("", selection: $mode) {
                    Text("Installer").tag("installer")
                    Text("Non usati").tag("old")
                    Text("Duplicati").tag("dup")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Divider()
            switch mode {
            case "dup": duplicates
            default: downloads(old: mode == "old")
            }
        }
        .onAppear { if !m.loaded && !m.loading { m.load() } }
    }

    @ViewBuilder
    func downloads(old: Bool) -> some View {
        let m = s.downloads
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date())!
        let list = old ? m.items.filter { ($0.date ?? .distantFuture) < cutoff }
                       : m.items.filter { INSTALLER_EXT.contains(($0.path as NSString).pathExtension.lowercased()) }
        let total = list.reduce(0) { $0 + $1.size }
        HStack {
            Text(old ? "Non aperti da più di" : "Immagini disco e pacchetti in ~/Downloads").foregroundStyle(.secondary)
            if old {
                Picker("", selection: $months) {
                    Text("3 mesi").tag(3); Text("6 mesi").tag(6); Text("1 anno").tag(12); Text("2 anni").tag(24)
                }
                .labelsHidden().fixedSize()
            }
            Spacer()
            Text("\(list.count) elementi · \(fmt(total))").font(.headline)
            Button("Cestina tutti", systemImage: "trash") {
                s.trash(list.map(\.path), known: Dictionary(uniqueKeysWithValues: list.map { ($0.path, $0.size) })) { m.dropTrashed($0) }
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(list.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        if m.loading && m.items.isEmpty {
            Loading(text: "Leggo i Download…")
        } else if list.isEmpty {
            ContentUnavailableView(old ? "Niente di dimenticato" : "Nessun installer", systemImage: "checkmark.seal")
                .frame(maxHeight: .infinity)
        } else {
            let top = Double(list.map(\.size).max() ?? 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { i in
                        ResourceRow(icon: .file(i.path), title: i.name,
                                    pills: !old && m.isInstalled(i.path) ? [("App già installata", .green)] : [],
                                    dateText: (old ? "aperto " : "") + relative(i.date), size: i.size, top: top, color: .indigo) {
                            revealAction(i.path)
                            IconAction(symbol: "trash", help: "Sposta nel Cestino", color: .red) {
                                s.trash([i.path], known: [i.path: i.size]) { m.dropTrashed($0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    var duplicates: some View {
        let m = s.downloads
        let selSize = m.groups.flatMap(\.files).filter { m.dupSel.contains($0.path) }.reduce(0) { $0 + $1.size }
        HStack {
            Picker("Cerca in", selection: $scope) {
                Text("Download").tag(HOME + "/Downloads")
                Text("Documenti").tag(HOME + "/Documents")
                Text("Scrivania").tag(HOME + "/Desktop")
                Text("Immagini").tag(HOME + "/Pictures")
                Text("Filmati").tag(HOME + "/Movies")
                Text("Tutta la home").tag(HOME)
            }
            .fixedSize()
            Picker("da", selection: $minMB) {
                Text("1 MB").tag(1); Text("10 MB").tag(10); Text("100 MB").tag(100)
            }
            .fixedSize()
            Button("Cerca", systemImage: "magnifyingglass") { m.findDups(root: scope, minMB: minMB) }
                .keyboardShortcut("r")
                .disabled(m.dupLoading)
            Spacer()
            if !m.groups.isEmpty {
                Text("\(m.groups.count) gruppi · \(fmt(m.groups.reduce(0) { $0 + $1.wasted })) doppi").font(.headline)
            }
            Button("Cestina selezionati (\(fmt(selSize)))", systemImage: "trash") {
                let files = m.groups.flatMap(\.files).filter { m.dupSel.contains($0.path) }
                s.trash(files.map(\.path), known: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.size) })) { m.dropTrashed($0) }
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(m.dupSel.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        if m.dupLoading {
            Loading(text: "Confronto i file per contenuto…")
        } else if !m.dupSearched {
            ContentUnavailableView {
                Label("Duplicati veri", systemImage: "doc.on.doc.fill")
            } description: {
                Text("Confronta il contenuto dei file, non il nome.\nDi ogni gruppo tiene la copia più vecchia: le altre sono già spuntate.")
            } actions: {
                Button("Cerca") { m.findDups(root: scope, minMB: minMB) }.buttonStyle(.borderedProminent)
            }
            .frame(maxHeight: .infinity)
        } else if m.groups.isEmpty {
            ContentUnavailableView("Nessun duplicato", systemImage: "checkmark.seal").frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(m.groups) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                FileIcon(path: g.files[0].path, size: 28)
                                Text(g.files[0].name).font(.headline).lineLimit(1)
                                Spacer()
                                Pill(text: "\(g.files.count) copie · \(fmt(g.size)) l'una", color: .orange)
                            }
                            ForEach(g.files) { f in
                                let checked = m.dupSel.contains(f.path)
                                let othersKept = g.files.filter { $0.path != f.path && !m.dupSel.contains($0.path) }.count
                                Toggle(isOn: Binding(get: { checked },
                                                     set: { if $0 { m.dupSel.insert(f.path) } else { m.dupSel.remove(f.path) } })) {
                                    HStack {
                                        Text(tilde(f.path)).font(.callout).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text(relative(f.date)).font(.caption).foregroundStyle(.secondary)
                                        if !checked { Pill(text: "Tenuto", color: .green) }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .disabled(!checked && othersKept == 0)  // almeno una copia resta sempre
                                .contextMenu {
                                    Button("Mostra nel Finder", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)])
                                    }
                                }
                            }
                        }
                        .padding(14).card()
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Docker

struct DockerView: View {
    @Environment(Store.self) private var s

    var body: some View {
        let m = s.docker
        VStack(spacing: 0) {
            PageHeader(page: .docker, subtitle: m.state == .ok ? "\(m.rows.count) elementi · \(fmt(m.rows.reduce(0) { $0 + $1.size }))"
                                                               : "Immagini, container, volumi e build cache") {
                if m.loading || m.busy { ProgressView().controlSize(.small) }
                if m.state == .ok {
                    Button("Svuota build cache", systemImage: "trash") { m.pruneBuildCache(store: s) }.disabled(m.busy)
                }
                Button("Aggiorna", systemImage: "arrow.clockwise") { m.load() }.keyboardShortcut("r")
            }
            Divider()
            switch m.state {
            case .unknown:
                Loading(text: "Interrogo Docker…")
            case .notInstalled:
                ContentUnavailableView("Docker non è installato", systemImage: "cube.box").frame(maxHeight: .infinity)
            case .notRunning:
                ContentUnavailableView {
                    Label("Docker non è avviato", systemImage: "cube.box")
                } description: {
                    Text("Avvialo per vedere immagini, container e volumi uno per uno.\nIl suo disco virtuale occupa comunque spazio anche da spento.")
                } actions: {
                    Button("Avvia Docker") {
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"), configuration: .init())
                        Task { try? await Task.sleep(for: .seconds(20)); m.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            case .ok:
                let top = Double(m.rows.map(\.size).max() ?? 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            ForEach(m.summary, id: \.0) { t in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.0).font(.caption).foregroundStyle(.secondary)
                                    Text(fmt(t.1)).font(.system(.title3, design: .rounded).weight(.bold))
                                    Text("recuperabile \(t.2)").font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading).card()
                            }
                        }
                        .padding(.horizontal, 10).padding(.top, 10)
                        ForEach([DockerRow.Kind.image, .container, .volume], id: \.self) { kind in
                            let rows = m.rows.filter { $0.kind == kind }
                            if !rows.isEmpty {
                                ListSection(title: kind.rawValue, detail: "\(rows.count) · \(fmt(rows.reduce(0) { $0 + $1.size }))") {
                                    ForEach(rows) { r in
                                        let style: (String, Color) = kind == .image ? ("square.stack.3d.up.fill", .blue)
                                            : kind == .container ? ("shippingbox.fill", .orange) : ("externaldrive.fill", .purple)
                                        ResourceRow(icon: .symbol(style.0, style.1), title: r.title, subtitle: r.subtitle,
                                                    dateText: r.when, size: r.size, top: top, color: style.1) {
                                            IconAction(symbol: "trash", help: "Elimina (definitivo)", color: .red) { m.remove(r, store: s) }
                                                .disabled(m.busy)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
        .onAppear { if m.state == .unknown && !m.loading { m.load() } }
    }
}

// MARK: - Simulatori

struct SimsView: View {
    @Environment(Store.self) private var s

    func platformStyle(_ name: String) -> (String, Color) {
        name.hasPrefix("watchOS") ? ("applewatch", .pink) : name.hasPrefix("tvOS") ? ("appletv", .gray)
            : name.hasPrefix("visionOS") ? ("visionpro", .purple) : ("iphone.gen3", .blue)
    }

    var body: some View {
        let m = s.sims
        let all = m.runtimes.reduce(0) { $0 + $1.size } + m.devices.reduce(0) { $0 + $1.size }
        let top = Double(max(m.runtimes.map(\.size).max() ?? 1, m.devices.map(\.size).max() ?? 1))
        VStack(spacing: 0) {
            PageHeader(page: .sims, subtitle: m.runtimes.isEmpty && m.loading ? "Leggo i simulatori…"
                       : "\(m.runtimes.count) runtime e \(m.devices.count) simulatori · \(fmt(all))") {
                if m.loading || m.busy { ProgressView().controlSize(.small) }
                Button("Elimina non disponibili", systemImage: "xmark.circle") { m.deleteUnavailable(store: s) }
                    .disabled(m.busy || !m.devices.contains { !$0.available })
                Button("Aggiorna", systemImage: "arrow.clockwise") { m.load() }.keyboardShortcut("r")
            }
            Divider()
            if m.loading && m.runtimes.isEmpty && m.devices.isEmpty {
                Loading(text: "Leggo runtime e simulatori…")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ListSection(title: "Runtime", detail: "le versioni di iOS/watchOS scaricate da Xcode") {
                            ForEach(m.runtimes) { r in
                                let st = platformStyle(r.name)
                                let used = m.devices.filter { $0.runtime == r.name }.count
                                ResourceRow(icon: .symbol(st.0, st.1), title: r.name,
                                            subtitle: used > 0 ? "\(used) simulatori lo usano" : "Nessun simulatore lo usa",
                                            pills: used == 0 ? [("Inutilizzato", .orange)] : [],
                                            dateText: "usato " + relative(r.lastUsed), size: r.size, top: top, color: st.1) {
                                    IconAction(symbol: "trash", help: "Elimina runtime (definitivo)", color: .red) { m.deleteRuntime(r, store: s) }
                                        .disabled(!r.deletable || m.busy)
                                }
                            }
                        }
                        ListSection(title: "Simulatori", detail: "app e dati installati in ciascun dispositivo") {
                            ForEach(m.devices) { d in
                                let st = platformStyle(d.runtime)
                                ResourceRow(icon: .symbol(st.0, st.1), title: d.name, subtitle: d.runtime,
                                            pills: d.available ? [] : [("Non disponibile", .orange)],
                                            dateText: "usato " + relative(d.lastUsed), size: d.size, top: top, color: st.1) {
                                    IconAction(symbol: "trash", help: "Elimina simulatore (definitivo)", color: .red) { m.deleteDevice(d, store: s) }
                                        .disabled(m.busy)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
        .onAppear { if m.runtimes.isEmpty && m.devices.isEmpty && !m.loading { m.load() } }
    }
}

// MARK: - Modelli AI

struct AIView: View {
    @Environment(Store.self) private var s

    var body: some View {
        let m = s.ai
        let top = Double(m.models.map(\.size).max() ?? 1)
        VStack(spacing: 0) {
            PageHeader(page: .ai, subtitle: m.loaded ? "\(m.models.count) modelli · \(fmt(m.models.reduce(0) { $0 + $1.size }))"
                                                     : "LM Studio, Hugging Face, Draw Things, Ollama") {
                if m.loading { ProgressView().controlSize(.small) }
                Button("Aggiorna", systemImage: "arrow.clockwise") { m.load() }.keyboardShortcut("r")
            }
            Divider()
            if m.loading && m.models.isEmpty {
                Loading(text: "Cerco i modelli…")
            } else if m.models.isEmpty {
                ContentUnavailableView("Nessun modello trovato", systemImage: "brain").frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(Set(m.models.map(\.source))).sorted(), id: \.self) { src in
                            let list = m.models.filter { $0.source == src }
                            let st = aiStyle(src)
                            ListSection(title: src, detail: "\(list.count) · \(fmt(list.reduce(0) { $0 + $1.size }))") {
                                ForEach(list) { a in
                                    ResourceRow(icon: .symbol(st.symbol, st.color), title: a.name, subtitle: tilde(a.path),
                                                dateText: "usato " + relative(a.lastUsed), size: a.size, top: top, color: st.color) {
                                        revealAction(a.path)
                                        IconAction(symbol: "trash", help: "Sposta nel Cestino", color: .red) {
                                            s.trash([a.path], known: [a.path: a.size]) { _ in m.load() }
                                        }
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

// MARK: - Macchine virtuali

struct VMView: View {
    @Environment(Store.self) private var s

    var body: some View {
        let m = s.vms
        let top = Double(m.vms.map(\.size).max() ?? 1)
        VStack(spacing: 0) {
            PageHeader(page: .vms, subtitle: m.loaded ? "\(m.vms.count) \(m.vms.count == 1 ? "macchina" : "macchine") · \(fmt(m.vms.reduce(0) { $0 + $1.size }))"
                                                      : "UTM, Parallels, VMware, VirtualBox") {
                if m.loading { ProgressView().controlSize(.small) }
                Button("Aggiorna", systemImage: "arrow.clockwise") { m.load() }.keyboardShortcut("r")
            }
            Divider()
            if m.loading && m.vms.isEmpty {
                Loading(text: "Cerco le macchine virtuali…")
            } else if m.vms.isEmpty {
                ContentUnavailableView("Nessuna macchina virtuale", systemImage: "pc").frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(m.vms) { v in
                            ResourceRow(icon: FileManager.default.fileExists(atPath: v.appPath) ? .file(v.appPath) : .symbol("pc", .brown),
                                        title: v.name, subtitle: v.app + " · " + tilde(v.path),
                                        dateText: "modificata " + relative(v.modified), size: v.size, top: top, color: .brown) {
                                revealAction(v.path)
                                IconAction(symbol: "trash", help: "Sposta nel Cestino", color: .red) {
                                    s.trash([v.path], known: [v.path: v.size]) { _ in m.load() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
        .onAppear { if !m.loaded && !m.loading { m.load() } }
    }
}

// MARK: - Avvio automatico

struct StartupView: View {
    @Environment(Store.self) private var s

    var body: some View {
        let m = s.startup
        VStack(spacing: 0) {
            PageHeader(page: .startup, subtitle: "Cosa parte da solo all'accensione o gira in background") {
                if m.loading { ProgressView().controlSize(.small) }
                Button("Impostazioni Elementi login", systemImage: "gearshape") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
                Button("Aggiorna", systemImage: "arrow.clockwise") { m.load() }.keyboardShortcut("r")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ListSection(title: "Elementi di login", detail: "le app che si aprono quando accedi") {
                        if let login = m.loginItems {
                            if login.isEmpty {
                                Text("Nessuno (le app più recenti si gestiscono da Impostazioni → Elementi login)")
                                    .foregroundStyle(.secondary).padding(.leading, 10)
                            }
                            ForEach(login, id: \.self) { name in
                                startupRow(icon: appIcon(name), title: name, subtitle: "Elemento di login", pills: []) {
                                    IconAction(symbol: "minus.circle", help: "Togli dall'avvio", color: .red) {
                                        if confirm("Togliere \(name) dagli elementi di login?", "L'app resta installata, solo non si apre più da sola.") {
                                            Task { await Task.detached { removeLoginItem(name) }.value; m.loadLogin() }
                                        }
                                    }
                                }
                            }
                        } else {
                            Button("Leggi elementi di login") { m.loadLogin() }
                                .padding(.leading, 10)
                                .help("macOS chiederà il permesso di controllare Eventi di Sistema")
                        }
                    }
                    ForEach([StartupItem.Scope.user, .system, .daemon], id: \.self) { scope in
                        let list = m.items.filter { $0.scope == scope }
                        if !list.isEmpty {
                            ListSection(title: scope.rawValue, detail: scope == .user ? "puoi attivarli e disattivarli" : "sola lettura: richiedono l'amministratore o li gestisce l'azienda") {
                                ForEach(list) { item in
                                    startupRow(icon: item.appPath.map { .file($0) } ?? .symbol("gearshape.2.fill", .gray),
                                               title: item.name, subtitle: item.label, pills: pills(item)) {
                                        if item.editable {
                                            if item.missing {
                                                IconAction(symbol: "trash", help: "Rimuovi: il programma non esiste più", color: .red) {
                                                    s.trash([item.plist]) { _ in m.load() }
                                                }
                                            }
                                            Toggle("", isOn: Binding(get: { !item.disabled }, set: { _ in m.toggle(item) }))
                                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                                        } else {
                                            Image(systemName: "lock.fill").foregroundStyle(.tertiary).help("Sola lettura")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .onAppear { if m.items.isEmpty && !m.loading { m.load() } }
    }

    func pills(_ item: StartupItem) -> [(String, Color)] {
        var p: [(String, Color)] = [(item.schedule, .blue)]
        if item.running { p.append(("In esecuzione", .green)) }
        if item.disabled { p.append(("Disattivato", .gray)) }
        if item.missing { p.append(("Programma mancante", .orange)) }
        return p
    }

    func appIcon(_ name: String) -> RowIcon {
        let p = APP_DIRS.map { $0 + "/" + name + ".app" }.first { FileManager.default.fileExists(atPath: $0) }
        return p.map { .file($0) } ?? .symbol("app.fill", .blue)
    }

    func startupRow<A: View>(icon: RowIcon, title: String, subtitle: String, pills: [(String, Color)], @ViewBuilder actions: () -> A) -> some View {
        HStack(spacing: 12) {
            switch icon {
            case .file(let p): FileIcon(path: p, size: 30)
            case .symbol(let sy, let c): IconBadge(symbol: sy, color: c, size: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    ForEach(pills.indices, id: \.self) { i in Pill(text: pills[i].0, color: pills[i].1) }
                }
                Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) { actions() }.buttonStyle(.borderless)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Pulizia programmata (card in Manutenzione)

let WEEKDAYS = ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"]

struct AutocleanCard: View {
    @Environment(Store.self) private var s
    @State private var cfg = loadAutoclean()
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconBadge(symbol: "calendar.badge.clock", color: .green, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pulizia programmata").font(.headline)
                    Text(cfg.enabled ? "Ogni \(WEEKDAYS[cfg.weekday]) alle \(cfg.hour):00, anche ad app chiusa" : "Disattivata")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if cfg.enabled {
                    Picker("", selection: $cfg.weekday) { ForEach(0..<7, id: \.self) { Text(WEEKDAYS[$0].capitalized).tag($0) } }
                        .labelsHidden().fixedSize()
                    Picker("", selection: $cfg.hour) { ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) } }
                        .labelsHidden().fixedSize()
                }
                Toggle("", isOn: $cfg.enabled).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("Attiva pulizia programmata")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(AUTOCLEAN_OPTIONS, id: \.id) { o in
                    Toggle(isOn: Binding(get: { cfg.tasks.contains(o.id) },
                                         set: { on in if on { cfg.tasks.append(o.id) } else { cfg.tasks.removeAll { $0 == o.id } } })) {
                        HStack(spacing: 8) {
                            IconBadge(symbol: o.symbol, color: o.color, size: 22)
                            Text(o.label)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            HStack {
                Button(running ? "Pulizia in corso…" : "Esegui ora", systemImage: "play.fill") {
                    running = true
                    let c = cfg
                    Task {
                        let r = await Task.detached { runAutoclean(c) }.value
                        running = false
                        s.flash("Pulizia completata: liberati \(fmt(r.freed))")
                        s.refreshDisk()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || cfg.tasks.isEmpty)
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Text("A fine pulizia arriva una notifica con lo spazio liberato. Tutto finisce nel Registro.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .card()
        .onChange(of: cfg) {
            saveAutoclean(cfg)
            if cfg.enabled { requestNotifications() }
        }
    }
}

// MARK: - Registro

struct LogView: View {
    @Environment(Store.self) private var s
    @State private var sessions: [LogSession] = []

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(page: .log, subtitle: "Tutto ciò che MacSweep ha spostato nel Cestino, da rimettere al suo posto con un clic") {
                Button("Apri file di registro", systemImage: "doc.text") { NSWorkspace.shared.open(URL(fileURLWithPath: LOG_PATH)) }
                Button("Aggiorna", systemImage: "arrow.clockwise") { reload() }.keyboardShortcut("r")
            }
            Divider()
            if sessions.isEmpty {
                ContentUnavailableView("Registro vuoto", systemImage: "clock.arrow.circlepath",
                                       description: Text("Qui compare ogni pulizia e disinstallazione.")).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sessions.prefix(60)) { session in sessionCard(session) }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear(perform: reload)
    }

    func reload() { sessions = readLog() }

    func sessionCard(_ session: LogSession) -> some View {
        let restorable = session.trashed.filter { $0.status == .inTrash }
        let total = session.trashed.reduce(0) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IconBadge(symbol: session.title.hasPrefix("Disinstalla") ? "xmark.bin.fill"
                          : session.title.hasPrefix("Pulizia") ? "calendar.badge.clock" : "trash.fill",
                          color: session.title.hasPrefix("Disinstalla") ? .red : .orange, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.headline).lineLimit(1)
                    Text(session.start.formatted(date: .abbreviated, time: .shortened)
                         + (total > 0 ? " · \(fmt(total))" : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !restorable.isEmpty {
                    Button("Rimetti tutto (\(restorable.count))", systemImage: "arrow.uturn.backward") { restoreAll(restorable) }
                        .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                }
            }
            ForEach(session.entries) { e in
                if e.kind == "CESTINO" {
                    let st: (String, Color, String) = switch e.status {
                    case .inTrash: ("trash", .orange, "Nel Cestino")
                    case .restored: ("arrow.uturn.backward.circle.fill", .green, "Al suo posto")
                    case .gone: ("xmark.circle", .gray, "Cestino svuotato")
                    case .unknown: ("questionmark.circle", .gray, "Rimetti dal Finder")
                    case .info: ("info.circle", .gray, "")
                    }
                    HStack(spacing: 8) {
                        Image(systemName: st.0).foregroundStyle(st.1).frame(width: 18)
                        Text((e.path as NSString).lastPathComponent).lineLimit(1)
                        Text(tilde((e.path as NSString).deletingLastPathComponent)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if e.size > 0 { Text(fmt(e.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                        if e.status == .inTrash {
                            Button("Rimetti") { restoreAll([e]) }.controlSize(.small)
                        } else {
                            Text(st.2).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                } else {
                    Text("\(e.kind.capitalized) \(e.text)").font(.caption).foregroundStyle(e.kind == "ERRORE" ? .red : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .card()
    }

    func restoreAll(_ entries: [LogEntry]) {
        var errors: [String] = []
        for e in entries {
            do { try restore(e) } catch { errors.append("\((e.path as NSString).lastPathComponent): \(error.localizedDescription)") }
        }
        s.flash(errors.isEmpty ? "Rimessi al loro posto: \(entries.count)" : "Errore: \(errors.first!)")
        s.refreshDisk()
        reload()
    }
}

// MARK: - Barra dei menu

struct MenuBarView: View {
    @Environment(Store.self) private var s
    @Environment(\.openWindow) private var openWindow
    @AppStorage("alertGB") private var alertGB = 30

    var body: some View {
        let used = max(s.total - s.free, 0)
        let g = growth(s.history, days: 7)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconBadge(symbol: "internaldrive.fill", color: s.lowSpace ? .red : .blue, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(fmt(s.free)) liberi").font(.headline)
                    Text("su \(fmt(s.total))").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(used), total: Double(max(s.total, 1))).tint(s.lowSpace ? .red : .accentColor)
            let mem = memStats()
            HStack {
                Label("Memoria \(fmtMem(mem.used)) / \(fmtMem(mem.total))", systemImage: "memorychip")
                Spacer()
                Text(mem.pressure >= 4 ? "critica" : mem.pressure == 2 ? "sotto pressione" : "ok")
                    .foregroundStyle(mem.pressure >= 4 ? .red : mem.pressure == 2 ? .orange : .green)
            }
            .font(.caption)
            if s.lowSpace {
                Label("Sotto la soglia di \(alertGB) GB", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if !g.rows.isEmpty {
                Text("Cresciuti negli ultimi 7 giorni").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(g.rows.filter { $0.delta > 0 }.prefix(3)) { r in
                    HStack {
                        Image(systemName: r.symbol).foregroundStyle(r.color)
                        Text(r.label).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("+" + fmt(r.delta)).foregroundStyle(.red).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            if s.cleanable > 0 { Pill(text: "Puoi liberare subito \(fmt(s.cleanable))", symbol: "sparkles") }
            let trash = s.categories.first { $0.id == "trash" }?.size ?? 0
            HStack(spacing: 8) {
                Button { s.openMain(quickClean: true) } label: { Label("Pulizia rapida", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    .tint(.purple)
                Button { s.emptyTrash() } label: { Label(trash > 0 ? fmt(trash) : "Vuoto", systemImage: "trash").frame(maxWidth: .infinity) }
                    .tint(.red).disabled(trash == 0 || s.emptyingTrash)
                    .help("Svuota il Cestino")
            }
            .buttonStyle(.bordered).controlSize(.regular)
            Divider()
            HStack {
                Button("Apri MacSweep") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
