import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 程序画的专辑封面（600×600 JPEG）：每种风格一套图形，再写上专辑名与艺人名。
enum Cover {
    enum Style { case morning, night, fields }
    static let size = 600

    static func draw(_ style: Style, title: String, artist: String) throws -> Data {
        let s = CGFloat(size)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WriterError.failed("画布") }
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        func gradient(_ top: UInt32, _ bottom: UInt32) {
            let g = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
        }
        var textColor = color(0x2B2420)

        switch style {
        case .morning:
            // 晨光：暖色渐变、半个太阳、几道光、底部一排琴键
            gradient(0xFFE2C6, 0xFFF6E8)
            ctx.setFillColor(color(0xFFB36B, 0.9))
            ctx.fillEllipse(in: CGRect(x: s * 0.5 - 150, y: s * 0.32 - 150, width: 300, height: 300))
            ctx.setStrokeColor(color(0xFFC98F, 0.6))
            ctx.setLineWidth(6)
            for k in 0..<9 {
                let angle = CGFloat.pi * CGFloat(k) / 8
                ctx.move(to: CGPoint(x: s * 0.5 + cos(angle) * 175, y: s * 0.32 + sin(angle) * 175))
                ctx.addLine(to: CGPoint(x: s * 0.5 + cos(angle) * 235, y: s * 0.32 + sin(angle) * 235))
            }
            ctx.strokePath()
            ctx.setFillColor(color(0xFFFFFF))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s * 0.2))
            let white = s / 14
            ctx.setStrokeColor(color(0xD8CFC4)); ctx.setLineWidth(2)
            for k in 0...14 {
                ctx.move(to: CGPoint(x: CGFloat(k) * white, y: 0)); ctx.addLine(to: CGPoint(x: CGFloat(k) * white, y: s * 0.2))
            }
            ctx.strokePath()
            ctx.setFillColor(color(0x2B2420))
            for k in [0, 1, 3, 4, 5, 7, 8, 10, 11, 12] {
                ctx.fill(CGRect(x: CGFloat(k + 1) * white - white * 0.3, y: s * 0.075, width: white * 0.6, height: s * 0.125))
            }
        case .night:
            // 夜行：深蓝到紫、透视网格、霓虹圆环与扫描线
            gradient(0x0B1033, 0x2A0E4A)
            ctx.setStrokeColor(color(0x3EE6FF, 0.55)); ctx.setLineWidth(2)
            let horizon = s * 0.42
            for k in 0...16 {
                let x = CGFloat(k) / 16 * s
                ctx.move(to: CGPoint(x: s / 2 + (x - s / 2) * 0.15, y: horizon)); ctx.addLine(to: CGPoint(x: s / 2 + (x - s / 2) * 2.2, y: 0))
            }
            var y = horizon
            var step: CGFloat = 8
            while y > 0 { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: s, y: y)); y -= step; step *= 1.35 }
            ctx.strokePath()
            for (r, alpha) in [(150.0, 0.95), (165.0, 0.35), (180.0, 0.15)] {
                ctx.setStrokeColor(color(0xFF3FD3, alpha)); ctx.setLineWidth(5)
                ctx.strokeEllipse(in: CGRect(x: s / 2 - r, y: horizon + 30 - r * 0.2, width: r * 2, height: r * 2))
            }
            ctx.setFillColor(color(0x0B1033, 0.35))
            var line: CGFloat = 0
            while line < s { ctx.fill(CGRect(x: 0, y: line, width: s, height: 2)); line += 6 }
            textColor = color(0xF2F6FF)
        case .fields:
            // 原野：天蓝渐变、几层起伏的山丘、一条弯弯的小路
            gradient(0x9ED8F5, 0xE9F7FF)
            for (base, amp, hex) in [(0.46, 30.0, 0x9CCB86), (0.36, 24.0, 0x7DB46C), (0.24, 20.0, 0x5E9A55)] as [(CGFloat, CGFloat, UInt32)] {
                ctx.setFillColor(color(hex))
                ctx.move(to: CGPoint(x: 0, y: 0))
                for k in 0...60 {
                    let x = CGFloat(k) / 60 * s
                    ctx.addLine(to: CGPoint(x: x, y: s * base + sin(x / s * 2 * .pi * 1.3 + base * 9) * amp))
                }
                ctx.addLine(to: CGPoint(x: s, y: 0)); ctx.closePath(); ctx.fillPath()
            }
            ctx.setFillColor(color(0xF1E3C2))
            ctx.move(to: CGPoint(x: s * 0.38, y: 0))
            ctx.addCurve(to: CGPoint(x: s * 0.52, y: s * 0.43), control1: CGPoint(x: s * 0.6, y: s * 0.15), control2: CGPoint(x: s * 0.35, y: s * 0.3))
            ctx.addLine(to: CGPoint(x: s * 0.535, y: s * 0.43))
            ctx.addCurve(to: CGPoint(x: s * 0.68, y: 0), control1: CGPoint(x: s * 0.42, y: s * 0.3), control2: CGPoint(x: s * 0.78, y: s * 0.15))
            ctx.closePath(); ctx.fillPath()
            ctx.setFillColor(color(0xFFFFFF, 0.9))
            for (cx, cy) in [(0.2, 0.86), (0.27, 0.88), (0.72, 0.8), (0.8, 0.82)] as [(CGFloat, CGFloat)] {
                ctx.fillEllipse(in: CGRect(x: s * cx - 40, y: s * cy - 18, width: 80, height: 36))
            }
        }

        // 文字：专辑名大字、艺人名小字，放在左上角
        func text(_ string: String, size: CGFloat, weight: String, at point: CGPoint) {
            let font = CTFontCreateWithName(weight as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                              .init(kCTForegroundColorAttributeName as String): textColor]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            ctx.textPosition = point
            CTLineDraw(line, ctx)
        }
        text(title, size: 52, weight: "PingFangSC-Semibold", at: CGPoint(x: 44, y: s - 100))
        text(artist, size: 26, weight: "PingFangSC-Regular", at: CGPoint(x: 46, y: s - 145))

        guard let image = ctx.makeImage() else { throw WriterError.failed("生成图片") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw WriterError.failed("JPEG") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw WriterError.failed("JPEG 编码") }
        return out as Data
    }
}
