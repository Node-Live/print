import NodePrintCore
import SwiftUI

struct MainView: View {
    let model: AppModel
    /// The channel whose printer list is open, if any.
    @State private var open: Channel?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 0) {
                ChannelSection(channel: .label, model: model, open: $open)
                    .padding(.top, 66)
                ChannelSection(channel: .document, model: model, open: $open)
                    .padding(.top, 17)
            }
            .padding(.horizontal, Theme.inset)
            TitleCapsule()
                .frame(maxWidth: .infinity)
                .position(x: Theme.windowSize.width / 2, y: model.titlebarMidY)
            LinkStatus(linked: model.linked)
                .frame(width: Theme.windowSize.width - 20, alignment: .trailing)
                .position(x: (Theme.windowSize.width - 20) / 2, y: model.titlebarMidY)
            if !model.listening {
                Text("Port 19233 is in use")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.redText)
                    .position(x: Theme.windowSize.width / 2, y: model.titlebarMidY + 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlayPreferenceValue(CardFrames.self) { frames in
            GeometryReader { window in
                if let open, let anchor = frames[open] {
                    let card = window[anchor]
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { self.open = nil }
                    PrinterPanel(channel: open, model: model, card: card, window: window.size, titlebarBottom: model.titlebarMidY + 24) {
                        self.open = nil
                    }
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
        .onChange(of: open) { if open != nil { model.refresh() } }
    }
}

/// Where each card sits, so the open list can hang from it.
struct CardFrames: PreferenceKey {
    static let defaultValue: [Channel: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Channel: Anchor<CGRect>], nextValue: () -> [Channel: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Whether a NODE page has reached the local service within the last minute.
struct LinkStatus: View {
    let linked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(linked ? Theme.green : Theme.gray)
                .frame(width: 6, height: 6)
            Text(linked ? "Linked to NODE" : "Waiting for NODE")
                .font(.system(size: 11.5))
                .foregroundStyle(linked ? Theme.pillText : Theme.secondary)
        }
        .lineLimit(1)
    }
}
struct TitleCapsule: View {
    var body: some View {
        HStack(spacing: 0) {
            LogoMark()
                .frame(width: 26.5, height: 26.5)
                .padding(.leading, 8)
            Text(verbatim: "NODE")
                .font(.system(size: 14, weight: .bold))
                .tracking(1.7)
                .foregroundStyle(Theme.ink)
                .padding(.leading, 8)
            Text(verbatim: "Print")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.leading, 8.5)
            Text(verbatim: "v\(NodePrint.version)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .padding(.leading, 6.5)
                .padding(.trailing, 14)
        }
        .frame(height: 38)
        .fixedSize()
        .modifier(CapsuleSurface())
    }
}

/// Liquid Glass on macOS 26, tinted white so it reads as the design's white capsule; a material capsule before it.
struct CapsuleSurface: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(.white), in: .capsule)
        } else {
            materialCapsule(content)
        }
        #else
        materialCapsule(content)
        #endif
    }

    private func materialCapsule(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.capsuleEdge.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.07), radius: 12, y: 6)
    }
}

struct ChannelSection: View {
    let channel: Channel
    let model: AppModel
    @Binding var open: Channel?

    var body: some View {
        let status = model.status(of: channel)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(channel.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(channel.purpose)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(.leading, 8)
                Spacer(minLength: 12)
                StateLabel(state: status.state)
                    .offset(y: 1)
            }
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 16)
            PrinterCard(channel: channel, status: status, open: $open)
                .padding(.top, 11)
        }
    }
}

struct StateLabel: View {
    let state: ChannelState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(state.dotColor)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4.2 }
            Text(state.word)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(state.textColor)
        }
    }
}

struct PrinterCard: View {
    let channel: Channel
    let status: ChannelStatus
    @Binding var open: Channel?

