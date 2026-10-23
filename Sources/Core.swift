import AppKit
import CoreServices
import Foundation
import Observation
import SwiftUI

let HOME = NSHomeDirectory()
let DATA_VOL = "/System/Volumes/Data"  // dove vivono davvero i dati su APFS

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }
func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
/// RAM in unità binarie, come Monitoraggio Attività (24 GB, non 25,77)
func fmtMem(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .memory) }

@discardableResult
func run(_ args: [String], mergeErr: Bool = false) -> (out: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = mergeErr ? pipe : FileHandle.nullDevice  // du scrive tanti "Permission denied": mai in una pipe non letta
    do { try p.run() } catch { return ("\(error.localizedDescription)", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
}

// MARK: - Dimensioni

// duTree/duTotal: vedi Scanner.swift

struct Item: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var isDir = false
    let size: Int64
    var date: Date? = nil
}

func listDir(_ path: String, sizes: [String: Int64]) -> [Item]? {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys) else { return nil }
    return urls.map { u in
        let v = try? u.resourceValues(forKeys: Set(keys))
        let isDir = (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false)
        let p = (path as NSString).appendingPathComponent(u.lastPathComponent)
        return Item(path: p, isDir: isDir,
                    size: isDir ? sizes[p] ?? 0 : Int64(v?.totalFileAllocatedSize ?? 0),
                    date: v?.contentModificationDate)
    }.sorted { $0.size > $1.size }
}

func bigFiles(minMB: Int) -> [Item] {
    // Spotlight: istantaneo ma non indicizza ~/Library; per quello c'è Esplora
    let q = "kMDItemFSSize > \(minMB * 1_048_576)"
    let paths = run(["/usr/bin/mdfind", "-onlyin", HOME, q]).out.split(separator: "\n").map(String.init)
    return paths.compactMap { p -> Item? in
        let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .contentModificationDateKey])
        guard let v, v.isDirectory != true else { return nil }
        return Item(path: p, size: Int64(v.totalFileAllocatedSize ?? 0), date: v.contentModificationDate)
    }.sorted { $0.size > $1.size }
}

let DEV_JUNK = ["node_modules", ".venv", "venv", "__pycache__", ".next", ".turbo", "target", "Pods", ".gradle"]

func devJunk() -> [Item] {
    // cartelle nascoste in ~ (es. ~/.nvm) escluse: lì dentro node_modules sono pacchetti globali, non spazzatura
    let names = DEV_JUNK.flatMap { ["-name", $0, "-o"] }.dropLast()
    let args = ["/usr/bin/find", HOME, "-xdev",
                "(", "-path", "\(HOME)/.*", "-o", "-path", "\(HOME)/Library", "-o", "-path", "\(HOME)/Applications", ")",
                "-prune", "-o", "-type", "d", "("] + names + [")", "-prune", "-print"]
    let paths = run(args).out.split(separator: "\n").map(String.init)
    return parallelSizes(paths).map { Item(path: $0.0, isDir: true, size: $0.1) }.sorted { $0.size > $1.size }
}

func parallelSizes(_ paths: [String]) -> [(String, Int64)] {
    var sizes = [Int64](repeating: 0, count: paths.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: paths.count) { i in
        let s = duTotal(paths[i])
        lock.lock(); sizes[i] = s; lock.unlock()
    }
    return Array(zip(paths, sizes))
}

// MARK: - Categorie e task

struct Category: Identifiable {
    let id: String, label: String, path: String, cleanable: Bool, note: String, symbol: String, color: Color
    var size: Int64? = nil
}

