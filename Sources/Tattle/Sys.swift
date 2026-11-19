import Foundation
import Darwin

/// Low-level helpers for asking macOS about processes.
struct KProc {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
}

enum Sys {
    static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    /// Every process on the machine (pid, parent, owner).
    static func allProcesses() -> [KProc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let cap = size / MemoryLayout<kinfo_proc>.stride + 64
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: cap)
        size = cap * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        return buf.prefix(n).compactMap {
            let pid = $0.kp_proc.p_pid
            return pid > 0 ? KProc(pid: pid, ppid: $0.kp_eproc.e_ppid, uid: $0.kp_eproc.e_ucred.cr_uid) : nil
        }
    }

    static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    /// Total processor time used so far (nanoseconds) and memory footprint (bytes).
    static func usage(of pid: pid_t) -> (cpuNs: UInt64, mem: UInt64)? {
        var ri = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard r == 0 else { return nil }
        let ticks = ri.ri_user_time &+ ri.ri_system_time
        let ns = ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        return (ns, ri.ri_phys_footprint)
    }

    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private static let respFn: RespFn? = {
        guard let h = dlopen(nil, RTLD_NOW),
              let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: RespFn.self)
    }()

    /// The process macOS holds responsible for this one (e.g. the app behind a helper).
    static func responsible(_ pid: pid_t) -> pid_t {
        guard let f = respFn else { return pid }
        let r = f(pid)
        return r > 0 ? r : pid
    }

    /// Run a command-line tool and return what it printed.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 8) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    /// Fallback for processes owned by the administrator account, which we can't measure directly.
    static func psTimes() -> [pid_t: (cpuNs: UInt64, mem: UInt64)] {
        var out: [pid_t: (UInt64, UInt64)] = [:]
        let text = run("/bin/ps", ["-axo", "pid=,time=,rss="])
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = pid_t(f[0]), let rss = UInt64(f[2]) else { continue }
            out[pid] = (parseCpuTime(String(f[1])), rss * 1024)
        }
        return out
    }

    private static func parseCpuTime(_ s: String) -> UInt64 {
        var days = 0.0
        var rest = s
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            rest = String(s[s.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        var secs = 0.0
        for p in parts { secs = secs * 60 + p }
        secs += days * 86400
        return UInt64(secs * 1_000_000_000)
    }
}

// MARK: - Plain-English number formatting

func fmtBytes(_ b: UInt64) -> String {
    let v = Double(b)
    if v < 1024 { return b == 0 ? "0" : "<1 KB" }
    if v < 1024 * 1024 { return String(format: "%.0f KB", v / 1024) }
    if v < 1024 * 1024 * 1024 {
        let mb = v / 1024 / 1024
        return String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb)
    }
    return String(format: "%.1f GB", v / 1024 / 1024 / 1024)
}

func fmtRate(_ bytesPerSec: Double) -> String {
    if bytesPerSec < 512 { return "–" }
    if bytesPerSec < 1024 * 1024 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
    return String(format: "%.1f MB/s", bytesPerSec / 1024 / 1024)
}

func fmtCPU(_ pct: Double) -> String {
    if pct < 0.5 { return "–" }
    if pct < 10 { return String(format: "%.1f%%", pct) }
    return String(format: "%.0f%%", pct)
}

func fmtDuration(_ secs: Double) -> String {
    if secs < 60 { return String(format: "%.0f sec", secs) }
    if secs < 3600 { return String(format: "%.0f min", secs / 60) }
    return String(format: "%.1f hr", secs / 3600)
}
