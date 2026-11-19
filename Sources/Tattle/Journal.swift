import Foundation

/// Where Tattle keeps its long-term records. Everything stays on this Mac.
enum Store {
    static let dir: URL = {
        // TATTLE_DATA_DIR lets a test run keep its records apart from the real ones.
        let custom = ProcessInfo.processInfo.environment["TATTLE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        let d = custom ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tattle")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let history = dir.appendingPathComponent("history.json")
    static let journal = dir.appendingPathComponent("journal.jsonl")
    static let state = dir.appendingPathComponent("state.json")
    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let watchedKey = "_watched"
}

/// Running totals per app per day.
struct DayTotals: Codable {
    var name: String
    var up: UInt64 = 0          // bytes sent, all day
    var down: UInt64 = 0
    var hiddenUp: UInt64 = 0    // bytes sent while it had no window open
    var hiddenDown: UInt64 = 0
    var hiddenCpu: Double = 0   // seconds of processor time used with no window open
    var hiddenSec: Double = 0   // seconds spent running with no window open
    var runSec: Double = 0      // seconds spent running at all
    var micSec: Double = 0      // seconds with the microphone open

    init(name: String) { self.name = name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        up = try c.decodeIfPresent(UInt64.self, forKey: .up) ?? 0
        down = try c.decodeIfPresent(UInt64.self, forKey: .down) ?? 0
        hiddenUp = try c.decodeIfPresent(UInt64.self, forKey: .hiddenUp) ?? 0
        hiddenDown = try c.decodeIfPresent(UInt64.self, forKey: .hiddenDown) ?? 0
        hiddenCpu = try c.decodeIfPresent(Double.self, forKey: .hiddenCpu) ?? 0
        hiddenSec = try c.decodeIfPresent(Double.self, forKey: .hiddenSec) ?? 0
        runSec = try c.decodeIfPresent(Double.self, forKey: .runSec) ?? 0
        micSec = try c.decodeIfPresent(Double.self, forKey: .micSec) ?? 0
    }
}

final class HistoryStore {
    private var days: [String: [String: DayTotals]] = [:]
    private var dirty = false
    static let keepDays = 60

    init() { days = HistoryStore.readAll() }

    static func readAll() -> [String: [String: DayTotals]] {
        guard let data = try? Data(contentsOf: Store.history),
              let d = try? JSONDecoder().decode([String: [String: DayTotals]].self, from: data) else { return [:] }
        return d
    }

    private var today: String { Store.dayFormat.string(from: Date()) }

    func add(key: String, name: String, up: UInt64, down: UInt64, cpuSec: Double, noWindow: Bool, mic: Bool, dt: Double) {
        guard dt > 0 else { return }
        var t = days[today, default: [:]][key] ?? DayTotals(name: name)
        t.name = name
        t.up += up; t.down += down
        t.runSec += dt
        if noWindow {
            t.hiddenUp += up; t.hiddenDown += down
            t.hiddenCpu += cpuSec
            t.hiddenSec += dt
        }
        if mic { t.micSec += dt }
        days[today, default: [:]][key] = t
        dirty = true
    }

    /// How long Tattle itself was watching, so a report can tell "quiet" from "wasn't looking".
    func addWatched(_ dt: Double) {
        guard dt > 0, dt < 120 else { return }
        var t = days[today, default: [:]][Store.watchedKey] ?? DayTotals(name: "Tattle")
        t.runSec += dt
        days[today, default: [:]][Store.watchedKey] = t
        dirty = true
    }

    func totals(_ key: String) -> DayTotals? { days[today]?[key] }

    func save() {
        guard dirty else { return }
        let keep = Set(days.keys.sorted().suffix(HistoryStore.keepDays))
        days = days.filter { keep.contains($0.key) }
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: Store.history, options: .atomic) }
        dirty = false
    }
}

// MARK: - Journal of notable events

struct JournalEvent: Codable {
    let t: Date
    let kind: String   // flag, mic, camera, unexplained, new_app, autostart_added, autostart_removed, permission_gained, permission_lost
    let app: String
    let text: String
}

/// What Tattle knew last time, so it can spot what changed.
struct JournalState: Codable {
    var baselined = false
    var seen: [String: String] = [:]          // app key -> name
    var autoStart: [String] = []              // "Owner — label: detail"
    var powerful: [String: [String]] = [:]    // app name -> powerful permissions it holds
}

final class Journal {
    static let shared = Journal()

    private let lock = NSLock()
    private var state: JournalState
    private var lastLogged: [String: Date] = [:]
    private var stateDirty = false
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private init() {
        if let data = try? Data(contentsOf: Store.state), let s = try? JSONDecoder().decode(JournalState.self, from: data) {
            state = s
        } else {
            state = JournalState()
        }
        // Keep the journal from growing without limit.
        if let size = (try? FileManager.default.attributesOfItem(atPath: Store.journal.path))?[.size] as? Int, size > 4_000_000,
           let text = try? String(contentsOf: Store.journal, encoding: .utf8) {
            let lines = text.split(separator: "\n")
            try? lines.suffix(lines.count / 2).joined(separator: "\n").appending("\n").write(to: Store.journal, atomically: true, encoding: .utf8)
        }
    }

