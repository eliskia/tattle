import AppKit
import ApplicationServices

/// "Press a key and see who reacts": watches which apps wake up right after a key press.
final class KeyTester: ObservableObject {
    enum Phase: Equatable { case idle, listening, watching, done }

    struct Result: Equatable {
        var key: String
        var reactions: [String]
        var when: Date
    }

    @Published var phase: Phase = .idle
    @Published var result: Result?
    @Published var needsPermission = false

    /// Supplied by the monitor: maps a process to an app name, and reports recent processor use.
    var nameForPid: (pid_t) -> String? = { _ in nil }
    var cpuSnapshot: () -> [String: Double] = { [:] }   // app name -> seconds of processor time so far
    var normalLoad: () -> [String: Double] = { [:] }    // app name -> usual % of a core

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pendingModifier: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var windowsBefore: [Int: pid_t] = [:]
    private var shapesBefore: [Int: String] = [:]
    private var micBefore = Set<pid_t>()
    private var micSeen = Set<pid_t>()
    private var micTimer: Timer?
    private var refresh: Timer?
    private var events: [String] = []
    private var frontBefore: String?
    private let watchSeconds = 2.0

    func start() {
        guard phase == .idle || phase == .done else { return }
        guard AXIsProcessTrusted() else {
            needsPermission = true
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            return
        }
        needsPermission = false
        result = nil
        events = []
        phase = .listening
        let first = WindowScanner.scan()
        windowsBefore = first.allOnScreen
        shapesBefore = first.shape
        frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName
        refresh = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.phase == .listening else { return }
            let w = WindowScanner.scan()
            self.windowsBefore = w.allOnScreen
            self.shapesBefore = w.shape
            self.frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] ev in self?.handle(ev) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] ev in
            self?.handle(ev)
            return nil
        }
        let t = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .listening else { return }
            self.stopListening()
            self.phase = .idle
        }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: t)
    }

    func cancel() {
        stopListening()
        phase = .idle
    }

    private func stopListening() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
        pendingModifier?.cancel()
        timeout?.cancel()
        refresh?.invalidate()
        refresh = nil
    }

    private func mods(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.command) { m |= KeyCombo.cmd }
        if f.contains(.shift) { m |= KeyCombo.shift }
        if f.contains(.option) { m |= KeyCombo.opt }
        if f.contains(.control) { m |= KeyCombo.ctrl }
        if f.contains(.function) { m |= KeyCombo.fn }
        return m
    }

    private func handle(_ ev: NSEvent) {
        guard phase == .listening else { return }
        if ev.type == .keyDown {
            pendingModifier?.cancel()
            captured(KeyCombo(keyCode: Int(ev.keyCode), mods: mods(ev.modifierFlags)))
        } else {
            // A modifier went down. Wait a moment in case it's the start of a longer combination.
            let m = ev.keyCode == 57 ? 0 : mods(ev.modifierFlags)
            if ev.keyCode == 57 { captured(KeyCombo(keyCode: 57, mods: 0)); return }
            guard m != 0 else { return }
            pendingModifier?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .listening else { return }
                self.captured(KeyCombo(keyCode: -1, mods: m))
            }
            pendingModifier = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func captured(_ combo: KeyCombo) {
        stopListening()
        phase = .watching
        let cpuBefore = cpuSnapshot()
        let load = normalLoad()
        micBefore = Set(Media.micPids())
        micSeen = []
        let mt = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.micSeen.formUnion(Set(Media.micPids()).subtracting(self.micBefore))
        }
        RunLoop.main.add(mt, forMode: .common)
        micTimer = mt
        let center = NSWorkspace.shared.notificationCenter
        let me = ProcessInfo.processInfo.processIdentifier
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != me, let name = app.localizedName else { return }
            self?.events.append("\(name) jumped to the front")
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = app.localizedName else { return }
            self?.events.append("\(name) was launched")
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + watchSeconds) { [weak self] in
            guard let self else { return }
            for o in self.observers { center.removeObserver(o) }
            self.observers = []
            var reactions = self.events
            self.micTimer?.invalidate()
            self.micTimer = nil
            func who(_ pid: pid_t) -> String? {
                self.nameForPid(pid) ?? NSRunningApplication(processIdentifier: pid)?.localizedName
            }

            // Microphone switched on.
            self.micSeen.formUnion(Set(Media.micPids()).subtracting(self.micBefore))
            for name in Set(self.micSeen.map { who($0) ?? "macOS (Siri or Dictation)" }).sorted() {
                reactions.append("\(name) started using the microphone")
            }

            // New things on screen, or existing things that changed size.
            let scan = WindowScanner.scan()
            var shown = Set<String>(), changed = Set<String>()
            for (wid, pid) in scan.allOnScreen where pid != me {
                guard let name = who(pid) else { continue }
                if self.windowsBefore[wid] == nil { shown.insert(name) }
                else if self.shapesBefore[wid] != scan.shape[wid] { changed.insert(name) }
            }
            for (wid, pid) in self.windowsBefore where scan.allOnScreen[wid] == nil && pid != me {
                if let name = who(pid), !shown.contains(name) { changed.insert(name) }
            }
            for name in shown.sorted() { reactions.append("\(name) put something new on screen") }
            for name in changed.subtracting(shown).sorted() { reactions.append("\(name) changed what it shows on screen") }

            // Apps that suddenly got busy.
            let cpuAfter = self.cpuSnapshot()
            var busy: [(String, Double)] = []
            for (name, secs) in cpuAfter {
                let used = secs - (cpuBefore[name] ?? secs)
                let expected = (load[name] ?? 0) / 100 * self.watchSeconds
                if used > expected * 2 + 0.05 { busy.append((name, used)) }
            }
            for (name, used) in busy.sorted(by: { $0.1 > $1.1 }).prefix(4)
            where !reactions.contains(where: { $0.hasPrefix(name + " ") }) {
                reactions.append(String(format: "%@ got busy (%.0f ms of processor time)", name, used * 1000))
            }

            var seen = Set<String>()
            reactions = reactions.filter { seen.insert($0).inserted }
            self.result = Result(key: combo.display, reactions: reactions, when: Date())
            self.phase = .done
        }
    }
}
