import NodePrintCore
import SwiftUI

/// The window in SwiftUI's own controls and styles only, to compare with the design version.
struct NativeView: View {
    let model: AppModel

    var body: some View {
        Form {
            if !model.listening {
                Section {
                    Label("Port 19233 is in use", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            NativeChannelSection(channel: .label, model: model)
            NativeChannelSection(channel: .document, model: model)
            Section {
                Label {
                    Text(model.linked ? "Linked to NODE" : "Waiting for NODE")
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(model.linked ? .green : .secondary)
                }
                LabeledContent("Version", value: NodePrint.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct NativeChannelSection: View {
    let channel: Channel
    let model: AppModel

    var body: some View {
        let status = model.status(of: channel)
        Section {
            Picker("Printer", selection: Binding(
                get: { model.channels[channel] },
                set: { id in
                    if let printer = model.printers.first(where: { $0.id == id }) { model.choose(printer, for: channel) }
                }
            )) {
                if model.channels[channel] == nil {
                    Text("Choose a printer").tag(String?.none)
                }
                if status.state == .missing, let id = model.channels[channel] {
                    Text(verbatim: id).tag(String?.some(id))
                }
                ForEach(model.printers) { printer in
                    Text(verbatim: printer.name).tag(String?.some(printer.id))
                }
            }
            LabeledContent("Status") {
                Label {
                    Text(status.state.word)
                } icon: {
                    Image(systemName: status.state.symbol).foregroundStyle(status.state.systemColor)
                }
            }
            if let printer = status.printer, status.state != .missing {
                if let word = printer.connection.word {
                    LabeledContent("Connection") { Text(word) }
                }
                if printer.kind == .thermal {
                    LabeledContent("Type") { Text("Thermal") }
                }
                let papers = channel.papers.filter(printer.papers.contains)
                if !papers.isEmpty {
                    LabeledContent("Paper", value: papers.map(\.word).joined(separator: " / "))
                }
            }
        } header: {
            Text(channel.title)
        } footer: {
            Text(channel.purpose)
        }
    }
}

extension ChannelState {
    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .busy: "printer.fill"
        case .paused: "pause.circle.fill"
        case .offline: "xmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .missing: "questionmark.circle.fill"
        case .none: "circle.dashed"
        }
    }

    var systemColor: Color {
        switch self {
        case .ready, .busy: .green
        case .paused: .orange
        case .offline, .error, .missing: .red
        case .none: .secondary
        }
    }
}
