import AppKit
import CoreAudio
import CoreMediaIO
import Darwin

// MARK: - Which app does a process belong to?

func isSystemPath(_ p: String) -> Bool {
    if p.hasPrefix("/usr/local/") { return false }
    for pre in ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"] where p.hasPrefix(pre) { return true }
    return false
}

/// "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/..." -> "/Applications/Slack.app"
func outerApp(_ path: String) -> String? {
    guard let r = path.range(of: ".app/") else { return nil }
    return String(path[..<r.lowerBound]) + ".app"
}

struct BundleInfo {
    let path: String
    let name: String
    let bundleID: String?
    let isApple: Bool
}

/// Remembers what we've learned about installed apps.
final class AppIndex {
    private var cache: [String: BundleInfo] = [:]
    private var idToPath: [String: String] = [:]
    private var lastIndex = Date.distantPast
    private let lock = NSLock()

    func info(_ bundlePath: String) -> BundleInfo {
        lock.lock(); defer { lock.unlock() }
        return infoLocked(bundlePath)
    }

    private func infoLocked(_ bundlePath: String) -> BundleInfo {
        if let c = cache[bundlePath] { return c }
        let b = Bundle(path: bundlePath)
        let id = b?.bundleIdentifier
        let fileName = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var name = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }))
        if name.isEmpty || name == "Electron" { name = fileName }
        let apple = (id ?? "").hasPrefix("com.apple.") || bundlePath.hasPrefix("/System/")
        let info = BundleInfo(path: bundlePath, name: name, bundleID: id, isApple: apple)
        cache[bundlePath] = info
        if let id { idToPath[id.lowercased()] = bundlePath }
        return info
    }

    func refreshIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(lastIndex) > 600 else { return }
        lastIndex = Date()
        let fm = FileManager.default
        let roots = ["/Applications", "/Applications/Setapp", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for root in roots {
            for item in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where item.hasSuffix(".app") {
                _ = infoLocked(root + "/" + item)
            }
        }
    }

    func path(forAppNamed name: String) -> String? {
        let want = name.lowercased()
        lock.lock(); defer { lock.unlock() }
        var hits: [String] = []
        for (path, info) in cache where !info.isApple {
            let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            if info.name.lowercased() == want || file == want { hits.append(path) }
        }
        // Prefer the copy in the Applications folder over helpers tucked away elsewhere.
        return hits.min { ($0.hasPrefix("/Applications/") ? 0 : 1, $0.count) < ($1.hasPrefix("/Applications/") ? 0 : 1, $1.count) }
    }

    func path(forBundleID id: String) -> String? {
        lock.lock()
        if let p = idToPath[id.lowercased()] { lock.unlock(); return p }
        lock.unlock()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        _ = info(url.path)
        return url.path
    }

    /// Match a loose helper like "com.stclairsoft.AppTamer.Helper" to the app it came from.
    func matchHelper(named raw: String) -> String? {
        let name = raw.lowercased()
        let comps = name.split(separator: ".")
        guard comps.count >= 3 else { return nil }
        lock.lock(); defer { lock.unlock() }
        var best: (id: String, path: String)?
        for (id, path) in idToPath where !id.hasPrefix("com.apple.") {
            if name.hasPrefix(id), id.count > (best?.id.count ?? 0) { best = (id, path) }
        }
        if let best { return best.path }
        let stem = comps[0] + "." + comps[1] + "."
        let hits = Set(idToPath.filter { $0.key.hasPrefix(stem) && !$0.key.hasPrefix("com.apple.") }.values)
        return hits.count == 1 ? hits.first : nil
    }
}

/// Decides which app (if any) each running process should be counted under.
struct Classifier {
    let paths: [pid_t: String]
    let ppids: [pid_t: pid_t]
    let index: AppIndex
    let helperMap: [String: String]
    let runningBundle: [pid_t: String]
    private var memo: [pid_t: String?] = [:]

    init(paths: [pid_t: String], ppids: [pid_t: pid_t], index: AppIndex, helperMap: [String: String],
         runningBundle: [pid_t: String]) {
        self.paths = paths; self.ppids = ppids; self.index = index; self.helperMap = helperMap
        self.runningBundle = runningBundle
    }

    /// Returns nil for things that belong to macOS itself.
    mutating func key(for pid: pid_t, depth: Int = 0) -> String? {
        if let m = memo[pid] { return m }
        let k = compute(pid, depth)
        memo[pid] = k
        return k
    }

    func known(_ pid: pid_t) -> String? { memo[pid] ?? nil }

