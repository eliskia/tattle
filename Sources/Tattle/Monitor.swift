import AppKit
import ApplicationServices
import UserNotifications

final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published var snap = Snapshot()
    @Published var shortcuts = ShortcutReport()
    @Published var trusted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "trusted") ?? [])
    let tester = KeyTester()
    let activity = ActivityLog()

    private let q = DispatchQueue(label: "tattle.sample", qos: .utility)
    private let sq = DispatchQueue(label: "tattle.shortcuts", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let index = AppIndex()
    private let history = HistoryStore()

    // Only touched on the sampling queue.
    private var lastSample: Date?
    private var prevCpu: [pid_t: UInt64] = [:]
    private var prevNet: [pid_t: (down: UInt64, up: UInt64)] = [:]
    private var prevPids = Set<pid_t>()
    private var rings: [String: [(t: Date, cpu: Double, up: UInt64, down: UInt64)]] = [:]
    private var autoItems: [AutoItem] = []
    private var helperMap: [String: String] = [:]
    private var lastAuto = Date.distantPast
    private var lastPrivacy = Date.distantPast
    private var lastFiles = Date.distantPast
    private var lastIcons = Date.distantPast
    private var lastSave = Date()
    private var grantsByKey: [String: [Permission]] = [:]
    private var cameraKeys = Set<String>()
    private var listenerNames: [String] = []
    private var hasFDA = false
    private var privacyDiag = ""
    private var powerfulByName: [String: [String]] = [:]
    private var cameraWasOn = false
    private var filesByKey: [String: (sensitive: [String], folders: [String])] = [:]
    private var iconPids = Set<pid_t>()
    private var notified: [String: Date] = [:]
    private var open = false
    private var trustedCopy = Set<String>()

    // Read on the main thread by the key tester.
    private var pidOwner: [pid_t: String] = [:]

    func start() {
        trustedCopy = trusted
        tester.nameForPid = { [weak self] pid in self?.pidOwner[pid] }
        activity.nameForPid = { [weak self] pid in self?.pidOwner[pid] }
        activity.start()
        tester.cpuSnapshot = { [weak self] in
            var out: [String: Double] = [:]
            for (pid, name) in self?.pidOwner ?? [:] {
                if let u = Sys.usage(of: pid) { out[name, default: 0] += Double(u.cpuNs) / 1e9 }
            }
            return out
        }
        tester.normalLoad = { [weak self] in
            var out: [String: Double] = [:]
            for a in self?.snap.apps ?? [] { out[a.name] = a.cpuMinute }
            return out
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [weak self] in self?.sample(force: false) }
        t.resume()
        timer = t
        refreshShortcuts(scanMenus: false)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func setOpen(_ isOpen: Bool) {
        q.async {
            self.open = isOpen
            if isOpen { self.sample(force: true) }
        }
    }

    func refreshNow() { q.async { self.sample(force: true) } }

    // MARK: - Sampling

    private struct RunInfo {
        let regular: Bool
        let name: String?
        let bundlePath: String?
    }

    private func sample(force: Bool) {
        let now = Date()
        if !force, !open, let last = lastSample, now.timeIntervalSince(last) < 14 { return }
        if force, let last = lastSample, now.timeIntervalSince(last) < 1.5 { return }
        let dt = lastSample.map { now.timeIntervalSince($0) } ?? 0
        lastSample = now

        var running: [pid_t: RunInfo] = [:]
        DispatchQueue.main.sync {
            for a in NSWorkspace.shared.runningApplications {
                running[a.processIdentifier] = RunInfo(regular: a.activationPolicy == .regular,
                                                       name: a.localizedName, bundlePath: a.bundleURL?.path)
            }
        }
        index.refreshIfNeeded()
        if now.timeIntervalSince(lastAuto) > 300 {
            autoItems = AutoStart.load(index: index)
            helperMap = [:]
            for item in autoItems {
                if let key = item.appKey, !item.program.isEmpty, outerApp(item.program) == nil { helperMap[item.program] = key }
            }
            lastAuto = now
        }

        // 1. Every process, and which app it belongs to.
        let procs = Sys.allProcesses()
        var paths = [pid_t: String](minimumCapacity: procs.count)
        var ppids = [pid_t: pid_t](minimumCapacity: procs.count)
        var uids = [pid_t: uid_t](minimumCapacity: procs.count)
        for p in procs {
            paths[p.pid] = Sys.path(of: p.pid)
            ppids[p.pid] = p.ppid
            uids[p.pid] = p.uid
        }
        var runningBundle: [pid_t: String] = [:]
        for (pid, info) in running { if let b = info.bundlePath { runningBundle[pid] = b } }
        var classifier = Classifier(paths: paths, ppids: ppids, index: index, helperMap: helperMap,
                                    runningBundle: runningBundle)
        let me = getpid()
        let myBundle = Bundle.main.bundlePath
        var groups: [String: [pid_t]] = [:]
        var systemCount = 0
        for p in procs {
            if p.pid == me || p.ppid == me { continue }
            if let k = classifier.key(for: p.pid) {
                if k == myBundle || (!k.hasPrefix("tool:") && index.info(k).bundleID == "local.tattle.app") { continue }
                groups[k, default: []].append(p.pid)
            } else {
                systemCount += 1
            }
        }

        // 2. Processor and memory use.
        var usage: [pid_t: (cpuNs: UInt64, mem: UInt64)] = [:]
        var missing = false
        for pids in groups.values {
            for pid in pids {
                if let u = Sys.usage(of: pid) { usage[pid] = u } else { missing = true }
            }
        }
        if missing {
            let ps = Sys.psTimes()
            for pids in groups.values { for pid in pids where usage[pid] == nil { usage[pid] = ps[pid] } }
        }

        // 3. Windows, network, microphone, camera.
        let wins = WindowScanner.scan()
        let net = NetSampler.sample()
        let micPids = Media.micPids()
        let cameraOn = Media.cameraOn()
        let axTrusted = AXIsProcessTrusted()

        // 4. Slower checks, done less often.
        if now.timeIntervalSince(lastPrivacy) > (hasFDA ? 120 : 20) {
            loadPrivacy()
            lastPrivacy = now
        }
        if now.timeIntervalSince(lastFiles) > (open ? 12 : 45) {
            var result: [String: (sensitive: [String], folders: [String])] = [:]
            for (key, pids) in groups {
                var all: [String] = []
                for pid in pids where uids[pid] == getuid() { all += OpenFiles.paths(of: pid) }
                let bundleID = key.hasPrefix("tool:") ? nil : index.info(key).bundleID
                let a = OpenFiles.assess(paths: all, bundleID: bundleID)
                if !a.sensitive.isEmpty || !a.folders.isEmpty { result[key] = a }
            }
            filesByKey = result
            lastFiles = now
        }
        if axTrusted, now.timeIntervalSince(lastIcons) > 90 {
            var found = Set<pid_t>()
            for (pid, info) in running where !info.regular && classifier.known(pid) != nil {
                if ShortcutScanner.hasMenuBarIcon(pid: pid) { found.insert(pid) }
            }
            iconPids = found
            lastIcons = now
        }

        // 5. Build one row per app.
        var entries: [AppEntry] = []
        var owner: [pid_t: String] = [:]
        var micKeys = Set<String>()
        var micSystem = false
        for pid in micPids {
            if let k = classifier.known(pid) { micKeys.insert(k) } else if pid != me { micSystem = true }
        }

        for (key, pids) in groups {
            let isTool = key.hasPrefix("tool:")
            let info = isTool ? nil : index.info(key)
            var e = AppEntry(id: key, name: info?.name ?? (key as NSString).lastPathComponent)
            e.isTool = isTool
            e.bundlePath = info?.path
            e.bundleID = info?.bundleID

            let mainPrefix = key + "/Contents/MacOS/"
            let mains = pids.filter { running[$0]?.bundlePath == key || (paths[$0] ?? "").hasPrefix(mainPrefix) }
            e.mainPid = mains.first { running[$0]?.bundlePath == key } ?? mains.first
            e.mainRunning = e.mainPid != nil
            if let mp = e.mainPid, let n = running[mp]?.name, !n.isEmpty { e.name = n }
            e.inDock = pids.contains { running[$0]?.regular == true && running[$0]?.bundlePath == key }
            e.menuBarIcon = pids.contains { iconPids.contains($0) || wins.statusItem.contains($0) }
            e.addOnOnly = !e.mainRunning && pids.allSatisfy { (paths[$0] ?? "").contains(".appex/") }

            var upDelta: UInt64 = 0, downDelta: UInt64 = 0
            for pid in pids {
                owner[pid] = e.name
                let u = usage[pid]
                var cpu = 0.0
                if let u, let prev = prevCpu[pid], dt > 0, u.cpuNs >= prev {
                    cpu = Double(u.cpuNs - prev) / 1e9 / dt * 100
                }
                let root = uids[pid] == 0
                if root { e.anyRoot = true }
                var name = ((paths[pid] ?? "") as NSString).lastPathComponent
                if pid == e.mainPid { name = e.name + " (main app)" }
                e.pieces.append(Piece(pid: pid, name: name, cpu: cpu, mem: u?.mem ?? 0, root: root))
                e.cpu += cpu
                e.mem += u?.mem ?? 0
                if let n = net[pid] {
                    if let prev = prevNet[pid] {
                        if n.up >= prev.up { upDelta += n.up - prev.up }
                        if n.down >= prev.down { downDelta += n.down - prev.down }
                    } else if dt > 0, !prevPids.contains(pid) {
                        upDelta += n.up; downDelta += n.down
                    }
                }
            }
            e.pieces.sort { ($0.cpu, $0.mem) > ($1.cpu, $1.mem) }

            let onScreen = pids.contains { wins.onScreen.contains($0) }
            let hasWindow = pids.contains { wins.hasWindow.contains($0) }
            e.presence = onScreen ? .onScreen : hasWindow ? .elsewhere : e.inDock ? .dockNoWindow : .hidden

            // Recent history for this app.
            var ring = rings[key] ?? []
            if dt > 0 { ring.append((now, e.cpu, upDelta, downDelta)) }
            ring.removeAll { now.timeIntervalSince($0.t) > 600 }
            rings[key] = ring
            if dt > 0 {
                e.upRate = Double(upDelta) / dt
                e.downRate = Double(downDelta) / dt
            }
            let lastMinute = ring.filter { now.timeIntervalSince($0.t) <= 60 }
            e.cpuMinute = lastMinute.isEmpty ? e.cpu : lastMinute.map(\.cpu).reduce(0, +) / Double(lastMinute.count)
            e.cpuTenMin = ring.isEmpty ? e.cpu : ring.map(\.cpu).reduce(0, +) / Double(ring.count)
            e.up10 = ring.map(\.up).reduce(0, +)
            e.down10 = ring.map(\.down).reduce(0, +)

            let noWindow = e.presence == .hidden || e.presence == .dockNoWindow
            history.add(key: key, name: e.name, up: upDelta, down: downDelta, cpuSec: e.cpu / 100 * dt,
                        noWindow: noWindow, mic: micKeys.contains(key), dt: dt)
            if let t = history.totals(key) {
                e.upToday = t.up; e.downToday = t.down; e.hiddenCpuToday = t.hiddenCpu
            }

            e.mic = micKeys.contains(key)
            e.permissions = (grantsByKey[key] ?? []).sorted { ($0.powerful ? 0 : 1, $0.text) < ($1.powerful ? 0 : 1, $1.text) }
            if let f = filesByKey[key] { e.sensitive = f.sensitive; e.folderNotes = f.folders }
            e.autoStart = autoItems.filter { $0.appKey == key }
            e.trusted = trustedCopy.contains(key)
            e.status = statusText(e)
            e.flags = flags(for: e, historySeconds: ring.first.map { now.timeIntervalSince($0.t) } ?? 0)
            entries.append(e)
        }

        entries.sort {
            let a = ($0.needsLook ? $0.worst!.rawValue : 0, $0.cpuMinute, Double($0.mem))
            let b = ($1.needsLook ? $1.worst!.rawValue : 0, $1.cpuMinute, Double($1.mem))
            return a > b
        }

        prevCpu = usage.mapValues(\.cpuNs)
        prevNet = net
        prevPids = Set(procs.map(\.pid))
        for key in rings.keys where groups[key] == nil { rings[key] = nil }
        history.addWatched(dt)
        Journal.shared.observe(apps: entries, autoItems: autoItems, powerful: hasFDA ? powerfulByName : nil)
        if cameraOn != cameraWasOn {
            if cameraOn {
                let who = entries.filter { cameraKeys.contains($0.id) }.map(\.name)
                Journal.shared.log("camera", app: who.isEmpty ? "Tattle can't tell which app" : "Possibly " + who.prefix(4).joined(separator: " or "),
                                   "Camera switched on")
            }
            cameraWasOn = cameraOn
        }
        if now.timeIntervalSince(lastSave) > 60 { history.save(); Journal.shared.saveState(); lastSave = now }

        // 6. Microphone and camera summary.
        var s = Snapshot()
        s.apps = entries
        let micApps = entries.filter(\.mic)
        s.micNames = micApps.map(\.name) + (micSystem && micApps.isEmpty ? ["macOS itself (Siri or Dictation)"] : [])
        s.micHidden = micApps.contains { $0.presence != .onScreen }
        s.cameraOn = cameraOn
        if cameraOn {
            let suspects = entries.filter { cameraKeys.contains($0.id) }
            s.cameraSuspects = suspects.sorted { ($0.mic ? 1 : 0, $0.cpu) > ($1.mic ? 1 : 0, $1.cpu) }.prefix(4).map(\.name)
            s.cameraHidden = !suspects.contains { $0.presence == .onScreen }
        }
        s.systemHidden = systemCount
        s.hasFDA = hasFDA
        s.hasAX = axTrusted
        s.diag = privacyDiag
        s.everydayPermsKnown = hasFDA && Privacy.userStoreReadable
        s.autoItems = autoItems
        s.updated = now
        s.ready = true

        notifyIfNeeded(s)
        DispatchQueue.main.async {
            self.pidOwner = owner
            self.snap = s
        }
    }

    private func statusText(_ e: AppEntry) -> String {
        let n = e.pieces.count
        let pieces = n == 1 ? "1 piece" : "\(n) pieces"
        switch e.presence {
        case .onScreen: return "On screen now · \(pieces)"
        case .elsewhere: return "Window on another desktop or minimized · \(pieces)"
        case .dockNoWindow: return "In the Dock, no window · \(pieces)"
        case .hidden:
            if e.isTool { return e.anyRoot ? "Background helper with administrator rights" : "Background tool, not a regular app" }
            if e.menuBarIcon { return "Menu bar icon only · \(pieces)" }
            if e.addOnOnly { return "App closed · only a widget or add-on is loaded" }
            if !e.mainRunning { return "App closed · \(pieces) still running" }
            return "No window, no Dock icon · \(pieces)"
        }
    }

    /// Processor use (percent of one core, averaged over a minute) that counts as "working hard" when hidden.
    private let cpuFlagLevel = Double(ProcessInfo.processInfo.environment["TATTLE_CPU_FLAG"] ?? "") ?? 10

    private func flags(for e: AppEntry, historySeconds: Double) -> [Flag] {
        var out: [Flag] = []
        let noWindow = e.presence == .hidden || e.presence == .dockNoWindow
        if e.mic && e.presence != .onScreen {
            out.append(Flag(kind: "mic", level: .alert, text: "Using your microphone with no window on screen"))
        }
        if !e.sensitive.isEmpty {
            let list = e.sensitive.joined(separator: ", ")
            out.append(Flag(kind: "files", level: noWindow ? .alert : .warn, text: "Has \(list) open right now"))
        }
        guard !e.trusted else { return out }
        if noWindow {
            if e.cpuMinute >= cpuFlagLevel, historySeconds >= 25 {
                out.append(Flag(kind: "cpu", level: .warn,
                                text: "Working hard with no window open (\(fmtCPU(e.cpuMinute)) of a processor core over the last minute)"))
            } else if e.cpuTenMin >= 4, historySeconds >= 300 {
                out.append(Flag(kind: "cpu", level: .warn,
                                text: "Steadily busy with no window open (\(fmtCPU(e.cpuTenMin)) of a processor core for 10 minutes)"))
            }
            if e.up10 >= 5_000_000 {
                out.append(Flag(kind: "upload", level: .warn, text: "Sent \(fmtBytes(e.up10)) in the last 10 minutes with no window open"))
            }
            if e.down10 >= 50_000_000 {
                out.append(Flag(kind: "download", level: .warn,
                                text: "Downloaded \(fmtBytes(e.down10)) in the last 10 minutes with no window open (often a self-update)"))
            }
            if e.presence == .hidden, !e.mainRunning, !e.isTool, !e.addOnOnly, !e.menuBarIcon {
                out.append(Flag(kind: "leftover", level: .note, text: "The app isn't open, but parts of it are still running"))
            }
        }
        return out
    }

    private func loadPrivacy() {
        guard let grants = Privacy.grants() else {
            hasFDA = false
            privacyDiag = Privacy.lastError
            return
        }
        hasFDA = true
        let overrides = Privacy.overrides()
        var cameraServices: Set<String> = ["kTCCServiceCamera"]
        var keyServices: Set<String> = ["kTCCServiceListenEvent", "kTCCServiceAccessibility"]
        for (service, o) in overrides {
            if (o["role"] as? String) == "camera" { cameraServices.insert(service) }
            if (o["role"] as? String) == "keys" { keyServices.insert(service) }
        }
        var counts: [String: Int] = [:]
        for g in grants { counts[g.service, default: 0] += 1 }
        privacyDiag = Privacy.lastError + "services: " + counts.sorted { $0.key < $1.key }.map { "\($0.key.replacingOccurrences(of: "kTCCService", with: ""))=\($0.value)" }.joined(separator: " ")
        var byKey: [String: [Permission]] = [:]
        var cams = Set<String>()
        var listeners = Set<String>()
        func keyFor(_ g: Grant) -> String? {
            if g.isPath {
                if let app = outerApp(g.client + "/") ?? outerApp(g.client) { return app }
                return "tool:" + g.client
            }
            return index.path(forBundleID: g.client)
        }
        func targetName(_ id: String) -> String {
            if let p = index.path(forBundleID: id) { return index.info(p).name }
            return id
        }
        for g in grants {
            if cameraServices.contains(g.service), let key = keyFor(g) { cams.insert(key) }
            if keyServices.contains(g.service), let key = keyFor(g), key != Bundle.main.bundlePath {
                listeners.insert(key.hasPrefix("tool:") ? (key as NSString).lastPathComponent : index.info(key).name)
            }
            guard let key = keyFor(g), let perm = Privacy.describe(g, targetName: targetName, overrides: overrides) else { continue }
            if !(byKey[key] ?? []).contains(perm) { byKey[key, default: []].append(perm) }
        }
        grantsByKey = byKey
        var strong: [String: [String]] = [:]
        for (key, perms) in byKey where key != Bundle.main.bundlePath {
            let texts = perms.filter(\.powerful).map(\.text).sorted()
            if texts.isEmpty { continue }
            let name = key.hasPrefix("tool:") ? (key as NSString).lastPathComponent : index.info(key).name
            strong[name] = Array(Set((strong[name] ?? []) + texts)).sorted()
        }
        powerfulByName = strong
        cameraKeys = cams
        listenerNames = listeners.sorted { $0.lowercased() < $1.lowercased() }
        let names = listenerNames
        DispatchQueue.main.async {
            self.shortcuts.listeners = names
            self.shortcuts.listenersKnown = true
        }
    }

    private func notifyIfNeeded(_ s: Snapshot) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        var messages: [(String, String, String)] = []
        for e in s.apps {
            for f in e.flags where f.level == .alert {
                messages.append((e.id + f.kind, e.name, f.text))
            }
        }
        if s.cameraOn && s.cameraHidden {
            let who = s.cameraSuspects.isEmpty ? "an app" : s.cameraSuspects.joined(separator: " or ")
            messages.append(("camera", "Camera is on", "No app with the camera is on screen. It may be \(who)."))
        }
        let now = Date()
        for (id, title, body) in messages {
            if let last = notified[id], now.timeIntervalSince(last) < 1800 { continue }
            notified[id] = now
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }

    // MARK: - Actions (main thread)

    func setTrusted(_ key: String, _ on: Bool) {
        if on { trusted.insert(key) } else { trusted.remove(key) }
        UserDefaults.standard.set(Array(trusted), forKey: "trusted")
        let copy = trusted
        q.async { self.trustedCopy = copy }
        q.asyncAfter(deadline: .now() + 1.6) { self.sample(force: true) }
    }

    /// Ask an app to quit. Returns false if some pieces need administrator rights to stop.
    @discardableResult
    func quit(_ e: AppEntry, force: Bool) -> Bool {
        var asked = false
        if !force, let mp = e.mainPid, let app = NSRunningApplication(processIdentifier: mp) {
            asked = app.terminate()
        }
        if !asked {
            for p in e.pieces where !p.root {
                if let app = NSRunningApplication(processIdentifier: p.pid), force { app.forceTerminate() }
                else { kill(p.pid, force ? SIGKILL : SIGTERM) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refreshNow() }
        return !e.pieces.contains(where: \.root)
    }

    // MARK: - Shortcuts

    func refreshShortcuts(scanMenus: Bool) {
        shortcuts.scanning = true
        var targets: [(pid_t, String)] = []
        if scanMenus {
            for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular {
                if a.processIdentifier != getpid() { targets.append((a.processIdentifier, a.localizedName ?? "App")) }
            }
        }
        let previous = shortcuts
        var runningApps = Set<String>()
        for a in NSWorkspace.shared.runningApplications {
            if let p = a.bundleURL?.path { runningApps.insert(outerApp(p + "/") ?? p) }
        }
        sq.async {
            self.index.refreshIfNeeded()
            let globals = (ShortcutScanner.system() + ShortcutScanner.appGlobals(index: self.index)).map { e -> ShortcutEntry in
                var e = e
                e.running = e.appPath == nil || runningApps.contains(e.appPath!)
                return e
            }
            var inApp: [ShortcutEntry] = []
            var scannedApps = 0
            if scanMenus, AXIsProcessTrusted() {
                for (pid, name) in targets {
                    let found = ShortcutScanner.menuShortcuts(pid: pid, appName: name)
                    if !found.isEmpty { scannedApps += 1 }
                    inApp += found
                }
            }
            let result = ShortcutScanner.analyse(globals: globals, inApp: inApp)
            var remappers: [String] = []
            if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/karabiner/karabiner.json") {
                remappers.append("Karabiner-Elements")
            }
            DispatchQueue.main.async {
                var r = self.shortcuts
                r.globals = globals
                r.conflicts = result.conflicts
                r.keyRemappers = remappers
                if scanMenus {
                    r.shadows = result.shadows
                    r.menuScanned = AXIsProcessTrusted()
                    r.menuApps = scannedApps
                    r.menuShortcuts = inApp.count
                } else {
                    r.shadows = previous.shadows
                }
                r.scanning = false
                r.loaded = true
                self.shortcuts = r
            }
        }
    }
}
