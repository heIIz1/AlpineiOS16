// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import UIKit

@MainActor
final class VMViewModel: ObservableObject {
    @Published var isJITLive: Bool = false
    @Published var isVMRunning: Bool = false
    @Published var isUnpacking: Bool = false
    @Published var unpackProgress: Double = 0
    @Published var jitStatusText: String = "Checking JIT..."
    @Published var vmStatusText: String = "Initializing..."
    @Published var systemKeyboardVisible = false

    @Published var hasMachine = false
    @Published var imageStatus: String?
    @Published var imageError: String?
    @Published var softwareStatus: PhoshInstaller.SoftwareStatus?
    @Published var consolePassword = PhoshInstaller.storedPassword()
    private var installTask: Task<Void, Never>?

    private var didAutoLaunchAttempt = false

    init() {
        let bridge = WinIOSBridge.shared
        bridge.installTrapGuard()
        bridge.onStateChanged = { [weak self] in
            Task { @MainActor in
                self?.syncFromBridge()
            }
        }
        syncFromBridge()
        Task { @MainActor [weak self] in
            self?.onAppBecameActive()
        }
    }

    func syncFromBridge() {
        let b = WinIOSBridge.shared
        isJITLive = b.isJITLive
        isVMRunning = b.isVMRunning
        isUnpacking = b.isUnpacking
        unpackProgress = b.unpackProgress
        jitStatusText = b.jitStatusText
        vmStatusText = b.vmStatusText
        hasMachine = b.hasProvisionedMachine()
        if consolePassword != nil && softwareStatus != .ready {
            softwareStatus = PhoshInstaller.softwareStatus()
            if softwareStatus == .ready { PhoshInstaller.clearRequest() }
        }
    }

    func onAppBecameActive() {
        let b = WinIOSBridge.shared
        if !b.isJITLive && b.isDebuggerAttached {
            _ = b.tryAcquireJIT(true)
        }
        syncFromBridge()
        if b.isJITLive && !b.isVMRunning && !b.isUnpacking && installTask == nil && hasMachine && !didAutoLaunchAttempt {
            didAutoLaunchAttempt = true
            b.prepareAndStart(with: nil)
            syncFromBridge()
        }
    }

    func startOrRetry() {
        didAutoLaunchAttempt = isJITLive
        WinIOSBridge.shared.prepareAndStart(with: nil)
        syncFromBridge()
    }

    func downloadPhosh(address: String, apps: Set<PhoshApp>) {
        guard installTask == nil, !hasMachine else { return }
        imageError = nil
        imageStatus = "Preparing download…"
        installTask = Task {
            let password = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            do {
                try await PhoshInstaller.install(address: address, apps: apps, password: password) {
                    imageStatus = $0
                }
                consolePassword = password
                installTask = nil
                imageStatus = nil
                startOrRetry()
            } catch {
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    imageError = error.localizedDescription
                }
                imageStatus = nil
                installTask = nil
                syncFromBridge()
            }
        }
    }

    func cancelDownload() { installTask?.cancel() }

    func requestStikDebugJIT() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var urlStr = "stikjit://enable-jit?bundle-id=\(bundleID)&pid=\(getpid())"
        if let scriptPath = Bundle.main.path(forResource: "henge-jit", ofType: "js"),
           let script = try? String(contentsOfFile: scriptPath, encoding: .utf8),
           let data = script.data(using: .utf8) {
            let b64 = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            if let encoded = b64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlStr += "&script-data=\(encoded)"
            }
        }
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
