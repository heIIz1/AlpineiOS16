// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// Full-screen guest display and serial console.
struct SessionView: View {
    @ObservedObject var vm: VMViewModel
    @State private var showHelp = false
    @State private var showInstallationLog = false
    @State private var desktop = true
    @State private var controlsVisible = false
    @State private var importingFile = false
    @State private var toolsMessage: String?
    @State private var restartPrompt = false
    @AppStorage("guestDisplayProfile") private var displayProfile = "automatic"
    @AppStorage("guestTouchRotation") private var touchRotation = 0

    private func send(_ text: String) {
        _ = WinIOSBridge.shared.sendSerial(Data(text.utf8))
    }

    private func showApps() {
        controlsVisible = false
        vm.systemKeyboardVisible = false
        // USB HID Left GUI (Super) + A opens Phosh's application grid.
        WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe3)], key: 0x04)
    }

    private var softwareStatusLabel: String {
        switch vm.softwareStatus {
        case .installing: "Installing selected Linux apps…"
        case .retrying: "Waiting to retry the Linux app installation…"
        case .ready: "Selected Linux apps installed."
        case nil: "Waiting for Linux to start the app installation…"
        }
    }

    private func importFile(_ url: URL) {
        do {
            try SessionTools.addFile(url)
            toolsMessage = "File saved to Shared/Files. Open dav://10.0.2.4/Files in Linux Files."
        } catch {
            toolsMessage = error.localizedDescription
        }
    }

    private func runAction(_ action: String) {
        do { try SessionTools.send(action) }
        catch { toolsMessage = error.localizedDescription }
    }

    private var tools: some View {
        Menu {
            Button("Installation log", systemImage: "text.alignleft") { showInstallationLog = true }
            Picker("Display profile", selection: $displayProfile) {
                Text("Automatic").tag("automatic")
                Text("Smooth").tag("smooth")
                Text("Sharp").tag("sharp")
            }
            Button("Send iPhone clipboard to Linux", systemImage: "clipboard") {
                if let text = UIPasteboard.general.string, !text.isEmpty {
                    WinIOSBridge.shared.publishClipboard(text)
                    runAction("paste")
                } else { toolsMessage = "The iPhone clipboard has no text." }
            }
            Button("Copy Linux clipboard to iPhone", systemImage: "doc.on.clipboard") {
                _ = WinIOSBridge.shared.takeGuestClipboard()
                runAction("copy")
                Task { @MainActor in
                    for _ in 0..<15 {
                        try? await Task.sleep(for: .milliseconds(300))
                        if let text = WinIOSBridge.shared.takeGuestClipboard(), !text.isEmpty {
                            UIPasteboard.general.string = text
                            toolsMessage = "Linux clipboard copied."
                            return
                        }
                    }
                    toolsMessage = "No Linux clipboard text received."
                }
            }
            Button("Send file to Linux", systemImage: "folder") { importingFile = true }
            Button("Restart Phosh", systemImage: "arrow.clockwise") { restartPrompt = true }
        } label: {
            toolbarIcon("ellipsis.circle")
        }
        .accessibilityLabel("Linux tools")
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name).frame(minWidth: 28, minHeight: 30)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    desktop.toggle()
                    controlsVisible = false
                    vm.systemKeyboardVisible = false
                } label: {
                    Label(desktop ? "Console" : "Phosh", systemImage: desktop ? "terminal" : "display")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
                if desktop {
                    Button { controlsVisible = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close controls")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                Button { WinIOSBridge.shared.pressPowerButton() } label: { toolbarIcon("power") }
                    .accessibilityLabel("Shut down Linux")
                Button { vm.systemKeyboardVisible.toggle() } label: { toolbarIcon("keyboard") }
                    .accessibilityLabel("Toggle keyboard")
                Button { showHelp = true } label: { toolbarIcon("info.circle") }
                    .accessibilityLabel("Help")
                if desktop {
                    tools
                    Menu {
                        Picker("Phosh display orientation", selection: $touchRotation) {
                            Text("Normal").tag(0)
                            Text("90° counterclockwise").tag(90)
                            Text("180°").tag(180)
                            Text("90° clockwise").tag(270)
                        }
                    } label: {
                        toolbarIcon("rotate.left")
                    }
                    .accessibilityLabel("Touch orientation")
                }
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .tint(AlpineTheme.accent)
        .padding(12)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !desktop && vm.isVMRunning {
                controls
            }

            ZStack {
                SerialTerminalView(keyboardVisible: $vm.systemKeyboardVisible, onOutput: vm.observeGuestSerial)
                    .opacity(desktop ? 0 : 1)
                    .allowsHitTesting(!desktop)
                if desktop && vm.isVMRunning {
                    MetalDisplayView(keyboardVisible: $vm.systemKeyboardVisible,
                                     onThreeFingerTap: { controlsVisible.toggle() },
                                     onAppsSwipe: showApps,
                                     touchRotation: touchRotation)
                        .ignoresSafeArea(.container)
                }
                if !vm.isVMRunning {
                    PhoshSetupView(vm: vm, openHelp: { showHelp = true })
                }
            }
            .background(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !desktop && vm.isVMRunning {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        Button("Esc") { send("\u{1b}") }
                        Button("Tab") { send("\t") }
                        Button("Ctrl-C") { send("\u{03}") }
                        Button("Ctrl-D") { send("\u{04}") }
                        Button("↑") { send("\u{1b}[A") }
                        Button("↓") { send("\u{1b}[B") }
                        Button("←") { send("\u{1b}[D") }
                        Button("→") { send("\u{1b}[C") }
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                }
            }
        }
        .overlay(alignment: .top) {
            if desktop && vm.isVMRunning && controlsVisible {
                VStack(spacing: 0) {
                    controls
                    Button(action: showApps) {
                        Label("Apps", systemImage: "square.grid.3x3.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AlpineTheme.accent)
                    .padding([.horizontal, .bottom], 12)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding()
            }
        }
        .overlay(alignment: .bottom) {
            if vm.isVMRunning && (vm.guestToolsStatus != nil || (vm.consolePassword != nil && vm.softwareStatus != .ready)) {
                Button { showInstallationLog = true } label: {
                    Label(vm.guestToolsStatus ?? softwareStatusLabel, systemImage: "text.alignleft")
                }
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
            }
        }
        .onChange(of: displayProfile) { _ in WinIOSBridge.shared.refreshGuestDisplay() }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item]) { result in
            do { importFile(try result.get()) }
            catch { toolsMessage = error.localizedDescription }
        }
        .onOpenURL { url in
            if url.isFileURL { importFile(url) }
        }
        .alert("Linux tools", isPresented: Binding(get: { toolsMessage != nil },
                                                   set: { if !$0 { toolsMessage = nil } })) {
            Button("OK") { toolsMessage = nil }
        } message: { Text(toolsMessage ?? "") }
        .confirmationDialog("Restart the Linux desktop? Open Linux windows will close.", isPresented: $restartPrompt) {
            Button("Restart Phosh", role: .destructive) { runAction("restart") }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showInstallationLog) { InstallationLogView(vm: vm) }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("First launch").font(.title2.bold())
                        Text("Choose apps and download a Phosh image from the setup screen. You can also import a prepared machine into Machines/PostmarketOS-Native using Files or Finder.")
                        if let password = vm.consolePassword {
                            Text(softwareStatusLabel)
                            Text("Console login is user. Use this password for doas and the serial console.")
                            Text(password).font(.body.monospaced()).textSelection(.enabled)
                        } else {
                            Text("For a manually prepared machine, sign in as user with the password in login.txt.")
                        }
                        Text("Tap with three fingers to show controls. Tap Apps or swipe up with two fingers inside the desktop to open the Phosh app grid.")
                        Text("If taps are offset after changing the orientation in Phosh, open the controls with three fingers and match Touch orientation to the displayed image.")
                        Text("Swipe up from the bottom to return to iOS. Use the power button in the controls to ask Linux to shut down first.")
                        Divider()
                        Link("Credits and licenses", destination: URL(string: "https://github.com/Lumid-Off/AlpineiOS/blob/main/THIRD_PARTY_NOTICES.md")!)
                        Text(vm.vmStatusText).font(.caption.monospaced())
                    }.padding()
                }
                .navigationTitle("AlpineiOS")
                .toolbar { Button("Done") { showHelp = false } }
            }
        }
    }
}
