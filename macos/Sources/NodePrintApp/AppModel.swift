import NodePrintCore
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private(set) var printers: [Printer] = []
    private(set) var channels: Config.Channels
    private(set) var launchAtLogin: Bool
    /// Whether the local server holds its port.
    var listening = true
    /// Distance from the window top to the centre of the traffic lights, so the capsule sits level with them.
    var titlebarMidY: CGFloat = 29.75

    let config: ConfigStore
    private let system: any PrintSystem
    private var refresher: Timer?

    init(config: ConfigStore, system: any PrintSystem) {
        self.config = config
        self.system = system
        channels = config.config.channels
        launchAtLogin = config.config.launchAtLogin
        refresh()
    }

    func status(of channel: Channel) -> ChannelStatus {
        ChannelStatus(chosen: channels[channel], among: printers)
    }

    func choose(_ printer: Printer, for channel: Channel) {
        config.update { $0.channels[channel] = printer.id }
        channels = config.config.channels
    }

    func refresh() {
        printers = system.printers().inListOrder()
        channels = config.config.channels
    }

    /// Polls CUPS while the window is open; the menu bar needs no printer state.
    func watch(_ visible: Bool) {
        refresher?.invalidate()
        refresher = nil
        guard visible else { return }
        refresh()
        refresher = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        config.update { $0.launchAtLogin = on }
        launchAtLogin = on
        applyLaunchAtLogin()
    }

    /// Makes the login item match the config file, which may have been edited by hand.
    func applyLaunchAtLogin() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let service = SMAppService.mainApp
        do {
            if launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("NODE Print: login item: %@", error.localizedDescription)
        }
    }
}
