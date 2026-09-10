import SwiftUI

struct SettingsView: View {
    @State private var proxyURL: String = "http://127.0.0.1:7890"
    @State private var useProxy: Bool = true
    @State private var useSystemProxy: Bool = true
    @State private var saveDir: String = ""

    var body: some View {
        Form {
            Section("Proxy") {
                Toggle("Enable proxy", isOn: $useProxy)
                Toggle("Use system proxy", isOn: $useSystemProxy)
                TextField("Proxy URL", text: $proxyURL)
            }

            Section("Download") {
                TextField("Save directory", text: $saveDir)
                Button("Choose folder…") { }
                    .buttonStyle(.glass)
            }

            Section("About") {
                LabeledContent("Version", value: "2.2.2-macOS-port")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

#Preview {
    SettingsView()
}
