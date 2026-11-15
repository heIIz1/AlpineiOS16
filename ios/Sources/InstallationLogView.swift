// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

struct InstallationLogView: View {
    @ObservedObject var vm: VMViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var linuxLog = ""

    private var text: String {
        let native = vm.installationLog
        if linuxLog.isEmpty { return native.isEmpty ? "No installation activity yet." : native }
        return native + "\nLinux package installation\n" + linuxLog
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Installation log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                while !Task.isCancelled {
                    linuxLog = vm.guestInstallationLog()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}
