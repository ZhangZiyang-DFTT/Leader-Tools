import AppKit
import ImageIO
import UniformTypeIdentifiers

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                      bytesPerRow: pixels * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: Double(pixels) / 1024, y: Double(pixels) / 1024)
    c.setFillColor(CGColor(gray: 0.10, alpha: 1))
    c.addPath(CGPath(roundedRect: CGRect(x: 60, y: 60, width: 904, height: 904),
                     cornerWidth: 184, cornerHeight: 184, transform: nil))
    c.fillPath()
    c.setStrokeColor(CGColor(red: 0.33, green: 0.85, blue: 0.78, alpha: 1))
    c.setLineWidth(22)
    c.strokeEllipse(in: CGRect(x: 184, y: 184, width: 656, height: 656))
    c.setStrokeColor(CGColor(gray: 0.40, alpha: 1))
    c.setLineWidth(7)
    c.strokeEllipse(in: CGRect(x: 225, y: 225, width: 574, height: 574))
    c.move(to: CGPoint(x: 512, y: 512))
    c.addLine(to: CGPoint(x: 705, y: 716))
    c.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
    c.setLineWidth(12)
    c.strokePath()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    let text = "10" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 320, weight: .semibold),
        .foregroundColor: NSColor.white,
        .kern: 0
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(at: CGPoint(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2 + 12),
              withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    c.setFillColor(CGColor(red: 1, green: 0.65, blue: 0.25, alpha: 1))
    c.move(to: CGPoint(x: 469, y: 140))
    c.addLine(to: CGPoint(x: 555, y: 140))
    c.addLine(to: CGPoint(x: 512, y: 95))
    c.closePath()
    c.fillPath()
    let suffix = scale == 2 ? "@2x" : ""
    let url = folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, c.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Icon encoding failed") }
}
