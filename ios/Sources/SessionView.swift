// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Full-screen guest display and serial console.
struct SessionView: View {
    @ObservedObject var vm: VMViewModel
    @State private var showHelp = false
    @State private var desktop = true
    @State private var controlsVisible = false
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

    private var controls: some View {
        HStack {
            Button(desktop ? "Console" : "Phosh") {
                desktop.toggle()
                controlsVisible = false
                vm.systemKeyboardVisible = false
            }
            Spacer()
            if vm.isVMRunning {
                Button { WinIOSBridge.shared.pressPowerButton() } label: { Image(systemName: "power") }
                    .accessibilityLabel("Shut down Linux")
            }
            Button { vm.systemKeyboardVisible.toggle() } label: { Image(systemName: "keyboard") }
                .accessibilityLabel("Toggle keyboard")
            Button { showHelp = true } label: { Image(systemName: "info.circle") }
                .accessibilityLabel("Help")
            if desktop && vm.isVMRunning {
                Menu {
                    Picker("Phosh display orientation", selection: $touchRotation) {
                        Text("Normal").tag(0)
                        Text("90° counterclockwise").tag(90)
                        Text("180°").tag(180)
                        Text("90° clockwise").tag(270)
                    }
                } label: {
                    Image(systemName: "rotate.left")
                }
                .accessibilityLabel("Touch orientation")
                Button { controlsVisible = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close controls")
            }
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
                SerialTerminalView(keyboardVisible: $vm.systemKeyboardVisible)
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
            if vm.isVMRunning && vm.consolePassword != nil && vm.softwareStatus != .ready {
                Text(softwareStatusLabel)
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .allowsHitTesting(false)
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                ScrollView {
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
