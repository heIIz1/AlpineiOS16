// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

@main
struct WindowsiOSApp: App {
    @StateObject private var viewModel = VMViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SessionView(vm: viewModel)
                .preferredColorScheme(.dark)
                .onAppear {
                    viewModel.onAppBecameActive()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        WinIOSBridge.shared.setGuestPaused(false)
                        viewModel.onAppBecameActive()
                    } else if newPhase == .background {
                        WinIOSBridge.shared.setGuestPaused(true)
                        WinIOSBridge.shared.flushDisks()
                    }
                }
        }
    }
}
