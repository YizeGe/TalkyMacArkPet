// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 MacArkPet contributors

import AppKit

// MARK: - 流體玻璃對話氣泡

final class SpeechBubbleWindow: NSWindow {
    private let container = SpeechBubbleContainer()
    private var isAppearing = false
    private var isDisappearing = false

    var bubbleSize: NSSize { container.bubbleSize }

    init() {
        let startFrame = NSRect(x: 0, y: 0, width: 200, height: 60)
        super.init(contentRect: startFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        container.wantsLayer = true
        contentView = container
    }

    func setText(_ text: String) {
        container.setText(text)
    }

    func fadeIn() {
        guard !isAppearing else { return }
        isAppearing = true
        isDisappearing = false

        if alphaValue > 0.01 && isVisible {
            isAppearing = false
            return
        }

        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            self?.isAppearing = false
        }
    }

    func fadeOut(completion: (() -> Void)? = nil) {
        guard !isDisappearing else { return }
        isDisappearing = true

        if alphaValue < 0.01 || !isVisible {
            orderOut(nil)
            isDisappearing = false
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
            self?.isDisappearing = false
            completion?()
        }
    }
}

// MARK: - 气泡内容视图

private final class SpeechBubbleContainer: NSView {
    private let textLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        field.textColor = NSColor(calibratedWhite: 0.08, alpha: 1) // 深黑色（毛玻璃上更清晰）
        field.alignment = .left
        field.maximumNumberOfLines = 4
        field.lineBreakMode = .byWordWrapping
        return field
    }()

    private let blurView = NSVisualEffectView()
    private let glowLayer = CAGradientLayer()
    private let shapeMask = CAShapeLayer()
    private let borderLayer = CAShapeLayer()

    private var currentText: String = ""
    private(set) var bubbleSize: NSSize = NSSize(width: 200, height: 60)

    // 布局常量
    private let padH: CGFloat = 20
    private let padV: CGFloat = 12
    private let arrowH: CGFloat = 10
    private let arrowW: CGFloat = 16
    private let cornerRadius: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // --- 毛玻璃效果层 ---
        blurView.material = .hudWindow
        blurView.blendingMode = .withinWindow
        blurView.state = .active
        blurView.wantsLayer = true
        addSubview(blurView)

        // --- 表面光泽层（流体的高光效果） ---
        glowLayer.colors = [
            NSColor.white.withAlphaComponent(0.25).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.clear.cgColor,
        ]
        glowLayer.locations = [0, 0.5, 1]
        glowLayer.startPoint = CGPoint(x: 0, y: 1)
        glowLayer.endPoint = CGPoint(x: 0, y: 0)
        glowLayer.zPosition = 1
        blurView.layer?.addSublayer(glowLayer)

        // --- 边框描边层 ---
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.30).cgColor
        borderLayer.lineWidth = 1.0
        borderLayer.zPosition = 2
        blurView.layer?.addSublayer(borderLayer)

        // 毛玻璃背景上黑色文字不需要阴影
        addSubview(textLabel)

        self.shapeMask.fillRule = .evenOdd
        blurView.layer?.mask = shapeMask
        blurView.layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { nil }

    func setText(_ text: String) {
        currentText = text
        textLabel.stringValue = text

        let screenWidth = NSScreen.main?.frame.width ?? 800
        let maxW = min(screenWidth * 0.48, 380) - padH * 2

        textLabel.preferredMaxLayoutWidth = maxW
        let textMaxSize = NSSize(width: maxW, height: 140)
        let textSize = textLabel.sizeThatFits(textMaxSize)
        let textW = min(maxW, ceil(textSize.width))
        let textH = max(20, ceil(textSize.height))

        let contentW = textW + padH * 2
        let contentH = padV * 2 + textH
        let totalH = contentH + arrowH

        bubbleSize = NSSize(width: ceil(contentW), height: ceil(totalH))

        if let window = self.window {
            window.setContentSize(bubbleSize)
        }
        window?.invalidateShadow()
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let contentTop = bounds.height - arrowH
        
        let screenWidth = NSScreen.main?.frame.width ?? 800
        let maxW = min(screenWidth * 0.48, 380) - padH * 2
        textLabel.preferredMaxLayoutWidth = maxW
        let textMaxSize = NSSize(width: maxW, height: 140)
        let textSize = textLabel.sizeThatFits(textMaxSize)
        let textH = max(20, ceil(textSize.height))
        
        let bubbleH = padV * 2 + textH
        let bubbleBottom: CGFloat = contentTop - bubbleH

        // 更新毛玻璃层
        blurView.frame = NSRect(
            x: 0, y: 0,
            width: bounds.width,
            height: bounds.height
        )

        // 文本位置
        textLabel.frame = NSRect(
            x: padH,
            y: contentTop - padV - textH,
            width: bounds.width - padH * 2,
            height: textH
        )

        // --- 生成气泡+箭头遮罩路径 ---
        let path = CGMutablePath()
        let bubbleRect = CGRect(
            x: padH,
            y: bubbleBottom,
            width: bounds.width - padH * 2,
            height: bubbleH
        )

        // 气泡圆角矩形
        path.addRoundedRect(in: bubbleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)

        // 箭头（向下，在气泡底部居中）
        let arrowMidX = bounds.width / 2
        path.move(to: CGPoint(x: arrowMidX - arrowW / 2, y: bubbleBottom))
        path.addLine(to: CGPoint(x: arrowMidX, y: bubbleBottom - arrowH))
        path.addLine(to: CGPoint(x: arrowMidX + arrowW / 2, y: bubbleBottom))
        path.closeSubpath()

        shapeMask.path = path

        // 光泽层渐变
        let glowH = bubbleH * 0.55
        glowLayer.frame = CGRect(
            x: padH,
            y: bubbleBottom + bubbleH - glowH,
            width: bubbleRect.width,
            height: glowH
        )

        // 边框路径（和遮罩相同，但只是描边）
        borderLayer.path = path
    }
}
