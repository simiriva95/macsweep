import AppKit
import Darwin
import Foundation
import Observation
import SwiftUI

// MARK: - Browser e privacy

struct BrowserPart: Identifiable {
    let id: String, label: String, symbol: String, paths: [String], defaultOn: Bool, warning: String
    var sizes: [String: Int64] = [:]
    var size: Int64 { sizes.values.reduce(0, +) }
}

struct BrowserInfo: Identifiable {
    var id: String { bundleId }
    let name: String, bundleId: String, appPath: String
    var parts: [BrowserPart]
    var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
}

let LIB = HOME + "/Library"

func existing(_ paths: [String]) -> [String] { paths.filter { FileManager.default.fileExists(atPath: $0) } }

func chromium(_ name: String, _ bundleId: String, _ app: String, support: String, caches: String) -> BrowserInfo? {
    let sup = LIB + "/Application Support/" + support
    guard FileManager.default.fileExists(atPath: sup) else { return nil }
    let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: sup)) ?? []).filter { $0 == "Default" || $0.hasPrefix("Profile ") }
    var cache = [LIB + "/Caches/" + caches] + ["GrShaderCache", "ShaderCache", "GraphiteDawnCache"].map { sup + "/" + $0 }
    var history: [String] = [], cookies: [String] = []
    for p in profiles {
        let d = sup + "/" + p
        cache += ["Code Cache", "GPUCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache"].map { d + "/" + $0 }
        history += ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"].map { d + "/" + $0 }
        cookies += ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"].map { d + "/" + $0 }
    }
    return BrowserInfo(name: name, bundleId: bundleId, appPath: "/Applications/\(app).app", parts: [
        BrowserPart(id: "cache", label: "Cache", symbol: "archivebox.fill", paths: existing(cache), defaultOn: true, warning: ""),
        BrowserPart(id: "history", label: "Cronologia", symbol: "clock.fill", paths: existing(history), defaultOn: false,
                    warning: "Spariscono i siti visitati e i suggerimenti della barra indirizzi."),
        BrowserPart(id: "cookies", label: "Cookie", symbol: "key.fill", paths: existing(cookies), defaultOn: false,
                    warning: "Verrai disconnesso da tutti i siti."),
    ])
}

func loadBrowsers() -> [BrowserInfo] {
    var list: [BrowserInfo] = []
    if let b = chromium("Google Chrome", "com.google.Chrome", "Google Chrome", support: "Google/Chrome", caches: "Google/Chrome") { list.append(b) }
    if let b = chromium("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge", support: "Microsoft Edge", caches: "Microsoft Edge") { list.append(b) }
    if let b = chromium("Brave", "com.brave.Browser", "Brave Browser", support: "BraveSoftware/Brave-Browser", caches: "BraveSoftware/Brave-Browser") { list.append(b) }
    if let b = chromium("Arc", "company.thebrowser.Browser", "Arc", support: "Arc/User Data", caches: "Arc") { list.append(b) }
    if FileManager.default.fileExists(atPath: LIB + "/Safari") {
        let c = LIB + "/Containers/com.apple.Safari/Data/Library"
        list.append(BrowserInfo(name: "Safari", bundleId: "com.apple.Safari", appPath: "/Applications/Safari.app", parts: [
            BrowserPart(id: "cache", label: "Cache", symbol: "archivebox.fill",
                        paths: existing([LIB + "/Caches/com.apple.Safari", c + "/Caches"]), defaultOn: true, warning: ""),
            BrowserPart(id: "history", label: "Cronologia", symbol: "clock.fill",
                        paths: existing(["History.db", "History.db-shm", "History.db-wal", "History.db-lock"].map { LIB + "/Safari/" + $0 }),
                        defaultOn: false, warning: "Sparisce la cronologia (anche sugli altri dispositivi con iCloud)."),
            BrowserPart(id: "cookies", label: "Cookie", symbol: "key.fill",
                        paths: existing([c + "/Cookies/Cookies.binarycookies", LIB + "/Cookies/Cookies.binarycookies"]),
                        defaultOn: false, warning: "Verrai disconnesso da tutti i siti."),
        ]))
    }
    let ff = LIB + "/Application Support/Firefox/Profiles"
    if let profiles = try? FileManager.default.contentsOfDirectory(atPath: ff), !profiles.isEmpty {
        // ponytail: niente cronologia di Firefox, sta in places.sqlite insieme ai segnalibri
        list.append(BrowserInfo(name: "Firefox", bundleId: "org.mozilla.firefox", appPath: "/Applications/Firefox.app", parts: [
            BrowserPart(id: "cache", label: "Cache", symbol: "archivebox.fill",
                        paths: existing(profiles.map { LIB + "/Caches/Firefox/Profiles/\($0)/cache2" }), defaultOn: true, warning: ""),
            BrowserPart(id: "cookies", label: "Cookie", symbol: "key.fill",
                        paths: existing(profiles.flatMap { prof in ["cookies.sqlite", "cookies.sqlite-wal"].map { "\(ff)/\(prof)/\($0)" } }),
                        defaultOn: false, warning: "Verrai disconnesso da tutti i siti."),
        ]))
    }
    // dimensioni
    let all = list.flatMap { $0.parts.flatMap(\.paths) }
    let sizes = Dictionary(parallelSizes(all), uniquingKeysWith: { a, _ in a })
    for i in list.indices {
        for j in list[i].parts.indices { list[i].parts[j].sizes = Dictionary(uniqueKeysWithValues: list[i].parts[j].paths.map { ($0, sizes[$0] ?? 0) }) }
    }
    // cartelle rimaste di browser disinstallati e vuote: non servono
    return list.filter { FileManager.default.fileExists(atPath: $0.appPath) || $0.parts.contains { $0.size > 0 } }
}