let CATEGORIES: [Category] = [
    .init(id: "caches", label: "Cache utente", path: expand("~/Library/Caches"), cleanable: true, note: "Si rigenerano da sole", symbol: "archivebox.fill", color: .orange),
    .init(id: "logs", label: "Log", path: expand("~/Library/Logs"), cleanable: true, note: "Diagnostica delle app", symbol: "doc.text.fill", color: .gray),
    .init(id: "derived", label: "Xcode DerivedData", path: expand("~/Library/Developer/Xcode/DerivedData"), cleanable: true, note: "Build intermedie", symbol: "hammer.fill", color: .blue),
    .init(id: "devsupport", label: "iOS DeviceSupport", path: expand("~/Library/Developer/Xcode/iOS DeviceSupport"), cleanable: true, note: "Simboli di device vecchi", symbol: "iphone.gen3", color: .indigo),
    .init(id: "archives", label: "Xcode Archives", path: expand("~/Library/Developer/Xcode/Archives"), cleanable: true, note: "Attenzione: build pubblicate", symbol: "shippingbox.fill", color: .brown),
    .init(id: "simulators", label: "Simulatori iOS", path: expand("~/Library/Developer/CoreSimulator/Devices"), cleanable: false, note: "Pulisci da Manutenzione", symbol: "ipad.and.iphone", color: .teal),
    .init(id: "iosbackup", label: "Backup iPhone/iPad", path: expand("~/Library/Application Support/MobileSync/Backup"), cleanable: true, note: "Attenzione: backup reali", symbol: "externaldrive.fill.badge.timemachine", color: .green),
    .init(id: "npm", label: "Cache npm", path: expand("~/.npm"), cleanable: true, note: "Pacchetti scaricati", symbol: "cube.fill", color: .red),
    .init(id: "pnpm", label: "Store pnpm", path: expand("~/Library/pnpm/store"), cleanable: false, note: "Pulisci da Manutenzione", symbol: "cube.transparent.fill", color: .yellow),
    .init(id: "gradle", label: "Cache Gradle", path: expand("~/.gradle/caches"), cleanable: true, note: "Dipendenze Android/Java", symbol: "leaf.fill", color: .mint),
    .init(id: "docker", label: "Docker", path: expand("~/Library/Containers/com.docker.docker"), cleanable: false, note: "Pulisci da Manutenzione", symbol: "cube.box.fill", color: .cyan),
    .init(id: "maildl", label: "Allegati Mail", path: expand("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"), cleanable: true, note: "Allegati già aperti", symbol: "paperclip", color: .blue),
    .init(id: "downloads", label: "Download", path: expand("~/Downloads"), cleanable: false, note: "Da rivedere a mano", symbol: "arrow.down.circle.fill", color: .purple),
    .init(id: "trash", label: "Cestino", path: expand("~/.Trash"), cleanable: false, note: "Svuota da Manutenzione", symbol: "trash.fill", color: .secondary),
    .init(id: "apps", label: "Applicazioni", path: "/Applications", cleanable: false, note: "App installate", symbol: "square.grid.3x3.fill", color: .indigo),
]

struct MaintTask: Identifiable { let id: String, label: String, detail: String, cmd: String, symbol: String, color: Color }

let TASKS: [MaintTask] = [
    .init(id: "brew", label: "Homebrew", detail: "Cache e versioni vecchie dei pacchetti", cmd: "brew cleanup --prune=all -s", symbol: "mug.fill", color: .orange),
    .init(id: "simctl", label: "Simulatori iOS", detail: "Elimina i simulatori non più disponibili", cmd: "xcrun simctl delete unavailable", symbol: "iphone", color: .teal),
    .init(id: "npm", label: "Cache npm", detail: "Svuota la cache dei pacchetti npm", cmd: "npm cache clean --force", symbol: "cube.fill", color: .red),
    .init(id: "pnpm", label: "Store pnpm", detail: "Rimuove i pacchetti orfani dallo store", cmd: "pnpm store prune", symbol: "cube.transparent.fill", color: .yellow),
    .init(id: "docker", label: "Docker", detail: "Container fermi, immagini dangling, build cache", cmd: "docker system prune -f", symbol: "cube.box.fill", color: .cyan),
    .init(id: "quicklook", label: "Anteprime QuickLook", detail: "Reset della cache delle miniature", cmd: "qlmanage -r cache", symbol: "eye.fill", color: .blue),
    .init(id: "snapshots", label: "Snapshot Time Machine", detail: "Elenca gli snapshot locali", cmd: "tmutil listlocalsnapshots /", symbol: "clock.arrow.circlepath", color: .green),
    .init(id: "emptytrash", label: "Svuota Cestino", detail: "Definitivo: non si torna indietro", cmd: "osascript -e 'tell application \"Finder\" to empty trash'", symbol: "trash.fill", color: .red),
]

/// Icona e colore per tipo di file (per estensione).
func fileStyle(_ path: String) -> (symbol: String, color: Color) {
    switch (path as NSString).pathExtension.lowercased() {
    case "mp4", "mov", "m4v", "mkv", "avi", "webm": ("film.fill", .pink)
    case "jpg", "jpeg", "png", "heic", "dng", "psd", "tiff", "gif": ("photo.fill", .orange)
    case "zip", "rar", "7z", "tar", "gz", "xz", "tgz", "bz2": ("doc.zipper", .yellow)
    case "ckpt", "safetensors", "gguf", "bin", "pt", "pth", "onnx", "mlmodel", "ckpt-tensordata", "tensordata": ("brain.fill", .purple)
    case "dmg", "iso", "img", "raw", "vmdk", "qcow2", "vhdx", "utm", "xcz": ("opticaldiscdrive.fill", .gray)
    case "mp3", "wav", "flac", "m4a", "aac", "aiff": ("music.note", .red)
    case "pdf": ("doc.richtext.fill", .red)
    case "apk", "ipa", "pkg", "xapk": ("app.badge.fill", .green)
    default: ("doc.fill", .blue)
    }
}

