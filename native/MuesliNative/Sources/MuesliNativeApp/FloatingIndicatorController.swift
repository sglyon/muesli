import AppKit
import QuartzCore
import Foundation

@MainActor
private final class HoverIndicatorView: NSView {
    weak var owner: FloatingIndicatorController?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        owner?.scheduleHoverExit()
    }
}

@MainActor
final class FloatingIndicatorController {
    private var panel: NSPanel?
    private var contentView: HoverIndicatorView?
    private var iconLabel: NSTextField?
    private var textLabel: NSTextField?
    private var state: DictationState = .idle
    private var isHovered = false
    private var hoverExitWorkItem: DispatchWorkItem?
    private let configStore: ConfigStore
    private var barLayers: [CALayer] = []
    private var amplitudeTimer: Timer?
    private var smoothedAmplitude: CGFloat = 0
    var powerProvider: (() -> Float)?

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    func setState(_ state: DictationState, config: AppConfig) {
        let previousState = self.state
        let previousHover = isHovered
        self.state = state
        if state != .idle {
            isHovered = false
        }
        guard config.showFloatingIndicator else {
            close()
            return
        }
        if panel == nil {
            createPanel(config: config)
        }
        guard let panel, let contentView, let iconLabel, let textLabel else { return }

        if previousState == .recording && state != .recording {
            stopWaveformAnimation()
        }

        let style = styleForState(state)
        let targetFrame = frameForState(state, config: config)

        let duration = transitionDuration(
            from: previousState,
            to: state,
            wasHovered: previousHover,
            isHovered: isHovered
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = style.alpha

            contentView.animator().frame = NSRect(origin: .zero, size: targetFrame.size)
            contentView.layer?.cornerRadius = targetFrame.height / 2
            contentView.layer?.backgroundColor = style.background.cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = style.border.cgColor

            if state == .recording {
                iconLabel.animator().alphaValue = 0
                textLabel.animator().alphaValue = 0
            } else {
                iconLabel.isHidden = false
                iconLabel.animator().alphaValue = 1
                iconLabel.stringValue = style.icon
                iconLabel.textColor = style.iconColor
                textLabel.stringValue = style.title
                textLabel.textColor = style.textColor
                textLabel.animator().alphaValue = style.title.isEmpty ? 0 : 1
                textLabel.isHidden = style.title.isEmpty
                layoutLabels(
                    iconLabel: iconLabel,
                    textLabel: textLabel,
                    in: targetFrame.size,
                    hasTitle: !style.title.isEmpty,
                    animated: true
                )
            }
        }

        if state == .recording {
            startWaveformAnimation(in: targetFrame.size)
        }

        panel.orderFrontRegardless()
    }

    func ensureVisible(config: AppConfig) {
        setState(state, config: config)
    }

    func setHovered(_ hovered: Bool) {
        guard state == .idle, isHovered != hovered else { return }
        hoverExitWorkItem?.cancel()
        isHovered = hovered
        let config = configStore.load()
        setState(.idle, config: config)
    }

