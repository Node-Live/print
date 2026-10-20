import NodePrintCore
import SwiftUI

struct MainView: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 0) {
                ChannelSection(channel: .label, model: model)
                    .padding(.top, 66)
                ChannelSection(channel: .document, model: model)
                    .padding(.top, 17)
            }
            .padding(.horizontal, Theme.inset)
            TitleCapsule()
                .frame(maxWidth: .infinity)
                .position(x: Theme.windowSize.width / 2, y: model.titlebarMidY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
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
            PrinterCard(channel: channel, status: status, model: model)
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
    let model: AppModel
    @State private var choosing = false

    var body: some View {
        Button {
            choosing.toggle()
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
                                .font(.system(size: 12))
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
                    ConnectionPill(word: word)
                        .padding(.trailing, 9.5)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 12)
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        PrinterList(channel: channel, model: model) { choosing = false }
                    }
            }
            .frame(height: 60)
            .frame(maxWidth: .infinity)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onChange(of: choosing) { if choosing { model.refresh() } }
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

    var body: some View {
        Text(word)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.pillText)
            .padding(.horizontal, 9.5)
            .frame(height: 24)
            .background(.white, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.pillBorder, lineWidth: 1))
    }
}

struct PrinterList: View {
    let channel: Channel
    let model: AppModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.printers.isEmpty {
                Text("No printers")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .padding(10)
            }
            ForEach(model.printers) { printer in
                Button {
                    model.choose(printer, for: channel)
                    done()
                } label: {
                    PrinterRow(printer: printer, chosen: model.channels[channel] == printer.id)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 300, alignment: .leading)
    }
}

struct PrinterRow: View {
    let printer: Printer
    let chosen: Bool
    @State private var hovering = false

    var body: some View {
        let state = ChannelState(printer.state)
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .opacity(chosen ? 1 : 0)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: printer.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 5) {
                    if let word = printer.connection.word {
                        Text(word)
                        Text(verbatim: "·")
                    }
                    Circle().fill(state.dotColor).frame(width: 6, height: 6)
                    Text(state.word).foregroundStyle(state.textColor)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
