import AppKit
// README 截圖裁切：swift scripts/crop-screenshot.swift <輸入> <輸出> <上方裁掉的像素> <保留高度>
// sips -c 實測沒有裁切（輸出大小不變），所以用 CoreGraphics
let a = CommandLine.arguments
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(filePath: a[1])))!
let img = rep.cgImage!
let top = Int(a[3])!, height = Int(a[4])!
let cropped = img.cropping(to: CGRect(x: 0, y: top, width: img.width, height: height))!
let out = NSBitmapImageRep(cgImage: cropped)
try! out.representation(using: .png, properties: [:])!.write(to: URL(filePath: a[2]))
print("\(a[2]): \(cropped.width)x\(cropped.height)")
