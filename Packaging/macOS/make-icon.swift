import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

let frame = CGRect(x: 93, y: 93, width: 838, height: 838)
let tile = CGPath(roundedRect: frame, cornerWidth: 202, cornerHeight: 202, transform: nil)
context.saveGState()
context.addPath(tile)
context.clip()
let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [color(0.10, 0.60, 0.52), color(0.055, 0.25, 0.30), color(0.04, 0.13, 0.22)] as CFArray,
                            locations: [0, 0.57, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 180, y: 880), end: CGPoint(x: 870, y: 130), options: [])
context.restoreGState()
context.addPath(tile)
context.setStrokeColor(color(0.80, 1, 0.95, 0.20))
context.setLineWidth(3)
context.strokePath()

let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 742))
shield.addQuadCurve(to: CGPoint(x: 718, y: 656), control: CGPoint(x: 624, y: 675))
shield.addLine(to: CGPoint(x: 718, y: 516))
shield.addQuadCurve(to: CGPoint(x: 512, y: 287), control: CGPoint(x: 718, y: 386))
shield.addQuadCurve(to: CGPoint(x: 306, y: 516), control: CGPoint(x: 306, y: 386))
shield.addLine(to: CGPoint(x: 306, y: 656))
shield.addQuadCurve(to: CGPoint(x: 512, y: 742), control: CGPoint(x: 400, y: 675))
shield.closeSubpath()
context.addPath(shield)
context.setFillColor(color(0.73, 1, 0.91, 0.11))
context.setStrokeColor(color(0.85, 1, 0.95))
context.setLineJoin(.round)
context.setLineWidth(32)
context.drawPath(using: .fillStroke)

context.setStrokeColor(color(0.67, 1, 0.86))
context.setLineWidth(37)
context.setLineCap(.round)
context.move(to: CGPoint(x: 417, y: 517))
context.addLine(to: CGPoint(x: 484, y: 451))
context.addLine(to: CGPoint(x: 610, y: 581))
context.strokePath()

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