@MainActor @Observable final class BrowsersModel {
    var browsers: [BrowserInfo] = []
    var selected = Set<String>()  // "bundleId/part"
    var loading = false
    var loaded = false

    func load() {
        loading = true
        Task {
            browsers = await Task.detached { loadBrowsers() }.value
            if !loaded { selected = Set(browsers.flatMap { b in b.parts.filter(\.defaultOn).map { "\(b.bundleId)/\($0.id)" } }) }
            loading = false; loaded = true
        }
    }

    func clean(_ b: BrowserInfo, store: Store) {
        let parts = b.parts.filter { selected.contains("\(b.bundleId)/\($0.id)") && !$0.paths.isEmpty }
        guard !parts.isEmpty else { return }
        let total = parts.reduce(0) { $0 + $1.size }
        var msg = parts.map { "• \($0.label) (\(fmt($0.size)))" + ($0.warning.isEmpty ? "" : " — \($0.warning)") }.joined(separator: "\n")
        msg += "\n\nTutto va nel Cestino."
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: b.bundleId)
        if !running.isEmpty { msg += "\n\(b.name) è aperto: verrà chiuso." }
        guard confirm("Pulire \(b.name) (\(fmt(total)))?", msg) else { return }
        Task {
            if !running.isEmpty {
                running.forEach { $0.terminate() }
                var waited = 0
                while running.contains(where: { !$0.isTerminated }) && waited < 50 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
                if running.contains(where: { !$0.isTerminated }) { store.flash("Errore: \(b.name) non si chiude, chiudilo e riprova"); return }
            }
            await store.performTrash(parts.flatMap(\.paths), known: parts.reduce(into: [:]) { $0.merge($1.sizes) { a, _ in a } })
            load()
        }
    }
}

// MARK: - Prestazioni

struct ProcGroup: Identifiable {
    var id: String { key }
    let key: String, name: String, appPath: String?
    var pids: [Int32]
    var cpu: Double
    var mem: Int64
}

struct MemStats {
    var total: Int64 = 0, app: Int64 = 0, wired: Int64 = 0, compressed: Int64 = 0, cached: Int64 = 0, swap: Int64 = 0
    var pressure = 1  // 1 normale, 2 attenzione, 4 critica
    var used: Int64 { app + wired + compressed }
}

func sysctlInt(_ name: String) -> Int {
    var v: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname(name, &v, &size, nil, 0)
    return Int(v)
}

func memStats() -> MemStats {
    var s = MemStats()
    s.total = Int64(ProcessInfo.processInfo.physicalMemory)
    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    if r == KERN_SUCCESS {
        let page = Int64(vm_kernel_page_size)
        s.app = (Int64(vm.internal_page_count) - Int64(vm.purgeable_count)) * page
        s.wired = Int64(vm.wire_count) * page
        s.compressed = Int64(vm.compressor_page_count) * page
        s.cached = (Int64(vm.external_page_count) + Int64(vm.purgeable_count)) * page
    }
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { s.swap = Int64(swap.xsu_used) }
    s.pressure = sysctlInt("kern.memorystatus_vm_pressure_level")
    return s
}

/// Tick CPU cumulativi (user+system, totale): la percentuale viene dalla differenza tra due letture.
func cpuTicks() -> (busy: Double, total: Double) {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
    }
    guard r == KERN_SUCCESS else { return (0, 0) }
    let t = info.cpu_ticks
    let user = Double(t.0), sys = Double(t.1), idle = Double(t.2), nice = Double(t.3)
    return (user + sys + nice, user + sys + idle + nice)
}

