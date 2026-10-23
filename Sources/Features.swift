import AppKit
import CryptoKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Helper

/// Shell di login: le app GUI non hanno il PATH utente (docker, brew, npm…).
func sh(_ cmd: String) -> (out: String, code: Int32) { run(["/bin/zsh", "-lc", cmd], mergeErr: true) }
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func allocatedSize(_ path: String) -> Int64 {
    Int64((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
}

/// Ultimo uso secondo Spotlight, altrimenti ultima modifica.
func lastUsed(_ path: String) -> Date? {
    if let item = MDItemCreate(nil, path as CFString), let d = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { return d }
    return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}

let ISO = ISO8601DateFormatter()

/// "1.23GB", "512MB", "12.3kB", "0B" (unità decimali di Docker) -> byte
func parseHumanSize(_ s: String) -> Int64 {
    let t = s.trimmingCharacters(in: .whitespaces)
    let num = t.prefix { $0.isNumber || $0 == "." }
    let unit = t.dropFirst(num.count).uppercased()
    let mult: Double = unit.hasPrefix("T") ? 1e12 : unit.hasPrefix("G") ? 1e9 : unit.hasPrefix("M") ? 1e6 : unit.hasPrefix("K") ? 1e3 : 1
    return Int64((Double(num) ?? 0) * mult)
}

func notify(_ title: String, _ body: String) {
    let c = UNMutableNotificationContent()
    c.title = title; c.body = body; c.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

func requestNotifications() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
}

func loadJSONLines(_ out: String) -> [[String: Any]] {
    out.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

// MARK: - Avvio automatico

struct StartupItem: Identifiable {
    enum Scope: String { case user = "Tuoi agenti", system = "Agenti di sistema (tutti gli utenti)", daemon = "Servizi di sistema" }
    var id: String { plist }
    let label: String, plist: String, program: String, scope: Scope, schedule: String
    var running: Bool, disabled: Bool

    var appPath: String? { program.range(of: ".app/").map { String(program[..<$0.upperBound].dropLast()) } }
    var missing: Bool { !program.isEmpty && !FileManager.default.fileExists(atPath: program) }
    var name: String { appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? label }
    var editable: Bool { scope == .user }
}

func loadStartupItems() -> [StartupItem] {
    var running = Set<String>()
    for line in run(["/bin/launchctl", "list"]).out.split(separator: "\n").dropFirst() {
        let c = line.split(separator: "\t")
        if c.count == 3, c[0] != "-" { running.insert(String(c[2])) }
    }
    var disabled = Set<String>()
    for line in run(["/bin/launchctl", "print-disabled", "gui/\(getuid())"]).out.split(separator: "\n") where line.contains("=> disabled") {
        let parts = line.split(separator: "\"")
        if parts.count >= 2 { disabled.insert(String(parts[1])) }
    }
    let dirs: [(String, StartupItem.Scope)] = [(HOME + "/Library/LaunchAgents", .user), ("/Library/LaunchAgents", .system), ("/Library/LaunchDaemons", .daemon)]
    var items: [StartupItem] = []
    for (dir, scope) in dirs {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
            let path = dir + "/" + f
            guard let d = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            let label = d["Label"] as? String ?? (f as NSString).deletingPathExtension
            let prog = d["Program"] as? String ?? (d["ProgramArguments"] as? [String])?.first ?? ""
            let sched = d["StartCalendarInterval"] != nil || d["StartInterval"] != nil ? "Pianificato"
                : (d["KeepAlive"] as? Bool) == true || d["KeepAlive"] is [String: Any] ? "Sempre attivo"
                : (d["RunAtLoad"] as? Bool) == true ? "All'avvio" : "Su richiesta"
            items.append(StartupItem(label: label, plist: path, program: prog, scope: scope, schedule: sched,
                                     running: running.contains(label), disabled: disabled.contains(label)))
        }
    }
    return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// Solo agenti utente: quelli di sistema/aziendali restano in sola lettura.
func setStartup(_ item: StartupItem, enabled: Bool) {
    let dom = "gui/\(getuid())"
    if enabled {
        run(["/bin/launchctl", "enable", "\(dom)/\(item.label)"])
        run(["/bin/launchctl", "bootstrap", dom, item.plist])  // errore se già caricato: va bene
    } else {
        run(["/bin/launchctl", "bootout", "\(dom)/\(item.label)"])
        run(["/bin/launchctl", "disable", "\(dom)/\(item.label)"])
    }
    logLine("AVVIO \(enabled ? "attivato" : "disattivato") \(item.label)")
}

/// Elementi di login "classici" via System Events (chiede il permesso la prima volta). nil = non leggibili.
func loadLoginItems() -> [String]? {
    let r = run(["/usr/bin/osascript", "-e", "tell application \"System Events\" to get the name of every login item"], mergeErr: true)
    guard r.code == 0 else { return nil }
    let t = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? [] : t.components(separatedBy: ", ")
}

func removeLoginItem(_ name: String) {
    run(["/usr/bin/osascript", "-e", "on run argv", "-e", "tell application \"System Events\" to delete login item (item 1 of argv)", "-e", "end run", name])
    logLine("AVVIO rimosso elemento di login \(name)")
}

@MainActor @Observable final class StartupModel {
    var items: [StartupItem] = []
    var loginItems: [String]? = nil
    var loading = false

    func load() {
        loading = true
        Task {
            items = await Task.detached { loadStartupItems() }.value
            loading = false
        }
    }

    func loadLogin() {
        Task { loginItems = await Task.detached { loadLoginItems() }.value ?? [] }
    }

    func toggle(_ item: StartupItem) {
        let enable = item.disabled
        Task {
            await Task.detached { setStartup(item, enabled: enable) }.value
            load()
        }
    }
}

// MARK: - Andamento

struct Snapshot: Codable {
    var date: Date
    var free: Int64
    var total: Int64
    var cats: [String: Int64]
    var dirs: [String: Int64]
}

let SUPPORT_DIR = HOME + "/Library/Application Support/MacSweep"
let HISTORY_PATH = SUPPORT_DIR + "/history.json"

func loadHistory() -> [Snapshot] {
    guard let d = FileManager.default.contents(atPath: HISTORY_PATH) else { return [] }
    return (try? JSONDecoder().decode([Snapshot].self, from: d)) ?? []
}

func saveHistory(_ h: [Snapshot]) {
    try? FileManager.default.createDirectory(atPath: SUPPORT_DIR, withIntermediateDirectories: true)
    try? JSONEncoder().encode(h).write(to: URL(fileURLWithPath: HISTORY_PATH))
}

struct Growth: Identifiable {
    var id: String { label }
    let label: String, delta: Int64, symbol: String, color: Color
}

/// Cosa è cambiato tra l'ultima fotografia e quella di `days` giorni fa (o la più vecchia).
func growth(_ h: [Snapshot], days: Int) -> (since: Date?, freeDelta: Int64, rows: [Growth]) {
    guard let last = h.last, h.count > 1 else { return (nil, 0, []) }
    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
    let base = h.last(where: { $0.date <= cutoff }) ?? h.first!
    guard base.date != last.date else { return (nil, 0, []) }
    var rows: [Growth] = []
    for c in CATEGORIES {
        if let a = base.cats[c.id], let b = last.cats[c.id] { rows.append(Growth(label: c.label, delta: b - a, symbol: c.symbol, color: c.color)) }
    }
    for (p, b) in last.dirs {
        if let a = base.dirs[p] { rows.append(Growth(label: tilde(p), delta: b - a, symbol: "folder.fill", color: .cyan)) }
    }
    rows = rows.filter { abs($0.delta) >= 50_000_000 }.sorted { $0.delta > $1.delta }
    return (base.date, last.free - base.free, rows)
}

// MARK: - Download, installer, duplicati

let INSTALLER_EXT: Set = ["dmg", "pkg", "mpkg", "xip", "iso", "apk", "xapk"]

func downloadItems() -> [Item] {
    let dir = HOME + "/Downloads"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }
    let paths = names.map { dir + "/" + $0 }
    return parallelSizes(paths).map { p, s in
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
        return Item(path: p, isDir: isDir.boolValue && !p.hasSuffix(".app"), size: s, date: lastUsed(p))
    }.sorted { $0.size > $1.size }
}

func installedAppNames() -> [String] {
    APP_DIRS.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        .filter { $0.hasSuffix(".app") }
        .map { normalizeName(($0 as NSString).deletingPathExtension) }
        .filter { $0.count >= 4 }
}

func normalizeName(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }

struct DupGroup: Identifiable {
    var id: String { files.first?.path ?? "" }
    let size: Int64
    var files: [Item]
    var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
}

func sha256(_ path: String, limit: Int? = nil) -> String? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    var hasher = SHA256()
    var read = 0
    while true {
        let chunk = h.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
        read += chunk.count
        if let limit, read >= limit { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Duplicati veri: stessa dimensione -> stesso hash del primo MB -> stesso hash completo.
func findDuplicates(root: String, minSize: Int64) -> [DupGroup] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
    guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
    var bySize: [Int64: [Item]] = [:]
    let lib = HOME + "/Library"
    for case let u as URL in en {
        if u.path == lib { en.skipDescendants(); continue }  // ponytail: ~/Library ha i suoi strumenti, qui solo file utente
        guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
              let size = v.fileSize, Int64(size) >= minSize else { continue }
        bySize[Int64(size), default: []].append(Item(path: u.path, size: Int64(v.totalFileAllocatedSize ?? size), date: v.contentModificationDate))
    }
    var groups: [DupGroup] = []
    for (size, items) in bySize where items.count > 1 {
        for partial in Dictionary(grouping: items, by: { sha256($0.path, limit: 1 << 20) ?? UUID().uuidString }).values where partial.count > 1 {
            for full in Dictionary(grouping: partial, by: { sha256($0.path) ?? UUID().uuidString }).values where full.count > 1 {
                groups.append(DupGroup(size: size, files: full.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }))
            }
        }
    }
    return groups.sorted { $0.wasted > $1.wasted }
}

@MainActor @Observable final class DownloadsModel {
    var items: [Item] = []
    var appNames: [String] = []
    var loading = false
    var loaded = false

    var groups: [DupGroup] = []
    var dupLoading = false
    var dupSearched = false
    var dupSel = Set<String>()

    func load() {
        loading = true
        Task {
            let (i, n) = await Task.detached { (downloadItems(), installedAppNames()) }.value
            items = i; appNames = n
            loading = false; loaded = true
        }
    }

    func isInstalled(_ path: String) -> Bool {
        let n = normalizeName(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        return appNames.contains { n.hasPrefix($0) }
    }

    func findDups(root: String, minMB: Int) {
        dupLoading = true; groups = []; dupSel = []
        Task {
            let g = await Task.detached { findDuplicates(root: root, minSize: Int64(minMB) * 1_000_000) }.value
            groups = g
            // preseleziona tutte le copie tranne la più vecchia di ogni gruppo
            dupSel = Set(g.flatMap { $0.files.dropFirst().map(\.path) })
            dupLoading = false; dupSearched = true
        }
    }

    func dropTrashed(_ done: [String]) {
        let gone = Set(done)
        items.removeAll { gone.contains($0.path) }
        groups = groups.map { g in var g = g; g.files.removeAll { gone.contains($0.path) }; return g }.filter { $0.files.count > 1 }
        dupSel.subtract(gone)
    }
}

// MARK: - Docker

struct DockerRow: Identifiable {
    enum Kind: String { case image = "Immagini", container = "Container", volume = "Volumi" }
    var id: String { kind.rawValue + key }
    let kind: Kind, key: String, title: String, subtitle: String, size: Int64, when: String
}

enum DockerState { case unknown, notInstalled, notRunning, ok }

func loadDocker() -> (DockerState, [DockerRow], [(String, Int64, String)]) {
    if sh("command -v docker").out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (.notInstalled, [], []) }
    if sh("docker info --format '{{.ServerVersion}}'").code != 0 { return (.notRunning, [], []) }
    var rows: [DockerRow] = []
    for j in loadJSONLines(sh("docker images --format '{{json .}}'").out) {
        let repo = j["Repository"] as? String ?? "", tag = j["Tag"] as? String ?? ""
        // nome:tag per le immagini con nome (stesso ID con più tag = più righe), ID solo per quelle senza nome
        let named = repo != "<none>" && tag != "<none>"
        rows.append(DockerRow(kind: .image, key: named ? "\(repo):\(tag)" : j["ID"] as? String ?? "", title: repo == "<none>" ? "Immagine senza nome" : repo,
                              subtitle: tag == "<none>" ? (j["ID"] as? String ?? "") : tag,
                              size: parseHumanSize(j["Size"] as? String ?? ""), when: j["CreatedSince"] as? String ?? ""))
    }
    for j in loadJSONLines(sh("docker ps -a --size --format '{{json .}}'").out) {
        let size = (j["Size"] as? String ?? "").split(separator: " ").first.map(String.init) ?? ""
        rows.append(DockerRow(kind: .container, key: j["ID"] as? String ?? "", title: j["Names"] as? String ?? "",
                              subtitle: "\(j["Image"] as? String ?? "") · \(j["Status"] as? String ?? "")",
                              size: parseHumanSize(size), when: j["RunningFor"] as? String ?? ""))
    }
    // dimensioni dei volumi solo dalla tabella testuale di `docker system df -v`
    var inVolumes = false
    for line in sh("docker system df -v").out.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("VOLUME NAME") { inVolumes = true; continue }
        if inVolumes {
            let c = line.split(separator: " ", omittingEmptySubsequences: true)
            if c.count < 3 { inVolumes = false; continue }
            rows.append(DockerRow(kind: .volume, key: String(c[0]), title: String(c[0]), subtitle: "\(c[1]) container collegati",
                                  size: parseHumanSize(String(c[2])), when: ""))
        }
    }
    let summary = loadJSONLines(sh("docker system df --format '{{json .}}'").out).map {
        ($0["Type"] as? String ?? "", parseHumanSize($0["Size"] as? String ?? ""), $0["Reclaimable"] as? String ?? "")
    }
    return (.ok, rows.sorted { $0.size > $1.size }, summary)
}

@MainActor @Observable final class DockerModel {
    var state = DockerState.unknown
    var rows: [DockerRow] = []
    var summary: [(String, Int64, String)] = []
    var loading = false
    var busy = false

    func load() {
        loading = true
        Task {
            (state, rows, summary) = await Task.detached { loadDocker() }.value
            loading = false
        }
    }

    func remove(_ r: DockerRow, store: Store) {
        let cmd = switch r.kind {
        case .image: "docker rmi \(shq(r.key))"
        case .container: "docker rm \(shq(r.key))"
        case .volume: "docker volume rm \(shq(r.key))"
        }
        guard confirm("Eliminare \(r.title) (\(fmt(r.size)))?", "Docker lo cancella in modo DEFINITIVO, non va nel Cestino.") else { return }
        exec(cmd, label: r.title, store: store)
    }

    func pruneBuildCache(store: Store) {
        guard confirm("Svuotare la build cache di Docker?", "Cancellazione definitiva. Si rigenera alla prossima build.") else { return }
        exec("docker builder prune -f", label: "Build cache", store: store)
    }

    private func exec(_ cmd: String, label: String, store: Store) {
        busy = true
        Task {
            let r = await Task.detached { sh(cmd) }.value
            logLine("DOCKER \(cmd) -> \(r.code)")
            store.flash(r.code == 0 ? "\(label): eliminato" : "Errore: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))")
            busy = false
            store.refreshDisk()
            load()
        }
    }
}

// MARK: - Simulatori

struct SimRuntime: Identifiable {
    let id: String, name: String, size: Int64, lastUsed: Date?, deletable: Bool
}

struct SimDevice: Identifiable {
    var id: String { udid }
    let udid: String, name: String, runtime: String, size: Int64, lastUsed: Date?, available: Bool
}

func platformName(_ s: String) -> String {
    let l = s.lowercased()
    return l.contains("watch") ? "watchOS" : l.contains("tv") ? "tvOS" : l.contains("xr") || l.contains("vision") ? "visionOS" : "iOS"
}

func loadSims() -> ([SimRuntime], [SimDevice]) {
    var runtimes: [SimRuntime] = []
    if let d = try? JSONSerialization.jsonObject(with: Data(run(["/usr/bin/xcrun", "simctl", "runtime", "list", "-j"]).out.utf8)) as? [String: [String: Any]] {
        for (id, r) in d {
            runtimes.append(SimRuntime(id: id, name: "\(platformName(r["platformIdentifier"] as? String ?? "")) \(r["version"] as? String ?? "")",
                                       size: (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                                       lastUsed: (r["lastUsedAt"] as? String).flatMap(ISO.date(from:)),
                                       deletable: r["deletable"] as? Bool ?? false))
        }
    }
    var devices: [SimDevice] = []
    if let d = try? JSONSerialization.jsonObject(with: Data(run(["/usr/bin/xcrun", "simctl", "list", "devices", "-j"]).out.utf8)) as? [String: Any],
       let byRuntime = d["devices"] as? [String: [[String: Any]]] {
        for (key, list) in byRuntime {
            // com.apple.CoreSimulator.SimRuntime.iOS-26-5 -> iOS 26.5
            let tail = key.split(separator: ".").last.map(String.init) ?? key
            let parts = tail.split(separator: "-")
            let rt = parts.isEmpty ? tail : "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
            for dev in list {
                let size = ((dev["dataPathSize"] as? NSNumber)?.int64Value ?? 0) + ((dev["logPathSize"] as? NSNumber)?.int64Value ?? 0)
                devices.append(SimDevice(udid: dev["udid"] as? String ?? "", name: dev["name"] as? String ?? "", runtime: rt, size: size,
                                         lastUsed: (dev["lastUsedAt"] as? String).flatMap(ISO.date(from:)),
                                         available: dev["isAvailable"] as? Bool ?? true))
            }
        }
    }
    return (runtimes.sorted { $0.size > $1.size }, devices.sorted { $0.size > $1.size })
}

@MainActor @Observable final class SimsModel {
    var runtimes: [SimRuntime] = []
    var devices: [SimDevice] = []
    var loading = false
    var busy = false

    func load() {
        loading = true
        Task {
            (runtimes, devices) = await Task.detached { loadSims() }.value
            loading = false
        }
    }

    func deleteRuntime(_ r: SimRuntime, store: Store) {
        guard confirm("Eliminare il runtime \(r.name) (\(fmt(r.size)))?", "Cancellazione definitiva. Si può riscaricare da Xcode → Impostazioni → Componenti.") else { return }
        exec(["/usr/bin/xcrun", "simctl", "runtime", "delete", r.id], label: r.name, store: store)
    }

    func deleteDevice(_ d: SimDevice, store: Store) {
        guard confirm("Eliminare il simulatore \(d.name) (\(d.runtime))?", "Cancellazione definitiva di app e dati del simulatore (\(fmt(d.size))).") else { return }
        exec(["/usr/bin/xcrun", "simctl", "delete", d.udid], label: d.name, store: store)
    }

    func deleteUnavailable(store: Store) {
        exec(["/usr/bin/xcrun", "simctl", "delete", "unavailable"], label: "Simulatori non disponibili", store: store)
    }

    private func exec(_ args: [String], label: String, store: Store) {
        busy = true
        Task {
            let r = await Task.detached { run(args, mergeErr: true) }.value
            logLine("SIMULATORI \(args.dropFirst().joined(separator: " ")) -> \(r.code)")
            store.flash(r.code == 0 ? "\(label): eliminato" : "Errore: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))")
            busy = false
            store.refreshDisk()
            load()
        }
    }
}

// MARK: - Modelli AI

struct AIModel: Identifiable {
    var id: String { path }
    let path: String, name: String, source: String, size: Int64, lastUsed: Date?
}

let AI_SOURCES: [(name: String, dir: String, depth: Int)] = [
    ("LM Studio", HOME + "/.lmstudio/models", 2),
    ("LM Studio", HOME + "/.cache/lm-studio/models", 2),
    ("Hugging Face", HOME + "/.cache/huggingface/hub", 1),
    ("Draw Things", HOME + "/Library/Containers/com.liuliu.draw-things/Data/Documents/Models", 1),
    ("Ollama", HOME + "/.ollama", 1),
]

func aiStyle(_ source: String) -> (symbol: String, color: Color) {
    switch source {
    case "LM Studio": ("brain.fill", .purple)
    case "Hugging Face": ("face.smiling.inverse", .yellow)
    case "Draw Things": ("paintbrush.pointed.fill", .pink)
    case "Ollama": ("hare.fill", .gray)
    default: ("cpu.fill", .blue)
    }
}

func newestAccess(_ path: String) -> Date? {
    let keys: [URLResourceKey] = [.contentAccessDateKey]
    guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys) else {
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: Set(keys)))?.contentAccessDate
    }
    var best: Date? = nil
    for case let u as URL in en {
        if let d = (try? u.resourceValues(forKeys: Set(keys)))?.contentAccessDate, d > (best ?? .distantPast) { best = d }
    }
    return best ?? (try? URL(fileURLWithPath: path).resourceValues(forKeys: Set(keys)))?.contentAccessDate
}

