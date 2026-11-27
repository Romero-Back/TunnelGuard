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
                            colors: [color(0.16, 0.73, 0.51), color(0.07, 0.41, 0.34), color(0.04, 0.19, 0.24)] as CFArray,
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

// The route bends at the filter before continuing to the VPN exit.
let nodes = [CGPoint(x: 413, y: 448), CGPoint(x: 512, y: 548), CGPoint(x: 613, y: 548)]
context.setStrokeColor(color(0.72, 1, 0.87))
context.setLineWidth(28)
context.setLineCap(.round)
context.move(to: nodes[0])
for node in nodes.dropFirst() { context.addLine(to: node) }
context.strokePath()
for node in nodes {
    context.setFillColor(color(0.83, 1, 0.91))
    context.fillEllipse(in: CGRect(x: node.x - 27, y: node.y - 27, width: 54, height: 54))
}

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
