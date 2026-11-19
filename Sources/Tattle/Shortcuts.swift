import AppKit
import ApplicationServices

// MARK: - Key combinations

struct KeyCombo: Hashable {
    static let cmd = 1, shift = 2, opt = 4, ctrl = 8, fn = 16

    var keyCode: Int   // -1 means "modifier keys only" (e.g. fn pressed by itself)
    var mods: Int

    init(keyCode: Int, mods: Int) {
        var m = mods
        // Arrow and function keys always report "fn"; that isn't part of the shortcut.
        if keyCode >= 96 { m &= ~KeyCombo.fn }
        self.keyCode = keyCode
        self.mods = m
    }

    /// Cocoa-style modifier flags (as stored by most Mac apps).
    init(keyCode: Int, cocoaFlags f: Int) {
        var m = 0
        if f & (1 << 20) != 0 { m |= KeyCombo.cmd }
        if f & (1 << 17) != 0 { m |= KeyCombo.shift }
        if f & (1 << 19) != 0 { m |= KeyCombo.opt }
        if f & (1 << 18) != 0 { m |= KeyCombo.ctrl }
        if f & (1 << 23) != 0 { m |= KeyCombo.fn }
        self.init(keyCode: keyCode, mods: m)
    }

    /// Old Carbon-style modifier flags.
    init(keyCode: Int, carbonFlags f: Int) {
        var m = 0
        if f & 256 != 0 { m |= KeyCombo.cmd }
        if f & 512 != 0 { m |= KeyCombo.shift }
        if f & 2048 != 0 { m |= KeyCombo.opt }
        if f & 4096 != 0 { m |= KeyCombo.ctrl }
        self.init(keyCode: keyCode, mods: m)
    }

    var isFnAlone: Bool { keyCode == -1 && mods == KeyCombo.fn }

    var display: String {
        if isFnAlone { return "fn (Globe) by itself" }
        var s = ""
        if mods & KeyCombo.fn != 0 { s += "fn " }
        if mods & KeyCombo.ctrl != 0 { s += "⌃" }
        if mods & KeyCombo.opt != 0 { s += "⌥" }
        if mods & KeyCombo.shift != 0 { s += "⇧" }
        if mods & KeyCombo.cmd != 0 { s += "⌘" }
        if keyCode >= 0 { return s + KeyNames.name(keyCode) }
        // Modifier keys held with nothing else.
        var names: [String] = []
        if mods & KeyCombo.fn != 0 { names.append("fn") }
        if mods & KeyCombo.ctrl != 0 { names.append("⌃ Control") }
        if mods & KeyCombo.opt != 0 { names.append("⌥ Option") }
        if mods & KeyCombo.shift != 0 { names.append("⇧ Shift") }
        if mods & KeyCombo.cmd != 0 { names.append("⌘ Command") }
        return names.joined(separator: " + ") + (names.count > 1 ? " held together" : " by itself")
    }
}

enum KeyNames {
    static let table: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc", 57: "Caps Lock",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
        118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    static let reverse: [String: Int] = {
        var r: [String: Int] = [:]
        for (k, v) in table { r[v.lowercased()] = k }
        r["pagedown"] = 121; r["pageup"] = 116; r["escape"] = 53; r["enter"] = 36; r["backspace"] = 51
        r["up"] = 126; r["down"] = 125; r["left"] = 123; r["right"] = 124; r["capslock"] = 57; r["plus"] = 24
        return r
    }()
    static func name(_ code: Int) -> String { table[code] ?? "key \(code)" }
    static func code(_ name: String) -> Int? { reverse[name.lowercased()] }
}

struct ShortcutEntry: Hashable, Identifiable {
    let owner: String
    let action: String
    let combo: KeyCombo
    let global: Bool
    var appPath: String? = nil
    var running = true
    var id: String { owner + "|" + action + "|" + combo.display }
}

struct Conflict: Identifiable {
    let combo: KeyCombo
    let entries: [ShortcutEntry]
    var id: String { combo.display }
}

/// A global shortcut that takes a key combination away from a menu command inside an app.
struct Shadow: Identifiable {
    let combo: KeyCombo
    let global: ShortcutEntry
    let victims: [ShortcutEntry]
    var id: String { combo.display + global.owner }
}

struct ShortcutReport {
    var globals: [ShortcutEntry] = []
    var conflicts: [Conflict] = []
    var shadows: [Shadow] = []
    var listeners: [String] = []
    var listenersKnown = false
    var keyRemappers: [String] = []
    var menuScanned = false
    var menuApps = 0
    var menuShortcuts = 0
    var scanning = false
    var loaded = false
}

