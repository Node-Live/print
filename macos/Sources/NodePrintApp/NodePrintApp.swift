import AppKit
import ImageIO
import NodePrintCore
import SwiftUI
import UniformTypeIdentifiers

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
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            DistributedNotificationCenter.default().postNotificationName(Self.showWindowNotification, object: nil, deliverImmediately: true)
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(forName: Self.showWindowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.showWindow() }
        }

        let system = SystemPrinting()
        let config = ConfigStore(firstRun: system.printers)
        let api = LocalAPI(system: system, config: config)
        let model = AppModel(config: config, system: system, api: api)
        model.applyLaunchAtLogin()
        self.model = model

        let server = LocalServer(api: api)
        server.start { port in
            DispatchQueue.main.async { model.listening = port != nil }
        }
        self.server = server
        if !launchedAsLoginItem { showWindow() }
        if let path = ProcessInfo.processInfo.environment["NODE_PRINT_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.snapshot(model, to: URL(fileURLWithPath: path)) }
        }
    }

    /// Renders the window content to a PNG, for CI runners that may not capture the screen.
    private func snapshot(_ model: AppModel, to url: URL) {
        let content = native
            ? AnyView(NativeView(model: model))
            : AnyView(MainView(model: model).frame(width: Theme.windowSize.width, height: Theme.windowSize.height))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
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
