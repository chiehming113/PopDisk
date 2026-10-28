// 產生 App 圖示（Icon Composer 格式 PopDisk/AppIcon.icon）用的前景圖層：1024×1024 透明底、白色圖案置中
// 用法：swift assets/icon/make-icon.swift assets/menubar/glyph.png PopDisk/AppIcon.icon/Assets/glyph.png
//
// 背景色（黑）、陰影、玻璃效果寫在 PopDisk/AppIcon.icon/icon.json，由系統依 macOS 版本繪製；
// macOS 26 以前的舊格式圖示由 Xcode 建置時自動產生。
// 圖示是滿版的（系統會裁成圓角），圖案約佔 60%，和舊版圓角方形內的比例相同。
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let glyphImage = NSImage(contentsOfFile: arguments[1]),
      let glyph = glyphImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: make-icon.swift <glyph.png> <output.png>")
    exit(1)
}

let size = 1024
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// 圖案用原圖的 alpha 當遮罩，填白色
let side = 620.0
let glyphRect = CGRect(x: (1024 - side) / 2, y: (1024 - side) / 2, width: side, height: side)
context.clip(to: glyphRect, mask: glyph)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(glyphRect)

let output = NSBitmapImageRep(cgImage: context.makeImage()!)
try! output.representation(using: .png, properties: [:])!.write(to: URL(filePath: arguments[2]))
print("wrote \(arguments[2])")