func loadAIModels() -> [AIModel] {
    var found: [(String, String, String)] = []  // path, nome, fonte
    for src in AI_SOURCES {
        let level1 = ((try? FileManager.default.contentsOfDirectory(atPath: src.dir)) ?? []).filter { !$0.hasPrefix(".") }
        if src.name == "Ollama" {
            if FileManager.default.fileExists(atPath: src.dir + "/models") { found.append((src.dir + "/models", "Tutti i modelli Ollama", src.name)) }
            continue
        }
        for a in level1 {
            let p1 = src.dir + "/" + a
            if src.depth == 2 {
                for b in ((try? FileManager.default.contentsOfDirectory(atPath: p1)) ?? []).filter({ !$0.hasPrefix(".") }) {
                    found.append((p1 + "/" + b, "\(a)/\(b)", src.name))
                }
            } else if src.name == "Hugging Face" {
                guard a.hasPrefix("models--") || a.hasPrefix("datasets--") else { continue }
                found.append((p1, a.components(separatedBy: "--").dropFirst().joined(separator: "/"), src.name))  // models--org--nome -> org/nome
            } else {
                found.append((p1, a, src.name))
            }
        }
    }
    let sizes = parallelSizes(found.map(\.0))
    return zip(found, sizes).map { f, s in AIModel(path: f.0, name: f.1, source: f.2, size: s.1, lastUsed: newestAccess(f.0)) }
        .filter { $0.size >= 10_000_000 }
        .sorted { $0.size > $1.size }
}

