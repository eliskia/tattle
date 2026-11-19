import Foundation
import Darwin
import SQLite3

// MARK: - Permissions the user has granted (macOS privacy database)

struct Grant {
    let service: String
    let client: String
    let isPath: Bool
    let target: String?
}

enum Privacy {
    static let userDB = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    static let systemDB = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// Why the last attempt to read the database failed (for troubleshooting).
    static var lastError = ""

    /// False on macOS versions that keep microphone, camera and folder permissions where apps can't read them.
    static var userStoreReadable = false

    /// Returns nil when macOS won't let us read the database (no file access granted yet).
    /// The system-wide store holds the powerful permissions; the per-user store (older macOS) holds the rest.
    static func grants() -> [Grant]? {
        lastError = ""
        guard let system = read(systemDB) else { return nil }
        let user = FileManager.default.fileExists(atPath: userDB) ? read(userDB) : nil
        userStoreReadable = user != nil
        return system + (user ?? [])
    }

    /// Optional wording overrides, so new macOS permission names can be described without rebuilding the app.
    /// File: ~/Library/Application Support/Tattle/permissions.json
    /// { "kTCCServiceSomething": { "text": "Can do X", "powerful": true, "hide": false, "role": "camera" | "keys" } }
    static func overrides() -> [String: [String: Any]] {
        let path = NSHomeDirectory() + "/Library/Application Support/Tattle/permissions.json"
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
        return j
    }

    private static func read(_ path: String) -> [Grant]? {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            let readable = access(path, R_OK) == 0
            lastError += "[open failed: \(why); readable=\(readable) errno=\(readable ? 0 : errno); exists=\(FileManager.default.fileExists(atPath: path)) \((path as NSString).lastPathComponent) in \(path.hasPrefix("/Library") ? "system" : "user") store] "
            sqlite3_close(db)
            db = nil
            let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1"
            if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
                sqlite3_close(db)
                return nil
            }
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT service, client, client_type, auth_value, indirect_object_identifier FROM access"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            lastError += "[query failed: \(String(cString: sqlite3_errmsg(db)))] "
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        var out: [Grant] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard sqlite3_column_int(stmt, 3) >= 2,   // 2 = allowed, 3 = limited
                  let s = sqlite3_column_text(stmt, 0), let c = sqlite3_column_text(stmt, 1) else { continue }
            let target = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            out.append(Grant(service: String(cString: s), client: String(cString: c),
                             isPath: sqlite3_column_int(stmt, 2) == 1,
                             target: (target == "UNUSED" || target?.isEmpty == true) ? nil : target))
        }
        return out
    }

    /// Plain-English meaning of each macOS permission. `powerful` marks the ones worth knowing about.
    static func describe(_ g: Grant, targetName: (String) -> String, overrides: [String: [String: Any]] = [:]) -> Permission? {
        if let o = overrides[g.service] {
            if (o["hide"] as? Bool) == true { return nil }
            if let t = o["text"] as? String { return Permission(text: t, powerful: (o["powerful"] as? Bool) ?? false) }
        }
        switch g.service {
        case "kTCCServiceSystemPolicyAllFiles":
            return Permission(text: "Can read every file on your Mac, including Messages and Mail (Full Disk Access)", powerful: true)
        case "kTCCServiceAccessibility":
            return Permission(text: "Can control your Mac and watch what you type (Accessibility)", powerful: true)
        case "kTCCServiceListenEvent":
            return Permission(text: "Can see every key you press (Input Monitoring)", powerful: true)
        case "kTCCServiceScreenCapture":
            return Permission(text: "Can record your screen", powerful: true)
        case "kTCCServicePostEvent":
            return Permission(text: "Can press keys and click on your behalf", powerful: true)
        case "kTCCServiceDeveloperTool":
            return Permission(text: "Can run software that skips some macOS security checks (Developer Tool)", powerful: true)
        case "kTCCServiceSystemPolicyAppData":
            return Permission(text: "Can read other apps' private data", powerful: true)
        case "kTCCServiceMicrophone": return Permission(text: "Can use the microphone", powerful: false)
        case "kTCCServiceCamera": return Permission(text: "Can use the camera", powerful: false)
        case "kTCCServiceAppleEvents":
            guard let t = g.target else { return nil }
            return Permission(text: "Can control " + targetName(t), powerful: false)
        case "kTCCServiceAddressBook": return Permission(text: "Can read your Contacts", powerful: false)
        case "kTCCServiceCalendar": return Permission(text: "Can read your Calendar", powerful: false)
        case "kTCCServiceReminders": return Permission(text: "Can read your Reminders", powerful: false)
        case "kTCCServicePhotos": return Permission(text: "Can see your Photos", powerful: false)
        case "kTCCServiceSystemPolicyDocumentsFolder": return Permission(text: "Can read your Documents folder", powerful: false)
        case "kTCCServiceSystemPolicyDesktopFolder": return Permission(text: "Can read your Desktop folder", powerful: false)
        case "kTCCServiceSystemPolicyDownloadsFolder": return Permission(text: "Can read your Downloads folder", powerful: false)
        case "kTCCServiceSystemPolicyNetworkVolumes": return Permission(text: "Can read network drives", powerful: false)
        case "kTCCServiceSystemPolicyRemovableVolumes": return Permission(text: "Can read external drives", powerful: false)
        case "kTCCServiceSpeechRecognition": return Permission(text: "Can use speech recognition", powerful: false)
        case "kTCCServiceBluetoothAlways": return Permission(text: "Can use Bluetooth", powerful: false)
        case "kTCCServiceUbiquity", "kTCCServiceLiverpool", "kTCCServiceWebKitIntelligentTrackingPrevention",
             "kTCCServiceFileProviderDomain", "kTCCServiceFileProviderPresence", "kTCCServiceUserTracking":
            return nil
        default:
            // A permission this version of Tattle doesn't have wording for: show its macOS name rather than hide it.
            let raw = g.service.replacingOccurrences(of: "kTCCService", with: "").replacingOccurrences(of: "SystemPolicy", with: "")
            return Permission(text: "Has the “" + ShortcutScanner.pretty(raw) + "” permission", powerful: false)
        }
    }
}

