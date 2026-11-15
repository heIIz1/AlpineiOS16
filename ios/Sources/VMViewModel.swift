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
    @Published var guestToolsStatus: String?
    @Published var hasDiskSnapshot = FileManager.default.fileExists(atPath: SessionTools.snapshot.path)
    private let guestTools = GuestToolsUpdate()
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
        guestTools.prepare(password: consolePassword)
        syncFromBridge()
        Task { @MainActor [weak self] in
            self?.onAppBecameActive()
        }
    }

    func observeGuestSerial(_ data: Data) {
        guestTools.observe(data)
        if let password = PhoshInstaller.storedPassword(), consolePassword != password { consolePassword = password }
        guestToolsStatus = guestTools.status
    }

    func syncFromBridge() {
        let b = WinIOSBridge.shared
        isJITLive = b.isJITLive
        isVMRunning = b.isVMRunning
        isUnpacking = b.isUnpacking
        unpackProgress = b.unpackProgress
        jitStatusText = b.jitStatusText
        vmStatusText = b.vmStatusText
        guestTools.observe(Data())
        if let password = PhoshInstaller.storedPassword(), consolePassword != password { consolePassword = password }
        guestToolsStatus = guestTools.status
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
        if b.isJITLive && !b.isVMRunning && !b.isUnpacking && installTask == nil && imageStatus == nil && hasMachine && !didAutoLaunchAttempt {
            didAutoLaunchAttempt = true
            b.prepareAndStart(with: nil)
            syncFromBridge()
        }
    }

    func diskSnapshot(restore: Bool) {
        guard !isVMRunning, !isUnpacking, imageStatus == nil, hasMachine else { return }
        let disk = URL(fileURLWithPath: WinIOSBridge.shared.machineDirectory()).appendingPathComponent("alpine.img")
        let snapshot = SessionTools.snapshot
        imageError = nil
        imageStatus = restore ? "Restoring disk snapshot…" : "Saving disk snapshot…"
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try SessionTools.copyDisk(from: restore ? snapshot : disk, to: restore ? disk : snapshot)
                }.value
                hasDiskSnapshot = true
            } catch {
                imageError = error.localizedDescription
            }
            imageStatus = nil
        }
    }

    func startOrRetry() {
        didAutoLaunchAttempt = isJITLive
        WinIOSBridge.shared.prepareAndStart(with: nil)
        syncFromBridge()
    }

    func downloadPhosh(address: String, apps: Set<PhoshApp>, customPassword: String) {
        guard installTask == nil, !hasMachine, PhoshInstaller.validCustomPassword(customPassword) else { return }
        imageError = nil
        imageStatus = "Preparing download…"
        installTask = Task {
            let password = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            do {
                try await PhoshInstaller.install(address: address, apps: apps, password: password, customPassword: customPassword) {
                    imageStatus = $0
                }
                consolePassword = password
                guestTools.prepare(password: password)
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