    var body: some View {
        let isOpen = open == channel
        Button {
            open = isOpen ? nil : channel
        } label: {
            HStack(spacing: 0) {
                PrinterTile(channel: channel, state: status.state)
                    .padding(.leading, 11)
                VStack(alignment: .leading, spacing: 0) {
                    if let printer = status.printer {
                        Text(verbatim: printer.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        let detail = status.state == .missing ? "" : printer.detail(for: channel)
                        if !detail.isEmpty {
                            Text(verbatim: detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondary)
                        }
                    } else {
                        Text("Choose a printer")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .lineLimit(1)
                .padding(.leading, 11)
                Spacer(minLength: 12)
                if let printer = status.printer, status.state != .missing, let word = printer.connection.word {
                    ConnectionPill(word: word, border: isOpen ? Theme.openPillBorder : Theme.pillBorder)
                        .padding(.trailing, 9.5)
                }
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 12)
            }
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .background(isOpen ? .white : Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if isOpen {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(Theme.raisedBorder, lineWidth: 1)
                        .padding(-1)
                }
            }
            .shadow(color: .black.opacity(isOpen ? 0.06 : 0), radius: 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .anchorPreference(key: CardFrames.self, value: .bounds) { [channel: $0] }
    }
}

struct PrinterTile: View {
    let channel: Channel
    let state: ChannelState

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.tileBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: channel == .label ? "tag" : "doc.text")
                    .font(.system(size: channel == .label ? 13 : 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .scaleEffect(x: channel == .label ? -1 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(state.dotColor)
                    .frame(width: 8, height: 8)
                    .padding(2)
                    .background(.white, in: Circle())
                    .offset(x: 2, y: 2)
            }
    }
}

struct ConnectionPill: View {
    let word: LocalizedStringKey
    var border = Theme.pillBorder

    var body: some View {
        Text(word)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.pillText)
            .padding(.horizontal, 9.5)
            .frame(height: 24)
            .background(.white, in: Capsule())
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
    }
}

/// The open printer list: a white panel 6 pt under the card, as wide as it, laid over whatever is below. It opens
/// upward when there is more room above the card, and scrolls when its rows do not fit.
struct PrinterPanel: View {
    let channel: Channel
    let model: AppModel
    let card: CGRect
    let window: CGSize
    let titlebarBottom: CGFloat
    let done: () -> Void

    private static let rowHeight: CGFloat = 46
    private static let padding: CGFloat = 7
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 12

    var body: some View {
        let content = CGFloat(max(model.printers.count, 1)) * Self.rowHeight + 2 * Self.padding
        let below = window.height - (card.maxY + 1 + Self.gap) - Self.margin
        let above = card.minY - 1 - Self.gap - titlebarBottom
        let downward = content <= below || below >= above
        let height = min(content, downward ? below : above)
        let top = downward ? card.maxY + 1 + Self.gap : card.minY - 1 - Self.gap - height
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if model.printers.isEmpty {
                    Text("No printers found")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                }
                ForEach(model.printers) { printer in
                    Button {
                        model.choose(printer, for: channel)
                        done()
                    } label: {
                        PanelRow(printer: printer, channel: channel, chosen: model.channels[channel] == printer.id)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Self.padding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: card.width + 2, height: height)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Theme.raisedBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
        .offset(x: card.minX - 1, y: top)
    }
}

struct PanelRow: View {
    let printer: Printer
    let channel: Channel
    let chosen: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.card)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "printer")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(ChannelState(printer.state).dotColor)
                        .frame(width: 7, height: 7)
                        .padding(2)
                        .background(.white, in: Circle())
                        .offset(x: 2.75, y: 2.75)
                }
                .padding(.leading, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: printer.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                let detail = printer.detail(for: channel)
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .lineLimit(1)
            .padding(.leading, 12)
            Spacer(minLength: 12)
            if let word = printer.connection.word {
                Text(word)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.pillText)
                    .padding(.horizontal, 8.5)
                    .frame(height: 22)
                    .background(Theme.card, in: Capsule())
            }
            if chosen {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.check)
                    .padding(.leading, 14.5)
            }
        }
        .padding(.trailing, chosen ? 12 : 10)
        .frame(height: 46)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension Channel {
    var title: LocalizedStringKey {
        self == .label ? "Label printer" : "Document printer"
    }

    var purpose: LocalizedStringKey {
        self == .label ? "Shipping labels · 4 × 6 in" : "Pick sheets & packing slips · Letter"
    }

    /// The papers worth naming on this channel's card.
    var papers: [Paper] {
        self == .label ? [.fourBySix] : [.letter, .a4]
    }
}

extension ChannelState {
    init(_ state: PrinterState) {
        self = switch state {
        case .ready: .ready
        case .busy: .busy
        case .paused: .paused
        case .offline: .offline
        case .error: .error
        }
    }

    var word: LocalizedStringKey {
        switch self {
        case .ready: "Ready"
        case .busy: "Printing"
        case .paused: "Paused"
        case .offline: "Offline"
        case .error: "Error"
        case .missing: "Not found"
        case .none: "No printer"
        }
    }

    var dotColor: Color {
        switch self {
        case .ready, .busy: Theme.green
        case .paused: Theme.amber
        case .offline, .error, .missing: Theme.red
        case .none: Theme.gray
        }
    }

    var textColor: Color {
        switch self {
        case .ready, .busy: Theme.greenText
        case .paused: Theme.amberText
        case .offline, .error, .missing: Theme.redText
        case .none: Theme.secondary
        }
    }
}

extension Connection {
    var word: LocalizedStringKey? {
        switch self {
        case .usb: "USB"
        case .network: "Network"
        case .bluetooth: "Bluetooth"
        case .other: nil
        }
    }
}

extension Paper {
    var word: String {
        switch self {
        case .fourBySix: String(localized: "4 × 6 in")
        case .letter: String(localized: "Letter")
        case .a4: String(localized: "A4")
        }
    }
}

extension Printer {
    /// "Thermal · 4 × 6 in", "Letter / A4", or "" when nothing is known for sure.
    func detail(for channel: Channel) -> String {
        var parts: [String] = []
        if kind == .thermal { parts.append(String(localized: "Thermal")) }
        let named = channel.papers.filter(papers.contains)
        if !named.isEmpty { parts.append(named.map(\.word).joined(separator: " / ")) }
        return parts.joined(separator: " · ")
    }
}
