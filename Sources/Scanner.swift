import Darwin
import Foundation

/// Scanner parallelo con getattrlistbulk: dimensione allocata di ogni cartella sotto root, come `du -kx`
/// (hard link contati una volta, non attraversa altri volumi) ma ~4-5x più veloce.
final class FastScanner {
    private struct Dir { let path: String; let parent: Int; var own: Int64 = 0 }
    private var dirs: [Dir] = []
    private var queue: [Int] = []
    private var pending = 0
    private let cond = NSCondition()
    // hard link: contati una volta sola, come du (pnpm ne è pieno). Set a spicchi per non litigare sul lock
    private var seen = [Set<UInt64>](repeating: [], count: 64)
    private let seenLocks = (0..<64).map { _ in NSLock() }

    /// Cartelle analizzate finora (per la barra di avanzamento).
    var scanned: Int { cond.lock(); defer { cond.unlock() }; return dirs.count }

    func scan(_ root: String, threads: Int = 12) -> [String: Int64] {
        dirs = [Dir(path: root, parent: -1)]
        queue = [0]
        pending = 1
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            Thread { self.worker(); group.leave() }.start()
        }
        group.wait()
        // somma dal basso: i figli hanno sempre indice maggiore del padre
        var total = dirs.map(\.own)
        for i in stride(from: dirs.count - 1, to: 0, by: -1) { total[dirs[i].parent] += total[i] }
        var out = [String: Int64](minimumCapacity: dirs.count)
        for i in dirs.indices { out[dirs[i].path] = total[i] }
        return out
    }

    private func firstTime(_ inode: UInt64) -> Bool {
        let i = Int(inode % 64)
        seenLocks[i].lock(); defer { seenLocks[i].unlock() }
        return seen[i].insert(inode).inserted
    }

    private func worker() {
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        while true {
            cond.lock()
            while queue.isEmpty && pending > 0 { cond.wait() }
            if queue.isEmpty { cond.broadcast(); cond.unlock(); return }
            let idx = queue.removeLast()
            let path = dirs[idx].path
            cond.unlock()

            var own: Int64 = 0
            var subdirs: [String] = []
            listDir(path, buf, bufSize, &own, &subdirs)

            cond.lock()
            dirs[idx].own = own
            for s in subdirs {
                dirs.append(Dir(path: s, parent: idx))
                queue.append(dirs.count - 1)
            }
            pending += subdirs.count - 1
            cond.broadcast()
            cond.unlock()
        }
    }

    private func listDir(_ path: String, _ buf: UnsafeMutableRawPointer, _ bufSize: Int, _ own: inout Int64, _ subdirs: inout [String]) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return }  // permessi (TCC) o sparita: come du, si salta
        defer { close(fd) }
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_FILEID) | attrgroup_t(ATTR_CMN_ERROR)
        al.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        let prefix = path == "/" ? "/" : path + "/"
        while true {
            let n = getattrlistbulk(fd, &al, buf, bufSize, 0)
            if n <= 0 { break }
            var entry = buf
            for _ in 0..<n {
                // layout: lunghezza, attributi restituiti, poi i valori nell'ordine dei bit richiesti
                let len = Int(entry.load(as: UInt32.self))
                var f = entry + 4
                let ret = f.loadUnaligned(as: attribute_set_t.self)
                f += MemoryLayout<attribute_set_t>.size
                var name = ""
                if ret.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let off = f.loadUnaligned(as: Int32.self)
                    name = String(cString: (f + Int(off)).assumingMemoryBound(to: CChar.self))
                    f += MemoryLayout<attrreference_t>.size
                }
                var type: UInt32 = 0
                if ret.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { type = f.loadUnaligned(as: UInt32.self); f += 4 }
                var inode: UInt64 = 0
                if ret.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 { inode = f.loadUnaligned(as: UInt64.self); f += 8 }
                var err: UInt32 = 0
                if ret.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 { err = f.loadUnaligned(as: UInt32.self); f += 4 }
                if err == 0 {
                    if type == UInt32(VDIR.rawValue) {
                        var mount: UInt32 = 0
                        if ret.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 { mount = f.loadUnaligned(as: UInt32.self) }
                        if mount & UInt32(DIR_MNTSTATUS_MNTPOINT) == 0 { subdirs.append(prefix + name) }  // -x: non attraversa altri volumi
                    } else {
                        var links: UInt32 = 1
                        if ret.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { links = f.loadUnaligned(as: UInt32.self); f += 4 }
                        if ret.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0, links <= 1 || firstTime(inode) {
                            own += f.loadUnaligned(as: Int64.self)
                        }
                    }
                }
                entry += len
            }
        }
    }
}

/// Dimensione di ogni sottocartella di root.
func duTree(_ root: String) -> [String: Int64] { FastScanner().scan(root) }

/// Dimensione totale di un file o di una cartella.
func duTotal(_ path: String) -> Int64 {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
    // ponytail: 4 thread perché di solito gira già dentro parallelSizes
    return isDir.boolValue ? FastScanner().scan(path, threads: 4)[path] ?? 0 : allocatedSize(path)
}

// MARK: - Cache su disco: l'ultima scansione compare subito all'avvio

struct SizeCache: Codable {
    var sizes: [String: Int64]
    var times: [String: Date]
}

let SIZE_CACHE_PATH = SUPPORT_DIR + "/scan-cache.json"

func loadSizeCache() -> SizeCache? {
    guard let d = FileManager.default.contents(atPath: SIZE_CACHE_PATH) else { return nil }
    return try? JSONDecoder().decode(SizeCache.self, from: d)
}

/// Solo cartelle da 1 MB in su: ~57k voci, ~6 MB invece di 100 MB. Le più piccole si misurano quando ci entri.
func saveSizeCache(_ sizes: [String: Int64], _ times: [String: Date]) {
    try? FileManager.default.createDirectory(atPath: SUPPORT_DIR, withIntermediateDirectories: true)
    let c = SizeCache(sizes: sizes.filter { $0.value >= 1_000_000 }, times: times)
    try? JSONEncoder().encode(c).write(to: URL(fileURLWithPath: SIZE_CACHE_PATH), options: .atomic)
}