/// Processi dell'utente raggruppati per app (Chrome + i suoi helper = una riga).
func loadProcesses() -> [ProcGroup] {
    let out = run(["/bin/ps", "-U", String(getuid()), "-o", "pid=,pcpu=,rss=,comm="]).out
    var groups: [String: ProcGroup] = [:]
    for line in out.split(separator: "\n") {
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard f.count == 4, let pid = Int32(f[0]), let cpu = Double(f[1].replacingOccurrences(of: ",", with: ".")), let rss = Int64(f[2]) else { continue }
        let comm = String(f[3])
        let app = comm.range(of: ".app/").map { String(comm[..<$0.upperBound].dropLast()) }
        let key = app ?? comm
        let name = app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? (comm as NSString).lastPathComponent
        if groups[key] == nil { groups[key] = ProcGroup(key: key, name: name, appPath: app, pids: [], cpu: 0, mem: 0) }
        groups[key]!.pids.append(pid)
        groups[key]!.cpu += cpu
        groups[key]!.mem += rss * 1024
    }
    return Array(groups.values)
}

@MainActor @Observable final class PerformanceModel {
    var mem = MemStats()
    var cpu: Double = 0
    var procs: [ProcGroup] = []
    private var lastTicks: (busy: Double, total: Double)? = nil

    func refresh() {
        Task {
            let (m, p, t) = await Task.detached { (memStats(), loadProcesses(), cpuTicks()) }.value
            mem = m; procs = p
            if let l = lastTicks, t.total > l.total { cpu = (t.busy - l.busy) / (t.total - l.total) }
            lastTicks = t
        }
    }

    func quit(_ g: ProcGroup, store: Store) {
        guard g.pids.allSatisfy({ $0 != getpid() }) else { store.flash("Errore: non posso chiudere MacSweep da qui"); return }
        guard confirm("Chiudere \(g.name)?", "Usa \(fmtMem(g.mem)) di memoria e \(Int(g.cpu))% di CPU. Le modifiche non salvate potrebbero andare perse.") else { return }
        if let app = g.appPath, let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(path: app)?.bundleIdentifier ?? "").first {
            running.terminate()
        } else {
            g.pids.forEach { kill($0, SIGTERM) }
        }
        logLine("PRESTAZIONI chiuso \(g.name)")
        Task { try? await Task.sleep(for: .seconds(1)); refresh() }
    }
}

// MARK: - Aggiornamenti

struct UpdateItem: Identifiable {
    enum Kind: String { case formula = "Homebrew", cask = "App Homebrew", appStore = "App Store", macOS = "macOS", dev = "Sviluppo" }
    var id: String { kind.rawValue + key }
    let kind: Kind, key: String, name: String, from: String, to: String
    var cmd = ""
}

func loadBrewOutdated() -> [UpdateItem] {
    guard let d = try? JSONSerialization.jsonObject(with: Data(run(["/opt/homebrew/bin/brew", "outdated", "--json=v2"]).out.utf8)) as? [String: Any] else { return [] }
    var items: [UpdateItem] = []
    for f in d["formulae"] as? [[String: Any]] ?? [] {
        items.append(UpdateItem(kind: .formula, key: f["name"] as? String ?? "", name: f["name"] as? String ?? "",
                                from: (f["installed_versions"] as? [String])?.last ?? "", to: f["current_version"] as? String ?? ""))
    }
    for c in d["casks"] as? [[String: Any]] ?? [] {
        let inst = (c["installed_versions"] as? [String])?.last ?? c["installed_versions"] as? String ?? ""
        items.append(UpdateItem(kind: .cask, key: c["name"] as? String ?? "", name: c["name"] as? String ?? "", from: inst, to: c["current_version"] as? String ?? ""))
    }
    return items
}

func loadMasOutdated() -> [UpdateItem]? {
    guard sh("command -v mas").code == 0 else { return nil }
    // "497799835 Xcode (15.0 -> 15.1)"
    return sh("mas outdated").out.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let open = parts[1].lastIndex(of: "(") else { return nil }
        let name = parts[1][..<open].trimmingCharacters(in: .whitespaces)
        let vers = parts[1][parts[1].index(after: open)...].dropLast().components(separatedBy: " -> ")
        return UpdateItem(kind: .appStore, key: String(parts[0]), name: name, from: vers.first ?? "", to: vers.count > 1 ? vers[1] : "")
    }
}