    func scheduleHoverExit() {
        guard state == .idle, isHovered else { return }
        hoverExitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.pointerIsInsidePanel() else { return }
            self.setHovered(false)
        }
        hoverExitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: workItem)
    }

    func close() {
        stopWaveformAnimation()
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        panel?.close()
        panel = nil
        contentView = nil
        iconLabel = nil
        textLabel = nil
    }

    // MARK: - Waveform Animation

    private static let barCount = 5
    private static let barWidth: CGFloat = 3.0
    private static let barSpacing: CGFloat = 4.0
    private static let barMinHeight: CGFloat = 5.0
    private static let barMaxHeight: CGFloat = 26.0
    private static let barMultipliers: [CGFloat] = [0.6, 0.85, 1.0, 0.85, 0.6]

    private func startWaveformAnimation(in size: NSSize) {
        let savedProvider = powerProvider
        stopWaveformAnimation()
        powerProvider = savedProvider
        guard let contentView else { return }

        let totalWidth = CGFloat(Self.barCount) * Self.barWidth + CGFloat(Self.barCount - 1) * Self.barSpacing
        let startX = (size.width - totalWidth) / 2

        for i in 0..<Self.barCount {
            let bar = CALayer()
            let x = startX + CGFloat(i) * (Self.barWidth + Self.barSpacing)
            let height = Self.barMinHeight * Self.barMultipliers[i]
            bar.frame = CGRect(
                x: x,
                y: (size.height - height) / 2,
                width: Self.barWidth,
                height: height
            )
            bar.cornerRadius = Self.barWidth / 2
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(x: x + Self.barWidth / 2, y: size.height / 2)

            let anim = CABasicAnimation(keyPath: "transform.scale.y")
            anim.fromValue = 0.3
            anim.toValue = 1.0
            anim.duration = 0.6
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.beginTime = CACurrentMediaTime() + Double(i) * 0.07
            bar.add(anim, forKey: "pulse")

            contentView.layer?.addSublayer(bar)
            barLayers.append(bar)
        }

        smoothedAmplitude = 0
        amplitudeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateBarAmplitudes()
            }
        }
    }

    private func stopWaveformAnimation() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        for bar in barLayers {
            bar.removeAllAnimations()
            bar.removeFromSuperlayer()
        }
        barLayers.removeAll()
        smoothedAmplitude = 0
        powerProvider = nil
    }

    private func updateBarAmplitudes() {
        let dB = CGFloat(powerProvider?() ?? -160)
        let normalized = max(0, min(1, (dB + 40) / 35))
        smoothedAmplitude = smoothedAmplitude * 0.5 + normalized * 0.5

        let pillHeight = panel?.frame.height ?? 32
        for (i, bar) in barLayers.enumerated() {
            let multiplier = Self.barMultipliers[i]
            let height = Self.barMinHeight + smoothedAmplitude * (Self.barMaxHeight - Self.barMinHeight) * multiplier
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: height)
            bar.position = CGPoint(x: bar.position.x, y: pillHeight / 2)
            CATransaction.commit()
        }
    }

    private func createPanel(config: AppConfig) {
        let panel = NSPanel(
            contentRect: frameForState(.idle, config: config),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let contentView = HoverIndicatorView(frame: NSRect(origin: .zero, size: panel.frame.size))
        contentView.owner = self
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = panel.frame.height / 2
        contentView.layer?.masksToBounds = false

        let iconLabel = NSTextField(labelWithString: "")
        iconLabel.alignment = .center
        iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        contentView.addSubview(iconLabel)

        let textLabel = NSTextField(labelWithString: "")
        textLabel.alignment = .left
        textLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        contentView.addSubview(textLabel)

        panel.contentView = contentView

        self.panel = panel
        self.contentView = contentView
        self.iconLabel = iconLabel
        self.textLabel = textLabel
        setState(.idle, config: config)
    }

    private func frameForState(_ state: DictationState, config: AppConfig) -> NSRect {
        guard let screen = NSScreen.main?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: 64, height: 28)
        }
        let size: NSSize
        switch state {
        case .idle:
            size = isHovered ? NSSize(width: 220, height: 36) : NSSize(width: 44, height: 28)
        case .preparing: size = NSSize(width: 44, height: 28)
        case .recording: size = NSSize(width: 80, height: 32)
        case .transcribing: size = NSSize(width: 120, height: 32)
        }

        let origin: CGPoint
        if let manual = config.indicatorOrigin {
            origin = CGPoint(x: manual.x, y: manual.y)
        } else {
            origin = CGPoint(
                x: screen.maxX - size.width - 8,
                y: screen.minY + (screen.height * 0.56) - (size.height / 2)
            )
        }

        let x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        let y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func styleForState(_ state: DictationState) -> (background: NSColor, border: NSColor, icon: String, title: String, iconColor: NSColor, textColor: NSColor, alpha: CGFloat) {
        switch state {
        case .idle:
            return (
                .colorWith(hex: 0x000000, alpha: isHovered ? 0.96 : 0.66),
                .colorWith(hex: 0xFFFFFF, alpha: 0.18),
                "🎤",
                isHovered ? "Hold Left Cmd to dictate" : "",
                .colorWith(hex: 0xFFFFFF, alpha: 0.92),
                .colorWith(hex: 0xFFFFFF, alpha: 0.92),
                isHovered ? 1.0 : 0.82
            )
        case .preparing:
            return (
                .colorWith(hex: 0x3B4757, alpha: 0.94),
                .colorWith(hex: 0xFFFFFF, alpha: 0.24),
                "🎤",
                "",
                .white,
                .white,
                1.0
            )
        case .recording:
            return (
                .colorWith(hex: 0xD32F2F, alpha: 0.72),
                .colorWith(hex: 0xFFFFFF, alpha: 0.24),
                "🎤",
                "Listening",
                .white,
                .white,
                1.0
            )
        case .transcribing:
            return (
                .colorWith(hex: 0xD99A11, alpha: 0.72),
                .colorWith(hex: 0xFFFFFF, alpha: 0.24),
                "✍️",
                "Transcribing",
                .colorWith(hex: 0x1A140D, alpha: 0.95),
                .black,
                1.0
            )
        }
    }

    private func transitionDuration(from oldState: DictationState, to newState: DictationState, wasHovered: Bool, isHovered: Bool) -> TimeInterval {
        if oldState == .idle, newState == .idle, wasHovered != isHovered {
            return isHovered ? 0.24 : 0.2
        }
        if oldState == .idle || newState == .idle {
            return 0.18
        }
        return 0.16
    }

    private func layoutLabels(iconLabel: NSTextField, textLabel: NSTextField, in size: NSSize, hasTitle: Bool, animated: Bool) {
        if !hasTitle {
            let iconSize = iconLabel.attributedStringValue.size()
            let iconWidth = max(26, ceil(iconSize.width) + 4)
            let iconHeight = max(18, ceil(iconSize.height))
            let iconFrame = NSRect(
                x: (size.width - iconWidth) / 2,
                y: (size.height - iconHeight) / 2,
                width: iconWidth,
                height: iconHeight
            )
            if animated {
                iconLabel.animator().frame = iconFrame
                textLabel.animator().alphaValue = 0
                textLabel.animator().frame = .zero
            } else {
                iconLabel.frame = iconFrame
                textLabel.alphaValue = 0
                textLabel.frame = .zero
            }
            return
        }

        let iconSize = iconLabel.attributedStringValue.size()
        let textSize = textLabel.attributedStringValue.size()
        let gap: CGFloat = 4

        let iconWidth = max(24, ceil(iconSize.width) + 2)
        let iconHeight = max(18, ceil(iconSize.height))
        let textWidth = ceil(textSize.width) + 2
        let textHeight = max(16, ceil(textSize.height))

        let totalWidth = iconWidth + gap + textWidth
        let originX = max((size.width - totalWidth) / 2, 12)

        let iconFrame = NSRect(
            x: originX,
            y: (size.height - iconHeight) / 2,
            width: iconWidth,
            height: iconHeight
        )
        let textFrame = NSRect(
            x: originX + iconWidth + gap,
            y: (size.height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        if animated {
            iconLabel.animator().frame = iconFrame
            textLabel.animator().alphaValue = 1
            textLabel.animator().frame = textFrame
        } else {
            iconLabel.frame = iconFrame
            textLabel.alphaValue = 1
            textLabel.frame = textFrame
        }
    }

    private func pointerIsInsidePanel() -> Bool {
        guard let panel else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }
}

private extension NSColor {
    static func colorWith(hex: Int, alpha: CGFloat) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