// MARK: - Finding shortcuts

enum ShortcutScanner {
    // macOS's own shortcuts, by the internal number macOS gives each one.
    static let systemNames: [Int: String] = [
        7: "Move focus to the menu bar", 8: "Move focus to the Dock", 9: "Move focus to the active window",
        10: "Move focus to the toolbar", 11: "Move focus to the floating window",
        12: "Turn keyboard access on or off", 13: "Change the way Tab moves focus",
        27: "Move focus to next window", 28: "Save picture of screen as a file", 29: "Copy picture of screen",
        30: "Save picture of selected area", 31: "Copy picture of selected area", 32: "Mission Control",
        33: "Application windows", 36: "Show Desktop", 52: "Turn Dock hiding on or off",
        57: "Move focus to status menus", 59: "Turn VoiceOver on or off", 60: "Select previous input source",
        61: "Select next input source", 64: "Spotlight search", 65: "Finder search window",
        79: "Move left a desktop", 81: "Move right a desktop", 118: "Switch to Desktop 1",
        119: "Switch to Desktop 2", 120: "Switch to Desktop 3", 121: "Switch to Desktop 4",
        160: "Launchpad", 163: "Show Notification Center", 175: "Turn Do Not Disturb on or off",
        184: "Screenshot and recording options", 190: "Quick Note",
    ]
    // Used when the user has never changed them (macOS then stores nothing).
    static let systemDefaults: [(Int, Int, Int)] = [
        (64, 49, KeyCombo.cmd), (65, 49, KeyCombo.cmd | KeyCombo.opt),
        (28, 20, KeyCombo.cmd | KeyCombo.shift), (29, 20, KeyCombo.cmd | KeyCombo.shift | KeyCombo.ctrl),
        (30, 21, KeyCombo.cmd | KeyCombo.shift), (31, 21, KeyCombo.cmd | KeyCombo.shift | KeyCombo.ctrl),
        (184, 23, KeyCombo.cmd | KeyCombo.shift), (32, 126, KeyCombo.ctrl), (33, 125, KeyCombo.ctrl),
        (79, 123, KeyCombo.ctrl), (81, 124, KeyCombo.ctrl), (27, 50, KeyCombo.cmd),
        (52, 2, KeyCombo.cmd | KeyCombo.opt),
    ]

    static func system() -> [ShortcutEntry] {
        var out: [ShortcutEntry] = []
        let stored = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
        var seen = Set<Int>()
        for (idString, raw) in stored {
            guard let id = Int(idString), let name = systemNames[id], let d = raw as? [String: Any] else { continue }
            seen.insert(id)
            let enabled = (d["enabled"] as? NSNumber)?.boolValue ?? false
            guard enabled, let value = d["value"] as? [String: Any],
                  let params = value["parameters"] as? [NSNumber], params.count >= 3 else { continue }
            let code = params[1].intValue
            guard code != 65535 else { continue }
            out.append(ShortcutEntry(owner: "macOS", action: name,
                                     combo: KeyCombo(keyCode: code, cocoaFlags: params[2].intValue), global: true))
        }
        for (id, code, mods) in systemDefaults where !seen.contains(id) {
            out.append(ShortcutEntry(owner: "macOS", action: systemNames[id] ?? "System shortcut",
                                     combo: KeyCombo(keyCode: code, mods: mods), global: true))
        }
        out.append(ShortcutEntry(owner: "macOS", action: "Switch between apps", combo: KeyCombo(keyCode: 48, mods: KeyCombo.cmd), global: true))
        out.append(ShortcutEntry(owner: "macOS", action: "Force Quit window", combo: KeyCombo(keyCode: 53, mods: KeyCombo.cmd | KeyCombo.opt), global: true))
        out.append(ShortcutEntry(owner: "macOS", action: "Lock screen", combo: KeyCombo(keyCode: 12, mods: KeyCombo.cmd | KeyCombo.ctrl), global: true))

        // What the Globe / fn key does when pressed by itself.
        let fnUse = (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? NSNumber)?.intValue ?? 0
        let fnNames = [1: "Change input source", 2: "Show Emoji & Symbols", 3: "Start Dictation"]
        if let n = fnNames[fnUse] {
            out.append(ShortcutEntry(owner: "macOS", action: "Globe key: " + n, combo: KeyCombo(keyCode: -1, mods: KeyCombo.fn), global: true))
        }
        return out
    }