// MARK: - Files an app has open right now

struct SensitiveSpot {
    let prefix: String
    let what: String
    let ownerPrefix: String?   // bundle-id prefix of the app that legitimately owns it
    let nameFilter: [String]?
}

enum OpenFiles {
    static let home = NSHomeDirectory()

    static let spots: [SensitiveSpot] = [
        SensitiveSpot(prefix: home + "/Library/Messages/", what: "your Messages history", ownerPrefix: nil, nameFilter: nil),
        SensitiveSpot(prefix: home + "/Library/Mail/", what: "your Mail", ownerPrefix: nil, nameFilter: nil),
        SensitiveSpot(prefix: home + "/Library/Safari/", what: "your Safari history and bookmarks", ownerPrefix: nil, nameFilter: nil),
        SensitiveSpot(prefix: home + "/Library/Application Support/AddressBook/", what: "your Contacts", ownerPrefix: nil, nameFilter: nil),
        SensitiveSpot(prefix: home + "/Library/Calendars/", what: "your Calendar", ownerPrefix: nil, nameFilter: nil),
        SensitiveSpot(prefix: home + "/Library/Group Containers/group.com.apple.notes/", what: "your Notes", ownerPrefix: nil, nameFilter: nil),
        SensitiveSpot(prefix: home + "/Pictures/Photos Library.photoslibrary/", what: "your Photos library", ownerPrefix: nil, nameFilter: nil),
        SensitiveSpot(prefix: home + "/.ssh/", what: "your SSH keys", ownerPrefix: nil, nameFilter: nil),
        SensitiveSpot(prefix: home + "/Library/Application Support/Google/Chrome/", what: "Chrome's saved cookies and logins",
                      ownerPrefix: "com.google.", nameFilter: ["Cookies", "Login Data", "History"]),
    ]

    static let folders: [(String, String)] = [
        (home + "/Documents/", "Documents"), (home + "/Desktop/", "Desktop"), (home + "/Downloads/", "Downloads"),
    ]

    /// Paths of regular files a process currently has open. Empty if macOS won't let us look.
    static func paths(of pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride + 8
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return [] }
        let n = Int(got) / MemoryLayout<proc_fdinfo>.stride
        var out: [String] = []
        for fd in fds.prefix(n) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard r > 0 else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }

    /// What private data (if any) do these open files touch?
    static func assess(paths: [String], bundleID: String?) -> (sensitive: [String], folders: [String]) {
        var hits: [String] = []
        var counts: [String: Int] = [:]
        for p in paths {
            for s in spots where p.hasPrefix(s.prefix) {
                if let owner = s.ownerPrefix, (bundleID ?? "").hasPrefix(owner) { continue }
                if let names = s.nameFilter, !names.contains((p as NSString).lastPathComponent) { continue }
                if !hits.contains(s.what) { hits.append(s.what) }
            }
            for (prefix, name) in folders where p.hasPrefix(prefix) { counts[name, default: 0] += 1 }
        }
        let notes = counts.sorted { $0.key < $1.key }.map {
            "Has \($0.value) file\($0.value == 1 ? "" : "s") open in your \($0.key) folder"
        }
        return (hits, notes)
    }
}