    /// Append one event. `repeatAfter` stops the same thing being written over and over.
    func log(_ kind: String, app: String, _ text: String, repeatAfter: TimeInterval = 0, topic: String = "") {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if repeatAfter > 0 {
            let id = kind + "|" + app + "|" + topic
            if let last = lastLogged[id], now.timeIntervalSince(last) < repeatAfter { return }
            lastLogged[id] = now
        }
        guard var data = try? encoder.encode(JournalEvent(t: now, kind: kind, app: app, text: text)) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: Store.journal) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: Store.journal)
        }
    }

    /// Compare what's true now with what was true last time and note the differences.
    func observe(apps: [AppEntry], autoItems: [AutoItem], powerful: [String: [String]]?) {
        var notes: [(String, String, String)] = []
        lock.lock()
        let first = !state.baselined

        for e in apps where state.seen[e.id] == nil {
            state.seen[e.id] = e.name
            stateDirty = true
            if !first { notes.append(("new_app", e.name, "Seen running for the first time (" + e.status + ")")) }
        }

        let autoNow = autoItems.map { $0.ownerName + " — " + $0.label + ": " + $0.detail }
        if Set(autoNow) != Set(state.autoStart) {
            if !first {
                for a in Set(autoNow).subtracting(state.autoStart) { notes.append(("autostart_added", String(a.prefix(while: { $0 != "—" })).trimmingCharacters(in: .whitespaces), "New auto-start entry: " + a)) }
                for a in Set(state.autoStart).subtracting(autoNow) { notes.append(("autostart_removed", String(a.prefix(while: { $0 != "—" })).trimmingCharacters(in: .whitespaces), "Auto-start entry removed: " + a)) }
            }
            state.autoStart = autoNow.sorted()
            stateDirty = true
        }

        // Only compare permissions when they could actually be read; otherwise everything would look "lost".
        if let powerful, powerful != state.powerful {
            if !first && !state.powerful.isEmpty {
                for (name, perms) in powerful {
                    for p in Set(perms).subtracting(state.powerful[name] ?? []) { notes.append(("permission_gained", name, "Was given a powerful permission: " + p)) }
                }
                for (name, perms) in state.powerful {
                    for p in Set(perms).subtracting(powerful[name] ?? []) { notes.append(("permission_lost", name, "No longer has: " + p)) }
                }
            }
            state.powerful = powerful
            stateDirty = true
        }
        if first { state.baselined = true; stateDirty = true }
        lock.unlock()

        for (kind, app, text) in notes { log(kind, app: app, text) }
        for e in apps {
            for f in e.flags where f.level >= .warn {
                log("flag", app: e.name, f.text, repeatAfter: 6 * 3600, topic: f.kind)
            }
        }
    }

    func saveState() {
        lock.lock(); defer { lock.unlock() }
        guard stateDirty else { return }
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Store.state, options: .atomic) }
        stateDirty = false
    }

    static func readEvents() -> [JournalEvent] {
        guard let text = try? String(contentsOf: Store.journal, encoding: .utf8) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? d.decode(JournalEvent.self, from: Data($0.utf8)) }
    }

    static func readState() -> JournalState {
        guard let data = try? Data(contentsOf: Store.state), let s = try? JSONDecoder().decode(JournalState.self, from: data) else { return JournalState() }
        return s
    }
}

// MARK: - Plain-text report (run with: Tattle --report 14)

