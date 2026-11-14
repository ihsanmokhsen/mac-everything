// mac-everything — pencarian nama file instan untuk macOS, meniru cara kerja Everything (voidtools).
//
// Prinsip yang ditiru dari Everything:
//   1. Hanya NAMA file yang diindeks, semuanya disimpan di RAM dalam satu blok byte.
//   2. Tiap entri hanya menyimpan penunjuk ke induknya; path lengkap dirakit saat dibutuhkan.
//   3. Indeks sudah terurut menurut nama, jadi hasil pencarian tidak perlu diurutkan lagi.
//   4. Pencarian = pindai seluruh blok nama secara paralel di semua inti CPU.
//   5. Indeks disimpan ke disk (seperti Everything.db) agar start berikutnya instan.
//   6. Perubahan dipantau terus-menerus (Everything: USN Journal; di sini: FSEvents).

import AppKit
import UniformTypeIdentifiers

let NONE: UInt32 = 0xFFFF_FFFF
let F_DIR: UInt8 = 1
let F_DEAD: UInt8 = 2
let F_NOISE: UInt8 = 4     // file sistem, tersembunyi, atau isi folder modul
let SLASH: UInt8 = 47

/// Tabel pelipat huruf besar ASCII ke huruf kecil.
let foldTable: UnsafeMutablePointer<UInt8> = {
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    for b in 0..<256 { p[b] = (b >= 65 && b <= 90) ? UInt8(b + 32) : UInt8(b) }
    return p
}()

@inline(__always)
func containsFold(_ h: UnsafePointer<UInt8>, _ hl: Int, _ n: UnsafePointer<UInt8>, _ nl: Int) -> Bool {
    if nl == 0 { return true }
    if nl > hl { return false }
    let first = n[0]
    let last = hl - nl
    var i = 0
    while i <= last {
        if foldTable[Int(h[i])] == first {
            var j = 1
            while j < nl && foldTable[Int(h[i + j])] == n[j] { j += 1 }
            if j == nl { return true }
        }
        i += 1
    }
    return false
}

/// Filter jenis: folder saja, atau daftar ekstensi (kosong = semua).
struct Kind {
    var title: String
    var dirsOnly = false
    var exts: [String] = []
    var isAll: Bool { !dirsOnly && exts.isEmpty }
}

let kinds: [Kind] = [
    Kind(title: "Semua"),
    Kind(title: "Folder", dirsOnly: true),
    Kind(title: "Dokumen", exts: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "csv", "md", "pages", "numbers", "key"]),
    Kind(title: "PDF", exts: ["pdf"]),
    Kind(title: "Gambar", exts: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "svg", "psd", "ai", "raw", "cr2", "nef"]),
    Kind(title: "Video", exts: ["mp4", "mov", "mkv", "avi", "wmv", "m4v", "webm", "flv", "mpg", "mpeg", "3gp"]),
    Kind(title: "Audio", exts: ["mp3", "wav", "m4a", "flac", "aac", "ogg", "wma", "aiff"]),
    Kind(title: "Arsip", exts: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "pkg"]),
    Kind(title: "Aplikasi", exts: ["app"]),
]

struct CExt { var p: UnsafeMutablePointer<UInt8>; var n: Int }

@inline(__always)
func extMatch(_ h: UnsafePointer<UInt8>, _ hl: Int, _ exts: UnsafeBufferPointer<CExt>) -> Bool {
    var d = hl - 1
    let stop = max(1, hl - 9)          // ekstensi paling panjang 8 huruf; titik di posisi 0 bukan ekstensi
    while d >= stop && h[d] != 46 { d -= 1 }
    if d < stop { return false }
    let el = hl - d - 1
    if el == 0 { return false }
    var e = 0
    while e < exts.count {
        if exts[e].n == el {
            var k = 0
            while k < el && foldTable[Int(h[d + 1 + k])] == exts[e].p[k] { k += 1 }
            if k == el { return true }
        }
        e += 1
    }
    return false
}

struct Term {
    var bytes: [UInt8]
    var isPath: Bool
    var neg: Bool
}

/// Kata dipisah spasi = semua harus cocok. Awalan "!" = tidak boleh cocok.
/// Kata yang mengandung "/" dicocokkan ke path lengkap, bukan hanya nama.
func parseQuery(_ q: String) -> [Term] {
    q.lowercased().split(separator: " ").compactMap { w in
        var s = w
        var neg = false
        if s.hasPrefix("!") && s.count > 1 { neg = true; s = s.dropFirst() }
        let b = Array(s.utf8)
        return b.isEmpty ? nil : Term(bytes: b, isPath: b.contains(SLASH), neg: neg)
    }
}

// MARK: - Indeks

final class Index {
    var pool = [UInt8]()     // semua nama, sambung-menyambung
    var off = [UInt32]()     // posisi nama di pool
    var par = [UInt32]()     // indeks folder induk
    var len = [UInt16]()     // panjang nama (byte)
    var flg = [UInt8]()      // F_DIR | F_DEAD
    var hasDead = false      // ada folder yang ditandai terhapus

    var count: Int { off.count }

    init(withRoot: Bool = true) {
        if withRoot { add(nil, 0, NONE, true) }
    }

    @discardableResult
    func add(_ p: UnsafePointer<UInt8>?, _ n: Int, _ parent: UInt32, _ dir: Bool) -> UInt32 {
        let i = UInt32(off.count)
        off.append(UInt32(pool.count))
        par.append(parent)
        len.append(UInt16(n))
        flg.append(dir ? F_DIR : 0)
        if let p = p, n > 0 { pool.append(contentsOf: UnsafeBufferPointer(start: p, count: n)) }
        return i
    }

