import AppKit
import NodePrintCore
import SwiftUI

@main
struct NodePrintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(delegate: delegate)
        } label: {
            Image(nsImage: .logoTemplate(height: 16))
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    let delegate: AppDelegate

    var body: some View {
        Button("Open NODE Print") { delegate.showWindow() }
        if let model = delegate.model {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let showWindowNotification = Notification.Name("live.node.print.show-window")

    private(set) var model: AppModel?
    @ObservationIgnored private var server: LocalServer?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var fixingSize = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.anotherCopyOfThisUserIsRunning() {
            DistributedNotificationCenter.default().postNotificationName(Self.showWindowNotification, object: nil, deliverImmediately: true)
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Another copy of this user's comes to the front instead. A copy in another user's session cannot; this one
    /// then opens as usual and, finding the port taken, says so.
    private static func anotherCopyOfThisUserIsRunning() -> Bool {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return false }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let name = ProcessInfo.processInfo.processName
        let user = getuid()
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).contains { process in
            var command = process.kp_proc.p_comm
            let processName = withUnsafeBytes(of: &command) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return process.kp_proc.p_pid != me && process.kp_eproc.e_ucred.cr_uid == user && processName == name
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(forName: Self.showWindowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.showWindow() }
        }

        let system = SystemPrinting()
        let config = ConfigStore(firstRun: system.printers)
        let model = AppModel(config: config, system: system)
        model.applyLaunchAtLogin()
        self.model = model

        Updater.removeStaging()
        let activity = Activity()
        let server = LocalServer(api: LocalAPI(system: system, config: config), activity: activity)
        server.start { port in
            DispatchQueue.main.async { model.listening = port != nil }
        }
        self.server = server
        let updater = Updater(activity: activity)
        Task {
            guard await updater.run() else { return }
            server.stop()
            exit(0)
        }
        if !startsWithoutWindow { showWindow() }
    }

    /// A login launch, and a restart after an update (`--tray`).
    private var startsWithoutWindow: Bool {
        if CommandLine.arguments.contains("--tray") { return true }
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func showWindow() {
        guard let model else { return }
        let window = window ?? makeWindow(model)
        self.window = window
        model.watch(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        alignTitle(in: window)
    }

    func windowWillClose(_ notification: Notification) {
        model?.watch(false)
    }

    /// AppKit grows the window when it lays out the toolbar on some systems; the window has one size.
    func windowDidResize(_ notification: Notification) {
        guard !fixingSize, let window = notification.object as? NSWindow, window.frame.size != Theme.windowSize else { return }
        fixingSize = true
        defer { fixingSize = false }
        var frame = window.frame
        frame.origin.y += frame.height - Theme.windowSize.height
        frame.size = Theme.windowSize
        window.setFrame(frame, display: true)
        if window.frame.size != Theme.windowSize {
            NSLog("NODE Print: the window stays %@", NSStringFromSize(window.frame.size))
        }
    }

    private func alignTitle(in window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton) else { return }
        window.layoutIfNeeded()
        model?.titlebarMidY = window.frame.height - close.convert(close.bounds, to: nil).midY
    }

    private func makeWindow(_ model: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Theme.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "NODE Print"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "main")
        window.toolbarStyle = .unified
        window.collectionBehavior = [.fullScreenNone]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        let content = NSHostingView(rootView: MainView(model: model))
        content.sizingOptions = []
        window.contentView = content
        window.setFrame(NSRect(origin: .zero, size: Theme.windowSize), display: false)
        window.delegate = self
        window.center()
        return window
    }
}