@MainActor @Observable final class AIModelsModel {
    var models: [AIModel] = []
    var loading = false
    var loaded = false

    func load() {
        loading = true
        Task {
            models = await Task.detached { loadAIModels() }.value
            loading = false; loaded = true
        }
    }
}

// MARK: - Macchine virtuali

struct VMInfo: Identifiable {
    var id: String { path }
    let path: String, name: String, app: String, appPath: String, size: Int64, modified: Date?
}

let VM_SOURCES: [(app: String, dir: String, ext: String, appPath: String)] = [
    ("UTM", HOME + "/Library/Containers/com.utmapp.UTM/Data/Documents", "utm", "/Applications/UTM.app"),
    ("Parallels", HOME + "/Parallels", "pvm", "/Applications/Parallels Desktop.app"),
    ("VMware Fusion", HOME + "/Virtual Machines.localized", "vmwarevm", "/Applications/VMware Fusion.app"),
    ("VMware Fusion", HOME + "/Documents/Virtual Machines.localized", "vmwarevm", "/Applications/VMware Fusion.app"),
    ("VirtualBox", HOME + "/VirtualBox VMs", "", "/Applications/VirtualBox.app"),
]

func loadVMs() -> [VMInfo] {
    var found: [(String, String, String)] = []
    for src in VM_SOURCES {
        for e in (try? FileManager.default.contentsOfDirectory(atPath: src.dir)) ?? [] where !e.hasPrefix(".") {
            if src.ext.isEmpty || (e as NSString).pathExtension.lowercased() == src.ext {
                found.append((src.dir + "/" + e, src.app, src.appPath))
            }
        }
    }
    let sizes = parallelSizes(found.map(\.0))
    return zip(found, sizes).map { f, s in
        VMInfo(path: f.0, name: ((f.0 as NSString).lastPathComponent as NSString).deletingPathExtension, app: f.1, appPath: f.2, size: s.1,
               modified: (try? URL(fileURLWithPath: f.0).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
    }.sorted { $0.size > $1.size }
}

@MainActor @Observable final class VMModel {
    var vms: [VMInfo] = []
    var loading = false
    var loaded = false

    func load() {
        loading = true
        Task {
            vms = await Task.detached { loadVMs() }.value
            loading = false; loaded = true
        }
    }
}

// MARK: - Pulizia programmata

struct AutocleanConfig: Codable, Equatable {
    var enabled = false
    var weekday = 0  // 0 = domenica (come launchd)
    var hour = 12
    var tasks: [String] = ["brew", "npm", "derived"]
}

let AUTOCLEAN_LABEL = "local.sriva.macsweep.autoclean"
let AUTOCLEAN_PLIST = HOME + "/Library/LaunchAgents/\(AUTOCLEAN_LABEL).plist"

let AUTOCLEAN_OPTIONS: [(id: String, label: String, symbol: String, color: Color)] = [
    ("brew", "Homebrew: cache e versioni vecchie", "mug.fill", .orange),
    ("npm", "Cache npm", "cube.fill", .red),
    ("pnpm", "Store pnpm: pacchetti orfani", "cube.transparent.fill", .yellow),
    ("simctl", "Simulatori non più disponibili", "iphone", .teal),
    ("dockercache", "Build cache di Docker", "cube.box.fill", .cyan),
    ("derived", "Xcode DerivedData (definitivo)", "hammer.fill", .blue),
    ("logs", "Log (definitivo)", "doc.text.fill", .gray),
]

func loadAutoclean() -> AutocleanConfig {
    guard let d = UserDefaults.standard.data(forKey: "autoclean"), let c = try? JSONDecoder().decode(AutocleanConfig.self, from: d) else { return AutocleanConfig() }
    return c
}

func saveAutoclean(_ c: AutocleanConfig) {
    UserDefaults.standard.set(try? JSONEncoder().encode(c), forKey: "autoclean")
    let dom = "gui/\(getuid())"
    run(["/bin/launchctl", "bootout", "\(dom)/\(AUTOCLEAN_LABEL)"])
    guard c.enabled else {
        try? FileManager.default.removeItem(atPath: AUTOCLEAN_PLIST)
        return
    }
    let plist: [String: Any] = [
        "Label": AUTOCLEAN_LABEL,
        "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/MacSweep.app/Contents/MacOS/MacSweep", "--autoclean"],
        "StartCalendarInterval": ["Weekday": c.weekday, "Hour": c.hour, "Minute": 0],
    ]
    (plist as NSDictionary).write(toFile: AUTOCLEAN_PLIST, atomically: true)
    run(["/bin/launchctl", "bootstrap", dom, AUTOCLEAN_PLIST])
}

func freeSpace() -> Int64 {
    (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
}

/// Esegue la pulizia configurata (anche da launchd con --autoclean). Ritorna byte liberati e riepilogo.
func runAutoclean(_ c: AutocleanConfig) -> (freed: Int64, report: String) {
    let before = freeSpace()
    var report: [String] = []
    for id in c.tasks {
        switch id {
        case "derived", "logs":
            let dir = CATEGORIES.first { $0.id == id }!.path
            var n = 0
            for e in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let p = dir + "/" + e
                if (try? checkTrashable(p)) != nil, (try? FileManager.default.removeItem(atPath: p)) != nil { n += 1 }
            }
            report.append("\(id): \(n) elementi rimossi")
        case "dockercache":
            report.append("docker: " + (sh("docker builder prune -f").code == 0 ? "ok" : "non avviato"))
        default:
            if let t = TASKS.first(where: { $0.id == id }) {
                let r = run(["/bin/zsh", "-lic", t.cmd], mergeErr: true)
                report.append("\(id): \(r.code == 0 ? "ok" : "errore")")
            }
        }
    }
    let freed = max(freeSpace() - before, 0)
    let summary = report.joined(separator: ", ")
    logLine("AUTOPULIZIA liberati \(fmt(freed)) — \(summary)")
    return (freed, summary)
}

// MARK: - Registro e ripristino

struct LogEntry: Identifiable {
    enum Status { case inTrash, restored, gone, unknown, info }
    let id = UUID()
    let date: Date, kind: String, path: String, trash: String, size: Int64, text: String
    var status: Status {
        guard kind == "CESTINO" else { return .info }
        if !trash.isEmpty && FileManager.default.fileExists(atPath: trash) { return .inTrash }
        if FileManager.default.fileExists(atPath: path) { return .restored }
        return trash.isEmpty ? .unknown : .gone  // unknown: voce vecchia o app di root cestinata dal Finder
    }
}

struct LogSession: Identifiable {
    var id: Date { start }
    let start: Date
    var title: String
    var entries: [LogEntry]
    var trashed: [LogEntry] { entries.filter { $0.kind == "CESTINO" } }
}

func readLog() -> [LogSession] {
    guard let text = try? String(contentsOfFile: LOG_PATH, encoding: .utf8) else { return [] }
    let iso = ISO8601DateFormatter()
    var entries: [LogEntry] = []
    for line in text.split(separator: "\n") where !line.contains("/.macsweep-selftest-") {  // rumore del self-test
        guard let sp = line.firstIndex(of: " "), let date = iso.date(from: String(line[..<sp])) else { continue }
        let rest = String(line[line.index(after: sp)...])
        let kind = rest.split(separator: " ").first.map(String.init) ?? ""
        let body = String(rest.dropFirst(kind.count + 1))
        if kind == "CESTINO" {
            let f = body.components(separatedBy: "\t")
            entries.append(LogEntry(date: date, kind: kind, path: f[0], trash: f.count > 1 ? f[1] : "",
                                    size: f.count > 2 ? Int64(f[2]) ?? 0 : 0, text: body))
        } else {
            entries.append(LogEntry(date: date, kind: kind, path: "", trash: "", size: 0, text: body))
        }
    }
    // sessione = voci a meno di 2 minuti l'una dall'altra
    var sessions: [LogSession] = []
    for e in entries {
        if let last = sessions.last?.entries.last, e.date.timeIntervalSince(last.date) < 120 {
            sessions[sessions.count - 1].entries.append(e)
        } else {
            sessions.append(LogSession(start: e.date, title: "", entries: [e]))
        }
    }
    for i in sessions.indices {
        let s = sessions[i]
        if let u = s.entries.first(where: { $0.kind == "DISINSTALLA" }) {
            sessions[i].title = "Disinstallazione di " + (u.text.components(separatedBy: " [").first ?? u.text)
        } else if s.entries.contains(where: { $0.kind == "AUTOPULIZIA" }) {
            sessions[i].title = "Pulizia programmata"
        } else if !s.trashed.isEmpty {
            sessions[i].title = s.trashed.count == 1 ? (s.trashed[0].path as NSString).lastPathComponent : "\(s.trashed.count) elementi nel Cestino"
        } else {
            sessions[i].title = s.entries.first.map { "\($0.kind.capitalized) \($0.text)" } ?? ""
        }
    }
    return sessions.reversed()
}

/// Rimette il file dov'era. Errore se il posto è occupato o il Cestino è stato svuotato.
func restore(_ e: LogEntry) throws {
    guard e.status == .inTrash else { throw GuardError(errorDescription: "Non è più nel Cestino") }
    guard !FileManager.default.fileExists(atPath: e.path) else { throw GuardError(errorDescription: "Esiste già un file in \(tilde(e.path))") }
    try FileManager.default.createDirectory(atPath: (e.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: e.trash, toPath: e.path)
    logLine("RIPRISTINO \(e.path)")
}

func featureSelfTest(dir: String) {
    precondition(parseHumanSize("1.5GB") == 1_500_000_000 && parseHumanSize("12.3kB") == 12_300 && parseHumanSize("0B") == 0)
    precondition(platformName("com.apple.platform.watchsimulator") == "watchOS")
    // notch: sosta sul notch apre, il pannello aperto resta aperto finché ci sei sopra, fuori si chiude
    let nz = NotchZones.make(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), notch: CGSize(width: 185, height: 32), open: CGSize(width: 452, height: 210))
    precondition(nz.decide(CGPoint(x: 756, y: 970), expanded: false) == .open)        // sul notch
    precondition(nz.decide(CGPoint(x: 600, y: 970), expanded: false) == .stay)        // barra dei menu accanto: niente
    precondition(nz.decide(CGPoint(x: 756, y: 800), expanded: false) == .stay)        // sotto, da chiuso: niente
    precondition(nz.decide(CGPoint(x: 756, y: 800), expanded: true) == .stay)         // dentro il pannello aperto
    precondition(nz.decide(CGPoint(x: 987, y: 790), expanded: true) == .stay)         // bordo (+8 di tolleranza)
    precondition(nz.decide(CGPoint(x: 756, y: 500), expanded: true) == .close)        // fuori
    precondition(nz.decide(CGPoint(x: 1100, y: 970), expanded: true) == .close)
    // updater sviluppo: lettura versioni e JSON sporco di output della shell
    precondition(firstVersion("rustup 1.29.0 (28d1352db 2026-03-05)") == "1.29.0" && firstVersion("uv 0.9.25 (38fcac0f3)") == "0.9.25")
    precondition(firstVersion("v24.18.0") == "v24.18.0" && compareVersions("v24.3.0", "v24.18.0") && !compareVersions("1.10", "1.9"))
    precondition((jsonObject(in: "Agent pid 42\n{\"npm\": {\"latest\": \"12.2.1\"}}\n") as? [String: Any])?["npm"] != nil)
    // scanner veloce = du: cartelle annidate, file e un hard link (contato una volta)
    let t = dir + "/scan"
    try! FileManager.default.createDirectory(atPath: t + "/a/b/c", withIntermediateDirectories: true)
    for (f, n) in [("x.bin", 300_000), ("a/y.bin", 50_000), ("a/b/z.bin", 1_000_000), ("a/b/c/w.bin", 7)] {
        FileManager.default.createFile(atPath: t + "/" + f, contents: Data(count: n))
    }
    try! FileManager.default.linkItem(atPath: t + "/a/b/z.bin", toPath: t + "/a/hard.bin")
    let fast = FastScanner().scan(t)
    let du = Int64(run(["/usr/bin/du", "-sk", t]).out.split(separator: "\t").first ?? "")! * 1024
    precondition(fast.count == 4 && fast[t + "/a/b/c"]! > 0, "cartelle mancanti: \(fast)")
    // du conta anche i blocchi delle cartelle stesse (pochi KB): tolleranza 64 KB
    precondition(abs(fast[t]! - du) <= 65_536, "scanner \(fast[t]!) vs du \(du)")
    // file nascosti di macOS: trova .DS_Store e ._*, non i file veri
    let j = dir + "/junk"
    try! FileManager.default.createDirectory(atPath: j + "/sotto", withIntermediateDirectories: true)
    for f in [".DS_Store", "._foto.jpg", "sotto/.DS_Store", "foto.jpg", "note.txt"] { FileManager.default.createFile(atPath: j + "/" + f, contents: Data(count: 10)) }
    let junk = Set(scanVolumeJunk(j).files.map { String($0.dropFirst(j.count + 1)) })
    precondition(junk == [".DS_Store", "._foto.jpg", "sotto/.DS_Store"], "file nascosti sbagliati: \(junk)")
    // mappa a raggiera: angoli proporzionali, figli dentro il genitore
    let arcs = sunburstArcs(root: "/r", items: [Item(path: "/r/a", isDir: true, size: 300), Item(path: "/r/b", size: 100)],
                            sizes: ["/r": 400, "/r/a": 300, "/r/a/x": 200, "/r/a/x/y": 100])
    let ra = arcs.first { $0.path == "/r/a" }!, rx = arcs.first { $0.path == "/r/a/x" }!, ry = arcs.first { $0.path == "/r/a/x/y" }!
    precondition(abs((ra.end - ra.start) - 1.5 * Double.pi) < 1e-9 && rx.depth == 2 && ry.depth == 3)
    precondition(rx.start >= ra.start && rx.end <= ra.end && abs((rx.end - rx.start) - (ra.end - ra.start) * 2 / 3) < 1e-9)
    // duplicati: due copie uguali + uno stesso peso ma diverso
    let d = dir + "/dup"
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    let a = Data((0..<300_000).map { UInt8($0 % 251) })
    var b = a; b[150_000] = 7
    FileManager.default.createFile(atPath: d + "/a.bin", contents: a)
    FileManager.default.createFile(atPath: d + "/a copia.bin", contents: a)
    FileManager.default.createFile(atPath: d + "/b.bin", contents: b)
    let g = findDuplicates(root: d, minSize: 100_000)
    precondition(g.count == 1 && g[0].files.count == 2 && !g[0].files.contains { $0.path.hasSuffix("b.bin") }, "duplicati sbagliati: \(g)")
    // cestino + ripristino dal registro (serve leggere ~/.Trash: senza Accesso completo al disco si salta)
    guard (try? FileManager.default.contentsOfDirectory(atPath: HOME + "/.Trash")) != nil else {
        print("ripristino non verificato: questo processo non ha l'Accesso completo al disco"); return
    }
    let f = d + "/ripristina.bin"
    FileManager.default.createFile(atPath: f, contents: Data(count: 10_000))
    precondition(moveToTrash([f]).done == [f])
    guard let entry = readLogRaw().last(where: { $0.path == f }) else { preconditionFailure("voce di registro mancante") }
    try! restore(entry)
    precondition(FileManager.default.fileExists(atPath: f), "ripristino fallito")
}

/// Come readLog ma senza filtri (per il self-test).
func readLogRaw() -> [LogEntry] {
    guard let text = try? String(contentsOfFile: LOG_PATH, encoding: .utf8) else { return [] }
    let iso = ISO8601DateFormatter()
    return text.split(separator: "\n").compactMap { line in
        guard let sp = line.firstIndex(of: " "), let date = iso.date(from: String(line[..<sp])) else { return nil }
        let rest = line[line.index(after: sp)...]
        guard rest.hasPrefix("CESTINO ") else { return nil }
        let f = rest.dropFirst(8).components(separatedBy: "\t")
        return LogEntry(date: date, kind: "CESTINO", path: f[0], trash: f.count > 1 ? f[1] : "", size: 0, text: "")
    }
}
