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
        let model = AppModel(config: config, system: system)
        model.applyLaunchAtLogin()
        self.model = model

        do {
            let server = try LocalServer(api: LocalAPI(system: system, config: config))
            server.start()
            self.server = server
        } catch {
            NSLog("NODE Print: cannot listen: %@", error.localizedDescription)
        }
        if !launchedAsLoginItem { showWindow() }
        if let path = ProcessInfo.processInfo.environment["NODE_PRINT_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.snapshot(model, to: URL(fileURLWithPath: path)) }
        }
    }

    /// Renders the window content to a PNG, for CI runners that may not capture the screen.
    private func snapshot(_ model: AppModel, to url: URL) {
        let renderer = ImageRenderer(content: MainView(model: model))
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

    func showWindow() {
        guard let model else { return }
        let window = window ?? makeWindow(model)
        self.window = window
        model.watch(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.watch(false)
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
        if let close = window.standardWindowButton(.closeButton) {
            window.layoutIfNeeded()
            let frame = close.convert(close.bounds, to: nil)
            model.titlebarMidY = window.frame.height - frame.midY
        }
        return window
    }
}
