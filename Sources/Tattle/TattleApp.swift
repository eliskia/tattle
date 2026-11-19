import SwiftUI
import AppKit

@main
enum Launcher {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--report") {
            Report.run(days: max(1, Int(args.dropFirst(i + 1).first ?? "") ?? 14))
            exit(0)
        }
        TattleApp.main()
    }
}

struct TattleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var monitor = Monitor.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(monitor)
        } label: {
            MenuBarLabel(snap: monitor.snap)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The icon in the menu bar: a plain eye when all is quiet, coloured with a count when something is flagged.
struct MenuBarLabel: View {
    let snap: Snapshot

    var body: some View {
        let count = snap.flagged.count + (snap.cameraOn && snap.cameraHidden ? 1 : 0)
        if count == 0 {
            Image(systemName: "eye")
        } else {
            let alert = (snap.worst ?? .warn) == .alert
            Image(nsImage: tinted(alert ? "eye.trianglebadge.exclamationmark.fill" : "eye.fill", alert ? .systemRed : .systemOrange))
            Text("\(count)")
        }
    }

    private func tinted(_ symbol: String, _ color: NSColor) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tattle")
            ?? NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Tattle")!
        let img = base.withSymbolConfiguration(cfg) ?? base
        img.isTemplate = false
        return img
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var debugWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        Monitor.shared.start()
        if let i = args.firstIndex(of: "--dump") {
            let wait = Double(args.dropFirst(i + 1).first ?? "") ?? 8
            Monitor.shared.setOpen(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.dump(); exit(0) }
        } else if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
            let path = args[i + 1]
            let wait = Double(value(after: "--wait", in: args) ?? "") ?? 12
            let tabName = value(after: "--tab", in: args)
            let tab = tabName == "shortcuts" ? 1 : tabName == "activity" ? 2 : 0
            let expand = value(after: "--expand", in: args)
            Monitor.shared.setOpen(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.snapshot(to: path, tab: tab, expand: expand) }
        }
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return nil }
        return args[i + 1]
    }

    // Developer aid: print what the app currently believes, as text.
    private func dump() {
        let s = Monitor.shared.snap
        print("ready=\(s.ready) FDA=\(s.hasFDA) AX=\(s.hasAX) systemHidden=\(s.systemHidden)")
        print("diag: \(s.diag)")
        print("mic=\(s.micNames) cameraOn=\(s.cameraOn) suspects=\(s.cameraSuspects)")
        func show(_ title: String, _ list: [AppEntry]) {
            print("\n== \(title) (\(list.count))")
            for e in list {
                let f = e.flags.map { "[\($0.level)] \($0.text)" }.joined(separator: " | ")
                print(String(format: "%-28@ cpu %6@ avg %6@ mem %8@ up %9@ down %9@  %@", e.name as NSString,
                             fmtCPU(e.cpu) as NSString, fmtCPU(e.cpuMinute) as NSString, fmtBytes(e.mem) as NSString,
                             fmtRate(e.upRate) as NSString, fmtRate(e.downRate) as NSString, e.status as NSString))
                if !f.isEmpty { print("      flags: \(f)") }
                if !e.sensitive.isEmpty || !e.folderNotes.isEmpty { print("      files: \(e.sensitive) \(e.folderNotes)") }
                if !e.autoStart.isEmpty { print("      auto: \(e.autoStart.map(\.label))") }
                if !e.powerful.isEmpty { print("      powerful: " + e.powerful.map { String($0.text.prefix(34)) }.joined(separator: " | ")) }
            }
        }
        show("Hidden", s.hidden); show("Add-ons", s.addOns); show("Dock, no window", s.dockOnly); show("Visible", s.visible)
        print("\n== Auto-start (\(s.autoItems.count))")
        for a in s.autoItems { print("  \(a.ownerName): \(a.label) (\(a.detail))") }
        let r = Monitor.shared.shortcuts
        print("\n== Shortcuts: \(r.globals.count) global, \(r.conflicts.count) conflicts")
        for c in r.conflicts { print("  CLASH \(c.combo.display): " + c.entries.map { "\($0.owner): \($0.action)" }.joined(separator: " / ")) }
        for (owner, list) in Dictionary(grouping: r.globals, by: \.owner).sorted(by: { $0.key < $1.key }) {
            print("  \(owner)\(list.first?.running == false ? " [not running]" : ""): " + list.prefix(8).map { "\($0.action)=\($0.combo.display)" }.joined(separator: ", ") + (list.count > 8 ? " …+\(list.count - 8)" : ""))
        }
    }

    // Developer aid: draw the dropdown into an image file without needing to click the menu bar.
    private func snapshot(to path: String, tab: Int, expand: String?) {
        var open: Set<String> = []
        if let expand, let e = Monitor.shared.snap.apps.first(where: { $0.name.lowercased().contains(expand.lowercased()) }) {
            open.insert(e.id)
        }
        let root = PopoverView(scrolls: false, tab: tab, expanded: open).environmentObject(Monitor.shared)
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        debugWindow = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
            exit(0)
        }
    }
}
