// 把黑白的圖示原稿轉成單色遮罩：黑色不透明、白色透明（選單列 template 圖示與 App 圖示前景都用 alpha 當遮罩）
// 用法：swift assets/menubar/make-glyph.swift assets/icon/glyph-source.png assets/menubar/glyph.png
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let source = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: make-glyph.swift <source.png> <output.png>")
    exit(1)
}

let width = source.width, height = source.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// 先鋪白底，原稿透明的地方也當成白色（透明）
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

for index in stride(from: 0, to: pixels.count, by: 4) {
    let luminance = (Int(pixels[index]) * 299 + Int(pixels[index + 1]) * 587 + Int(pixels[index + 2]) * 114) / 1000
    // premultiplied：黑色 RGB 都是 0，只需要設定 alpha
    pixels[index] = 0
    pixels[index + 1] = 0
    pixels[index + 2] = 0
    pixels[index + 3] = UInt8(255 - luminance)
}

let output = NSBitmapImageRep(cgImage: context.makeImage()!)
try! output.representation(using: .png, properties: [:])!.write(to: URL(filePath: arguments[2]))
print("wrote \(arguments[2])")
