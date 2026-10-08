import Foundation
import CoreGraphics
import ImageIO

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("无法创建上下文")
}

// 1) 圆角方形底（macOS 图标约 200 圆角）
let rect = CGRect(x: 0, y: 0, width: S, height: S)
let radius: CGFloat = 200
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

// 2) 对角渐变背景
let colors = [
    CGColor(red: 0.36, green: 0.66, blue: 0.98, alpha: 1.0),
    CGColor(red: 0.12, green: 0.36, blue: 0.78, alpha: 1.0)
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 120, y: S - 120), end: CGPoint(x: S - 120, y: 120), options: [])

// 3) 白色下载箭头（向下箭头 + 托盘）
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

// 箭杆
let shaft = CGRect(x: 472, y: 490, width: 80, height: 180)
ctx.addPath(CGPath(roundedRect: shaft, cornerWidth: 40, cornerHeight: 40, transform: nil))
ctx.fillPath()

// 箭头（三角）
ctx.move(to: CGPoint(x: 356, y: 490))
ctx.addLine(to: CGPoint(x: 668, y: 490))
ctx.addLine(to: CGPoint(x: 512, y: 390))
ctx.closePath()
ctx.fillPath()

// 托盘
let tray = CGRect(x: 316, y: 300, width: 392, height: 70)
ctx.addPath(CGPath(roundedRect: tray, cornerWidth: 35, cornerHeight: 35, transform: nil))
ctx.fillPath()

// 4) 输出 PNG
guard let image = ctx.makeImage() else { fatalError("生成图像失败") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("无法创建输出")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("写入失败") }
print("icon written: \(out.path)")