/// Icona e colore per i tipi di cartelle dev.
func devStyle(_ kind: String) -> (symbol: String, color: Color) {
    switch kind {
    case "node_modules": ("cube.fill", .green)
    case ".venv", "venv", "__pycache__": ("terminal.fill", .yellow)
    case "target": ("hammer.fill", .orange)
    case "Pods": ("shippingbox.fill", .blue)
    case ".next": ("n.square.fill", .primary)
    case ".turbo": ("bolt.fill", .pink)
    case ".gradle": ("leaf.fill", .mint)
    default: ("folder.fill", .gray)
    }
}

// MARK: - Guard cestino

struct GuardError: LocalizedError { let errorDescription: String? }

let PROTECTED: Set<String> = Set(["/", "/Applications", "/System", "/Library", "/Users", "/private", DATA_VOL,
    "~", "~/Library", "~/Documents", "~/Desktop", "~/Downloads", "~/Pictures", "~/Movies",
    "~/Music", "~/Applications", "~/.Trash", "~/.ssh", "~/.config"].map(expand))

/// Solo path sotto ~ o app in /Applications; mai cartelle di sistema o radici utente.
func checkTrashable(_ p: String) throws {
    let comps = p.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    guard p.hasPrefix("/"), !comps.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
        throw GuardError(errorDescription: "Path non valido: \(p)")
    }
    if PROTECTED.contains(p) { throw GuardError(errorDescription: "Path protetto: \(p)") }
    let lib = HOME + "/Library/"
    if p.hasPrefix(HOME + "/.Trash/") { throw GuardError(errorDescription: "Già nel Cestino") }
    if p.hasPrefix(lib) && !p.dropFirst(lib.count).contains("/") {
        throw GuardError(errorDescription: "Cartella di sistema utente, pulisci il contenuto: \(p)")
    }
    let inApps = ["/Applications", "/Applications/Utilities"].contains((p as NSString).deletingLastPathComponent) && p.hasSuffix(".app")
    let parts = p.split(separator: "/")
    let onExternal = parts.count >= 3 && parts[0] == "Volumes"
        && (try? FileManager.default.destinationOfSymbolicLink(atPath: "/Volumes/\(parts[1])")) != "/"  // "Macintosh HD" -> "/"
    guard p.hasPrefix(HOME + "/") || inApps || onExternal else { throw GuardError(errorDescription: "Fuori dalla home: \(p)") }
    guard FileManager.default.fileExists(atPath: p) || (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil else {
        throw GuardError(errorDescription: "Non esiste: \(p)")
    }
}

/// Registro di cosa finisce nel Cestino: ~/Library/Logs/MacSweep.log
let LOG_PATH = HOME + "/Library/Logs/MacSweep.log"

func logLine(_ msg: String) {
    let line = "\(Date().formatted(.iso8601)) \(msg)\n"
    if let h = FileHandle(forWritingAtPath: LOG_PATH) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(toFile: LOG_PATH, atomically: true, encoding: .utf8)
    }
}

/// Sposta nel Cestino (recuperabile con "Rimetti al suo posto"). Ritorna i path spostati e gli errori.
func moveToTrash(_ paths: [String], sizes: [String: Int64] = [:]) -> (done: [String], errors: [String]) {
    var done: [String] = [], errors: [String] = []
    for p in paths {
        var trashed: NSURL? = nil
        do {
            try checkTrashable(p)
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &trashed)
            } catch where p.hasSuffix(".app") {
                // app di root (App Store, installer): il Finder chiede la password admin come fa di solito
                let r = run(["/usr/bin/osascript", "-e", "on run argv", "-e",
                             "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)", "-e", "end run", p],
                            mergeErr: true)
                if FileManager.default.fileExists(atPath: p) { throw GuardError(errorDescription: r.out.isEmpty ? "\(error.localizedDescription)" : r.out) }
            }
            done.append(p)
            logLine("CESTINO \(p)\t\(trashed?.path ?? "")\t\(sizes[p] ?? 0)")
        } catch {
            errors.append("\((p as NSString).lastPathComponent): \(error.localizedDescription)")
            logLine("ERRORE \(p): \(error.localizedDescription)")
        }
    }
    return (done, errors)
}

// MARK: - App installate

