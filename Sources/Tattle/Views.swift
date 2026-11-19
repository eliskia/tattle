import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Small helpers

func levelColor(_ l: Level) -> Color {
    switch l {
    case .alert: return .red
    case .warn: return .orange
    case .note: return .yellow
    }
}

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 32, height: 32)
        cache[path] = i
        return i
    }
}

struct AppIcon: View {
    let entry: AppEntry
    var body: some View {
        if let p = entry.bundlePath {
            Image(nsImage: IconCache.shared.icon(p)).resizable().interpolation(.high)
        } else {
            Image(systemName: entry.anyRoot ? "gearshape.2.fill" : "terminal.fill")
                .resizable().scaledToFit().padding(3).foregroundStyle(.secondary)
        }
    }
}

let filesPermName = "Full Disk Access"
let controlPermName = "Accessibility"

func openSettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
}

struct Card<Content: View>: View {
    var tint: Color = .clear
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint == .clear ? Color.primary.opacity(0.05) : tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint == .clear ? Color.primary.opacity(0.08) : tint.opacity(0.35), lineWidth: 1))
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}

// MARK: - Main popover

struct PopoverView: View {
    @EnvironmentObject var m: Monitor
    var scrolls = true
    @State var tab = 0
    @State var expanded: Set<String> = []
    @State private var showVisible = false
    @State private var showAuto = false
    @State private var showAddOns = false
    @State private var showIdle = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if scrolls {
                ScrollView { content.padding(12) }
            } else {
                content.padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 540)
        .frame(height: scrolls ? 680 : nil)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { m.setOpen(true) }
        .onDisappear { m.setOpen(false) }
    }

    private var summary: (String, Color) {
        let s = m.snap
        if !s.ready { return ("Looking around…", .secondary) }
        let n = s.flagged.count + (s.cameraOn && s.cameraHidden ? 1 : 0)
        if n == 0 { return ("All quiet. Nothing sneaky right now.", .green) }
        let color: Color = (s.worst ?? .warn) == .alert ? .red : .orange
        return (n == 1 ? "1 thing worth a look" : "\(n) things worth a look", color)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tattle").font(.system(size: 15, weight: .bold))
                Circle().fill(summary.1).frame(width: 8, height: 8)
                Text(summary.0).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    LoginToggle()
                    Button("Refresh now") { m.refreshNow() }
                    Divider()
                    Button("Quit Tattle") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            HStack(spacing: 8) {
                mediaPill(icon: "mic.fill", label: "Microphone",
                          value: m.snap.micNames.isEmpty ? "off" : m.snap.micNames.joined(separator: ", "),
                          active: !m.snap.micNames.isEmpty, alarming: m.snap.micHidden)
                mediaPill(icon: "video.fill", label: "Camera",
                          value: !m.snap.cameraOn ? "off"
                            : m.snap.cameraSuspects.isEmpty ? "ON (can't tell which app)"
                            : "ON, probably " + m.snap.cameraSuspects.joined(separator: " or "),
                          active: m.snap.cameraOn, alarming: m.snap.cameraHidden)
            }
            Picker("", selection: $tab) {
                Text("Apps").tag(0)
                Text(m.shortcuts.conflicts.isEmpty ? "Shortcuts" : "Shortcuts (\(m.shortcuts.conflicts.count) clash\(m.shortcuts.conflicts.count == 1 ? "" : "es"))").tag(1)
                Text("Activity").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        .padding(12)
    }

    private func mediaPill(icon: String, label: String, value: String, active: Bool, alarming: Bool) -> some View {
        let color: Color = alarming ? .red : active ? .orange : .secondary
        return HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
            Text(label + ": ").font(.system(size: 11)).foregroundStyle(.secondary)
                + Text(value).font(.system(size: 11, weight: active ? .semibold : .regular)).foregroundStyle(active ? color : .secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(color.opacity(active ? 0.14 : 0.07)))
    }

    @ViewBuilder private var content: some View {
        if tab == 0 { appsTab } else if tab == 1 { ShortcutsTab() } else { ActivityTab() }
    }

    private var appsTab: some View {
        let s = m.snap
        return VStack(alignment: .leading, spacing: 8) {
            if s.ready && (!s.hasFDA || !s.hasAX) { SetupCard(hasFDA: s.hasFDA, hasAX: s.hasAX) }

            if !s.flagged.isEmpty {
                Card(tint: (s.worst ?? .warn) == .alert ? .red : .orange) {
                    Text("Worth a look").font(.system(size: 12, weight: .semibold))
                    ForEach(s.flagged) { e in
                        ForEach(e.flags.filter { $0.level >= .warn }) { f in
                            Button { toggle(e.id, forceOpen: true) } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Circle().fill(levelColor(f.level)).frame(width: 7, height: 7).padding(.top, 4)
                                    AppIcon(entry: e).frame(width: 16, height: 16)
                                    (Text(e.name).fontWeight(.semibold) + Text("  " + f.text))
                                        .font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !s.ready {
                Text("Taking the first reading. This takes a couple of seconds.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                columnHeader
                section("Running out of sight and busy",
                        "No window and no Dock icon, and using the processor or network right now.", s.hidden.filter(\.isBusy))
                let idle = s.hidden.filter { !$0.isBusy }
                if !idle.isEmpty {
                    Button { showIdle.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showIdle ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("Out of sight but idle (\(idle.count))").font(.system(size: 12, weight: .semibold))
                            Text("loaded, doing nothing right now").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 2)
                    if showIdle { rows(idle) }
                }
                section("In the Dock, but no window open",
                        "Still running after you closed the window. The Dock calls this “Running in Background”.", s.dockOnly)

                Button { showVisible.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showVisible ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text("Open with a window (\(s.visible.count))").font(.system(size: 12, weight: .semibold))
                        Text("counted as safe").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 6)
                if showVisible { rows(s.visible) }

                if !s.addOns.isEmpty {
                    Button { showAddOns.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showAddOns ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("Widgets and add-ons of closed apps (\(s.addOns.count))").font(.system(size: 12, weight: .semibold))
                            Text("small and usually idle").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 2)
                    if showAddOns { rows(s.addOns) }
                }

                Button { showAuto.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showAuto ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text("Set to start by themselves (\(s.autoItems.count))").font(.system(size: 12, weight: .semibold))
                        Text("whether or not you open the app").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 2)
                if showAuto {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(s.autoItems) { item in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.ownerName).font(.system(size: 11.5, weight: .medium))
                                Text(item.label + ": " + item.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        Text("Newer-style login items aren't listed here. See System Settings → General → Login Items.")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        Button("Open Login Items settings") { openSettings("com.apple.LoginItems-Settings.extension") }
                            .controlSize(.small)
                    }
                    .padding(.leading, 16)
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text("Processor").frame(width: 58, alignment: .trailing)
            Text("Memory").frame(width: 56, alignment: .trailing)
            Text("Sending").frame(width: 62, alignment: .trailing)
            Text("Receiving").frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    @ViewBuilder private func section(_ title: String, _ subtitle: String, _ list: [AppEntry]) -> some View {
        SectionTitle(title: "\(title) (\(list.count))", subtitle: subtitle)
        if list.isEmpty {
            Text("Nothing here.").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            rows(list)
        }
    }

    private func rows(_ list: [AppEntry]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { e in
                RowView(e: e, expanded: expanded.contains(e.id)) { toggle(e.id) }
                Divider().opacity(0.4)
            }
        }
    }

    private func toggle(_ id: String, forceOpen: Bool = false) {
        if expanded.contains(id) && !forceOpen { expanded.remove(id) } else { expanded.insert(id) }
        if forceOpen, m.snap.visible.contains(where: { $0.id == id }) { showVisible = true }
    }

    private var footer: some View {
        HStack {
            Text("\(m.snap.systemHidden) built-in macOS processes not shown")
            Spacer()
            if m.snap.ready {
                Text("Updated " + m.snap.updated.formatted(date: .omitted, time: .standard))
            }
        }
        .font(.system(size: 10)).foregroundStyle(.tertiary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct LoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle("Start Tattle when I log in", isOn: Binding(
            get: { on },
            set: { want in
                do {
                    if want { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {}
                on = SMAppService.mainApp.status == .enabled
            }))
    }
}

struct SetupCard: View {
    let hasFDA: Bool
    let hasAX: Bool
    var body: some View {
        Card(tint: .blue) {
            Text("Tattle needs two switches turned on").font(.system(size: 12, weight: .semibold))
            row(title: "Full Disk Access", working: hasFDA,
                why: "Lets Tattle read which powerful permissions every app holds, and each app's saved shortcuts.") {
                openSettings("com.apple.preference.security?Privacy_AllFiles")
            }
            row(title: "Accessibility", working: hasAX,
                why: "Lets Tattle read menu shortcuts, spot menu bar icons, and notice shortcut presses.") {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                openSettings("com.apple.preference.security?Privacy_Accessibility")
            }
            Text("Each button opens the right list in System Settings; find Tattle there and switch it on. If a switch is already on but still shows “not working” here, select Tattle in that list, remove it with the minus button, then add it again with the plus button. Everything stays on this Mac; Tattle never connects to the internet.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(title: String, working: Bool, why: String, open: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: working ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(working ? .green : .secondary).font(.system(size: 13)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title + (working ? ": working" : ": not working yet")).font(.system(size: 11.5, weight: .medium))
                Text(why).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !working { Button("Open", action: open).controlSize(.small) }
        }
    }
}

// MARK: - One app row

struct RowView: View {
    @EnvironmentObject var m: Monitor
    let e: AppEntry
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 9)
                    AppIcon(entry: e).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(e.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            if let w = e.worst { Circle().fill(levelColor(w)).frame(width: 7, height: 7) }
                            if e.mic { Image(systemName: "mic.fill").font(.system(size: 9)).foregroundStyle(.red) }
                            if !e.powerful.isEmpty {
                                Image(systemName: "key.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                                    .help("Holds powerful permissions")
                            }
                            if !e.autoStart.isEmpty {
                                Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                                    .help("Starts by itself")
                            }
                        }
                        Text(e.status).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    num(fmtCPU(e.cpu), 58, hot: e.cpu >= 10)
                    num(e.mem == 0 ? "–" : fmtBytes(e.mem), 56)
                    num(fmtRate(e.upRate), 62, hot: e.upRate > 200_000)
                    num(fmtRate(e.downRate), 62)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { DetailView(e: e).padding(.leading, 39).padding(.bottom, 8) }
        }
    }

    private func num(_ s: String, _ w: CGFloat, hot: Bool = false) -> some View {
        Text(s).font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(s == "–" ? AnyShapeStyle(.tertiary) : hot ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
            .frame(width: w, alignment: .trailing)
    }
}

struct DetailView: View {
    @EnvironmentObject var m: Monitor
    let e: AppEntry
    @State private var askedToQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(e.flags) { f in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(levelColor(f.level)).frame(width: 7, height: 7).padding(.top, 4)
                    Text(f.text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                }
            }

            block("Today") {
                line("Sent \(fmtBytes(e.upToday)) and received \(fmtBytes(e.downToday)) since Tattle started watching today")
                if e.hiddenCpuToday >= 1 {
                    line("Used \(fmtDuration(e.hiddenCpuToday)) of processor time while it had no window open")
                }
                line("Last 10 minutes: sent \(fmtBytes(e.up10)), received \(fmtBytes(e.down10)), averaged \(fmtCPU(e.cpuTenMin) == "–" ? "almost no" : fmtCPU(e.cpuTenMin)) processor")
            }

            block("The pieces (\(e.pieces.count))") {
                ForEach(e.pieces.prefix(12)) { p in
                    HStack(spacing: 6) {
                        Text(p.name + (p.root ? "  (administrator)" : "")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(fmtCPU(p.cpu)).frame(width: 44, alignment: .trailing)
                        Text(p.mem == 0 ? "–" : fmtBytes(p.mem)).frame(width: 56, alignment: .trailing)
                    }
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                if e.pieces.count > 12 { line("…and \(e.pieces.count - 12) more small ones") }
            }

            if !e.sensitive.isEmpty || !e.folderNotes.isEmpty {
                block("Files it has open right now") {
                    ForEach(e.sensitive, id: \.self) { s in line("Has \(s) open", color: .red) }
                    ForEach(e.folderNotes, id: \.self) { line($0) }
                }
            }

            if !e.permissions.isEmpty {
                block("What you've allowed it to do") {
                    ForEach(e.permissions) { p in
                        line(p.text, color: p.powerful ? .orange : .secondary, icon: p.powerful ? "key.fill" : nil)
                    }
                    if !m.snap.everydayPermsKnown {
                        line("This macOS version only lets Tattle see the powerful permissions, not microphone, camera or folder access.")
                    }
                }
            } else if !m.snap.hasFDA {
                block("What you've allowed it to do") { line("Unknown until Tattle is switched on under \(filesPermName)") }
            } else {
                block("What you've allowed it to do") {
                    line(m.snap.everydayPermsKnown ? "No special permissions." : "None of the powerful permissions (full file access, screen recording, keyboard watching, controlling your Mac).")
                }
            }

            if !e.autoStart.isEmpty {
                block("Starts by itself") {
                    ForEach(e.autoStart) { a in line(a.label + ": " + a.detail) }
                }
            }

            HStack(spacing: 8) {
                Button(askedToQuit ? "Force quit" : "Quit") {
                    m.quit(e, force: askedToQuit)
                    askedToQuit = true
                }
                .help(askedToQuit ? "Stops it immediately. Unsaved work in it is lost." : "Asks it to quit politely.")
                if let p = e.bundlePath ?? (e.isTool ? String(e.id.dropFirst(5)) : nil) {
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "") }
                }
                Spacer()
                Toggle("This one's fine", isOn: Binding(get: { m.trusted.contains(e.id) }, set: { m.setTrusted(e.id, $0) }))
                    .toggleStyle(.checkbox)
                    .help("Stop flagging this app for processor or network use. Microphone and private-file alerts still show.")
            }
            .controlSize(.small).font(.system(size: 11))
            if e.anyRoot {
                line("Some pieces run with administrator rights, so Tattle can't stop those.")
            }
            if !e.autoStart.isEmpty && askedToQuit {
                line("It has an auto-start entry, so it may come back by itself.")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func block<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func line(_ s: String, color: Color = .secondary, icon: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 8)).padding(.top, 3) }
            Text(s).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11)).foregroundStyle(color)
    }
}

// MARK: - Shortcuts tab

struct ShortcutsTab: View {
    @EnvironmentObject var m: Monitor
    @State private var openOwners: Set<String> = []

    var body: some View {
        let r = m.shortcuts
        VStack(alignment: .leading, spacing: 10) {
            if !r.conflicts.isEmpty {
                Card(tint: .red) {
                    Text("Clashing shortcuts").font(.system(size: 12, weight: .semibold))
                    Text("The same keys are claimed by more than one thing, so pressing them can set off both.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    ForEach(r.conflicts) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.combo.display).font(.system(size: 12, weight: .semibold))
                            ForEach(c.entries) { e in
                                Text("• \(e.owner): \(e.action)").font(.system(size: 11.5))
                            }
                            if c.combo.isFnAlone, c.entries.contains(where: { $0.owner == "macOS" }) {
                                Text("Fix: in System Settings → Keyboard, set “Press 🌐 key to” to “Do Nothing”, so only your app reacts to fn.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Button("Open Keyboard settings") { openSettings("com.apple.Keyboard-Settings.extension") }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            } else if r.loaded {
                Card(tint: .green) {
                    Text("No clashes among the global shortcuts I could find").font(.system(size: 12, weight: .semibold))
                }
            }

            KeyTestCard()

            SectionTitle(title: "Shortcuts that work everywhere (\(r.globals.count))",
                         subtitle: "Found in macOS settings and in each app's saved settings. Best effort: macOS keeps no master list, and apps still using their built-in default keys may not appear.")
            let owners = Dictionary(grouping: r.globals, by: \.owner)
            let rank: (String) -> String = { o in
                o == "macOS" ? "0" : ((owners[o]?.first?.running ?? true) ? "1" : "2") + o.lowercased()
            }
            ForEach(owners.keys.sorted { rank($0) < rank($1) }, id: \.self) { owner in
                let list = owners[owner] ?? []
                let isRunning = list.first?.running ?? true
                Button {
                    if openOwners.contains(owner) { openOwners.remove(owner) } else { openOwners.insert(owner) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: openOwners.contains(owner) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        Text(owner).font(.system(size: 12, weight: .medium)).foregroundStyle(isRunning ? .primary : .secondary)
                        Text(isRunning ? "\(list.count)" : "\(list.count) · not running, so inactive")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if openOwners.contains(owner) {
                    VStack(spacing: 2) {
                        ForEach(list.sorted { $0.action < $1.action }) { e in
                            HStack {
                                Text(e.action).lineLimit(1)
                                Spacer()
                                Text(e.combo.display).fontWeight(.medium)
                            }
                            .font(.system(size: 11.5))
                        }
                    }
                    .padding(.leading, 15)
                }
            }

            SectionTitle(title: "Apps that can react to any key",
                         subtitle: "These have permission to watch the whole keyboard. macOS can't tell me which keys they use; the key test above can.")
            if r.listenersKnown {
                Text((r.listeners + r.keyRemappers.filter { !r.listeners.contains($0) }).joined(separator: " · "))
                    .font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Needs \(filesPermName) to list them.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if !r.keyRemappers.isEmpty {
                Text("\(r.keyRemappers.joined(separator: ", ")) can change what any key does before other apps see it.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            SectionTitle(title: "Shortcuts inside apps",
                         subtitle: "Menu commands whose keys are taken over by a global shortcut from another app.")
            HStack {
                Button(r.scanning ? "Scanning…" : r.menuScanned ? "Scan again" : "Scan the menus of open apps") {
                    m.refreshShortcuts(scanMenus: true)
                }
                .controlSize(.small).disabled(r.scanning)
                if r.menuScanned {
                    Text("Read \(r.menuShortcuts) menu shortcuts from \(r.menuApps) apps")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else if !m.snap.hasAX {
                    Text("Needs \(controlPermName)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            if r.menuScanned && r.shadows.isEmpty {
                Text("No menu shortcut is being overridden.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(r.shadows.prefix(25)) { s in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(s.combo.display)  goes to \(s.global.owner) (\(s.global.action))")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("so it no longer does: " + s.victims.prefix(4).map { "\($0.owner) “\($0.action)”" }.joined(separator: ", ")
                         + (s.victims.count > 4 ? " and \(s.victims.count - 4) more" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { if !m.shortcuts.scanning { m.refreshShortcuts(scanMenus: false) } }
    }
}

struct KeyTestCard: View {
    @EnvironmentObject var m: Monitor
    @ObservedObject var t: KeyTester = Monitor.shared.tester

    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Key test").font(.system(size: 12, weight: .semibold))
                    Text("Press any key or combination and I'll watch which apps react in the next two seconds.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch t.phase {
                case .idle, .done: Button("Test a key") { t.start() }.controlSize(.small)
                case .listening: Button("Cancel") { t.cancel() }.controlSize(.small)
                case .watching: ProgressView().controlSize(.small)
                }
            }
            if t.needsPermission {
                Text("This needs \(controlPermName). Switch Tattle on in System Settings, then try again.")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if t.phase == .listening {
                Text("Listening… press the key now (for example fn).").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.blue)
            }
            if t.phase == .watching {
                Text("Got it. Watching what reacts…").font(.system(size: 11.5))
            }
            if let r = t.result, t.phase == .done {
                Text("You pressed: \(r.key)").font(.system(size: 11.5, weight: .semibold))
                if r.reactions.isEmpty {
                    Text("Nothing visibly reacted.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    ForEach(r.reactions, id: \.self) { Text("• " + $0).font(.system(size: 11.5)) }
                }
            }
        }
    }
}
