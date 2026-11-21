import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let tile = CGPath(roundedRect: CGRect(x: 92, y: 92, width: 840, height: 840),
                  cornerWidth: 186, cornerHeight: 186, transform: nil)
let gradient = CGGradient(colorsSpace: rgb, colors: [
    CGColor(srgbRed: 0.43, green: 0.33, blue: 0.84, alpha: 1),
    CGColor(srgbRed: 0.23, green: 0.16, blue: 0.54, alpha: 1)
] as CFArray, locations: [0, 1])!

func png(pixels: Int) -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                            space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 900), end: CGPoint(x: 800, y: 90), options: [])
    context.setFillColor(CGColor(srgbRed: 1, green: 0.98, blue: 0.92, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 274, y: 340, width: 476, height: 400),
                           cornerWidth: 115, cornerHeight: 115, transform: nil))
    context.fillPath()
    context.move(to: CGPoint(x: 388, y: 370))
    context.addLine(to: CGPoint(x: 375, y: 271))
    context.addLine(to: CGPoint(x: 506, y: 362))
    context.closePath()
    context.fillPath()
    context.setFillColor(CGColor(srgbRed: 0.33, green: 0.24, blue: 0.67, alpha: 1))
    for y in [450, 566] { context.fillEllipse(in: CGRect(x: 472, y: y, width: 80, height: 80)) }
    let bytes = NSMutableData()
    let output = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output))
    return bytes as Data
}

// Each ICNS element consists of a four-character type, a big-endian length
// (including its eight-byte header), and its payload.
func chunk(_ type: String, _ payload: Data) -> Data {
    var data = Data(type.utf8)
    withUnsafeBytes(of: UInt32(payload.count + 8).bigEndian) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}
var icons = Data()
for (type, pixels) in [("icp4", 16), ("icp5", 32), ("ic07", 128), ("ic08", 256), ("ic09", 512),
                       ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512), ("ic10", 1024)] {
    icons.append(chunk(type, png(pixels: pixels)))
}
try chunk("icns", icons).write(to: destination)
