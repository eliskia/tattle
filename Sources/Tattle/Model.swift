import Foundation
import Darwin

/// Where an app is, from the user's point of view.
enum Presence: Int {
    case onScreen       // has a window you can see right now
    case elsewhere      // has a window on another desktop, or minimized
    case dockNoWindow   // sitting in the Dock with no window
    case hidden         // no window and no Dock icon
}

enum Level: Int, Comparable {
    case note = 1, warn, alert
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

struct Flag: Hashable, Identifiable {
    let kind: String
    let level: Level
    let text: String
    var id: String { kind }
}

/// One running process that belongs to an app.
struct Piece: Hashable, Identifiable {
    let pid: pid_t
    let name: String
    let cpu: Double
    let mem: UInt64
    let root: Bool
    var id: pid_t { pid }
}

struct Permission: Hashable, Identifiable {
    let text: String
    let powerful: Bool
    var id: String { text }
}

/// Something set up to start by itself (at login, at boot, or on a timer).
struct AutoItem: Hashable, Identifiable {
    let label: String
    let program: String
    let detail: String
    let appKey: String?
    let ownerName: String
    var id: String { label + "|" + detail }
}

struct AppEntry: Identifiable {
    let id: String
    var name: String
    var bundlePath: String?
    var bundleID: String?
    var isTool = false
    var presence: Presence = .hidden
    var inDock = false
    var mainRunning = false
    var menuBarIcon = false
    var addOnOnly = false
    var anyRoot = false
    var mainPid: pid_t?
    var pieces: [Piece] = []
    var cpu = 0.0            // % of one processor core, right now
    var cpuMinute = 0.0      // average over the last minute
    var cpuTenMin = 0.0      // average over the last ten minutes
    var mem: UInt64 = 0
    var upRate = 0.0         // bytes per second
    var downRate = 0.0
    var up10: UInt64 = 0     // last ten minutes
    var down10: UInt64 = 0
    var upToday: UInt64 = 0
    var downToday: UInt64 = 0
    var hiddenCpuToday = 0.0 // seconds of processor time used with no window open
    var mic = false
    var permissions: [Permission] = []
    var sensitive: [String] = []
    var folderNotes: [String] = []
    var autoStart: [AutoItem] = []
    var flags: [Flag] = []
    var trusted = false
    var status = ""

    var worst: Level? { flags.map(\.level).max() }
    /// Doing something right now (as opposed to just sitting in memory).
    var isBusy: Bool { needsLook || mic || cpuMinute >= 0.5 || upRate >= 512 || downRate >= 512 || up10 + down10 >= 200_000 }
    var needsLook: Bool { (worst ?? .note) >= .warn }
    var powerful: [Permission] { permissions.filter(\.powerful) }
}

struct Snapshot {
    var apps: [AppEntry] = []
    var micNames: [String] = []
    var micHidden = false
    var cameraOn = false
    var cameraSuspects: [String] = []
    var cameraHidden = false
    var systemHidden = 0
    var hasFDA = false
    var hasAX = false
    var diag = ""
    var everydayPermsKnown = false
    var autoItems: [AutoItem] = []
    var updated = Date.distantPast
    var ready = false

    var flagged: [AppEntry] { apps.filter(\.needsLook) }
    var hidden: [AppEntry] { apps.filter { $0.presence == .hidden && !$0.addOnOnly } }
    var addOns: [AppEntry] { apps.filter { $0.presence == .hidden && $0.addOnOnly } }
    var dockOnly: [AppEntry] { apps.filter { $0.presence == .dockNoWindow } }
    var visible: [AppEntry] { apps.filter { $0.presence == .onScreen || $0.presence == .elsewhere } }
    var worst: Level? {
        var levels = flagged.compactMap(\.worst)
        if micHidden || cameraHidden { levels.append(.alert) }
        return levels.max()
    }
}