    func appendPath(_ i: Int, into out: inout [UInt8]) {
        if i == 0 { out.append(SLASH); return }
        var total = 0
        var c = i
        var depth = 0
        while c != 0 && depth < 1024 { total += Int(len[c]) + 1; c = Int(par[c]); depth += 1 }
        let start = out.count
        out.append(contentsOf: repeatElement(0, count: total))
        var end = start + total
        c = i
        depth = 0
        while c != 0 && depth < 1024 {
            let l = Int(len[c]), o = Int(off[c])
            end -= l
            var k = 0
            while k < l { out[end + k] = pool[o + k]; k += 1 }
            end -= 1
            out[end] = SLASH
            c = Int(par[c])
            depth += 1
        }
    }

    func pathBytes(_ i: Int) -> [UInt8] {
        var b = [UInt8]()
        appendPath(i, into: &b)
        return b
    }

    func name(_ i: Int) -> String {
        let o = Int(off[i])
        return String(decoding: pool[o..<(o + Int(len[i]))], as: UTF8.self)
    }

    func alive(_ i: Int) -> Bool {
        var c = i
        var depth = 0
        while c != 0 && depth < 1024 {
            if flg[c] & F_DEAD != 0 { return false }
            c = Int(par[c])
            depth += 1
        }
        return true
    }

    // Lokasi yang tidak ditelusuri: /System/Volumes berisi salinan seluruh disk data
    // (akan dobel), /dev bukan file sungguhan, /Volumes berisi disk lain.
    static let skipped: [[UInt8]] = ["/dev", "/Volumes", "/System/Volumes"].map { Array($0.utf8) }