    /// "quickSearchShortcut" -> "Quick search"
    static func pretty(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "KeyboardShortcuts_", with: "")
        if s == "accelerator" { s = "Quick entry" }
        s = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        var words = ""
        for ch in s {
            if ch.isUppercase, let last = words.last, last.isLowercase { words.append(" ") }
            words.append(ch)
        }
        words = words.trimmingCharacters(in: .whitespaces).lowercased()
        if words.isEmpty { return "Shortcut" }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// Recognise the common ways Mac apps store a shortcut in their settings.
    static func combo(fromDict d: [String: Any]) -> KeyCombo? {
        var code: Int?
        var mods: Int?
        var carbon = false
        for (k, v) in d {
            switch k.lowercased() {
            case "keycode", "key_code", "carbonkeycode": code = int(v)
            case "carbonmodifiers", "carbonflags": mods = int(v); carbon = true
            case "modifierflags", "modifiers", "modifier", "cocoamodifiers": if mods == nil { mods = int(v) }
            default: break
            }
        }
        guard let code, let mods, code >= 0, code < 128 else { return nil }
        let c = (carbon || mods < 65536) ? KeyCombo(keyCode: code, carbonFlags: mods) : KeyCombo(keyCode: code, cocoaFlags: mods)
        if c.mods == 0 && code < 96 { return nil }
        return c
    }

