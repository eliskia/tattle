import AppKit
import ApplicationServices
import SwiftUI

/// One thing that happened: an app jumping forward, launching, or starting to use the microphone.
struct ActivityEvent: Identifiable {
    let id = UUID()
    let time: Date
    let title: String
    let cause: String
    /// True when nothing the user did explains it (no click, no ordinary shortcut).
    let unexplained: Bool
}

/// Keeps a running record of apps coming to the front, so "why did that just open?" can be answered afterwards.
///
/// Privacy: only the single most recent fn / Caps Lock press or modifier shortcut is remembered, and it is
/// written into the log only if an app jumps forward within a second and a half. Ordinary typing is never looked at.
final class ActivityLog: ObservableObject {
    @Published var events: [ActivityEvent] = []
    @Published var watchingKeys = false

    var nameForPid: (pid_t) -> String? = { _ in nil }

    private var lastKey: (what: String, when: Date, alone: Bool)?
    private var lastClick: Date?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var timer: Timer?
    private var micNow = Set<pid_t>()
    private let window = 1.5
    private let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            self?.appEvent(n, launched: false)
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            self?.appEvent(n, launched: true)
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.lastClick = Date()
        }
        micNow = Set(Media.micPids())
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkMic()
            self?.ensureKeyMonitor()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        ensureKeyMonitor()
    }

    /// Shortcut presses can only be seen once Accessibility is switched on, so keep trying until it is.
    private func ensureKeyMonitor() {
        guard keyMonitor == nil, AXIsProcessTrusted() else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            self?.key(ev)
        }
        watchingKeys = keyMonitor != nil
    }

    private func key(_ ev: NSEvent) {
        let f = ev.modifierFlags
        if ev.type == .flagsChanged {
            if ev.keyCode == 63, f.contains(.function) { lastKey = ("fn", Date(), true) }
            else if ev.keyCode == 57 { lastKey = ("Caps Lock", Date(), true) }
            return
        }
        // Only shortcuts: something held with Command, Control or Option, or a function key. Never plain typing.
        let code = Int(ev.keyCode)
        let held = f.contains(.command) || f.contains(.control) || f.contains(.option)
        guard held || functionKeys.contains(code) else { return }
        var mods = 0
        if f.contains(.command) { mods |= KeyCombo.cmd }
        if f.contains(.shift) { mods |= KeyCombo.shift }
        if f.contains(.option) { mods |= KeyCombo.opt }
        if f.contains(.control) { mods |= KeyCombo.ctrl }
        if f.contains(.function) { mods |= KeyCombo.fn }
        lastKey = (KeyCombo(keyCode: code, mods: mods).display, Date(), false)
    }

    /// Works out what, if anything, the user did just before `now`.
    private func cause(at now: Date) -> (text: String, unexplained: Bool) {
        let keyAge = lastKey.map { now.timeIntervalSince($0.when) } ?? .infinity
        let clickAge = lastClick.map { now.timeIntervalSince($0) } ?? .infinity
        if let k = lastKey, keyAge < window, keyAge <= clickAge {
            // fn or Caps Lock by themselves shouldn't make an app jump forward, so that's worth flagging.
            return (String(format: "%.1f seconds after you pressed %@", keyAge, k.what), k.alone)
        }
        if clickAge < window { return ("right after a mouse click", false) }
        return ("with no click or shortcut just before, so something else brought it up", true)
    }

    private func add(_ title: String, _ c: (text: String, unexplained: Bool), at now: Date, app: String = "", mic: Bool = false) {
        // Keep a lasting note of the ones worth reviewing later.
        if mic { Journal.shared.log("mic", app: app, c.text) }
        else if c.unexplained, !app.isEmpty { Journal.shared.log("unexplained", app: app, title + " " + c.text) }
        events.insert(ActivityEvent(time: now, title: title, cause: c.text, unexplained: c.unexplained), at: 0)
        if events.count > 400 { events.removeLast(events.count - 400) }
    }

    private func appEvent(_ n: Notification, launched: Bool) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != getpid(), app.activationPolicy != .prohibited,
              let name = app.localizedName else { return }
        let now = Date()
        add(launched ? "\(name) was launched" : "\(name) came to the front", cause(at: now), at: now, app: name)
    }

    private func checkMic() {
        let current = Set(Media.micPids())
        defer { micNow = current }
        let now = Date()
        func name(_ pid: pid_t) -> String {
            nameForPid(pid) ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? "macOS (Siri or Dictation)"
        }
        for who in Set(current.subtracting(micNow).map(name)) where !Set(micNow.map(name)).contains(who) {
            add("\(who) started using the microphone", cause(at: now.addingTimeInterval(-0.5)), at: now, app: who, mic: true)
        }
        for who in Set(micNow.subtracting(current).map(name)) where !Set(current.map(name)).contains(who) {
            add("\(who) stopped using the microphone", ("", false), at: now)
        }
    }
}

struct ActivityTab: View {
    @EnvironmentObject var m: Monitor
    @ObservedObject var log: ActivityLog = Monitor.shared.activity
    @State private var onlyOdd = false

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }()

    var body: some View {
        let shown = onlyOdd ? log.events.filter(\.unexplained) : log.events
        VStack(alignment: .leading, spacing: 8) {
            Text("What jumped forward, and why").font(.system(size: 12, weight: .semibold))
            Text("Every time an app comes to the front, launches, or starts using the microphone, Tattle notes what you did just before. Orange means nothing you did explains it. Only fn, Caps Lock and shortcut combinations are noticed, never ordinary typing, and the list is forgotten when Tattle quits.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !log.watchingKeys {
                Text("Shortcut presses can't be seen until Tattle is switched on under Accessibility. Until then, key-triggered switches will show as unexplained.")
                    .font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Only show the unexplained ones", isOn: $onlyOdd).toggleStyle(.checkbox).font(.system(size: 11.5))
            if shown.isEmpty {
                Text(log.events.isEmpty ? "Nothing yet. Switch between a couple of apps and they'll appear here."
                     : "Nothing unexplained so far.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.vertical, 12)
            }
            ForEach(shown.prefix(150)) { e in
                HStack(alignment: .top, spacing: 8) {
                    Text(Self.clock.string(from: e.time)).font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    Circle().fill(e.unexplained ? Color.orange : Color.clear).frame(width: 7, height: 7).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 11.5, weight: .medium))
                        if !e.cause.isEmpty {
                            Text(e.cause).font(.system(size: 10.5)).foregroundStyle(e.unexplained ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