struct AppInfo: Identifiable, Hashable {
    var id: String { path }
    let path: String, name: String, bundleId: String, version: String
    var size: Int64 = 0
    var lastUsed: Date? = nil
    var isApple: Bool { bundleId.hasPrefix("com.apple.") }
    /// Protette da SIP, non rimovibili (le altre app Apple come Xcode o iMovie sì)
    var isSystem: Bool { ["com.apple.Safari"].contains(bundleId) }
    var fromAppStore: Bool { FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt") }
}

let APP_DIRS = ["/Applications", "/Applications/Utilities", HOME + "/Applications"]

func listApps() -> [AppInfo] {
    var apps: [AppInfo] = []
    for dir in APP_DIRS {
        for e in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where e.hasSuffix(".app") {
            let path = dir + "/" + e
            let info = Bundle(path: path)?.infoDictionary ?? [:]
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            apps.append(AppInfo(path: path, name: (name?.isEmpty == false ? name! : (e as NSString).deletingPathExtension),
                                bundleId: info["CFBundleIdentifier"] as? String ?? "",
                                version: info["CFBundleShortVersionString"] as? String ?? ""))
        }
    }
    let sizes = parallelSizes(apps.map(\.path))
    for i in apps.indices {
        apps[i].size = sizes[i].1
        if let item = MDItemCreate(nil, apps[i].path as CFString) {
            apps[i].lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
    }
    return apps
}

/// Cartelle di ~/Library dove le app lasciano roba.
let LEFTOVER_DIRS = ["Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
                     "Saved Application State", "Logs", "HTTPStorages", "WebKit", "Application Scripts", "LaunchAgents", "Cookies"]

/// Residui di un'app: match esatto su bundle id (o suoi sotto-id), nome app solo dove le app usano il nome.
/// ponytail: niente match fuzzy, meglio mancare un residuo che cestinare roba di un'altra app
func findLeftovers(bundleId: String, name: String, library: String = HOME + "/Library") -> [String] {
    let bid = bundleId.lowercased(), nm = name.lowercased()
    var out: [String] = []
    for d in LEFTOVER_DIRS {
        let base = library + "/" + d
        for e in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
            let l = e.lowercased()
            let stem = (l as NSString).deletingPathExtension  // .plist, .savedState, .binarycookies
            let byId = !bid.isEmpty && (stem == bid || stem.hasPrefix(bid + ".") || l == bid || l.hasPrefix(bid + ".")
                                        || l.hasSuffix("." + bid) || stem == "group." + bid)
            let byName = !nm.isEmpty && ["Application Support", "Caches", "Logs"].contains(d) && l == nm
            if byId || byName { out.append(base + "/" + e) }
        }
    }
    return out
}

func leftoverStyle(_ path: String) -> (label: String, symbol: String, color: Color) {
    let rel = path.replacingOccurrences(of: HOME + "/Library/", with: "")
    let dir = rel.components(separatedBy: "/").first ?? ""
    switch dir {
    case "Preferences": return ("Preferenze", "gearshape.fill", .gray)
    case "Caches", "HTTPStorages", "WebKit", "Cookies": return ("Cache", "archivebox.fill", .orange)
    case "Application Support": return ("Dati app", "folder.fill", .blue)
    case "Containers", "Group Containers", "Application Scripts": return ("Container", "shippingbox.fill", .purple)
    case "Logs": return ("Log", "doc.text.fill", .gray)
    case "Saved Application State": return ("Stato finestre", "macwindow", .teal)
    case "LaunchAgents": return ("Avvio automatico", "bolt.fill", .yellow)
    default: return (dir, "doc.fill", .gray)
    }
}

func selfTest() {
    for p in ["/", "/System", "/Applications", HOME, HOME + "/", HOME + "/Library", HOME + "/Library/Caches",
              HOME + "/Documents", HOME + "/../x", "relative", "/usr/bin/trash", HOME + "/.Trash", HOME + "/nope-xyz",
              "/Volumes", "/Volumes/Macintosh HD", "/Volumes/Macintosh HD/Users", "/Volumes/Macintosh HD/System"] {
        precondition((try? checkTrashable(p)) == nil, "doveva rifiutare \(p)")
    }
    let dir = HOME + "/.macsweep-selftest-\(getpid())"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let f = dir + "/junk.bin"
    FileManager.default.createFile(atPath: f, contents: Data(count: 100_000))
    precondition(duTree(dir)[dir, default: 0] > 0)
    let r = moveToTrash([f])
    precondition(r.done == [f] && !FileManager.default.fileExists(atPath: f), "trash fallito: \(r.errors)")

    // residui: match esatti sì, omonimi/prefissi parziali no
    let lib = dir + "/Library"
    for f in ["Preferences/com.acme.foo.plist", "Preferences/com.acme.foobar.plist", "Preferences/ByHost/com.acme.foo.ABC-123.plist",
              "Caches/com.acme.foo", "Containers/com.acme.foo", "Group Containers/TEAM123.com.acme.foo",
              "Application Support/Foo", "Application Support/Foobar", "Preferences/Foo",
              "Saved Application State/com.acme.foo.savedState", "Logs/com.acme.food"] {
        try! FileManager.default.createDirectory(atPath: lib + "/" + f, withIntermediateDirectories: true)
    }
    let found = Set(findLeftovers(bundleId: "com.acme.Foo", name: "Foo", library: lib).map { String($0.dropFirst(lib.count + 1)) })
    let expected: Set = ["Preferences/com.acme.foo.plist", "Preferences/ByHost/com.acme.foo.ABC-123.plist", "Caches/com.acme.foo",
                         "Containers/com.acme.foo", "Group Containers/TEAM123.com.acme.foo", "Application Support/Foo",
                         "Saved Application State/com.acme.foo.savedState"]
    precondition(found == expected, "residui sbagliati: \(found.symmetricDifference(expected))")
    featureSelfTest(dir: dir)
    try? FileManager.default.removeItem(atPath: dir)
    print("selftest ok")
}

// MARK: - Store

enum Page: String, CaseIterable, Identifiable {
    case overview = "Panoramica", history = "Andamento", explore = "Esplora", big = "File grandi", downloads = "Download e duplicati",
         volumes = "Dischi esterni",
         dev = "Progetti dev", toolchains = "Versioni strumenti", brew = "Homebrew", git = "Repository Git",
         docker = "Docker", sims = "Simulatori", ai = "Modelli AI", vms = "Macchine virtuali",
         apps = "Disinstalla", browsers = "Browser e privacy", startup = "Avvio automatico", performance = "Prestazioni",
         updates = "Aggiornamenti", battery = "Batteria", maint = "Manutenzione", log = "Registro"
    var id: Self { self }
    static let sections: [(String, [Page])] = [
        ("Spazio", [.overview, .history, .explore, .big, .downloads, .volumes]),
        ("Sviluppo", [.dev, .toolchains, .brew, .git, .docker, .sims, .ai, .vms]),
        ("Sistema", [.apps, .browsers, .startup, .performance, .updates, .battery, .maint, .log]),
    ]
    var icon: String {
        switch self {
        case .overview: "chart.pie.fill"
        case .history: "chart.xyaxis.line"
        case .explore: "folder.fill"
        case .big: "doc.badge.ellipsis"
        case .downloads: "arrow.down.doc.fill"
        case .volumes: "externaldrive.fill"
        case .toolchains: "square.stack.3d.up.fill"
        case .brew: "mug.fill"
        case .git: "arrow.triangle.branch"
        case .browsers: "globe"
        case .performance: "speedometer"
        case .updates: "arrow.down.circle.dotted"
        case .battery: "battery.75percent"
        case .dev: "hammer.fill"
        case .docker: "cube.box.fill"
        case .sims: "iphone.gen3"
        case .ai: "brain.fill"
        case .vms: "pc"
        case .apps: "xmark.bin.fill"
        case .startup: "power"
        case .maint: "wrench.and.screwdriver.fill"
        case .log: "clock.arrow.circlepath"
        }
    }
}

struct TaskResult { let ok: Bool, output: String, freed: Int64 }

struct Celebration: Equatable { let id = UUID(); let bytes: Int64; let title: String }
struct NotchFlash: Equatable { let symbol: String, text: String, color: Color }

@MainActor @Observable final class Store {
    var page: Page? = .overview
    var status = ""

