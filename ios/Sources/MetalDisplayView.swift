// SPDX-License-Identifier: GPL-2.0-or-later
import Metal
import QuartzCore
import SwiftUI
import UIKit

final class MetalCanvasUIView: UIView, UIKeyInput {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var touchRotation = 0 {
        didSet {
            if touchRotation != oldValue { releaseTouch() }
        }
    }
    private var activeTouch: UITouch?
    private var touchBounds: CGRect = .zero
    private var reportedWindowSize = CGSize.zero
    private var reportedWindowScale: CGFloat = 0
    private var lastTouchPoint = (x: 0.0, y: 0.0)
    var onThreeFingerTap: (() -> Void)?
    var onAppsSwipe: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resizeAspect
        updateDrawableScale()

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        addGestureRecognizer(threeFingerTap)

        let appsSwipe = UISwipeGestureRecognizer(target: self, action: #selector(handleAppsSwipe))
        appsSwipe.direction = .up
        appsSwipe.numberOfTouchesRequired = 2
        addGestureRecognizer(appsSwipe)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleTrackpadScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)
    }

    @objc private func handleTrackpadScroll(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: self).y
        guard abs(delta) >= 12 else { return }
        gesture.setTranslation(.zero, in: self)
        let (x, y) = normalizedPoint(for: gesture.location(in: self))
        WinIOSBridge.shared.sendTabletNormalizedX(x, y: y, buttons: 0, wheel: delta > 0 ? -1 : 1)
    }

    private func sendTouch(_ touch: UITouch, down: Bool) {
        let (screenX, screenY) = normalizedPoint(for: touch.location(in: self))
        let (x, y): (Double, Double)
        switch touchRotation {
        case 90: (x, y) = (1 - screenY, screenX)
        case 180: (x, y) = (1 - screenX, 1 - screenY)
        case 270: (x, y) = (screenY, 1 - screenX)
        default: (x, y) = (screenX, screenY)
        }
        lastTouchPoint = (x, y)
        WinIOSBridge.shared.sendTabletNormalizedX(x, y: y, buttons: down ? 1 : 0, wheel: 0)
    }

    private func releaseTouch() {
        guard activeTouch != nil else { return }
        activeTouch = nil
        WinIOSBridge.shared.sendTabletNormalizedX(lastTouchPoint.x, y: lastTouchPoint.y, buttons: 0, wheel: 0)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if (event?.allTouches?.count ?? touches.count) > 1 {
            releaseTouch()
            return
        }
        if let touch = touches.first {
            activeTouch = touch
            sendTouch(touch, down: true)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = activeTouch, touches.contains(touch) { sendTouch(touch, down: true) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = activeTouch, touches.contains(touch) {
            sendTouch(touch, down: false)
            activeTouch = nil
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = activeTouch, touches.contains(touch) { releaseTouch() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableScale()
        if window != nil {
            WinIOSBridge.shared.bindMetalLayer(metalLayer)
        } else {
            releaseTouch()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableScale()
    }

    private func updateDrawableScale() {
        if touchBounds != bounds {
            releaseTouch()
            touchBounds = bounds
        }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let w = max(1.0, bounds.width * scale)
        let h = max(1.0, bounds.height * scale)
        metalLayer.drawableSize = CGSize(width: w, height: h)
        if let winBounds = window?.bounds.size, winBounds.width > 0,
           winBounds != reportedWindowSize || scale != reportedWindowScale {
            reportedWindowSize = winBounds
            reportedWindowScale = scale
            WinIOSBridge.shared.updateScreenSize(winBounds, scale: scale)
        }
    }

    private func normalizedPoint(for pt: CGPoint) -> (Double, Double) {
        let bw = max(1.0, bounds.width)
        let bh = max(1.0, bounds.height)
        let fbW = Double(WinIOSBridge.shared.framebufferWidth)
        let fbH = Double(WinIOSBridge.shared.framebufferHeight)

        var rect = bounds
        if fbW > 0 && fbH > 0 {
            let viewAspect = Double(bw / bh)
            let fbAspect = fbW / fbH
            if abs(viewAspect / fbAspect - 1) <= 0.03 {
                // Match Metal's full-window presentation for near-identical ratios.
            } else if viewAspect > fbAspect {
                let fittedW = CGFloat(Double(bh) * fbAspect)
                rect = CGRect(x: (bw - fittedW) * 0.5, y: 0, width: fittedW, height: bh)
            } else {
                let fittedH = CGFloat(Double(bw) / fbAspect)
                rect = CGRect(x: 0, y: (bh - fittedH) * 0.5, width: bw, height: fittedH)
            }
        }
        let nx = min(1.0, max(0.0, Double((pt.x - rect.minX) / max(1.0, rect.width))))
        let ny = min(1.0, max(0.0, Double((pt.y - rect.minY) / max(1.0, rect.height))))
        return (nx, ny)
    }

    @objc private func handleAppsSwipe() {
        releaseTouch()
        onAppsSwipe?()
    }

    @objc private func handleThreeFingerTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        releaseTouch()
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onThreeFingerTap?()
    }

    // MARK: - Software & Hardware Keyboard (USB HID Page 0x07)

    override var keyCommands: [UIKeyCommand]? {
        let apps = UIKeyCommand(input: "a", modifierFlags: [.command, .alternate],
                                action: #selector(handleAppsSwipe))
        apps.discoverabilityTitle = "Linux Apps"
        let controls = UIKeyCommand(input: "l", modifierFlags: [.command, .alternate],
                                    action: #selector(showLinuxControls))
        controls.discoverabilityTitle = "Linux Controls"
        return [apps, controls]
    }

    @objc private func showLinuxControls() { onThreeFingerTap?() }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        for ch in text {
            sendCharacterAsHID(ch)
        }
    }

    func deleteBackward() {
        WinIOSBridge.shared.tapKeyHid(0x2a) // Backspace
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                let code = key.keyCode.rawValue
                if code >= 0x04 && code <= 0xe7 {
                    WinIOSBridge.shared.sendKeyHid(UInt8(code), down: true)
                    handled = true
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                let code = key.keyCode.rawValue
                if code >= 0x04 && code <= 0xe7 {
                    WinIOSBridge.shared.sendKeyHid(UInt8(code), down: false)
                    handled = true
                }
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private func sendCharacterAsHID(_ ch: Character) {
        guard let (usage, shift) = Self.asciiToHID(ch) else { return }
        if shift { WinIOSBridge.shared.sendKeyHid(0xe1, down: true) }
        WinIOSBridge.shared.sendKeyHid(usage, down: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            WinIOSBridge.shared.sendKeyHid(usage, down: false)
            if shift { WinIOSBridge.shared.sendKeyHid(0xe1, down: false) }
        }
    }

    static func asciiToHID(_ ch: Character) -> (UInt8, Bool)? {
        if let ascii = ch.asciiValue {
            switch ascii {
            case 97...122: return (UInt8(0x04 + Int(ascii - 97)), false) // a-z
            case 65...90:  return (UInt8(0x04 + Int(ascii - 65)), true)  // A-Z
            case 49...57:  return (UInt8(0x1e + Int(ascii - 49)), false) // 1-9
            case 48:       return (0x27, false) // 0
            case 10, 13:   return (0x28, false) // Enter
            case 9:        return (0x2b, false) // Tab
            case 32:       return (0x2c, false) // Space
            default: break
            }
        }
        let symbols: [Character: (UInt8, Bool)] = [
            "!": (0x1e, true), "@": (0x1f, true), "#": (0x20, true), "$": (0x21, true),
            "%": (0x22, true), "^": (0x23, true), "&": (0x24, true), "*": (0x25, true),
            "(": (0x26, true), ")": (0x27, true), "-": (0x2d, false), "_": (0x2d, true),
            "=": (0x2e, false), "+": (0x2e, true), "[": (0x2f, false), "{": (0x2f, true),
            "]": (0x30, false), "}": (0x30, true), "\\": (0x31, false), "|": (0x31, true),
            ";": (0x33, false), ":": (0x33, true), "'": (0x34, false), "\"": (0x34, true),
            "`": (0x35, false), "~": (0x35, true), ",": (0x36, false), "<": (0x36, true),
            ".": (0x37, false), ">": (0x37, true), "/": (0x38, false), "?": (0x38, true),
        ]
        return symbols[ch]
    }
}

struct MetalDisplayView: UIViewRepresentable {
    @Binding var keyboardVisible: Bool
    var onThreeFingerTap: () -> Void
    var onAppsSwipe: () -> Void
    var touchRotation: Int = 0

    func makeUIView(context: Context) -> MetalCanvasUIView {
        MetalCanvasUIView(frame: .zero)
    }

    func updateUIView(_ uiView: MetalCanvasUIView, context: Context) {
        uiView.touchRotation = touchRotation
        uiView.onThreeFingerTap = onThreeFingerTap
        uiView.onAppsSwipe = onAppsSwipe
        if keyboardVisible && !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        } else if !keyboardVisible && uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }
    }
}
