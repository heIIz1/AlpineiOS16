// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@MainActor
final class GuestToolsUpdate {
    private enum Stage { case login, password, prompt, doas, installing, done }
    private var stage = Stage.login
    private var tail = ""
    private var password: String?
    private var tryingPendingPassword = false
    private let share = URL.documentsDirectory.appendingPathComponent("Shared")
    private let marker = ".alpineios-tools-status"
    private let version = "15"

    var status: String? {
        if (try? String(contentsOf: share.appendingPathComponent(marker), encoding: .utf8)) == "failed" {
            return "Linux tools update failed. Restart Linux to retry."
        }
        if case .installing = stage { return "Updating Linux graphics, sound and hardware info…" }
        return nil
    }

    func prepare(password: String?) {
        self.password = PhoshInstaller.finishPasswordChange() ?? password
        guard let source = Bundle.main.url(forResource: "update_guest_tools", withExtension: "sh") else { return }
        do {
            try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
            try Data(contentsOf: source).write(to: share.appendingPathComponent("update_guest_tools.sh"), options: .atomic)
            for (name, ext) in [("guest-virgl.tar", "gz"), ("guest-virgl", "sha256")] {
                guard let resource = Bundle.main.url(forResource: name, withExtension: ext) else { continue }
                try Data(contentsOf: resource).write(to: share.appendingPathComponent(name + "." + ext), options: .atomic)
            }
        } catch {
            stage = .done
        }
    }

    func observe(_ data: Data) {
        if let committed = PhoshInstaller.finishPasswordChange() { password = committed }
        guard let password, !password.isEmpty else { return }
        if (try? String(contentsOf: share.appendingPathComponent(marker), encoding: .utf8)) == version {
            stage = .done
            return
        }
        tail += String(decoding: data, as: UTF8.self)
        tail = String(tail.suffix(2048))
        guard PhoshInstaller.softwareStatus() != nil else { return }
        switch stage {
        case .login where tail.contains("alpine-iphone login:"):
            send("user")
            stage = .password
        case .password where tail.contains("Password:"):
            send(tryingPendingPassword ? PhoshInstaller.pendingPassword() ?? password : password)
            stage = .prompt
        case .prompt where tail.contains("alpine-iphone login:"):
            guard !tryingPendingPassword, PhoshInstaller.pendingPassword() != nil else { return }
            tryingPendingPassword = true
            send("user")
            stage = .password
        case .prompt where tail.contains("~$"):
            if tryingPendingPassword, let committed = PhoshInstaller.finishPasswordChange(verifiedLogin: true) {
                self.password = committed
            }
            do { try PhoshInstaller.stagePasswordChange() }
            catch { return }
            send("wget -qO /tmp/alpineios-update.sh http://10.0.2.4/update_guest_tools.sh && doas sh /tmp/alpineios-update.sh")
            stage = .doas
        case .doas where tail.contains("doas (") && tail.contains("password:"):
            send(password)
            stage = .installing
        case .doas where tail.contains("Installing") || tail.contains("up to date"):
            stage = .installing
        default:
            return
        }
        tail = ""
    }

    private func send(_ command: String) {
        _ = WinIOSBridge.shared.sendSerial(Data((command + "\r").utf8))
    }
}