    var total: Int64 = 0
    var free: Int64 = 0
    var needsFDA = false
    var categories = CATEGORIES.filter { FileManager.default.fileExists(atPath: $0.path) }
    var loadingCats = false

    var sizes: [String: Int64] = [:]  // cache du: path -> byte. In RAM, ok fino a qualche milione di cartelle
    var path = HOME
    var items: [Item] = []
    var selection = Set<String>()
    var scanning = false
    var unreadable = false
    var scanCount = 0                    // cartelle analizzate nella scansione in corso
    var refreshing = false               // aggiornamento in background di dati già mostrati
    var scanTimes: [String: Date] = [:]  // quando è stata scansionata ogni radice

    var big: [Item] = []
    var loadingBig = false
    var minMB = 500
    var dev: [Item] = []
    var loadingDev = false
    var devSearched = false
    var running: String? = nil
    var results: [String: TaskResult] = [:]
    var shownTask: String? = nil

    // sezioni aggiunte
    let startup = StartupModel()
    let downloads = DownloadsModel()
    let docker = DockerModel()
    let sims = SimsModel()
    let ai = AIModelsModel()
    let vms = VMModel()
    let browsers = BrowsersModel()
    let perf = PerformanceModel()
    let updates = UpdatesModel()
    let tools = ToolsModel()
    let brew = BrewModel()
    let git = GitModel()
    let volumes = VolumesModel()
    var exploreMap = false
    var history: [Snapshot] = loadHistory()
    var celebration: Celebration? = nil
    var notchFlash: NotchFlash? = nil
    var showQuickClean = false
    var emptyingTrash = false
    private var started = false

    var apps: [AppInfo] = []
    var loadingApps = false
    var selectedApp: String? = nil
    var leftovers: [Item] = []
    var leftoverSel = Set<String>()
    var loadingLeftovers = false

    var cleanable: Int64 { categories.filter(\.cleanable).reduce(0) { $0 + ($1.size ?? 0) } }

