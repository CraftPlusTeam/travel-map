import AppKit

let directory = CommandLine.arguments.dropFirst().first ?? "TravelMap/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(NSColor(srgbRed: 0.04, green: 0.38, blue: 0.35, alpha: 1).cgColor)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
// A folded map and a location pin, drawn as vectors at export size.
let map = CGMutablePath()
map.move(to: CGPoint(x: 180, y: 266))
map.addLine(to: CGPoint(x: 393, y: 330))
map.addLine(to: CGPoint(x: 615, y: 266))
map.addLine(to: CGPoint(x: 838, y: 330))
map.addLine(to: CGPoint(x: 838, y: 660))
map.addLine(to: CGPoint(x: 615, y: 596))
map.addLine(to: CGPoint(x: 393, y: 660))
map.addLine(to: CGPoint(x: 180, y: 596))
map.closeSubpath()
context.addPath(map)
context.setFillColor(NSColor.white.cgColor)
context.fillPath()
context.setStrokeColor(NSColor(srgbRed: 0.04, green: 0.38, blue: 0.35, alpha: 0.25).cgColor)
context.setLineWidth(12)
for x in [393.0, 615.0] {
    context.move(to: CGPoint(x: x, y: x == 393 ? 330 : 266))
    context.addLine(to: CGPoint(x: x, y: x == 393 ? 660 : 596))
    context.strokePath()
}
let pin = CGMutablePath()
pin.move(to: CGPoint(x: 512, y: 409))
pin.addCurve(to: CGPoint(x: 358, y: 668), control1: CGPoint(x: 467, y: 488), control2: CGPoint(x: 358, y: 555))
pin.addCurve(to: CGPoint(x: 666, y: 668), control1: CGPoint(x: 358, y: 875), control2: CGPoint(x: 666, y: 875))
pin.addCurve(to: CGPoint(x: 512, y: 409), control1: CGPoint(x: 666, y: 555), control2: CGPoint(x: 557, y: 488))
context.addPath(pin)
context.setFillColor(NSColor(srgbRed: 1, green: 0.48, blue: 0.30, alpha: 1).cgColor)
context.fillPath()
context.setFillColor(NSColor.white.cgColor)
context.fillEllipse(in: CGRect(x: 451, y: 622, width: 122, height: 122))
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("AppIcon.png"))
let contents = """
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try contents.write(toFile: directory + "/Contents.json", atomically: true, encoding: .utf8)