enum Report {
    static func run(days: Int) {
        let now = Date()
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now)) ?? now
        let wanted = Set((0..<days).compactMap { cal.date(byAdding: .day, value: $0, to: start) }.map { Store.dayFormat.string(from: $0) })
        let history = HistoryStore.readAll().filter { wanted.contains($0.key) }
        let events = Journal.readEvents().filter { $0.t >= start }
        let state = Journal.readState()
        let stamp = DateFormatter()
        stamp.dateFormat = "EEE d MMM, h:mm a"

        // Add each app's days together.
        var totals: [String: DayTotals] = [:]
        var daysSeen: [String: Int] = [:]
        var watched = 0.0
        var watchedDays = 0
        for (_, apps) in history {
            for (key, t) in apps {
                if key == Store.watchedKey { watched += t.runSec; watchedDays += 1; continue }
                var sum = totals[key] ?? DayTotals(name: t.name)
                sum.name = t.name
                sum.up += t.up; sum.down += t.down; sum.hiddenUp += t.hiddenUp; sum.hiddenDown += t.hiddenDown
                sum.hiddenCpu += t.hiddenCpu; sum.hiddenSec += t.hiddenSec; sum.runSec += t.runSec; sum.micSec += t.micSec
                totals[key] = sum
                daysSeen[key, default: 0] += 1
            }
        }

        print("TATTLE REPORT: the last \(days) days (\(Store.dayFormat.string(from: start)) to \(Store.dayFormat.string(from: now)))")
        if watchedDays == 0 {
            print("Tattle has no usage totals for this period yet. (Detailed totals began with the build that added this report.)")
        } else {
            print("Tattle was watching for about \(fmtDuration(watched)) across \(watchedDays) of those days. Anything that happened while Tattle wasn't running is not in this report.")
        }
        print("How to read this: \"hidden\" means the app was running with no window open (in the Dock only, in the menu bar only, or not visible at all). Processor time is total seconds of one processor core. Network amounts are what the app itself sent and received.")

        func section(_ title: String) { print("\n== " + title) }

        section("1. Most processor time used while hidden")
        let cpu = totals.values.filter { $0.hiddenCpu >= 30 }.sorted { $0.hiddenCpu > $1.hiddenCpu }.prefix(15)
        if cpu.isEmpty { print("Nothing notable.") }
        for t in cpu {
            let share = t.hiddenSec > 0 ? t.hiddenCpu / t.hiddenSec * 100 : 0
            print("- \(t.name): \(fmtDuration(t.hiddenCpu)) of processor time over \(fmtDuration(t.hiddenSec)) hidden (average \(String(format: "%.1f", share))% of a core)")
        }

        section("2. Most data sent or received while hidden")
        let net = totals.values.filter { $0.hiddenUp >= 1_000_000 || $0.hiddenDown >= 20_000_000 }.sorted { $0.hiddenUp > $1.hiddenUp }.prefix(15)
        if net.isEmpty { print("Nothing notable.") }
        for t in net {
            print("- \(t.name): sent \(fmtBytes(t.hiddenUp)), received \(fmtBytes(t.hiddenDown)) while hidden (all told: sent \(fmtBytes(t.up)), received \(fmtBytes(t.down)))")
        }

        section("3. Always there: apps that ran hidden the longest")
        for t in totals.values.filter({ $0.hiddenSec >= 3600 }).sorted(by: { $0.hiddenSec > $1.hiddenSec }).prefix(25) {
            print("- \(t.name): hidden for \(fmtDuration(t.hiddenSec)) of the \(fmtDuration(t.runSec)) it was running")
        }

        func grouped(_ kinds: [String]) -> [(app: String, list: [JournalEvent])] {
            Dictionary(grouping: events.filter { kinds.contains($0.kind) }, by: \.app)
                .map { ($0.key, $0.value.sorted { $0.t < $1.t }) }.sorted { $0.list.count > $1.list.count }
        }

        section("4. Microphone and camera")
        let micTotals = totals.values.filter { $0.micSec >= 5 }.sorted { $0.micSec > $1.micSec }
        for t in micTotals { print("- \(t.name): microphone open for about \(fmtDuration(t.micSec)) in total") }
        let mic = grouped(["mic"])
        for g in mic {
            let odd = g.list.filter { $0.text.contains("no click or shortcut") }.count
            print("- \(g.app): started using the microphone \(g.list.count) time(s), \(odd) of them with no key press or click just before. Last: \(stamp.string(from: g.list.last!.t))")
        }
        for g in grouped(["camera"]) {
            print("- Camera switched on \(g.list.count) time(s). \(g.app). Last: \(stamp.string(from: g.list.last!.t))")
        }
        if micTotals.isEmpty && mic.isEmpty && grouped(["camera"]).isEmpty { print("No microphone or camera use recorded.") }

        section("5. Things Tattle flagged")
        let flags = grouped(["flag"])
        if flags.isEmpty { print("Nothing flagged.") }
        for g in flags {
            print("- \(g.app): flagged \(g.list.count) time(s), from \(stamp.string(from: g.list.first!.t)) to \(stamp.string(from: g.list.last!.t))")
            for text in Set(g.list.map(\.text)).prefix(4) { print("    • " + text) }
        }

        section("6. Apps that came forward or launched with nothing you did to explain it")
        let odd = Dictionary(grouping: events.filter { $0.kind == "unexplained" }, by: { $0.app })
            .map { ($0.key, $0.value.sorted { $0.t < $1.t }) }.sorted { $0.1.count > $1.1.count }
        if odd.isEmpty { print("None recorded.") }
        for (app, list) in odd.prefix(20) {
            let afterFn = list.filter { $0.text.contains("pressed fn") }.count
            print("- \(app): \(list.count) time(s)\(afterFn > 0 ? ", \(afterFn) of them right after the fn key" : ""). Last: \(stamp.string(from: list.last!.t)) (\(list.last!.text))")
        }

        section("7. What changed during the period")
        let changes = events.filter { ["new_app", "autostart_added", "autostart_removed", "permission_gained", "permission_lost"].contains($0.kind) }
        if changes.isEmpty { print("No new apps, auto-start entries or permission changes recorded.") }
        for e in changes.suffix(60) { print("- \(stamp.string(from: e.t)): \(e.app): \(e.text)") }

        section("8. Standing situation right now")
        print("Set to start by themselves (\(state.autoStart.count)):")
        for a in state.autoStart { print("- " + a) }
        print("Apps holding powerful permissions (\(state.powerful.count)):")
        for (name, perms) in state.powerful.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            print("- \(name): " + perms.map { $0.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression) }.joined(separator: "; "))
        }
        if state.powerful.isEmpty { print("(Not known: Tattle could not read the permission list.)") }
    }
}