    /// Festa a schermo + messaggio nel notch (+ notifica se l'app non è in primo piano).
    func celebrate(_ bytes: Int64, _ title: String) {
        // festa e cifra solo se ne vale la pena: "+193 KB liberi" è rumore
        let worth = bytes >= 50_000_000
        let f = NotchFlash(symbol: "checkmark.circle.fill", text: worth ? "+\(fmt(bytes)) liberi" : title, color: .green)
        notchFlash = f
        if worth {
            let c = Celebration(bytes: bytes, title: title)
            withAnimation(.spring) { celebration = c }
            Task {
                try? await Task.sleep(for: .seconds(3.2))
                if celebration?.id == c.id { withAnimation(.easeOut) { celebration = nil } }
            }
        } else {
            flash(title)
        }
        if !NSApp.isActive { notify("MacSweep", worth ? "\(title): liberati \(fmt(bytes))" : title) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notchFlash == f { notchFlash = nil }
        }
    }

    func emptyTrash() {
        guard !emptyingTrash else { return }  // un doppio clic non deve svuotarlo due volte in parallelo
        emptyingTrash = true
        NSApp.activate()
        let size = categories.first { $0.id == "trash" }?.size ?? 0
        guard confirm("Svuotare il Cestino" + (size > 0 ? " (\(fmt(size)))?" : "?"),
                      "Operazione definitiva: i file nel Cestino (anche quelli dei dischi esterni) non si potranno più recuperare.") else {
            emptyingTrash = false
            return
        }
        notchFlash = NotchFlash(symbol: "trash.fill", text: "Svuoto il Cestino…", color: .red)
        Task {
            let r = await Task.detached { emptyAllTrash() }.value
            refreshDisk()
            loadCategories()
            emptyingTrash = false
            celebrate(r.freed, r.failed == 0 ? "Cestino svuotato" : "Cestino svuotato (\(r.failed) elementi bloccati)")
        }
    }