    /// Electron-style text shortcuts such as "Alt+Space" or "shift+command+j".
    static func combo(fromAccelerator text: String) -> KeyCombo? {
        let parts = text.split(whereSeparator: { $0 == "+" || $0 == "-" }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !parts.isEmpty, parts.count <= 5 else { return nil }
        var mods = 0
        var code = -1
        for p in parts {
            switch p {
            case "command", "cmd", "commandorcontrol", "cmdorctrl", "super", "meta": mods |= KeyCombo.cmd
            case "control", "ctrl": mods |= KeyCombo.ctrl
            case "alt", "option", "opt", "altgr": mods |= KeyCombo.opt
            case "shift": mods |= KeyCombo.shift
            case "fn", "globe": mods |= KeyCombo.fn
            default:
                guard code == -1, let c = KeyNames.code(p) else { return nil }
                code = c
            }
        }
        if code == -1 && mods == 0 { return nil }
        if mods == 0 && code < 96 && code != 57 { return nil }
        return KeyCombo(keyCode: code, mods: mods)
    }

    /// Plain ⌘-letter shortcuts are almost always menu commands inside one app, not system-wide.
    private static func plausibleGlobal(_ c: KeyCombo) -> Bool {
        if c.mods == KeyCombo.cmd, c.keyCode >= 0, c.keyCode < 48, c.keyCode != 36 { return false }
        return true
    }

    private static func walkPlist(_ obj: Any, name: String, owner: String, depth: Int, out: inout [ShortcutEntry]) {
        guard out.count < 80 else { return }
        if let d = obj as? [String: Any] {
            if let c = combo(fromDict: d) {
                if plausibleGlobal(c) { out.append(ShortcutEntry(owner: owner, action: pretty(name), combo: c, global: true)) }
                return
            }
            guard depth < 4 else { return }
            for (k, v) in d {
                if k.hasPrefix("KeyboardShortcuts_"), let s = v as? String, let data = s.data(using: .utf8),
                   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = combo(fromDict: j) {
                    if plausibleGlobal(c) { out.append(ShortcutEntry(owner: owner, action: pretty(k), combo: c, global: true)) }
                } else {
                    walkPlist(v, name: k, owner: owner, depth: depth + 1, out: &out)
                }
            }
        } else if let s = obj as? String, name.range(of: "hotkey|shortcut", options: [.regularExpression, .caseInsensitive]) != nil {
            // Raycast style: "Command-49"
            let bits = s.split(separator: "-")
            if bits.count >= 2, let code = Int(bits.last!), code < 128 {
                let modText = bits.dropLast().joined(separator: "+")
                if let m = combo(fromAccelerator: modText + "+space") {
                    out.append(ShortcutEntry(owner: owner, action: pretty(name), combo: KeyCombo(keyCode: code, mods: m.mods), global: true))
                }
            } else if let c = combo(fromAccelerator: s) {
                out.append(ShortcutEntry(owner: owner, action: pretty(name), combo: c, global: true))
            }
        }
    }

    private static func walkJSON(_ obj: Any, name: String, owner: String, depth: Int, out: inout [ShortcutEntry]) {
        guard depth < 6, out.count < 80 else { return }
        if let d = obj as? [String: Any] {
            for (k, v) in d { walkJSON(v, name: k, owner: owner, depth: depth + 1, out: &out) }
        } else if let s = obj as? String, !s.isEmpty, s.count < 40,
                  name.range(of: "shortcut|hotkey|accelerator", options: [.regularExpression, .caseInsensitive]) != nil,
                  let c = combo(fromAccelerator: s), plausibleGlobal(c) {
            out.append(ShortcutEntry(owner: owner, action: pretty(name), combo: c, global: true))
        }
    }

    /// Wispr Flow stores shortcuts as lists of raw key numbers, e.g. "55+59+9".
    private static func wisprFlow() -> [ShortcutEntry] {
        let path = NSHomeDirectory() + "/Library/Application Support/Wispr Flow/config.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefs = root["prefs"] as? [String: Any], let user = prefs["user"] as? [String: Any],
              let shortcuts = user["shortcuts"] as? [String: Any] else { return [] }
        let modCodes: [Int: Int] = [55: KeyCombo.cmd, 54: KeyCombo.cmd, 56: KeyCombo.shift, 60: KeyCombo.shift,
                                    58: KeyCombo.opt, 61: KeyCombo.opt, 59: KeyCombo.ctrl, 62: KeyCombo.ctrl, 63: KeyCombo.fn]
        let names = ["ptt": "Dictate (push to talk)", "popo": "Hands-free dictation", "lens": "Flow Lens",
                     "paste_last_text": "Paste last dictation", "copy_last_text": "Copy last dictation",
                     "undo": "Undo dictation", "dismiss": "Cancel dictation"]
        var out: [ShortcutEntry] = []
        for (keys, action) in shortcuts {
            let codes = keys.split(separator: "+").compactMap { Int($0) }
            guard !codes.isEmpty, !codes.contains(65535) else { continue }
            var mods = 0
            var key = -1
            for c in codes { if let m = modCodes[c] { mods |= m } else { key = c } }
            if mods == 0 { continue }   // plain keys like Esc only apply while dictating
            let act = (action as? String) ?? "Shortcut"
            out.append(ShortcutEntry(owner: "Wispr Flow", action: names[act] ?? pretty(act),
                                     combo: KeyCombo(keyCode: key, mods: mods), global: true))
        }
        return out
    }

    /// Global shortcuts that other apps have saved in their settings (best effort).
    static func appGlobals(index: AppIndex) -> [ShortcutEntry] {
        let wisprPath = index.path(forAppNamed: "Wispr Flow")
        var out: [ShortcutEntry] = wisprFlow().map { var e = $0; e.appPath = wisprPath; return e }
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // Standard settings files.
        var plists: [(String, String)] = []   // (path, bundle id)
        let prefDir = home + "/Library/Preferences"
        for f in (try? fm.contentsOfDirectory(atPath: prefDir)) ?? [] where f.hasSuffix(".plist") && !f.hasPrefix("com.apple.") {
            plists.append((prefDir + "/" + f, (f as NSString).deletingPathExtension))
        }
        // Other apps' private folders are only readable with Full Disk Access. Trying without it makes
        // macOS show "Data Access Blocked" notices, so don't.
        let contDir = home + "/Library/Containers"
        let fullAccess = access(Privacy.systemDB, R_OK) == 0
        for c in (fullAccess ? (try? fm.contentsOfDirectory(atPath: contDir)) ?? [] : []) where !c.hasPrefix("com.apple.") {
            let p = contDir + "/" + c + "/Data/Library/Preferences/" + c + ".plist"
            if fm.fileExists(atPath: p) { plists.append((p, c)) }
        }
        for (path, id) in plists {
            guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size < 3_000_000,
                  let d = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            // Skip leftovers from apps that are no longer installed.
            guard let appPath = index.path(forBundleID: id) else { continue }
            let owner = index.info(appPath).name
            if owner == "Wispr Flow" { continue }
            var found: [ShortcutEntry] = []
            walkPlist(d, name: "", owner: owner, depth: 0, out: &found)
            out += found.map { var e = $0; e.appPath = appPath; return e }
        }

        // Electron-style apps keep JSON settings in Application Support.
        let supDir = home + "/Library/Application Support"
        let wanted = ["config.json", "state.json", "settings.json", "preferences.json", "user-preferences.json", "claude_desktop_config.json"]
        for dir in (try? fm.contentsOfDirectory(atPath: supDir)) ?? [] where dir != "Wispr Flow" && !dir.hasPrefix("com.apple.") {
            guard let appPath = index.path(forAppNamed: dir) else { continue }
            let owner = index.info(appPath).name
            for file in wanted {
                let p = supDir + "/" + dir + "/" + file
                guard let size = (try? fm.attributesOfItem(atPath: p))?[.size] as? Int, size < 1_000_000,
                      let data = fm.contents(atPath: p), let j = try? JSONSerialization.jsonObject(with: data) else { continue }
                var found: [ShortcutEntry] = []
                walkJSON(j, name: "", owner: owner, depth: 0, out: &found)
                out += found.map { var e = $0; e.appPath = appPath; return e }
            }
        }
        // Remove exact duplicates.
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    // MARK: Menu shortcuts inside apps (needs Accessibility permission)

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func number(_ el: AXUIElement, _ attr: String) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.intValue
    }

    static func menuShortcuts(pid: pid_t, appName: String) -> [ShortcutEntry] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &v) == .success,
              let ref = v, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return [] }
        let bar = ref as! AXUIElement
        var out: [ShortcutEntry] = []
        var budget = 2500
        let deadline = Date().addingTimeInterval(6)

        func visit(_ el: AXUIElement, path: String, depth: Int) {
            guard depth < 5, budget > 0, Date() < deadline else { return }
            for item in children(el) {
                budget -= 1
                if budget <= 0 { return }
                let title = string(item, kAXTitleAttribute as String) ?? ""
                let ch = string(item, kAXMenuItemCmdCharAttribute as String) ?? ""
                let vk = number(item, kAXMenuItemCmdVirtualKeyAttribute as String)
                if !title.isEmpty, !ch.isEmpty || vk != nil {
                    let m = number(item, kAXMenuItemCmdModifiersAttribute as String) ?? 0
                    var mods = 0
                    if m & 1 != 0 { mods |= KeyCombo.shift }
                    if m & 2 != 0 { mods |= KeyCombo.opt }
                    if m & 4 != 0 { mods |= KeyCombo.ctrl }
                    if m & 8 == 0 { mods |= KeyCombo.cmd }
                    let code = ch.isEmpty ? vk : (KeyNames.code(ch) ?? vk)
                    if let code, mods != 0 || code >= 96 {
                        out.append(ShortcutEntry(owner: appName, action: path.isEmpty ? title : path + " → " + title,
                                                 combo: KeyCombo(keyCode: code, mods: mods), global: false))
                    }
                }
                let sub = children(item)
                if !sub.isEmpty { visit(item, path: depth == 0 ? title : path, depth: depth + 1) }
            }
        }
        // Skip the Apple menu (first item); it's the same in every app.
        for top in children(bar).dropFirst() {
            let title = string(top, kAXTitleAttribute as String) ?? ""
            visit(top, path: title, depth: 1)
        }
        return out
    }

    /// Does this app own a menu bar icon? (Needs Accessibility permission.)
    static func hasMenuBarIcon(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &v) == .success,
              let ref = v, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        return !children(ref as! AXUIElement).isEmpty
    }

    // MARK: Putting it together

    static func analyse(globals: [ShortcutEntry], inApp: [ShortcutEntry]) -> (conflicts: [Conflict], shadows: [Shadow]) {
        var byCombo: [KeyCombo: [ShortcutEntry]] = [:]
        // A shortcut only exists while its app is running.
        for g in globals where g.running { byCombo[g.combo, default: []].append(g) }
        var conflicts: [Conflict] = []
        // Two halves of the same product (e.g. "Setapp" and "SetappLauncher") don't count as a clash.
        func family(_ owner: String) -> String {
            String(owner.lowercased().prefix { $0.isLetter || $0.isNumber }.prefix(6))
        }
        for (combo, list) in byCombo where Set(list.map { family($0.owner) }).count > 1 {
            conflicts.append(Conflict(combo: combo, entries: list.sorted { $0.owner < $1.owner }))
        }
        conflicts.sort { ($0.combo.isFnAlone ? 0 : 1, $0.combo.display) < ($1.combo.isFnAlone ? 0 : 1, $1.combo.display) }

        var victims: [KeyCombo: [ShortcutEntry]] = [:]
        for e in inApp { victims[e.combo, default: []].append(e) }
        var shadows: [Shadow] = []
        for g in globals where g.owner != "macOS" && g.running {
            guard let v = victims[g.combo] else { continue }
            let others = v.filter { $0.owner != g.owner }
            if !others.isEmpty { shadows.append(Shadow(combo: g.combo, global: g, victims: others)) }
        }
        shadows.sort { $0.victims.count > $1.victims.count }
        return (conflicts, shadows)
    }
}