    /// Updaters that live in a cache folder named after their app belong to that app.
    private func resolve(_ app: String) -> String? {
        if let r = app.range(of: "/Library/Caches/") {
            let rest = app[r.upperBound...]
            if let slash = rest.firstIndex(of: "/"), let owner = index.path(forBundleID: String(rest[..<slash])) {
                return index.info(owner).isApple ? nil : owner
            }
        }
        return index.info(app).isApple ? nil : app
    }

    /// Is this process itself part of an app bundle? (`found` is true even for Apple's own apps, whose key is nil.)
    private func directApp(_ pid: pid_t) -> (found: Bool, key: String?) {
        guard let path = paths[pid], !path.isEmpty, !isSystemPath(path) else { return (false, nil) }
        // Some apps (Chrome) run from a temporary copy, so trust what macOS says the app is.
        if let rb = runningBundle[pid], rb.hasSuffix(".app"), !isSystemPath(rb) {
            return (true, resolve(outerApp(rb + "/") ?? rb))
        }
        if let app = outerApp(path) { return (true, resolve(app)) }
        return (false, nil)
    }

    private mutating func compute(_ pid: pid_t, _ depth: Int) -> String? {
        guard let path = paths[pid], !path.isEmpty else { return nil }
        if !isSystemPath(path) {
            let d = directApp(pid)
            if d.found { return d.key }
            if let mapped = helperMap[path] { return mapped }
            let r = Sys.responsible(pid)
            if r > 1, r != pid, let k = directApp(r).key { return k }
            var p = ppids[pid] ?? 0
            var hops = 0
            while p > 1 && hops < 6 {
                if let k = directApp(p).key { return k }
                p = ppids[p] ?? 0
                hops += 1
            }
            if let app = index.matchHelper(named: (path as NSString).lastPathComponent) { return app }
            return "tool:" + path
        }
        // A macOS helper doing work on behalf of someone else's app (web views, shells, etc).
        let r = Sys.responsible(pid)
        if r > 1, r != pid, let rp = paths[r] {
            if let k = directApp(r).key { return k }
            if !isSystemPath(rp), depth < 3 { return key(for: r, depth: depth + 1) }
        }
        return nil
    }
}

// MARK: - Things that start themselves

enum AutoStart {
    static func load(index: AppIndex) -> [AutoItem] {
        let home = NSHomeDirectory()
        let places: [(String, String)] = [
            (home + "/Library/LaunchAgents", "starts when you log in"),
            ("/Library/LaunchAgents", "starts when anyone logs in"),
            ("/Library/LaunchDaemons", "starts when the Mac boots, with administrator rights"),
        ]
        var items: [AutoItem] = []
        for (dir, when) in places {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".plist") {
                guard let d = NSDictionary(contentsOfFile: dir + "/" + file) as? [String: Any] else { continue }
                let label = (d["Label"] as? String) ?? (file as NSString).deletingPathExtension
                if label.hasPrefix("com.apple.") { continue }
                let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first ?? ""
                var bits = [when]
                if let keep = d["KeepAlive"] as? Bool, keep { bits.append("restarts itself if quit") }
                else if d["KeepAlive"] is [String: Any] { bits.append("restarts itself if quit") }
                if let secs = d["StartInterval"] as? Int { bits.append("runs every " + fmtDuration(Double(secs))) }
                if d["StartCalendarInterval"] != nil { bits.append("runs on a schedule") }

                var appKey: String?
                if !program.isEmpty, !isSystemPath(program), let app = outerApp(program), !index.info(app).isApple {
                    appKey = app
                }
                if appKey == nil {
                    var ids: [String] = []
                    if let s = d["AssociatedBundleIdentifiers"] as? String { ids = [s] }
                    if let a = d["AssociatedBundleIdentifiers"] as? [String] { ids = a }
                    for id in ids { if let p = index.path(forBundleID: id) { appKey = p; break } }
                }
                if appKey == nil { appKey = index.matchHelper(named: label) }
                let owner = appKey.map { index.info($0).name } ?? label
                items.append(AutoItem(label: label, program: program, detail: bits.joined(separator: ", "),
                                      appKey: appKey, ownerName: owner))
            }
        }
        return items.sorted { $0.ownerName.lowercased() < $1.ownerName.lowercased() }
    }
}

// MARK: - Windows

struct WindowInfo {
    var hasWindow: Set<pid_t> = []   // a real window on some desktop
    var onScreen: Set<pid_t> = []    // a real window visible right now
    var statusItem: Set<pid_t> = []  // owns a menu bar icon (best effort)
    var allOnScreen: [Int: pid_t] = [:]  // every visible window id -> owner (any kind)
    var shape: [Int: String] = [:]       // size and opacity of each visible window, to spot changes
}