    /// Porta in primo piano la finestra principale (riaprendola se era chiusa).
    func openMain(quickClean: Bool = false) {
        NSApp.activate()
        if let w = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)  // riapertura: SwiftUI ricrea la finestra
        }
        if quickClean { showQuickClean = true }
    }

    /// Messaggio in basso che sparisce da solo.
    func flash(_ msg: String) {
        status = msg
        Task {
            try? await Task.sleep(for: .seconds(6))
            if status == msg { status = "" }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        refreshDisk()
        // subito i valori dell'ultima volta (fotografia e cache su disco), poi si aggiorna in background
        if let last = history.last {
            for i in categories.indices { categories[i].size = last.cats[categories[i].id] }
            categories.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        }
        if let cache = loadSizeCache() {
            sizes.merge(cache.sizes) { cur, _ in cur }
            scanTimes.merge(cache.times) { cur, _ in cur }
        }
        loadCategories()
        needsFDA = (try? FileManager.default.contentsOfDirectory(atPath: HOME + "/.Trash")) == nil
        applyLaunchArguments()
        Task {  // anche con la sola icona nella barra dei menu: spazio ogni 15 min, fotografia ogni 12 ore
            while true {
                try? await Task.sleep(for: .seconds(900))
                refreshDisk()
                checkLowSpace()
                if let last = history.last?.date, Date().timeIntervalSince(last) > 12 * 3600, !loadingCats { loadCategories() }
            }
        }
    }

    /// Per screenshot e documentazione: `--page apps --select-app /Applications/X.app`, `--explore /percorso --map`.
    private func applyLaunchArguments() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let p = value("--page"), let pg = Page.allCases.first(where: { "\($0)" == p }) { page = pg }
        if let app = value("--select-app") { selectedApp = app }
        if args.contains("--map") { exploreMap = true }
        if let dir = value("--explore") { explore(dir) }
    }

    var lowSpace: Bool {
        UserDefaults.standard.bool(forKey: "alertOn") && free > 0 && free < Int64(UserDefaults.standard.integer(forKey: "alertGB")) * 1_000_000_000
    }

    func checkLowSpace() {
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard lowSpace, UserDefaults.standard.double(forKey: "lastAlert") < today else { return }
        UserDefaults.standard.set(today, forKey: "lastAlert")
        notify("Spazio in esaurimento", "Restano \(fmt(free)) liberi. Apri MacSweep per vedere cosa è cresciuto.")
        let f = NotchFlash(symbol: "exclamationmark.triangle.fill", text: "Solo \(fmt(free)) liberi", color: .orange)
        notchFlash = f
        Task { try? await Task.sleep(for: .seconds(4)); if notchFlash == f { notchFlash = nil } }
    }

    /// Fotografia del disco per l'Andamento: una al giorno (quella di oggi si aggiorna).
    func recordSnapshot() {
        guard categories.allSatisfy({ $0.size != nil }) else { return }
        let depthLimit = HOME.split(separator: "/").count + 3
        let dirs = sizes.filter { $0.key.hasPrefix(HOME + "/") && $0.key.split(separator: "/").count <= depthLimit && $0.value >= 200_000_000 }
        var snap = Snapshot(date: Date(), free: free, total: total,
                            cats: Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.size!) }), dirs: dirs)
        if let last = history.last, Calendar.current.isDateInToday(last.date) {
            if snap.dirs.isEmpty { snap.dirs = last.dirs }
            history[history.count - 1] = snap
        } else {
            history.append(snap)
        }
        history = Array(history.suffix(730))
        saveHistory(history)
        checkLowSpace()
    }

    func refreshDisk() {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        total = Int64(v?.volumeTotalCapacity ?? 0)
        free = v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func loadCategories() {
        loadingCats = true
        let paths = categories.map(\.path)
        Task {
            let res = await Task.detached { parallelSizes(paths) }.value
            for (i, r) in res.enumerated() { categories[i].size = r.1 }
            categories.sort { ($0.size ?? 0) > ($1.size ?? 0) }
            loadingCats = false
            recordSnapshot()
        }
    }

    func explore(_ p: String, rescan: Bool = false) {
        page = .explore
        path = p; selection = []; unreadable = false; items = []
        if !rescan, sizes[p] != nil {
            // già nota (anche dalla cache su disco): elenco subito, e se è vecchia si aggiorna dietro
            showListing(p)
            if let t = scanTimes[p], Date().timeIntervalSince(t) > 3600, !refreshing { scan(p, background: true) }
            return
        }
        scan(p, background: false)
    }

    private func showListing(_ p: String) {
        let snapshot = sizes
        Task {
            let list = await Task.detached { listDir(p, sizes: snapshot) }.value
            guard path == p else { return }
            items = list ?? []
            unreadable = list == nil
            scanning = false
        }
    }

    private func scan(_ p: String, background: Bool) {
        if background { refreshing = true } else { scanning = true }
        scanCount = 0
        let scanner = FastScanner()
        let poll = Task {
            while !Task.isCancelled {
                scanCount = scanner.scanned
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        Task {
            let tree = await Task.detached { scanner.scan(p) }.value
            poll.cancel()
            let prefix = p == "/" ? "/" : p + "/"
            sizes = sizes.filter { !$0.key.hasPrefix(prefix) }.merging(tree) { $1 }
            scanTimes[p] = Date()
            if background { refreshing = false }
            if path == p { showListing(p) }
            if p == HOME { recordSnapshot() }
            saveScanCache()
        }
    }

    func saveScanCache() {
        let (sz, times) = (sizes, scanTimes)
        Task.detached { saveSizeCache(sz, times) }
    }

    func loadBig() {
        loadingBig = true
        let mb = minMB
        Task {
            big = await Task.detached { bigFiles(minMB: mb) }.value
            loadingBig = false
        }
    }

    func loadDev() {
        loadingDev = true
        Task {
            dev = await Task.detached { devJunk() }.value
            loadingDev = false; devSearched = true
        }
    }

    func runTask(_ t: MaintTask) {
        if t.id == "emptytrash" { emptyTrash(); return }
        running = t.id; shownTask = t.id; results[t.id] = nil
        let before = free
        Task {
            // shell di login interattiva: le app GUI non hanno il PATH utente (brew, nvm, pnpm)
            let r = await Task.detached { run(["/bin/zsh", "-lic", t.cmd], mergeErr: true) }.value
            let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            refreshDisk()
            let gained = free - before
            results[t.id] = TaskResult(ok: r.code == 0, output: out.isEmpty ? "(nessun output)" : out,
                                       freed: gained > 10_000_000 ? gained : 0)
            flash(r.code == 0 ? "\(t.label): fatto" + (gained > 10_000_000 ? ", liberati \(fmt(gained))" : "")
                              : "\(t.label): terminato con errori")
            running = nil
        }
    }

    func sizeOf(_ p: String) -> Int64 {
        sizes[p] ?? (items + big + dev + leftovers).first { $0.path == p }?.size ?? apps.first { $0.path == p }?.size ?? 0
    }

    /// Conferma + Cestino. `known` = dimensioni già note (dalle sezioni che non usano la cache du).
    func trash(_ paths: [String], known: [String: Int64] = [:], then: (([String]) -> Void)? = nil) {
        guard !paths.isEmpty else { return }
        for (p, sz) in known where sizes[p] == nil { sizes[p] = sz }
        let tot = paths.reduce(0) { $0 + sizeOf($1) }
        let what = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) elementi"
        guard confirm("Spostare nel Cestino \(what) (\(fmt(tot)))?", "Recuperabile dal Cestino finché non lo svuoti.") else { return }
        Task {
            let done = await performTrash(paths)
            then?(done)
        }
    }

    /// Sposta nel Cestino senza chiedere (in background: il Finder può chiedere la password). Ritorna i path spostati.
    @discardableResult
    func performTrash(_ paths: [String], known: [String: Int64] = [:]) async -> [String] {
        for (p, sz) in known where sizes[p] == nil { sizes[p] = sz }
        let freedBy = Dictionary(paths.map { ($0, sizeOf($0)) }, uniquingKeysWith: { a, _ in a })
        let r = await Task.detached { moveToTrash(paths, sizes: freedBy) }.value
        for p in r.done {  // aggiorna cache e antenati senza riscansionare
            sizes = sizes.filter { $0.key != p && !$0.key.hasPrefix(p + "/") }
            var a = (p as NSString).deletingLastPathComponent
            while let s = sizes[a] {
                sizes[a] = max(0, s - freedBy[p, default: 0])
                if a == "/" { break }
                a = (a as NSString).deletingLastPathComponent
            }
        }
        let gone = Set(r.done)
        items.removeAll { gone.contains($0.path) }
        big.removeAll { gone.contains($0.path) }
        dev.removeAll { gone.contains($0.path) }
        apps.removeAll { gone.contains($0.path) }
        leftovers.removeAll { gone.contains($0.path) }
        selection.subtract(gone)
        flash("Spostati nel Cestino: \(fmt(r.done.reduce(0) { $0 + freedBy[$1, default: 0] }))"
            + (r.errors.isEmpty ? "" : " — \(r.errors.count) saltati (\(r.errors.first!))"))
        refreshDisk()
        saveScanCache()
        return r.done
    }

    // MARK: Disinstalla

    func loadApps() {
        loadingApps = true
        Task {
            apps = await Task.detached { listApps() }.value
            loadingApps = false
            loadLeftovers()
        }
    }

    func loadLeftovers() {
        leftovers = []; leftoverSel = []
        guard let app = apps.first(where: { $0.path == selectedApp }) else { return }
        loadingLeftovers = true
        Task {
            let found = await Task.detached { () -> [Item] in
                parallelSizes(findLeftovers(bundleId: app.bundleId, name: app.name))
                    .map { Item(path: $0.0, isDir: true, size: $0.1) }
                    .sorted { $0.size > $1.size }
            }.value
            guard selectedApp == app.path else { return }
            leftovers = found
            leftoverSel = Set(found.map(\.path))
            loadingLeftovers = false
        }
    }

    func uninstall(_ app: AppInfo) {
        let extra = leftovers.filter { leftoverSel.contains($0.path) }.map(\.path)
        let tot = app.size + extra.reduce(0) { $0 + sizeOf($1) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId)
        var msg = "L'app e \(extra.count) file residui vanno nel Cestino (\(fmt(tot))). Recuperabili finché non lo svuoti."
        if !running.isEmpty { msg += "\n\n\(app.name) è aperta: verrà chiusa." }
        logLine("DISINSTALLA \(app.name) [\(app.bundleId)] richiesta: app + \(extra.count) residui, aperta=\(!running.isEmpty)")
        guard confirm("Disinstallare \(app.name)?", msg) else { logLine("DISINSTALLA \(app.name) annullata"); return }
        Task {
            if !running.isEmpty {
                running.forEach { $0.terminate() }
                var waited = 0
                while running.contains(where: { !$0.isTerminated }) && waited < 50 {
                    try? await Task.sleep(for: .milliseconds(100)); waited += 1
                }
                if running.contains(where: { !$0.isTerminated }) {
                    flash("Errore: \(app.name) non si chiude, chiudila a mano e riprova"); return
                }
            }
            let done = await performTrash([app.path] + extra)
            logLine("DISINSTALLA \(app.name) fine: \(done.count)/\(extra.count + 1) spostati")
            if done.contains(app.path) {
                selectedApp = nil
                flash("\(app.name) disinstallata: liberati \(fmt(tot))")
            }
        }
    }

    func clean(_ c: Category) {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: c.path)) ?? []
        let paths = children.map { (c.path as NSString).appendingPathComponent($0) }
        status = "Misuro \(c.label)…"
        Task {
            // sizeOf su figli non scansionati darebbe 0: misura prima
            let measured = await Task.detached { parallelSizes(paths) }.value
            for (p, s) in measured { sizes[p] = s }
            status = ""
            let tot = measured.reduce(0) { $0 + $1.1 }
            guard confirm("Pulire \(c.label) (\(fmt(tot)))?", "Il contenuto va nel Cestino, recuperabile finché non lo svuoti.") else { return }
            await performTrash(paths)
            loadCategories()
        }
    }
}

@MainActor func confirm(_ title: String, _ text: String) -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.addButton(withTitle: "Conferma")
    a.addButton(withTitle: "Annulla")
    return a.runModal() == .alertFirstButtonReturn
}
