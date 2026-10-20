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
        if Self.anotherCopyIsRunning() {
            DistributedNotificationCenter.default().postNotificationName(Self.showWindowNotification, object: nil, deliverImmediately: true)
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// One copy per Mac, whichever user started it: the port belongs to the machine. A copy in this session
    /// comes to the front on the notification; one in another session cannot, and this one still quits.
    private static func anotherCopyIsRunning() -> Bool {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return false }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let name = ProcessInfo.processInfo.processName
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).contains { process in
            var command = process.kp_proc.p_comm
            let processName = withUnsafeBytes(of: &command) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return process.kp_proc.p_pid != me && processName == name
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

        let server = LocalServer(api: LocalAPI(system: system, config: config))
        server.start { port in
            DispatchQueue.main.async { model.listening = port != nil }
        }
        self.server = server
        if !launchedAsLoginItem { showWindow() }
    }

    private var launchedAsLoginItem: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    /// `--style native` opens the window in SwiftUI's default styles instead of the design's.
    private let native = CommandLine.arguments.firstIndex(of: "--style").map {
        CommandLine.arguments.indices.contains($0 + 1) && CommandLine.arguments[$0 + 1] == "native"
    } ?? false

    func showWindow() {
        guard let model else { return }
        let window = window ?? (native ? makeNativeWindow(model) : makeWindow(model))
        self.window = window
        model.watch(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        alignCapsule(in: window)
    }

    func windowWillClose(_ notification: Notification) {
        model?.watch(false)
    }

    /// AppKit grows the window when it lays out the toolbar on some systems; the window has one size.
    func windowDidResize(_ notification: Notification) {
        guard !native, !fixingSize, let window = notification.object as? NSWindow, window.frame.size != Theme.windowSize else { return }
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

    private func alignCapsule(in window: NSWindow) {
        guard !native, let close = window.standardWindowButton(.closeButton) else { return }
        window.layoutIfNeeded()
        model?.titlebarMidY = window.frame.height - close.convert(close.bounds, to: nil).midY
    }

    private func makeNativeWindow(_ model: AppModel) -> NSWindow {
        let content = NSHostingController(rootView: NativeView(model: model))
        content.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: content)
        window.title = "NODE Print"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
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