enum WindowScanner {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias SpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let sls: (conn: Int32, spaces: SpacesFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let c1 = dlsym(h, "SLSMainConnectionID"),
              let c2 = dlsym(h, "SLSCopySpacesForWindows") else { return nil }
        return (unsafeBitCast(c1, to: ConnFn.self)(), unsafeBitCast(c2, to: SpacesFn.self))
    }()

    private typealias DisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias WindowsFn = @convention(c) (Int32, Int32, CFArray, Int32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
    private static let listing: (spaces: DisplaySpacesFn, windows: WindowsFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let a = dlsym(h, "SLSCopyManagedDisplaySpaces"),
              let b = dlsym(h, "SLSCopyWindowsWithOptionsAndTags") else { return nil }
        return (unsafeBitCast(a, to: DisplaySpacesFn.self), unsafeBitCast(b, to: WindowsFn.self))
    }()

    /// Windows that are genuinely open on some desktop, or minimized. Apps such as Notion and Zoom keep a
    /// closed window in memory; those are left out, which matches what the Dock calls "Running in Background".
    private static func openWindowIDs() -> Set<Int>? {
        guard let sls, let listing else { return nil }
        var spaceIDs: [NSNumber] = []
        let displays = listing.spaces(sls.conn)?.takeRetainedValue() as? [[String: Any]] ?? []
        for d in displays {
            for sp in d["Spaces"] as? [[String: Any]] ?? [] {
                if let id = (sp["id64"] as? NSNumber) ?? (sp["ManagedSpaceID"] as? NSNumber) { spaceIDs.append(id) }
            }
        }
        guard !spaceIDs.isEmpty else { return nil }
        var set: UInt64 = 0, clear: UInt64 = 0
        let ids = listing.windows(sls.conn, 0, spaceIDs as CFArray, 2, &set, &clear)?.takeRetainedValue() as? [NSNumber] ?? []
        return ids.isEmpty ? nil : Set(ids.map(\.intValue))
    }

    static func scan() -> WindowInfo {
        var info = WindowInfo()
        let open = openWindowIDs()
        let list = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let wid = w[kCGWindowNumber as String] as? Int ?? 0
            let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let width = bounds["Width"] ?? 0, height = bounds["Height"] ?? 0
            let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            if on, width >= 24, height >= 24, alpha > 0.05 {
                info.allOnScreen[wid] = pid
                info.shape[wid] = "\(Int(width))x\(Int(height))@\(Int(alpha * 10))"
            }
            if layer == 25 { info.statusItem.insert(pid) }
            guard layer == 0, width >= 120, height >= 80, alpha > 0.05 else { continue }
            if on {
                info.onScreen.insert(pid)
                info.hasWindow.insert(pid)
            } else if let open {
                if open.contains(wid) { info.hasWindow.insert(pid) }
            } else if let sls {
                // A window that lives on some desktop (another Space, or minimized) is real;
                // one that lives nowhere is just a hidden leftover.
                let spaces = sls.spaces(sls.conn, 7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [Any] ?? []
                if !spaces.isEmpty { info.hasWindow.insert(pid) }
            }
        }
        return info
    }
}

// MARK: - Network

enum NetSampler {
    /// Total bytes received / sent so far, per process.
    static func sample() -> [pid_t: (down: UInt64, up: UInt64)] {
        var out: [pid_t: (UInt64, UInt64)] = [:]
        let text = Sys.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"], timeout: 6)
        for line in text.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let down = UInt64(f[1]), let up = UInt64(f[2]),
                  let dot = f[0].lastIndex(of: "."),
                  let pid = pid_t(f[0][f[0].index(after: dot)...]) else { continue }
            out[pid] = (down, up)
        }
        return out
    }
}

// MARK: - Microphone and camera

enum Media {
    /// Processes that have the microphone open right now.
    static func micPids() -> [pid_t] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == 0 else { return [] }
        var out: [pid_t] = []
        for id in ids {
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == 0, running != 0 else { continue }
            var pid: pid_t = 0
            s = UInt32(MemoryLayout<pid_t>.size)
            var b = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(id, &b, 0, nil, &s, &pid) == 0, pid > 0 { out.append(pid) }
        }
        return out
    }

    /// True if any camera is switched on. macOS won't say which app turned it on.
    static func cameraOn() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(sys, &addr, 0, nil, size, &used, &ids) == 0 else { return false }
        for id in ids {
            var running: UInt32 = 0
            var u: UInt32 = 0
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            if CMIOObjectGetPropertyData(id, &a, 0, nil, 4, &u, &running) == 0, running != 0 { return true }
        }
        return false
    }
}
