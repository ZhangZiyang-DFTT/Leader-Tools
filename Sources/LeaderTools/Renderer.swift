import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CLeader

final class LeaderRenderer {
    let width: Int
    let height: Int
    let space: CGColorSpace
    let context: CGContext
    private let memory: UnsafeMutableRawPointer
    private var fonts: [String: CTFont] = [:]
    private var logoSource: Data?
    private var logo: CGImage?
    private var invertedInk = false
    private var designWidth: Double { Double(width) / Double(height) * 1080 }

    init(width: Int, height: Int) throws {
        self.width = width; self.height = height
        space = CGColorSpace(name: CGColorSpace.itur_709)!
        memory = .allocate(byteCount: width * height * 16, alignment: 64)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: width * height * 16)
        guard let c = CGContext(data: memory, width: width, height: height,
                                bitsPerComponent: 32, bytesPerRow: width * 16, space: space,
                                bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue
                                | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            memory.deallocate(); throw LeaderError("无法建立浮点绘图画布。")
        }
        context = c
        // Use coverage antialiasing, not contrast-dependent font smoothing.
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
    }
    deinit { memory.deallocate() }
    var pixels: UnsafePointer<Float> { UnsafePointer(memory.assumingMemoryBound(to: Float.self)) }
    private func color(_ v: Double) -> CGColor {
        let level = invertedInk ? 1 - v : v
        return CGColor(colorSpace: space, components: [level, level, level, 1])!
    }
    private func font(_ size: Double, bold: Bool) -> CTFont {
        let name = bold ? "HelveticaNeue-Bold" : "HelveticaNeue-Medium"
        let key = "\(name)-\(size)"
        if let cached = fonts[key] { return cached }
        let f = CTFontCreateWithName(name as CFString, size, nil)
        fonts[key] = f
        return f
    }
    private func text(_ string: String, x: Double, y: Double, size: Double,
                      value: Double = 1, maxWidth: Double = 1600, bold: Bool = false,
                      accent: Bool = false) {
        let ink = accent ? CGColor(colorSpace: space, components: [1, 0.64, 0.20, 1])! : color(value)
        let attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font(size, bold: bold),
            .init(kCTForegroundColorAttributeName as String): ink, .kern: 0
        ]
        let ct = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        var ascent: CGFloat = 0; var descent: CGFloat = 0
        let w = CTLineGetTypographicBounds(ct, &ascent, &descent, nil)
        let factor = min(1, maxWidth / max(w, 1))
        context.saveGState()
        context.translateBy(x: x, y: y)
        context.scaleBy(x: factor, y: -factor)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -w / 2, y: -(ascent - descent) / 2)
        CTLineDraw(ct, context)
        context.restoreGState()
    }
    private func notes(_ string: String, rect: CGRect) {
        guard !string.isEmpty else { return }
        var size = 44.0
        var setter: CTFramesetter!
        var bounds = CGSize.zero
        repeat {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = size * 0.30; style.alignment = .left
            setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                .init(kCTFontAttributeName as String): font(size, bold: false),
                .init(kCTForegroundColorAttributeName as String): color(1),
                .paragraphStyle: style, .kern: 0
            ]))
            bounds = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0),
                nil, CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            if bounds.height <= rect.height { break }
            size -= 1
        } while size >= 20
        let h = min(rect.height, ceil(bounds.height) + 4)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.midY + h / 2)
        context.scaleBy(x: 1, y: -1); context.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: h), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        context.restoreGState()
    }
    private func line(_ a: CGPoint, _ b: CGPoint, value: Double, width: Double = 2) {
        context.setStrokeColor(color(value)); context.setLineWidth(width)
        context.beginPath(); context.move(to: a); context.addLine(to: b); context.strokePath()
    }
    private func circle(x: Double, y: Double, r: Double, stroke: Double, lineWidth: Double, fill: Double? = nil) {
        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
        if let fill { context.setFillColor(color(fill)); context.fillEllipse(in: rect) }
        context.setStrokeColor(color(stroke)); context.setLineWidth(lineWidth); context.strokeEllipse(in: rect)
    }
    static func tickAngles(_ nominal: Int) -> [Double] {
        (0..<nominal).map { Double($0) / Double(nominal) * 2 * .pi - .pi / 2 }
    }
    private func clocks(settings: LeaderSettings, state: FrameState, kind: LeaderKind, invertClocks: Bool) {
        let previousInk = invertedInk
        invertedInk = invertClocks
        let w = designWidth, x = w * 0.63, y = 540.0, r = 385.0
        let smallX = w * 0.195, smallY = 360.0, smallR = min(195, w * 0.125)
        circle(x: x, y: y, r: r, stroke: 1, lineWidth: 8, fill: 0)
        circle(x: x, y: y, r: r - 48, stroke: 1, lineWidth: 4, fill: 0.27)
        let angle = state.phase * 2 * Double.pi - .pi / 2
        if state.phase > 0 {
            context.beginPath(); context.move(to: CGPoint(x: x, y: y))
            context.addArc(center: CGPoint(x: x, y: y), radius: r - 51,
                           startAngle: -.pi / 2, endAngle: angle, clockwise: false)
            context.closePath(); context.setFillColor(color(0.34)); context.fillPath()
        }
        let n = settings.rate.nominal
        let angles = Self.tickAngles(n)
        let current = min(n - 1, Int((state.phase * Double(n) + 0.000001).rounded(.down)))
        let labels = n <= 60 ? n : (1...30).filter { n % $0 == 0 }.max()!
        let step = n / labels
        for f in 0..<n {
            let a = angles[f]
            if n > 60 {
                line(CGPoint(x: x + cos(a) * (r - 3), y: y + sin(a) * (r - 3)),
                     CGPoint(x: x + cos(a) * (r - 10), y: y + sin(a) * (r - 10)), value: 0.50, width: 1)
            }
            let distance = min(abs(f - current), n - abs(f - current))
            let nearHighlight = current % step != 0 && Double(distance) < Double(step) * 0.70
            if f % step == 0 && !nearHighlight || f == current {
                text(String(format: n > 100 ? "%03d" : "%02d", f),
                     x: x + cos(a) * (r - 26), y: y + sin(a) * (r - 26),
                     size: n <= 30 ? 27 : (n <= 60 ? 21 : 23), value: f == current ? 1 : 0.50,
                     maxWidth: n > 100 ? 55 : 46, bold: true,
                     accent: settings.accent && f == current)
            }
        }
        line(CGPoint(x: x, y: y), CGPoint(x: x + cos(angle) * (r - 51), y: y + sin(angle) * (r - 51)),
             value: 1, width: 4)
        text("\(state.seconds)", x: x, y: y - 25, size: 370, maxWidth: 500, bold: true)
        text("SEC / \(settings.rate.label) FPS", x: x, y: y + 228, size: 34, maxWidth: 490, bold: true)
        circle(x: smallX, y: smallY, r: smallR, stroke: 0.43, lineWidth: 5, fill: 0)
        circle(x: smallX, y: smallY, r: smallR - 22, stroke: 0.45, lineWidth: 3, fill: 0.18)
        let remaining = kind == .tail ? settings.rate.frames(2) : state.remaining
        text("\(remaining)", x: smallX, y: smallY - 12, size: 136, value: 1,
             maxWidth: smallR * 1.72, bold: true)
        text("FRAMES", x: smallX, y: smallY + smallR * 0.58, size: 28, value: 1,
             maxWidth: smallR * 1.6, bold: true)
        invertedInk = previousInk
        if let label = LeaderTimeline(settings: settings).soundSyncLabel(state.index, kind: kind) {
            text(label, x: smallX, y: smallY + smallR + 110,
                 size: 32, value: 1, maxWidth: smallR * 2, bold: true)
        }
    }
    private func triangle(head: Bool) {
        let x = designWidth / 2
        let points: [CGPoint] = head
            ? [.init(x: x - 300, y: 330), .init(x: x + 300, y: 330), .init(x: x, y: 805)]
            : [.init(x: x - 300, y: 750), .init(x: x + 300, y: 750), .init(x: x, y: 275)]
        context.beginPath(); context.move(to: points[0])
        context.addLine(to: points[1]); context.addLine(to: points[2]); context.closePath()
        context.setStrokeColor(color(1)); context.setLineWidth(20); context.setLineJoin(.miter); context.strokePath()
    }
    private func drawLogo(_ data: Data?, rect: CGRect) {
        if logoSource != data {
            logoSource = data
            logo = data.flatMap { bytes in
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary)
            }
        }
        guard let logo else { return }
        let factor = min(rect.width / Double(logo.width), rect.height / Double(logo.height))
        let width = Double(logo.width) * factor, height = Double(logo.height) * factor
        context.saveGState()
        context.translateBy(x: rect.midX - width / 2, y: rect.midY + height / 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(logo, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }
    func render(settings: LeaderSettings, reel: Int, kind: LeaderKind, frame: Int,
                forceRole: FrameRole? = nil, inverseOverride: Bool? = nil) {
        let state = LeaderTimeline(settings: settings).state(frame, kind: kind)
        let role = forceRole ?? state.role
        let invert = inverseOverride ?? (role == .twoPop || role == .countdown && state.flash)
        invertedInk = role == .twoPop && invert
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(color(0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.normal)
        context.translateBy(x: 0, y: Double(height))
        context.scaleBy(x: Double(height) / 1080, y: -Double(height) / 1080)
        context.translateBy(x: designWidth / 2, y: 540)
        context.scaleBy(x: settings.scale, y: settings.scale)
        context.translateBy(x: -designWidth / 2, y: -540)
        context.setAllowsAntialiasing(true)
        let x = designWidth / 2, safe = designWidth * 0.86
        switch role {
        case .black: break
        case .headTriangle: triangle(head: true)
        case .tailTriangle: triangle(head: false)
        case .headLabel:
            text("HEAD", x: x, y: 400, size: 210, maxWidth: safe, bold: true)
            line(CGPoint(x: x - 420, y: 700), CGPoint(x: x + 310, y: 700), value: 1, width: 20)
            context.beginPath()
            context.move(to: CGPoint(x: x + 300, y: 665))
            context.addLine(to: CGPoint(x: x + 450, y: 700))
            context.addLine(to: CGPoint(x: x + 300, y: 735))
            context.closePath(); context.setFillColor(color(1)); context.fillPath()
        case .titleCard:
            text(settings.title, x: x, y: 540, size: 190, maxWidth: safe, bold: true)
        case .reelCard:
            text("第 \(reel) \(kind.reelSuffix)", x: x, y: 470, size: 155, maxWidth: safe, bold: true)
            text(String(format: "REEL %02d", reel), x: x, y: 650, size: 70, maxWidth: safe, bold: true)
        case .notesCard:
            let hasBrand = settings.logoData != nil || !settings.company.isEmpty
            notes(settings.notes, rect: CGRect(x: designWidth * 0.09, y: 190,
                                               width: designWidth * (hasBrand ? 0.60 : 0.82), height: 700))
            if hasBrand {
                drawLogo(settings.logoData, rect: CGRect(x: designWidth * 0.73, y: 355,
                                                        width: designWidth * 0.19, height: 250))
                text(settings.company, x: designWidth * 0.825, y: 665, size: 34, maxWidth: designWidth * 0.22)
            }
        case .pictureStart:
            text("开始", x: x, y: 235, size: 160, maxWidth: safe, bold: true)
            text("PICTURE START", x: x, y: 535, size: 160, maxWidth: safe, bold: true)
            text("装在片门", x: x, y: 835, size: 160, maxWidth: safe, bold: true)
        case .commag16, .comopt16, .comopt35:
            text(role == .comopt35 ? "35" : "16", x: x, y: 285, size: 165, maxWidth: safe, bold: true)
            text(role == .commag16 ? "COMMAG" : "COMOPT", x: x, y: 535, size: 160, maxWidth: safe, bold: true)
            text("SYNC", x: x, y: 785, size: 160, maxWidth: safe, bold: true)
        case .soundStart:
            text("SOUND START", x: x, y: 540, size: 220, maxWidth: safe, bold: true)
        case .endTitle:
            text("END OF", x: x, y: 365, size: 180, maxWidth: safe, bold: true)
            text("REEL", x: x, y: 675, size: 295, maxWidth: safe, bold: true)
        case .countdown, .twoPop:
            clocks(settings: settings, state: state, kind: kind, invertClocks: invert)
        }
        context.restoreGState()
        invertedInk = false
    }
    func image() throws -> CGImage {
        guard let image = context.makeImage() else { throw LeaderError("无法生成预览。") }
        return image
    }
    func png(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LeaderError("无法创建 PNG。")
        }
        CGImageDestinationAddImage(destination, try image(), nil)
        guard CGImageDestinationFinalize(destination) else { throw LeaderError("PNG 写入失败。") }
    }
    func tiff(to url: URL, settings: LeaderSettings, description: String) throws {
        let icc = space.copyICCData() as Data?
        let write: (UnsafeRawPointer?, Int) -> Int32 = { pointer, count in
            lt_write_tiff(url.path, self.pixels, UInt32(self.width), UInt32(self.height),
                          16, settings.range == .video ? 1 : 0,
                          settings.compressed ? 1 : 0, pointer, UInt32(count), description)
        }
        let success = icc.map { $0.withUnsafeBytes { write($0.baseAddress, $0.count) } } ?? write(nil, 0)
        guard success == 1 else { throw LeaderError("TIFF 写入失败：\(url.lastPathComponent)") }
    }
    func renderRamp() {
        let p = memory.assumingMemoryBound(to: Float.self)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 { p[(y * width + x) * 4 + c] = Float(x) / Float(max(1, width - 1)) }
                p[(y * width + x) * 4 + 3] = 1
            }
        }
    }
}