func loadMacOSUpdates() -> [UpdateItem] {
    // "* Label: macOS Tahoe 26.7-25G…" + "\tTitle: macOS Tahoe 26.7, Version: 26.7, Size: …"
    run(["/usr/sbin/softwareupdate", "-l"], mergeErr: true).out.split(separator: "\n").compactMap { line in
        guard line.contains("Title:") else { return nil }
        let fields = Dictionary(line.split(separator: ",").compactMap { kv -> (String, String)? in
            let p = kv.split(separator: ":", maxSplits: 1)
            return p.count == 2 ? (p[0].trimmingCharacters(in: .whitespaces), p[1].trimmingCharacters(in: .whitespaces)) : nil
        }, uniquingKeysWith: { a, _ in a })
        return UpdateItem(kind: .macOS, key: fields["Title"] ?? "", name: fields["Title"] ?? "", from: ProcessInfo.processInfo.operatingSystemVersionString, to: fields["Version"] ?? "")
    }
}

@MainActor @Observable final class UpdatesModel {
    var brew: [UpdateItem] = []
    var mas: [UpdateItem]? = nil
    var macos: [UpdateItem] = []
    var dev: [UpdateItem] = []
    var loadingDev = false
    var loading = false
    var loadingMacOS = false
    var loaded = false
    var busy: String? = nil
    var output = ""

    func load(refreshIndex: Bool = false) {
        loading = true
        Task {
            let (b, m) = await Task.detached { () -> ([UpdateItem], [UpdateItem]?) in
                if refreshIndex { run(["/opt/homebrew/bin/brew", "update"], mergeErr: true) }
                return (loadBrewOutdated(), loadMasOutdated())
            }.value
            brew = b; mas = m
            loading = false; loaded = true
        }
        loadingMacOS = true
        Task {
            macos = await Task.detached { loadMacOSUpdates() }.value
            loadingMacOS = false
        }
        loadingDev = true
        Task {
            dev = await Task.detached { loadDevUpdates() }.value
            loadingDev = false
        }
    }

    func upgrade(_ items: [UpdateItem], store: Store) {
        guard !items.isEmpty else { return }
        let cmds: [String] = items.map {
            switch $0.kind {
            case .formula: "brew upgrade \(shq($0.key))"
            case .cask: "brew upgrade --cask \(shq($0.key))"
            case .appStore: "mas upgrade \(shq($0.key))"
            case .dev: $0.cmd
            case .macOS: ""
            }
        }.filter { !$0.isEmpty }
        busy = items.count == 1 ? items[0].name : "\(items.count) aggiornamenti"
        output = ""
        Task {
            var ok = true
            for c in cmds {
                let r = await Task.detached { shi(c) }.value  // shell interattiva: nvm, npm, bun, rustup
                output += "$ \(c)\n\(r.out)\n"
                ok = ok && r.code == 0
                logLine("AGGIORNAMENTO \(c) -> \(r.code)")
            }
            store.flash(ok ? "Aggiornato: \(busy ?? "")" : "Errore: aggiornamento non riuscito, vedi output")
            busy = nil
            load()
        }
    }

    func installMas(store: Store) {
        busy = "mas"
        Task {
            let r = await Task.detached { sh("brew install mas") }.value
            output = r.out
            store.flash(r.code == 0 ? "mas installato" : "Errore: installazione di mas non riuscita")
            busy = nil
            load()
        }
    }
}

// MARK: - Versioni degli strumenti

struct ToolVersion: Identifiable {
    var id: String { path }
    let tool: String, version: String, path: String, symbol: String, color: Color
    var size: Int64 = 0
    var inUse = false
    var editable: Bool { path.hasPrefix(HOME + "/") }
}

