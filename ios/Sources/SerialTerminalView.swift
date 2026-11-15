// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import SwiftTerm
import UIKit

struct SerialTerminalView: UIViewRepresentable {
    @Binding var keyboardVisible: Bool
    var onOutput: (Data) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> TerminalView {
        context.coordinator.onOutput = onOutput
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        context.coordinator.start(view)
        return view
    }
    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.onOutput = onOutput
        if keyboardVisible && !view.isFirstResponder { view.becomeFirstResponder() }
        if !keyboardVisible && view.isFirstResponder { view.resignFirstResponder() }
    }
    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var timer: Timer?
        weak var view: TerminalView?
        var pending = Data()
        var onOutput: (Data) -> Void = { _ in }
        func start(_ view: TerminalView) {
            self.view = view
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self = self, let view = self.view else { return }
                let data = WinIOSBridge.shared.readSerial()
                if !data.isEmpty {
                    self.onOutput(data)
                    view.feed(byteArray: Array(data)[...])
                }
                if !self.pending.isEmpty {
                    let n = WinIOSBridge.shared.sendSerial(self.pending)
                    self.pending.removeFirst(Int(n))
                }
            }
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { pending.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