    /// Telusuri isi folder `start` dan semua turunannya, hanya dengan readdir (tanpa stat).
    func walk(from start: UInt32, progress: ((Int) -> Void)?) {
        var stack = [start]
        var nextReport = count + 50_000
        while let d = stack.popLast() {
            var p = pathBytes(Int(d))
            if p.count <= 16 && Index.skipped.contains(p) { continue }
            p.append(0)
            guard let dp = p.withUnsafeBufferPointer({ opendir(UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self)) }) else { continue }
            while let e = readdir(dp) {
                let n = Int(e.pointee.d_namlen)
                let type = e.pointee.d_type
                withUnsafePointer(to: &e.pointee.d_name) { raw in
                    let np = UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self)
                    if np[0] == 46 && (n == 1 || (n == 2 && np[1] == 46)) { return }   // "." dan ".."
                    let isDir = type == UInt8(DT_DIR)
                    let idx = add(np, n, d, isDir)
                    if isDir { stack.append(idx) }
                }
            }
            closedir(dp)
            if let progress = progress, count >= nextReport {
                nextReport = count + 50_000
                progress(count)
            }
        }
    }

    /// Salinan yang terurut menurut nama (tanpa membedakan huruf besar/kecil).
    func sortedCopy() -> Index {
        let n = count
        let r = Index()
        guard n > 1 else { return r }
        var perm = [UInt32]()
        perm.reserveCapacity(n - 1)
        for i in 1..<n where flg[i] & F_DEAD == 0 { perm.append(UInt32(i)) }
        pool.withUnsafeBufferPointer { pb in
            off.withUnsafeBufferPointer { ob in
                len.withUnsafeBufferPointer { lb in
                    let base = pb.baseAddress!
                    perm.sort { a, b in
                        let la = Int(lb[Int(a)]), l2 = Int(lb[Int(b)])
                        let pa = base + Int(ob[Int(a)]), p2 = base + Int(ob[Int(b)])
                        let m = min(la, l2)
                        var k = 0
                        while k < m {
                            let x = foldTable[Int(pa[k])], y = foldTable[Int(p2[k])]
                            if x != y { return x < y }
                            k += 1
                        }
                        if la != l2 { return la < l2 }
                        return a < b
                    }
                }
            }
        }
        var map = [UInt32](repeating: 0, count: n)
        for (pos, old) in perm.enumerated() { map[Int(old)] = UInt32(pos + 1) }
        r.pool.reserveCapacity(pool.count)
        r.off.reserveCapacity(perm.count + 1)
        r.par.reserveCapacity(perm.count + 1)
        r.len.reserveCapacity(perm.count + 1)
        r.flg.reserveCapacity(perm.count + 1)
        pool.withUnsafeBufferPointer { pb in
            for old in perm {
                let o = Int(old)
                r.add(pb.baseAddress! + Int(off[o]), Int(len[o]), map[Int(par[o])], flg[o] & F_DIR != 0)
            }
        }
        return r
    }

    /// Pindai semua nama secara paralel. Hasil sudah terurut karena indeksnya terurut.
    func search(_ terms: [Term], kind: Kind = kinds[0], hideNoise: Bool = false, cancelled: () -> Bool) -> [UInt32] {
        let n = count
        if n <= 1 { return [] }

        struct CTerm { var p: UnsafeMutablePointer<UInt8>; var n: Int; var isPath: Bool; var neg: Bool }
        let cterms: [CTerm] = terms.map { t in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, t.bytes.count))
            for (i, b) in t.bytes.enumerated() { p[i] = b }
            return CTerm(p: p, n: t.bytes.count, isPath: t.isPath, neg: t.neg)
        }
        defer { for c in cterms { c.p.deallocate() } }
        let cexts: [CExt] = kind.exts.map { e in
            let b = Array(e.utf8)
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, b.count))
            for (i, x) in b.enumerated() { p[i] = x }
            return CExt(p: p, n: b.count)
        }
        defer { for c in cexts { c.p.deallocate() } }
        let dirsOnly = kind.dirsOnly
        let skipMask: UInt8 = hideNoise ? (F_DEAD | F_NOISE) : F_DEAD

        let chunks = max(1, min(ProcessInfo.processInfo.activeProcessorCount * 4, n / 20_000 + 1))
        var parts = [[UInt32]](repeating: [], count: chunks)
        let checkDead = hasDead
        parts.withUnsafeMutableBufferPointer { out in
            let outp = out.baseAddress!
            pool.withUnsafeBufferPointer { pb in
                off.withUnsafeBufferPointer { ob in
                    len.withUnsafeBufferPointer { lb in
                        flg.withUnsafeBufferPointer { fb in
                            cterms.withUnsafeBufferPointer { tb in
                              cexts.withUnsafeBufferPointer { eb in
                                let base = pb.baseAddress!
                                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                                    let lo = 1 + (n - 1) * c / chunks
                                    let hi = 1 + (n - 1) * (c + 1) / chunks
                                    var local = [UInt32]()
                                    var buf = [UInt8]()
                                    var i = lo
                                    while i < hi {
                                        if (i & 0x3FFF) == 0 && cancelled() { break }
                                        if fb[i] & skipMask == 0 {
                                            var ok = true
                                            if dirsOnly { ok = fb[i] & F_DIR != 0 }
                                            else if eb.count > 0 { ok = extMatch(base + Int(ob[i]), Int(lb[i]), eb) }
                                            var t = 0
                                            while ok && t < tb.count {
                                                let term = tb[t]
                                                var hit: Bool
                                                if term.isPath {
                                                    buf.removeAll(keepingCapacity: true)
                                                    self.appendPath(i, into: &buf)
                                                    hit = buf.withUnsafeBufferPointer { containsFold($0.baseAddress!, $0.count, term.p, term.n) }
                                                } else {
                                                    hit = containsFold(base + Int(ob[i]), Int(lb[i]), term.p, term.n)
                                                }
                                                if hit == term.neg { ok = false; break }
                                                t += 1
                                            }
                                            if ok && (!checkDead || self.alive(i)) { local.append(UInt32(i)) }
                                        }
                                        i += 1
                                    }
                                    outp[c] = local
                                }
                              }
                            }
                        }
                    }
                }
            }
        }
        if chunks == 1 { return parts[0] }
        var res = [UInt32]()
        res.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for p in parts { res.append(contentsOf: p) }
        return res
    }

    /// Cari entri untuk sebuah path absolut (tanpa garis miring di akhir).
    func find(_ path: [UInt8]) -> UInt32? {
        if path.count <= 1 { return 0 }
        guard let slash = path.lastIndex(of: SLASH) else { return nil }
        let ns = slash + 1
        let L = path.count - ns
        if L == 0 || L > 0xFFFF { return nil }
        let l16 = UInt16(L)
        let n = count
        var buf = [UInt8]()
        return path.withUnsafeBufferPointer { pp -> UInt32? in
            pool.withUnsafeBufferPointer { pb -> UInt32? in
                guard let base = pb.baseAddress else { return nil }
                var i = 1
                while i < n {
                    if len[i] == l16 && flg[i] & F_DEAD == 0 && memcmp(base + Int(off[i]), pp.baseAddress! + ns, L) == 0 {
                        buf.removeAll(keepingCapacity: true)
                        appendPath(i, into: &buf)
                        if buf == path && alive(i) { return UInt32(i) }
                    }
                    i += 1
                }
                return nil
            }
        }
    }

    // MARK: Penanda file yang biasanya tidak dicari

    static let noiseDirs: [[UInt8]] = ["node_modules", "vendor", "__pycache__", "DerivedData", "Pods", "venv",
                                       "site-packages", "bower_components"].map { Array($0.utf8) }
    static let packageSuffixes: [[UInt8]] = [".app", ".framework", ".bundle", ".xcodeproj", ".xcworkspace",
                                             ".photoslibrary", ".kext", ".plugin", ".xcassets"].map { Array($0.utf8) }
    static let nUsers = Array("Users".utf8), nApps = Array("Applications".utf8), nLibrary = Array("Library".utf8)
    static let nCloud = Array("CloudStorage".utf8), nMobile = Array("Mobile Documents".utf8)

    func nameEq(_ i: Int, _ s: [UInt8]) -> Bool {
        let l = Int(len[i])
        if l != s.count { return false }
        let o = Int(off[i])
        var k = 0
        while k < l { if pool[o + k] != s[k] { return false }; k += 1 }
        return true
    }

    func isPackage(_ i: Int) -> Bool {
        let l = Int(len[i]), o = Int(off[i])
        for suf in Index.packageSuffixes where l > suf.count {
            var k = 0
            let start = o + l - suf.count
            while k < suf.count && foldTable[Int(pool[start + k])] == suf[k] { k += 1 }
            if k == suf.count { return true }
        }
        return false
    }

    /// ~/Library, yaitu /Users/<nama>/Library.
    func isHomeLibrary(_ i: Int) -> Bool {
        guard nameEq(i, Index.nLibrary) else { return false }
        let user = Int(par[i])
        if user == 0 { return false }
        let users = Int(par[user])
        return users != 0 && par[users] == 0 && nameEq(users, Index.nUsers)
    }

    /// Apakah entri ini "noise"? Penanda induknya harus sudah dihitung lebih dulu.
    func classify(_ i: Int) -> Bool {
        let p = Int(par[i])
        if p == 0 { return !(nameEq(i, Index.nUsers) || nameEq(i, Index.nApps)) }   // /System, /Library, /usr, /private, ...
        if flg[p] & F_NOISE != 0 {
            // Google Drive dan iCloud Drive tersimpan di dalam ~/Library, tetapi isinya dokumen pengguna.
            if (nameEq(i, Index.nCloud) || nameEq(i, Index.nMobile)) && isHomeLibrary(p) { return false }
            return true
        }
        if len[i] > 0 && pool[Int(off[i])] == 46 { return true }       // diawali titik = tersembunyi
        if isPackage(p) { return true }                                 // isi .app, .framework, ...
        if flg[i] & F_DIR != 0 {
            for d in Index.noiseDirs where nameEq(i, d) { return true }
            if isHomeLibrary(i) { return true }
        }
        return false
    }

    func computeNoise() {
        let n = count
        if n <= 1 { return }
        var done = [Bool](repeating: false, count: n)
        done[0] = true
        var chain = [Int]()
        for i in 1..<n where !done[i] {
            var c = i
            chain.removeAll(keepingCapacity: true)
            while !done[c] { chain.append(c); c = Int(par[c]) }
            while let k = chain.popLast() {
                if classify(k) { flg[k] |= F_NOISE } else { flg[k] &= ~F_NOISE }
                done[k] = true
            }
        }
    }

    // MARK: Simpan / muat (padanan Everything.db)

    static let magic: UInt64 = 0x0000_3258_494B_4943   // "CIKIX2"

    func save(to path: String, extra: [UInt64] = [0, 0, 0]) -> Bool {
        let tmp = path + ".tmp"
        guard let f = fopen(tmp, "wb") else { return false }
        var header: [UInt64] = [Index.magic, UInt64(count), UInt64(pool.count), extra[0], extra[1], extra[2]]
        var ok = fwrite(&header, 8, 6, f) == 6
        ok = ok && off.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, f) == $0.count }
        ok = ok && par.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, f) == $0.count }
        ok = ok && len.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, f) == $0.count }
        ok = ok && flg.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, f) == $0.count }
        ok = ok && pool.withUnsafeBytes { fwrite($0.baseAddress, 1, $0.count, f) == $0.count }
        fclose(f)
        if ok { ok = rename(tmp, path) == 0 }
        if !ok { unlink(tmp) }
        return ok
    }

    static func load(from path: String) -> (Index, [UInt64])? {
        guard let f = fopen(path, "rb") else { return nil }
        defer { fclose(f) }
        var header = [UInt64](repeating: 0, count: 6)
        guard fread(&header, 8, 6, f) == 6, header[0] == magic else { return nil }
        let n = Int(header[1]), pc = Int(header[2])
        guard n >= 1, n < 200_000_000, pc >= 0, pc < Int(UInt32.max) else { return nil }
        func read<T>(_ count: Int, _ zero: T) -> [T]? {
            var a = [T](repeating: zero, count: count)
            let want = count * MemoryLayout<T>.stride
            let got = a.withUnsafeMutableBytes { fread($0.baseAddress, 1, want, f) }
            return got == want ? a : nil
        }
        guard let off = read(n, UInt32(0)), let par = read(n, UInt32(0)),
              let len = read(n, UInt16(0)), let flg = read(n, UInt8(0)),
              let pool = read(pc, UInt8(0)) else { return nil }
        // Tolak berkas rusak: semua penunjuk harus berada di dalam batas.
        for i in 0..<n {
            if Int(off[i]) + Int(len[i]) > pc { return nil }
            if i > 0 && Int(par[i]) >= n { return nil }
        }
        let ix = Index(withRoot: false)
        ix.off = off; ix.par = par; ix.len = len; ix.flg = flg; ix.pool = pool
        ix.hasDead = flg.contains { $0 & (F_DIR | F_DEAD) == (F_DIR | F_DEAD) }
        return (ix, Array(header[3...5]))
    }
}

