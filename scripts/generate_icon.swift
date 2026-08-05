#!/usr/bin/env swift

import AppKit
import Foundation

// BatteryGlass 应用图标生成器
// 用法：swift scripts/generate_icon.swift（在项目根目录运行）

let fileManager = FileManager.default
let projectRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let resourcesDir = projectRoot.appendingPathComponent("Resources", isDirectory: true)
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)

try? fileManager.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat, scale: CGFloat) -> Data? {
    let pixelSize = Int(size * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = graphicsContext
    let ctx = graphicsContext.cgContext
    ctx.scaleBy(x: scale, y: scale)

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.219
    let squircle = CGPath(
        roundedRect: rect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    ctx.addPath(squircle)
    ctx.clip()

    // 深蓝 → 青的液态渐变（与面板流体玻璃一致）
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.12, green: 0.25, blue: 0.69, alpha: 1),
        CGColor(red: 0.15, green: 0.44, blue: 0.90, alpha: 1),
        CGColor(red: 0.20, green: 0.78, blue: 0.92, alpha: 1)
    ] as CFArray
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: colors,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    // 顶部玻璃光泽
    let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: -size * 0.15, y: size * 0.55, width: size * 0.9, height: size * 0.75))
    ctx.clip()
    ctx.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: size * 0.25, y: size * 0.85),
        startRadius: 0,
        endCenter: CGPoint(x: size * 0.25, y: size * 0.85),
        endRadius: size * 0.75,
        options: []
    )
    ctx.restoreGState()

    // 电池能量环（75% 弧线）
    let ringRect = CGRect(
        x: size * 0.22,
        y: size * 0.22,
        width: size * 0.56,
        height: size * 0.56
    )
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.32))
    ctx.setLineWidth(size * 0.028)
    ctx.setLineCap(.round)
    ctx.strokeEllipse(in: ringRect.insetBy(dx: size * 0.014, dy: size * 0.014))

    // 白色闪电
    let bolt = CGMutablePath()
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * size, y: y * size)
    }
    bolt.move(to: point(0.56, 0.16))
    bolt.addLine(to: point(0.31, 0.54))
    bolt.addLine(to: point(0.46, 0.54))
    bolt.addLine(to: point(0.41, 0.86))
    bolt.addLine(to: point(0.70, 0.44))
    bolt.addLine(to: point(0.54, 0.44))
    bolt.closeSubpath()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.addPath(bolt)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let entries: [(String, CGFloat, CGFloat)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2)
]

for (name, size, scale) in entries {
    guard let data = drawIcon(size: size, scale: scale) else {
        fatalError("无法绘制 \(name)")
    }
    let url = iconsetDir.appendingPathComponent(name)
    try? data.write(to: url)
    print("生成 \(name)")
}

let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("生成 AppIcon.icns")
} else {
    print("iconutil 失败，保留 iconset")
}