func subdirs(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

func firstLine(_ path: String) -> String {
    ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
}

func compareVersions(_ a: String, _ b: String) -> Bool {
    a.trimmingCharacters(in: CharacterSet(charactersIn: "v")).compare(b.trimmingCharacters(in: CharacterSet(charactersIn: "v")), options: .numeric) == .orderedAscending
}

func loadToolVersions() -> [ToolVersion] {
    var out: [ToolVersion] = []
    // Node (nvm): in uso = alias default (o la più recente se "node"/"stable") + quella attiva nella shell
    let nvm = HOME + "/.nvm/versions/node"
    let nodes = subdirs(nvm)
    if !nodes.isEmpty {
        let alias = firstLine(HOME + "/.nvm/alias/default")
        let latest = nodes.max(by: compareVersions) ?? ""
        let active = sh("node -v 2>/dev/null").out.trimmingCharacters(in: .whitespacesAndNewlines)
        for v in nodes {
            let isDefault = ["node", "stable", ""].contains(alias) ? v == latest : v == alias || v.hasPrefix("v" + alias.trimmingCharacters(in: CharacterSet(charactersIn: "v")))
            out.append(ToolVersion(tool: "Node.js (nvm)", version: v, path: nvm + "/" + v, symbol: "hexagon.fill", color: .green,
                                   inUse: isDefault || v == active))
        }
    }
    let pyGlobal = firstLine(HOME + "/.pyenv/version")
    for v in subdirs(HOME + "/.pyenv/versions") {
        out.append(ToolVersion(tool: "Python (pyenv)", version: v, path: HOME + "/.pyenv/versions/" + v, symbol: "terminal.fill", color: .yellow, inUse: v == pyGlobal))
    }
    let rbGlobal = firstLine(HOME + "/.rbenv/version")
    for v in subdirs(HOME + "/.rbenv/versions") {
        out.append(ToolVersion(tool: "Ruby (rbenv)", version: v, path: HOME + "/.rbenv/versions/" + v, symbol: "diamond.fill", color: .red, inUse: v == rbGlobal))
    }
    let rustDefault = ((try? String(contentsOfFile: HOME + "/.rustup/settings.toml", encoding: .utf8)) ?? "")
        .split(separator: "\n").first { $0.hasPrefix("default_toolchain") }?.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
    for v in subdirs(HOME + "/.rustup/toolchains") {
        out.append(ToolVersion(tool: "Rust (rustup)", version: v, path: HOME + "/.rustup/toolchains/" + v, symbol: "gearshape.2.fill", color: .orange,
                               inUse: !rustDefault.isEmpty && v.hasPrefix(rustDefault)))
    }
    for base in [HOME + "/Library/Java/JavaVirtualMachines", "/Library/Java/JavaVirtualMachines"] {
        for v in subdirs(base) { out.append(ToolVersion(tool: "Java", version: v, path: base + "/" + v, symbol: "cup.and.saucer.fill", color: .brown)) }
    }
    for v in subdirs(HOME + "/sdk") where v.hasPrefix("go") {
        out.append(ToolVersion(tool: "Go", version: v, path: HOME + "/sdk/" + v, symbol: "hare.fill", color: .cyan))
    }
    for v in subdirs(HOME + "/.gradle/wrapper/dists") {
        out.append(ToolVersion(tool: "Gradle wrapper", version: v, path: HOME + "/.gradle/wrapper/dists/" + v, symbol: "leaf.fill", color: .mint))
    }
    let android = HOME + "/Library/Android/sdk"
    for api in subdirs(android + "/system-images") {
        for tag in subdirs(android + "/system-images/" + api) {
            for abi in subdirs(android + "/system-images/\(api)/\(tag)") {
                out.append(ToolVersion(tool: "Android system image", version: "\(api) · \(tag) · \(abi)", path: android + "/system-images/\(api)/\(tag)/\(abi)",
                                       symbol: "candybarphone", color: .green))
            }
        }
    }
    for kind in ["platforms", "build-tools", "ndk"] {
        for v in subdirs(android + "/" + kind) {
            out.append(ToolVersion(tool: "Android \(kind)", version: v, path: android + "/\(kind)/\(v)", symbol: "candybarphone", color: .green))
        }
    }
    let sizes = parallelSizes(out.map(\.path))
    for i in out.indices { out[i].size = sizes[i].1 }
    return out
}

@MainActor @Observable final class ToolsModel {
    var tools: [ToolVersion] = []
    var loading = false
    var loaded = false

    func load() {
        loading = true
        Task {
            tools = await Task.detached { loadToolVersions() }.value
            loading = false; loaded = true
        }
    }
}

// MARK: - Pacchetti Homebrew

struct BrewPackage: Identifiable {
    var id: String { (isCask ? "cask:" : "") + name }
    let name: String, desc: String, version: String, isCask: Bool, onRequest: Bool, paths: [String]
    var size: Int64 = 0
    var usedBy: [String] = []
    var orphan = false
}

func loadBrewPackages() -> [BrewPackage] {
    let brew = "/opt/homebrew/bin/brew"
    guard let d = try? JSONSerialization.jsonObject(with: Data(run([brew, "info", "--json=v2", "--installed"]).out.utf8)) as? [String: Any] else { return [] }
    let prefix = run([brew, "--prefix"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    var pkgs: [BrewPackage] = []
    var deps: [String: [String]] = [:]
    for f in d["formulae"] as? [[String: Any]] ?? [] {
        let name = f["name"] as? String ?? ""
        let inst = (f["installed"] as? [[String: Any]])?.last ?? [:]
        deps[name] = f["dependencies"] as? [String] ?? []
        pkgs.append(BrewPackage(name: name, desc: f["desc"] as? String ?? "", version: inst["version"] as? String ?? "", isCask: false,
                                onRequest: inst["installed_on_request"] as? Bool ?? false, paths: ["\(prefix)/Cellar/\(name)"]))
    }
    for c in d["casks"] as? [[String: Any]] ?? [] {
        let token = c["token"] as? String ?? ""
        let apps = (c["artifacts"] as? [[String: Any]] ?? []).compactMap { ($0["app"] as? [Any])?.first as? String }.map { "/Applications/" + $0 }
        pkgs.append(BrewPackage(name: token, desc: c["desc"] as? String ?? (c["name"] as? [String])?.first ?? "", version: c["installed"] as? String ?? "",
                                isCask: true, onRequest: true, paths: ["\(prefix)/Caskroom/\(token)"] + existing(apps)))
    }
    // chi usa chi
    for (user, ds) in deps { for dep in ds { if let i = pkgs.firstIndex(where: { !$0.isCask && $0.name == dep }) { pkgs[i].usedBy.append(user) } } }
    // orfani secondo brew stesso
    let auto = run([brew, "autoremove", "--dry-run"], mergeErr: true).out
    let orphans = Set(auto.split(separator: "\n").filter { !$0.hasPrefix("==>") }.map { $0.trimmingCharacters(in: .whitespaces) })
    let sizes = Dictionary(parallelSizes(pkgs.flatMap(\.paths)), uniquingKeysWith: { a, _ in a })
    for i in pkgs.indices {
        pkgs[i].size = pkgs[i].paths.reduce(0) { $0 + (sizes[$1] ?? 0) }
        pkgs[i].orphan = orphans.contains(pkgs[i].name)
    }
    return pkgs.sorted { $0.size > $1.size }
}

@MainActor @Observable final class BrewModel {
    var pkgs: [BrewPackage] = []
    var loading = false
    var loaded = false
    var busy = false

    func load() {
        loading = true
        Task {
            pkgs = await Task.detached { loadBrewPackages() }.value
            loading = false; loaded = true
        }
    }

    func uninstall(_ p: BrewPackage, store: Store) {
        var msg = "Homebrew lo rimuove in modo DEFINITIVO (\(fmt(p.size)))."
        if p.isCask { msg += "\nÈ un'app: sparisce anche da Applicazioni." }
        if !p.usedBy.isEmpty { msg += "\nAttenzione: lo usano \(p.usedBy.joined(separator: ", "))." }
        guard confirm("Disinstallare \(p.name)?", msg) else { return }
        exec("brew uninstall \(p.isCask ? "--cask " : "")\(shq(p.name))", label: p.name, store: store)
    }

    func autoremove(store: Store) {
        let o = pkgs.filter(\.orphan)
        guard confirm("Rimuovere \(o.count) dipendenze orfane?", o.map(\.name).joined(separator: ", ") + "\n\nNessun pacchetto installato le usa più.") else { return }
        exec("brew autoremove", label: "Orfani", store: store)
    }

    private func exec(_ cmd: String, label: String, store: Store) {
        busy = true
        Task {
            let r = await Task.detached { sh(cmd) }.value
            logLine("HOMEBREW \(cmd) -> \(r.code)")
            store.flash(r.code == 0 ? "\(label): rimosso" : "Errore: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(160))")
            busy = false
            store.refreshDisk()
            load()
        }
    }
}

// MARK: - Repository Git

struct GitRepo: Identifiable {
    var id: String { path }
    let path: String
    var gitSize: Int64 = 0
    var loose: Int64 = 0
    var looseCount = 0
    var branch = ""
    var merged: [String] = []
    var lastCommit: Date? = nil
    var name: String { (path as NSString).lastPathComponent }
    var needsGC: Bool { loose >= 20_000_000 || looseCount >= 2000 }
}

let PROTECTED_BRANCHES: Set = ["main", "master", "develop", "dev", "staging", "production", "release"]

func scanRepo(_ path: String) -> GitRepo {
    var r = GitRepo(path: path)
    r.gitSize = duTotal(path + "/.git")
    let git = ["/usr/bin/git", "-C", path]
    for line in run(git + ["count-objects", "-v"]).out.split(separator: "\n") {
        let kv = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        if kv.count == 2 {
            if kv[0] == "count" { r.looseCount = Int(kv[1]) ?? 0 }
            if kv[0] == "size" { r.loose = (Int64(kv[1]) ?? 0) * 1024 }
        }
    }
    r.branch = run(git + ["branch", "--show-current"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    r.merged = run(git + ["branch", "--merged"]).out.split(separator: "\n")
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*+ ")) }
        .filter { !$0.isEmpty && $0 != r.branch && !PROTECTED_BRANCHES.contains($0) && !$0.hasPrefix("(") }
    if let t = Double(run(git + ["log", "-1", "--format=%ct"]).out.trimmingCharacters(in: .whitespacesAndNewlines)) {
        r.lastCommit = Date(timeIntervalSince1970: t)
    }
    return r
}

func findRepos() -> [GitRepo] {
    let args = ["/usr/bin/find", HOME, "-xdev",
                "(", "-path", "\(HOME)/.*", "-o", "-path", "\(HOME)/Library", "-o", "-name", "node_modules", ")", "-prune", "-o",
                "-type", "d", "-name", ".git", "-print", "-prune"]
    let paths = run(args).out.split(separator: "\n").map { ($0 as NSString).deletingLastPathComponent }.prefix(800)
    var repos = [GitRepo](repeating: GitRepo(path: ""), count: paths.count)
    let arr = Array(paths)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: arr.count) { i in
        let r = scanRepo(arr[i])
        lock.lock(); repos[i] = r; lock.unlock()
    }
    return repos.sorted { $0.gitSize > $1.gitSize }
}

@MainActor @Observable final class GitModel {
    var repos: [GitRepo] = []
    var loading = false
    var searched = false
    var busy: String? = nil

    func load() {
        loading = true
        Task {
            repos = await Task.detached { findRepos() }.value
            loading = false; searched = true
        }
    }

    func gc(_ r: GitRepo, store: Store) {
        busy = r.path
        Task {
            let after = await Task.detached { () -> GitRepo in
                run(["/usr/bin/git", "-C", r.path, "gc", "--quiet"], mergeErr: true)
                return scanRepo(r.path)
            }.value
            logLine("GIT gc \(r.path): \(fmt(r.gitSize)) -> \(fmt(after.gitSize))")
            store.flash("\(r.name): compattato, \(fmt(max(r.gitSize - after.gitSize, 0))) liberati")
            if let i = repos.firstIndex(where: { $0.path == r.path }) { repos[i] = after }
            busy = nil
            store.refreshDisk()
        }
    }

    func deleteMerged(_ r: GitRepo, store: Store) {
        guard confirm("Eliminare \(r.merged.count) branch già unite in \(r.name)?",
                      r.merged.joined(separator: ", ") + "\n\nSolo branch locali già unite (git branch -d): il loro lavoro è nella branch corrente.") else { return }
        busy = r.path
        Task {
            let after = await Task.detached { () -> GitRepo in
                run(["/usr/bin/git", "-C", r.path, "branch", "-d"] + r.merged, mergeErr: true)
                return scanRepo(r.path)
            }.value
            logLine("GIT branch -d in \(r.path): \(r.merged.joined(separator: " "))")
            store.flash("\(r.name): eliminate \(r.merged.count - after.merged.count) branch")
            if let i = repos.firstIndex(where: { $0.path == r.path }) { repos[i] = after }
            busy = nil
        }
    }
}

// MARK: - Batteria

struct BatteryInfo {
    var present = false
    var cycles = 0, designCycles = 1000
    var health = "", maxCapacity = 0  // %
    var charge = 0, charging = false, plugged = false, full = false
    var temperature: Double = 0
    var rawMax = 0, design = 0  // mAh
    var adapterWatts = 0
}

func loadBattery() -> BatteryInfo {
    var b = BatteryInfo()
    if let d = try? JSONSerialization.jsonObject(with: Data(run(["/usr/sbin/system_profiler", "SPPowerDataType", "-json"]).out.utf8)) as? [String: Any],
       let list = d["SPPowerDataType"] as? [[String: Any]] {
        for e in list {
            if let h = e["sppower_battery_health_info"] as? [String: Any] {
                b.present = true
                b.cycles = h["sppower_battery_cycle_count"] as? Int ?? 0
                b.health = h["sppower_battery_health"] as? String ?? ""
                b.maxCapacity = Int((h["sppower_battery_health_maximum_capacity"] as? String ?? "").filter(\.isNumber)) ?? 0
            }
            if let c = e["sppower_battery_charge_info"] as? [String: Any] {
                b.charge = c["sppower_battery_state_of_charge"] as? Int ?? 0
                b.charging = c["sppower_battery_is_charging"] as? String == "TRUE"
                b.full = c["sppower_battery_fully_charged"] as? String == "TRUE"
            }
        }
    }
    let io = run(["/usr/sbin/ioreg", "-rn", "AppleSmartBattery", "-a"]).out
    if let arr = try? PropertyListSerialization.propertyList(from: Data(io.utf8), format: nil) as? [[String: Any]], let r = arr.first {
        b.temperature = Double(r["Temperature"] as? Int ?? 0) / 100
        b.rawMax = r["AppleRawMaxCapacity"] as? Int ?? 0
        b.design = r["DesignCapacity"] as? Int ?? 0
        b.designCycles = r["DesignCycleCount9C"] as? Int ?? 1000
        b.plugged = r["ExternalConnected"] as? Bool ?? false
        b.adapterWatts = (r["AdapterDetails"] as? [String: Any])?["Watts"] as? Int ?? 0
    }
    return b
}

// MARK: - Dischi esterni

struct VolumeInfo: Identifiable {
    var id: String { path }
    let path: String, name: String, format: String, total: Int64, free: Int64, removable: Bool, local: Bool
    var junkFiles: [String] = []
    var junkSize: Int64 = 0
    var junkScanned = false
}

func loadVolumes() -> [VolumeInfo] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRemovableKey,
                                  .volumeIsEjectableKey, .volumeIsLocalKey, .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey]
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return urls.filter { $0.path.hasPrefix("/Volumes/") }.compactMap { u in
        guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
        return VolumeInfo(path: u.path, name: v.volumeName ?? u.lastPathComponent, format: v.volumeLocalizedFormatDescription ?? "",
                          total: Int64(v.volumeTotalCapacity ?? 0), free: Int64(v.volumeAvailableCapacity ?? 0),
                          removable: (v.volumeIsRemovable ?? false) || (v.volumeIsEjectable ?? false), local: v.volumeIsLocal ?? true)
    }
}

/// File nascosti che macOS lascia sui dischi esterni (.DS_Store, ._*, il Cestino del disco).
func scanVolumeJunk(_ vol: String) -> (files: [String], size: Int64) {
    var files = run(["/usr/bin/find", vol, "-xdev", "-type", "f", "(", "-name", ".DS_Store", "-o", "-name", "._*", ")"]).out
        .split(separator: "\n").map(String.init)
    for d in [".Trashes/\(getuid())", ".TemporaryItems"] where FileManager.default.fileExists(atPath: vol + "/" + d) {
        files.append(vol + "/" + d)
    }
    let size = files.reduce(Int64(0)) { $0 + ($1.hasSuffix(".DS_Store") || ($1 as NSString).lastPathComponent.hasPrefix("._") ? allocatedSize($1) : duTotal($1)) }
    return (files, size)
}

@MainActor @Observable final class VolumesModel {
    var volumes: [VolumeInfo] = []
    var loading = false
    var loaded = false
    var busy: String? = nil

    func load() {
        loading = true
        Task {
            volumes = await Task.detached { loadVolumes() }.value
            loading = false; loaded = true
        }
    }

    func scanJunk(_ v: VolumeInfo) {
        busy = v.path
        Task {
            let r = await Task.detached { scanVolumeJunk(v.path) }.value
            if let i = volumes.firstIndex(where: { $0.path == v.path }) {
                volumes[i].junkFiles = r.files; volumes[i].junkSize = r.size; volumes[i].junkScanned = true
            }
            busy = nil
        }
    }

    func cleanJunk(_ v: VolumeInfo, store: Store) {
        guard confirm("Eliminare \(v.junkFiles.count) file nascosti da \(v.name) (\(fmt(v.junkSize)))?",
                      "Cancellazione DEFINITIVA di .DS_Store, file ._ e del Cestino di questo disco. Sono metadati di macOS: i tuoi file non si toccano.") else { return }
        busy = v.path
        Task {
            let n = await Task.detached { () -> Int in
                var n = 0
                for f in v.junkFiles where f.hasPrefix(v.path + "/") {  // mai fuori dal disco
                    if (try? FileManager.default.removeItem(atPath: f)) != nil { n += 1 }
                }
                return n
            }.value
            logLine("DISCO \(v.name): eliminati \(n) file nascosti (\(fmt(v.junkSize)))")
            store.flash("\(v.name): eliminati \(n) file nascosti")
            busy = nil
            load()
        }
    }

    func eject(_ v: VolumeInfo, store: Store) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: v.path))
            store.flash("\(v.name) espulso")
        } catch {
            store.flash("Errore: \(error.localizedDescription)")
        }
        load()
    }
}
