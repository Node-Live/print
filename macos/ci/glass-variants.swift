import AppKit
import SwiftUI

// A white window with the title capsule in each Liquid Glass variant, for comparing them on a macOS 26 runner.
struct Variants: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sample("regular").glassEffect(.regular, in: .capsule)
            sample("regular, white tint").glassEffect(.regular.tint(.white), in: .capsule)
            sample("clear").glassEffect(.clear, in: .capsule)
            sample("clear, white tint").glassEffect(.clear.tint(.white), in: .capsule)
            sample("white fill, no glass").background(.white, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        }
        .padding(24)
        .frame(width: 522, height: 340, alignment: .topLeading)
        .background(.white)
    }

    private func sample(_ name: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "NODE").font(.system(size: 14, weight: .bold)).tracking(1.7)
            Text(verbatim: "Print").font(.system(size: 13.5, weight: .medium))
            Text(verbatim: name).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 522, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
window.backgroundColor = .white
window.appearance = NSAppearance(named: .aqua)
window.contentView = NSHostingView(rootView: Variants())
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
