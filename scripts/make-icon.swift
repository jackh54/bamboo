#!/usr/bin/env swift
// Draws Bamboo's app icon with Core Graphics at every size macOS uses and
// writes the PNGs and Contents.json into the app's AppIcon asset.
//
// Usage (from the repository root): swift scripts/make-icon.swift
//
// The artwork follows Apple's macOS icon grid: on a 1024 px canvas the tile is
// an 824 px superellipse ("squircle") inset 100 px, with a soft drop shadow.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(fileURLWithPath: "app/Bamboo/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations) else {
        fatalError("Cannot make a gradient")
    }
    return gradient
}

/// Apple's icon tile: a superellipse, |x|^n + |y|^n = 1 with n = 5.
func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let exponent = 5.0
    let steps = 720
    for step in 0...steps {
        let angle = Double(step) / Double(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = pow(abs(cosine), 2 / exponent) * (cosine < 0 ? -1 : 1)
        let y = pow(abs(sine), 2 / exponent) * (sine < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// A bamboo culm rising from below the tile, shaded like a cylinder, with nodes.
func drawStalk(_ context: CGContext, centerX: CGFloat, top: CGFloat, width: CGFloat, nodes: [CGFloat]) {
    let culm = CGRect(x: centerX - width / 2, y: 40, width: width, height: top - 40)
    context.saveGState()
    context.addPath(CGPath(roundedRect: culm, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
    context.clip()
    context.drawLinearGradient(
        gradient([color(0xDDEFCF), color(0xFBFDF4), color(0xE6F2D9), color(0xB9D8A2)], [0, 0.32, 0.62, 1]),
        start: CGPoint(x: culm.minX, y: 0), end: CGPoint(x: culm.maxX, y: 0), options: [])
    for node in nodes {
        // The ring is a darker band with a light lip above it.
        context.setFillColor(color(0x8FBF78, 0.9))
        context.fill(CGRect(x: culm.minX, y: node - 7, width: width, height: 10))
        context.setFillColor(color(0xFFFFFF, 0.75))
        context.fill(CGRect(x: culm.minX, y: node + 3, width: width, height: 4))
    }
    context.restoreGState()
    context.setStrokeColor(color(0x0E5E37, 0.18))
    context.setLineWidth(3)
    context.addPath(CGPath(roundedRect: culm, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
    context.strokePath()
}

/// A lance-shaped leaf from `base`, `length` long, pointing at `angle` radians.
func drawLeaf(_ context: CGContext, base: CGPoint, length: CGFloat, width: CGFloat, angle: CGFloat) {
    context.saveGState()
    context.translateBy(x: base.x, y: base.y)
    context.rotate(by: angle)
    let leaf = CGMutablePath()
    leaf.move(to: .zero)
    leaf.addCurve(to: CGPoint(x: length, y: 0),
                  control1: CGPoint(x: length * 0.25, y: width), control2: CGPoint(x: length * 0.7, y: width * 0.55))
    leaf.addCurve(to: .zero,
                  control1: CGPoint(x: length * 0.7, y: -width * 0.45), control2: CGPoint(x: length * 0.25, y: -width * 0.8))
    leaf.closeSubpath()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x0B4A2A, 0.35))
    context.addPath(leaf)
    context.setFillColor(color(0xF2FAEA))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.addPath(leaf)
    context.clip()
    context.drawLinearGradient(gradient([color(0xEFFADF), color(0xA9DE8A)], [0, 1]),
                               start: CGPoint(x: 0, y: width), end: CGPoint(x: length, y: -width), options: [])
    context.setStrokeColor(color(0x4F9443, 0.6))
    context.setLineWidth(4)
    context.move(to: CGPoint(x: length * 0.04, y: 0))
    context.addQuadCurve(to: CGPoint(x: length * 0.92, y: 0), control: CGPoint(x: length * 0.5, y: width * 0.12))
    context.strokePath()
    context.restoreGState()
}

func drawIcon(_ context: CGContext) {
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = squircle(in: tileRect)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
    context.addPath(tile)
    context.setFillColor(color(0x1F8A5A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(gradient([color(0x7BDDA4), color(0x2FA36B), color(0x0F6B40)], [0, 0.5, 1]),
                               start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.drawRadialGradient(gradient([color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)], [0, 1]),
                               startCenter: CGPoint(x: 330, y: 820), startRadius: 0,
                               endCenter: CGPoint(x: 330, y: 820), endRadius: 520, options: [])

    // A short culm behind, a tall one in front, and two leaves from the tall one's top node.
    drawStalk(context, centerX: 640, top: 690, width: 74, nodes: [300, 500])
    drawStalk(context, centerX: 440, top: 860, width: 98, nodes: [250, 470, 680])
    drawLeaf(context, base: CGPoint(x: 470, y: 690), length: 300, width: 62, angle: 0.62)
    drawLeaf(context, base: CGPoint(x: 476, y: 676), length: 250, width: 52, angle: -0.08)
    drawLeaf(context, base: CGPoint(x: 410, y: 480), length: 210, width: 44, angle: 2.75)

    context.restoreGState()

    // A hairline edge so the tile reads on light and dark backgrounds alike.
    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, 0.22))
    context.setLineWidth(3)
    context.strokePath()
}

func render(pixels: Int) -> Data {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Cannot make a \(pixels) px context") }
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(context)
    guard let image = context.makeImage() else { fatalError("Cannot render \(pixels) px") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot encode PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot encode \(pixels) px PNG") }
    return data as Data
}

var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: outputDirectory.appendingPathComponent(filename))
        entries.append(#"    { "filename" : "\#(filename)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
        print("wrote \(filename)")
    }
}
let contents = """
    {
      "images" : [
    \(entries.joined(separator: ",\n"))
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """
try contents.write(to: outputDirectory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
