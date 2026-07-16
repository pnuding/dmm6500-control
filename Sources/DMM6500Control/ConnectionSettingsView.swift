import SwiftUI
import AppKit

struct ConnectionSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection").font(.headline)
            LabeledContent("Host") {
                TextField("192.168.1.50", text: $model.host)
                    .textFieldStyle(.roundedBorder)
                    .help("The multimeter's IP address or hostname on your network")
            }
            if let error = model.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(model.connected ? "Reconnect" : "Connect") {
                    Task { await model.connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.host.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(model.connected ? "Reconnect to the instrument" : "Connect to the instrument")
            }
        }
        // Same AppKit auto-focus-the-first-field behavior as any other
        // freshly-appeared window/popover - resign it immediately so the
        // Host field isn't left looking selected for no reason.
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.resignFirstResponderIfEditingText()
            }
        }
    }
}
