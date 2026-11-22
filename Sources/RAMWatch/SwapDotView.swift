import AppKit

/// Pulsing red dot laid over the menu bar chip while the Mac is swapping.
/// Core Animation runs the pulse. Don't swap button images on a timer instead:
/// each new image is sent to the menu bar again, about 9% CPU at just 5 fps.
final class SwapDotView: NSView {
    private static let diameter: CGFloat = 8
    private static let pulseKey = "pulse"

    private let dot = NSView()
    private var dotCenter = NSPoint.zero

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        isHidden = true
        dot.wantsLayer = true
        if let layer = dot.layer {
            layer.backgroundColor = CGColor(srgbRed: 1, green: 0.12, blue: 0.12, alpha: 1)
            layer.borderColor = .white   // keeps it visible on the red pill
            layer.borderWidth = 1
            layer.cornerRadius = Self.diameter / 2
        }
        addSubview(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Clicks go through to the status button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `center` is measured from the top left of the button's image.
    func update(visible: Bool, center: NSPoint) {
        isHidden = !visible
        dotCenter = center
        needsLayout = true

        guard let layer = dot.layer else { return }
        if !visible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.removeAnimation(forKey: Self.pulseKey)
        } else if layer.animation(forKey: Self.pulseKey) == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: Self.pulseKey)
        }
    }

    override func layout() {
        super.layout()
        guard let button = superview as? NSButton, let cell = button.cell as? NSButtonCell else { return }
        let image = cell.imageRect(forBounds: button.bounds)
        let size = Self.diameter
        dot.frame = NSRect(x: image.minX + dotCenter.x - size / 2, y: image.minY + dotCenter.y - size / 2,
                           width: size, height: size)
    }
}