// MARK: - Mesin: indeks + pemantau perubahan

final class Engine {
    private(set) var index = Index()
    private var lock = pthread_rwlock_t()
    private let stateLock = NSLock()
    private var reindexing = false
    private var pending = [String]()
    private let evq = DispatchQueue(label: "mac-everything.events", qos: .utility)
    private var stream: FSEventStreamRef?
    private var saveScheduled = false
    private var lastEventId: UInt64 = 0     // event terakhir yang sudah tercermin di indeks
    private var inHistory = false           // sedang memutar ulang perubahan saat aplikasi mati
    private var historyCount = 0
    private var pendingOverflow = false

    var onSwap: (() -> Void)?            // indeks diganti seluruhnya
    var onChange: (() -> Void)?          // ada file bertambah/terhapus
    var onProgress: ((Int?) -> Void)?    // jumlah saat mengindeks, nil = selesai

    let cachePath: String = {
        let dir = NSHomeDirectory() + "/Library/Caches/mac-everything"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/index.bin"
    }()

    init() { pthread_rwlock_init(&lock, nil) }

    func read<T>(_ f: (Index) -> T) -> T {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return f(index)
    }

    /// Untuk thread UI: tidak pernah menunggu. nil jika indeks sedang ditulis.
    func tryRead<T>(_ f: (Index) -> T) -> T? {
        if pthread_rwlock_tryrdlock(&lock) != 0 { return nil }
        defer { pthread_rwlock_unlock(&lock) }
        return f(index)
    }

    private func write(_ f: () -> Void) {
        pthread_rwlock_wrlock(&lock)
        f()
        pthread_rwlock_unlock(&lock)
    }

    func start() {
        if let (ix, extra) = Index.load(from: cachePath) {
            ix.computeNoise()
            write { index = ix }
            DispatchQueue.main.async { self.onSwap?() }
            // Seperti Everything melanjutkan dari USN Journal: bila jurnal FSEvents masih
            // jurnal yang sama, cukup putar ulang perubahan sejak indeks terakhir disimpan.
            let uuid = Engine.journalUUID()
            if extra[0] != 0 && uuid != [0, 0] && Array(extra[1...2]) == uuid {
                lastEventId = extra[0]
                inHistory = true
                startWatching(since: extra[0])
                DispatchQueue.main.async { self.onProgress?(nil) }
                return
            }
        }
        lastEventId = FSEventsGetCurrentEventId()
        startWatching(since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow))
        reindex()
    }

    /// Identitas jurnal FSEvents volume data. Berubah jika riwayatnya dibuang sistem.
    static func journalUUID() -> [UInt64] {
        var st = stat()
        guard stat(NSHomeDirectory(), &st) == 0, let u = FSEventsCopyUUIDForDevice(st.st_dev) else { return [0, 0] }
        var bytes = CFUUIDGetUUIDBytes(u)
        return withUnsafeBytes(of: &bytes) { [$0.load(fromByteOffset: 0, as: UInt64.self), $0.load(fromByteOffset: 8, as: UInt64.self)] }
    }

    func reindex() {
        stateLock.lock()
        if reindexing { stateLock.unlock(); return }
        reindexing = true
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let fresh = Index()
            fresh.walk(from: 0) { n in DispatchQueue.main.async { self.onProgress?(n) } }
            let sorted = fresh.sortedCopy()
            sorted.computeNoise()
            write { index = sorted }
            DispatchQueue.main.async { self.onProgress?(nil); self.onSwap?() }
            evq.async { [self] in
                stateLock.lock()
                let p = pending
                let again = pendingOverflow
                pending = []
                pendingOverflow = false
                reindexing = false
                stateLock.unlock()
                if again { reindex(); return }
                if apply(p) { DispatchQueue.main.async { self.onChange?() } }
                save()
            }
        }
    }

    func save() {
        stateLock.lock()
        let busy = reindexing
        stateLock.unlock()
        if busy { return }   // indeks lama + id event baru tidak boleh disimpan bersama
        let u = Engine.journalUUID()
        _ = read { $0.save(to: cachePath, extra: [lastEventId, u[0], u[1]]) }
    }

    private func scheduleSave() {
        if saveScheduled { return }
        saveScheduled = true
        evq.asyncAfter(deadline: .now() + 120) { [self] in
            saveScheduled = false
            save()
        }
    }

    // MARK: FSEvents

    private func startWatching(since: FSEventStreamEventId) {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, num, paths, flags, ids in
            let eng = Unmanaged<Engine>.fromOpaque(info!).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self)
            let interesting = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
            let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
            var list = [String]()
            var rescan = false
            var maxId: UInt64 = 0
            for i in 0..<num {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { eng.inHistory = false; continue }
                if ids[i] > maxId { maxId = ids[i] }
                if f & lost != 0 {
                    if !rescan { FileHandle.standardError.write("indeks ulang: event hilang, flag=\(String(f, radix: 16)) path=\(arr[i])\n".data(using: .utf8)!) }
                    rescan = true
                    continue
                }
                if f & interesting == 0 { continue }   // isi file berubah: tidak relevan untuk indeks nama
                guard let p = arr[i] as? String else { continue }
                if p.hasPrefix("/System/Volumes/") || p.hasPrefix("/dev/") || p.hasPrefix("/Volumes/") { continue }
                list.append(p)
            }
            if eng.inHistory {
                // Terlalu banyak perubahan selama aplikasi mati: indeks ulang lebih murah.
                eng.historyCount += list.count
                if eng.historyCount > 20_000 {
                    FileHandle.standardError.write("indeks ulang: riwayat terlalu panjang\n".data(using: .utf8)!)
                    rescan = true
                    eng.inHistory = false
                }
            }
            eng.handle(list, rescan: rescan)
            if maxId > eng.lastEventId { eng.lastEventId = maxId }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, ["/"] as CFArray,
                                          since, 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, evq)
        FSEventStreamStart(s)
        stream = s
    }

    /// Dipanggil di evq.
    private func handle(_ paths: [String], rescan: Bool) {
        stateLock.lock()
        if reindexing {
            if pending.count < 10_000 { pending.append(contentsOf: paths) } else { pendingOverflow = true }
            if rescan { pendingOverflow = true }
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        // Ledakan perubahan terlalu besar: lebih murah mengindeks ulang daripada satu per satu.
        if rescan || paths.count > 3000 {
            if !rescan { FileHandle.standardError.write("indeks ulang: \(paths.count) perubahan sekaligus\n".data(using: .utf8)!) }
            reindex()
            return
        }
        if paths.isEmpty { return }
        if apply(paths) {
            scheduleSave()
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    private func apply(_ paths: [String]) -> Bool {
        if paths.isEmpty { return false }
        var changed = false
        write {
            for p in Set(paths) where applyOne(p) { changed = true }
        }
        return changed
    }

    private func applyOne(_ path: String) -> Bool {
        var p = Array(path.utf8)
        while p.count > 1 && p.last == SLASH { p.removeLast() }
        if p.count <= 1 { return false }
        let ix = index
        var st = stat()
        if lstat(path, &st) == 0 {
            if ix.find(p) != nil { return false }
            guard let slash = p.lastIndex(of: SLASH) else { return false }
            let parentPath = slash == 0 ? [SLASH] : Array(p[..<slash])
            guard let parent = ix.find(parentPath), ix.flg[Int(parent)] & F_DIR != 0 else { return false }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            let idx = p.withUnsafeBufferPointer { ix.add($0.baseAddress! + slash + 1, p.count - slash - 1, parent, isDir) }
            if isDir { ix.walk(from: idx, progress: nil) }   // folder yang dipindahkan membawa isinya
            for k in Int(idx)..<ix.count where ix.classify(k) { ix.flg[k] |= F_NOISE }
            return true
        } else {
            guard let i = ix.find(p) else { return false }
            ix.flg[Int(i)] |= F_DEAD
            if ix.flg[Int(i)] & F_DIR != 0 { ix.hasDead = true }
            return true
        }
    }
}

// MARK: - Mode uji tanpa jendela:  mac-everything --bench kata1 "kata dua" ...

func runBench(_ queries: [String]) {
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    var t = now()
    let raw = Index()
    raw.walk(from: 0, progress: nil)
    print(String(format: "telusur : %d entri dalam %.2f dtk", raw.count, now() - t))
    t = now()
    let ix = raw.sortedCopy()
    print(String(format: "urutkan : %.2f dtk", now() - t))
    let bytes = ix.pool.count + ix.count * 11
    print(String(format: "memori  : %.1f MB (%.1f byte per entri)", Double(bytes) / 1_048_576, Double(bytes) / Double(max(1, ix.count))))

    let tmp = NSTemporaryDirectory() + "mac-everything-bench.bin"
    t = now()
    let saved = ix.save(to: tmp)
    let tSave = now() - t
    t = now()
    let loaded = Index.load(from: tmp)
    print(String(format: "simpan  : %@ %.2f dtk, muat: %.2f dtk, cocok: %@", saved ? "ok" : "GAGAL", tSave, now() - t,
                 (loaded?.0.count == ix.count && loaded?.0.pool == ix.pool) ? "ya" : "TIDAK"))
    unlink(tmp)

    for q in [""] + queries {
        t = now()
        let r = ix.search(parseQuery(q)) { false }
        print(String(format: "cari %-22@ %8d hasil  %6.1f ms", "\"\(q)\"", r.count, (now() - t) * 1000))
        for i in r.prefix(3) { print("     ", String(decoding: ix.pathBytes(Int(i)), as: UTF8.self)) }
    }

    // Uji pencarian balik path -> entri (dipakai pemantau perubahan).
    let probe = Array("/usr/bin/swiftc".utf8)
    t = now()
    let found = ix.find(probe)
    print(String(format: "find /usr/bin/swiftc: %@ %.2f ms", found != nil ? "ketemu" : "TIDAK ketemu", (now() - t) * 1000))
}

// MARK: - Antarmuka

final class ResultTable: NSTableView {
    var onOpen: ((Bool) -> Void)?
    var onCopy: (() -> Void)?

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36 || e.keyCode == 76 {          // Return / Enter
            onOpen?(e.modifierFlags.contains(.command))
        } else {
            super.keyDown(with: e)
        }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

struct RowInfo {
    var name: String
    var folder: String
    var path: String
    var isDir: Bool
    var size: Int64
    var mtime: Date?
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let engine = Engine()
    var window: NSWindow!
    let field = NSSearchField()
    let table = ResultTable()
    let status = NSTextField(labelWithString: "")
    let kindPopup = NSPopUpButton()
    let noiseCheck = NSButton(checkboxWithTitle: "Sembunyikan file sistem & modul", target: nil, action: nil)
    var isIdle: Bool { field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty && kinds[max(0, kindPopup.indexOfSelectedItem)].isAll }
    var results = [UInt32]()
    var gen = 0
    var rowCache = [Int: RowInfo]()
    var iconCache = [String: NSImage]()
    var indexingCount: Int?
    var retryScheduled = false
    var changeScheduled = false

    let sizeFmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()
    let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()
    let numFmt: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        buildWindow()
        engine.onSwap = { [weak self] in self?.runSearch() }
        engine.onChange = { [weak self] in self?.scheduleRefresh() }
        engine.onProgress = { [weak self] c in self?.indexingCount = c; self?.updateStatus() }
        indexingCount = 0
        updateStatus()
        DispatchQueue.global(qos: .userInitiated).async { self.engine.start() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ n: Notification) { engine.save() }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: Susunan jendela

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "mac-everything"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MacEverythingMain")
        if window.frame.origin == .zero { window.center() }

        field.placeholderString = "Ketik nama file…  (spasi = DAN,  !kata = bukan,  pakai / untuk mencocokkan path)"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.font = .systemFont(ofSize: 14)

        for k in kinds { kindPopup.addItem(withTitle: k.title) }
        kindPopup.target = self
        kindPopup.action = #selector(filterChanged)
        let d = UserDefaults.standard
        noiseCheck.state = (d.object(forKey: "hideNoise") == nil || d.bool(forKey: "hideNoise")) ? .on : .off
        noiseCheck.target = self
        noiseCheck.action = #selector(filterChanged)
        noiseCheck.controlSize = .small
        noiseCheck.font = .systemFont(ofSize: 11)
        noiseCheck.toolTip = "Menyembunyikan folder sistem, ~/Library, file berawalan titik, isi .app, serta node_modules, vendor, dan sejenisnya."
        noiseCheck.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cols: [(String, String, CGFloat)] = [("name", "Nama", 300), ("folder", "Lokasi", 400), ("size", "Ukuran", 90), ("date", "Diubah", 140)]
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = w
            c.minWidth = 60
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onOpen = { [weak self] reveal in reveal ? self?.revealSelected() : self?.openSelected() }
        table.onCopy = { [weak self] in self?.copySelected() }

        let menu = NSMenu()
        menu.addItem(withTitle: "Buka", action: #selector(openSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Tampilkan di Finder", action: #selector(revealSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Salin Path", action: #selector(copySelected), keyEquivalent: "").target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let content = NSView()
        for v in [field, kindPopup, scroll, status, noiseCheck] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: kindPopup.leadingAnchor, constant: -8),
            kindPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            kindPopup.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            kindPopup.widthAnchor.constraint(equalToConstant: 130),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: noiseCheck.leadingAnchor, constant: -8),
            noiseCheck.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            noiseCheck.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        window.contentView = content
        showWindow()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return m
        }
        let app = sub("mac-everything")
        app.addItem(withTitle: "Sembunyikan mac-everything", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Keluar dari mac-everything", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = sub("Berkas")
        file.addItem(withTitle: "Fokus ke Pencarian", action: #selector(focusSearch), keyEquivalent: "f").target = self
        file.addItem(withTitle: "Buka", action: #selector(openSelected), keyEquivalent: "o").target = self
        file.addItem(withTitle: "Tampilkan di Finder", action: #selector(revealSelected), keyEquivalent: "\r").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Indeks Ulang", action: #selector(reindexNow), keyEquivalent: "r").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Tutup Jendela", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let filter = sub("Filter")
        for (i, k) in kinds.enumerated() {
            let item = filter.addItem(withTitle: k.title, action: #selector(pickKind(_:)), keyEquivalent: "\(i + 1)")
            item.target = self
            item.tag = i
        }

        let edit = sub("Edit")
        edit.addItem(withTitle: "Potong", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Salin", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Tempel", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Pilih Semua", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    // MARK: Pencarian

    func controlTextDidChange(_ n: Notification) { runSearch() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.moveDown(_:)) || sel == #selector(NSResponder.insertNewline(_:)) {
            guard !results.isEmpty else { return true }
            window.makeFirstResponder(table)
            if table.selectedRow < 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            return true
        }
        return false
    }

    func runSearch(keepPosition: Bool = false) {
        gen &+= 1
        let g = gen
        let q = field.stringValue
        let kind = kinds[max(0, kindPopup.indexOfSelectedItem)]
        let hide = noiseCheck.state == .on
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let terms = parseQuery(q)
            // Kolom kosong: tidak menampilkan apa pun, supaya tidak ada daftar jutaan baris di memori.
            let res = (terms.isEmpty && kind.isAll) ? [] : engine.read { $0.search(terms, kind: kind, hideNoise: hide) { self.gen != g } }
            DispatchQueue.main.async { [self] in
                guard gen == g else { return }
                results = res
                rowCache.removeAll(keepingCapacity: true)
                table.reloadData()
                if !keepPosition {
                    table.deselectAll(nil)
                    if !res.isEmpty { table.scrollRowToVisible(0) }
                }
                updateStatus()
            }
        }
    }

    /// Perubahan dari pemantau: segarkan paling sering sekali per setengah detik.
    func scheduleRefresh() {
        if changeScheduled { return }
        changeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            changeScheduled = false
            if isIdle { updateStatus() } else { runSearch(keepPosition: true) }
        }
    }

    func updateStatus() {
        var s: String
        if isIdle {
            let total = max(0, (engine.tryRead { $0.count } ?? 1) - 1)
            s = (numFmt.string(from: NSNumber(value: total)) ?? "\(total)") + " objek terindeks"
        } else {
            s = (numFmt.string(from: NSNumber(value: results.count)) ?? "\(results.count)") + " objek"
        }
        if let c = indexingCount {
            s += "   ·   mengindeks… " + (numFmt.string(from: NSNumber(value: c)) ?? "\(c)")
        }
        status.stringValue = s
    }

    // MARK: Tabel

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func info(_ row: Int) -> RowInfo? {
        if let r = rowCache[row] { return r }
        guard row < results.count else { return nil }
        let i = Int(results[row])
        let got: (String, String, Bool)?? = engine.tryRead { ix in
            guard i < ix.count else { return nil }
            let parent = Int(ix.par[i])
            let folder = parent < ix.count ? String(decoding: ix.pathBytes(parent), as: UTF8.self) : "/"
            return (ix.name(i), folder, ix.flg[i] & F_DIR != 0)
        }
        guard let inner = got else {       // indeks sedang ditulis: coba lagi sebentar lagi
            if !retryScheduled {
                retryScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                    retryScheduled = false
                    table.reloadData()
                }
            }
            return nil
        }
        guard let (name, folder, isDir) = inner else { return nil }
        let path = folder == "/" ? "/" + name : folder + "/" + name
        var st = stat()
        var size: Int64 = -1
        var mtime: Date?
        if lstat(path, &st) == 0 {
            size = isDir ? -1 : Int64(st.st_size)
            mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
        }
        let r = RowInfo(name: name, folder: folder, path: path, isDir: isDir, size: size, mtime: mtime)
        if rowCache.count > 2000 { rowCache.removeAll(keepingCapacity: true) }
        rowCache[row] = r
        return r
    }

    func icon(for r: RowInfo) -> NSImage {
        let key = r.isDir ? "/" : (r.name as NSString).pathExtension.lowercased()
        if let i = iconCache[key] { return i }
        let type: UTType = r.isDir ? .folder : (UTType(filenameExtension: key) ?? .data)
        let img = NSWorkspace.shared.icon(for: type)
        img.size = NSSize(width: 16, height: 16)
        iconCache[key] = img
        return img
    }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let id = col?.identifier else { return nil }
        let cell = (tv.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
        let r = info(row)
        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = r?.name ?? "…"
            cell.imageView?.image = r.map { icon(for: $0) }
        case "folder":
            cell.textField?.stringValue = r?.folder ?? ""
        case "size":
            cell.textField?.stringValue = (r != nil && r!.size >= 0) ? sizeFmt.string(fromByteCount: r!.size) : ""
        default:
            cell.textField?.stringValue = r?.mtime.map { dateFmt.string(from: $0) } ?? ""
        }
        return cell
    }

    func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = id.rawValue == "folder" ? .byTruncatingMiddle : .byTruncatingTail
        tf.font = .systemFont(ofSize: 12)
        if id.rawValue == "size" { tf.alignment = .right }
        if id.rawValue != "name" { tf.textColor = .secondaryLabelColor }
        cell.addSubview(tf)
        cell.textField = tf
        var lead = tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if id.rawValue == "name" {
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
            ])
            lead = tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5)
        }
        NSLayoutConstraint.activate([
            lead,
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Aksi

    func selectedPaths() -> [String] {
        table.selectedRowIndexes.compactMap { info($0)?.path }
    }

    @objc func openSelected() {
        for p in selectedPaths().prefix(20) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }

    @objc func revealSelected() {
        let urls = selectedPaths().prefix(50).map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }
    }

    @objc func copySelected() {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func filterChanged() {
        UserDefaults.standard.set(noiseCheck.state == .on, forKey: "hideNoise")
        runSearch()
    }

    @objc func pickKind(_ sender: NSMenuItem) {
        kindPopup.selectItem(at: sender.tag)
        runSearch()
    }

    @objc func focusSearch() {
        showWindow()
        field.selectText(nil)
    }

    @objc func reindexNow() {
        indexingCount = 0
        updateStatus()
        engine.reindex()
    }
}

// MARK: - Titik masuk

let args = CommandLine.arguments
if let b = args.firstIndex(of: "--bench") {
    runBench(Array(args[(b + 1)...]))
} else if let f = args.firstIndex(of: "--filters") {
    // mac-everything --filters <kata…>: muat cache, lalu hitung hasil tiap filter.
    let dir = NSHomeDirectory() + "/Library/Caches/mac-everything/index.bin"
    guard let (ix, _) = Index.load(from: dir) else { print("cache belum ada"); exit(1) }
    var t = Date()
    ix.computeNoise()
    let noise = ix.flg.reduce(0) { $0 + (($1 & F_NOISE) != 0 ? 1 : 0) }
    print(String(format: "penanda: %.0f ms, %d dari %d entri disembunyikan (%.0f%%)", Date().timeIntervalSince(t) * 1000, noise, ix.count, Double(noise) * 100 / Double(ix.count)))
    let terms = parseQuery(args[(f + 1)...].joined(separator: " "))
    for k in kinds {
        t = Date()
        let r = ix.search(terms, kind: k, hideNoise: true) { false }
        let ms = Date().timeIntervalSince(t) * 1000
        let all = ix.search(terms, kind: k, hideNoise: false) { false }.count
        print(String(format: "%-9@ %8d hasil (tanpa sembunyi: %8d)  %5.1f ms", k.title as NSString, r.count, all, ms))
        for i in r.prefix(2) { print("     ", String(decoding: ix.pathBytes(Int(i)), as: UTF8.self)) }
    }
} else if let h = args.firstIndex(of: "--headless"), args.count > h + 2 {
    // mac-everything --headless <detik> <kata…>: jalankan mesin seperti aplikasi, tunggu, lalu cari.
    let eng = Engine()
    var busy = true
    eng.onProgress = { if $0 == nil { busy = false } }
    let t0 = Date()
    eng.start()
    print(String(format: "start: %.2f dtk, %d entri dari cache", Date().timeIntervalSince(t0), eng.read { $0.count }))
    let wait = Double(args[h + 1]) ?? 3
    let deadline = Date().addingTimeInterval(busy ? 600 : wait)
    while Date() < deadline && (busy || Date().timeIntervalSince(t0) < wait) { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    RunLoop.main.run(until: Date().addingTimeInterval(wait))
    let q = args[(h + 2)...].joined(separator: " ")
    let r = eng.read { ix in ix.search(parseQuery(q)) { false }.map { String(decoding: ix.pathBytes(Int($0)), as: UTF8.self) } }
    print("\(r.count) hasil untuk \"\(q)\"")
    for p in r.prefix(10) { print("  ", p) }
    eng.save()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
