import Foundation
import ImageIO

struct LeaderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct FrameRate: Codable, Hashable {
    var numerator: Int
    var denominator: Int
    var value: Double { Double(numerator) / Double(denominator) }
    var label: String {
        if denominator == 1 { return "\(numerator)" }
        return String(format: "%.3f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
    var rational: String { "\(numerator)/\(denominator)" }
    var nominal: Int { Int(value.rounded()) }
    func frames(_ seconds: Int) -> Int {
        seconds * nominal
    }
    static let presets: [FrameRate] = [
        .init(numerator: 24000, denominator: 1001), .init(numerator: 24, denominator: 1),
        .init(numerator: 25, denominator: 1), .init(numerator: 30000, denominator: 1001),
        .init(numerator: 30, denominator: 1), .init(numerator: 48000, denominator: 1001),
        .init(numerator: 48, denominator: 1),
        .init(numerator: 50, denominator: 1), .init(numerator: 60000, denominator: 1001),
        .init(numerator: 60, denominator: 1), .init(numerator: 72, denominator: 1),
        .init(numerator: 90, denominator: 1), .init(numerator: 96, denominator: 1),
        .init(numerator: 100, denominator: 1), .init(numerator: 120000, denominator: 1001),
        .init(numerator: 120, denominator: 1), .init(numerator: 144, denominator: 1),
        .init(numerator: 200, denominator: 1), .init(numerator: 240000, denominator: 1001),
        .init(numerator: 240, denominator: 1)
    ]
    static func parse(_ input: String) throws -> FrameRate {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases: [String: Int] = ["23.976":24000, "29.97":30000, "29.970":30000,
            "47.952":48000, "59.94":60000, "59.940":60000, "119.88":120000,
            "119.880":120000, "239.76":240000, "239.760":240000]
        if let n = aliases[text] { return .init(numerator: n, denominator: 1001) }
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        var n: Int
        var d: Int
        if pieces.count == 2, let a = Int(pieces[0]), let b = Int(pieces[1]) {
            n = a; d = b
        } else if pieces.count == 1, let v = Double(text), v.isFinite, v >= 23, v <= 240 {
            n = Int((v * 1_000_000).rounded()); d = 1_000_000
        } else { throw LeaderError("帧率无效，请输入 23.976 至 240，或分数如 24000/1001。") }
        guard n > 0, d > 0, n <= 1_000_000_000, d <= 1_000_000_000 else {
            throw LeaderError("帧率分子与分母必须是有效正整数。")
        }
        let value = Double(n) / Double(d)
        guard value >= 24000.0 / 1001 - 0.0000001, value <= 240 else {
            throw LeaderError("帧率必须介于 24000/1001 与 240 FPS 之间。")
        }
        var a = n; var b = d
        while b != 0 { let r = a % b; a = b; b = r }
        n /= a; d /= a
        let rate = FrameRate(numerator: n, denominator: d)
        guard d == 1 || abs(rate.value * 1001 / 1000 - Double(rate.nominal)) < 0.000001 else {
            throw LeaderError("电影时基支持整数帧率或 1000/1001 家族，请使用如 25、23.976 或 24000/1001。")
        }
        return rate
    }
}

struct Resolution: Codable, Hashable, Identifiable {
    var name: String
    var width: Int
    var height: Int
    var id: String { "\(width)x\(height)" }
    var label: String { "\(name)  \(width) × \(height)" }
    static let presets = [
        Resolution(name: "FHD", width: 1920, height: 1080),
        Resolution(name: "UHD", width: 3840, height: 2160),
        Resolution(name: "2K Flat", width: 1998, height: 1080),
        Resolution(name: "2K Full", width: 2048, height: 1080),
        Resolution(name: "2K Scope", width: 2048, height: 858),
        Resolution(name: "4K Flat", width: 3996, height: 2160),
        Resolution(name: "4K Full", width: 4096, height: 2160),
        Resolution(name: "4K Scope", width: 4096, height: 1716)
    ]
}

enum LeaderKind: String, Codable, CaseIterable, Identifiable {
    case head, tail
    var id: String { rawValue }
    var label: String { self == .head ? "片头 Head" : "片尾 Tail" }
    var reelSuffix: String { self == .head ? "本头" : "本尾" }
}
enum PixelStorage: String, Codable, CaseIterable, Identifiable {
    case packed10, compatible16
    var id: String { rawValue }
    var label: String {
        self == .packed10
            ? "旧版 packed 10-bit（导出时自动转换）"
            : "10-bit 有效精度 / 16-bit 兼容容器"
    }
    var bits: Int { self == .packed10 ? 10 : 16 }
}
enum SignalRange: String, Codable, CaseIterable, Identifiable {
    case full, video
    var id: String { rawValue }
    var label: String { self == .full ? "Full · 0–1023" : "Video · 64–940" }
}
struct LeaderSettings: Codable, Equatable {
    var title = "未命名影片"
    var company = ""
    var notes = ""
    var logoData: Data?
    var firstReel = 1
    var lastReel = 1
    var rate = FrameRate(numerator: 24, denominator: 1)
    var resolution = Resolution.presets[0]
    var generateHead = true
    var generateTail = true
    var exportTIFF = true
    var exportMOV = false
    var storage: PixelStorage = .compatible16
    var range: SignalRange = .full
    var compressed = true
    var audio = true
    var accent = true
    var scale = 0.94
    var kinds: [LeaderKind] { (generateHead ? [.head] : []) + (generateTail ? [.tail] : []) }
    var frameCount: Int { rate.frames(10) }
    var duration: Double { Double(frameCount) / rate.value }
    var reelCount: Int {
        guard firstReel >= 1, lastReel >= firstReel, lastReel <= 23 else { return 0 }
        return lastReel - firstReel + 1
    }
    var totalFrames: Int { frameCount * reelCount * kinds.count }
    var rawBytes: Int64 {
        let row = (Int64(resolution.width) * 3 * Int64(storage.bits) + 7) / 8
        return (row * Int64(resolution.height) + 65_536) * Int64(max(0, totalFrames))
    }
    func validated() throws -> LeaderSettings {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 15,
              !title.contains(where: { $0.isNewline }) else {
            throw LeaderError("片名限 1–15 字，不含换行。")
        }
        guard company.count <= 120 else { throw LeaderError("出品方最多 120 个字符。") }
        guard notes.count <= 400, notes.components(separatedBy: .newlines).count <= 12 else {
            throw LeaderError("备注最多 400 字、12 行。")
        }
        guard (logoData?.count ?? 0) <= 20_000_000 else { throw LeaderError("Logo 文件过大。") }
        if let logoData {
            guard let source = CGImageSourceCreateWithData(logoData as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64
                  ] as CFDictionary) != nil else {
                throw LeaderError("无法解码 Logo，请选择完整的 PNG、JPEG 或 TIFF 图片。")
            }
        }
        guard firstReel >= 1, lastReel >= firstReel, lastReel <= 23 else {
            throw LeaderError("本号范围为 1–23，对应正片首帧 01:00:00:00 至 23:00:00:00。")
        }
        _ = try FrameRate.parse(rate.rational)
        guard resolution.width >= 320, resolution.height >= 240,
              resolution.width <= 8192, resolution.height <= 4320,
              Double(resolution.width) / Double(resolution.height) >= 1.2,
              Double(resolution.width) / Double(resolution.height) <= 2.5 else {
            throw LeaderError("分辨率需在 320×240 至 8192×4320 内，画幅比须为 1.2–2.5。")
        }
        guard !kinds.isEmpty else { throw LeaderError("请至少选择片头或片尾。") }
        guard exportTIFF || exportMOV else { throw LeaderError("请至少选择 TIFF 或 MOV。") }
        guard !exportMOV || resolution.width % 2 == 0 && resolution.height % 2 == 0 else {
            throw LeaderError("ProRes MOV 的宽、高须为偶数。")
        }
        guard scale.isFinite, scale >= 0.7, scale <= 1 else {
            throw LeaderError("画面缩放须为 70%–100%。")
        }
        var normalized = self
        // Packed 10-bit RGB TIFF is legal but poorly supported by ImageIO and
        // common review tools. Preserve 10-bit precision in a 16-bit container.
        normalized.storage = .compatible16
        return normalized
    }
    func startFrame(reel: Int, kind: LeaderKind) -> Int {
        let ffoa = reel * 3600 * rate.nominal
        return kind == .head ? ffoa - frameCount : ffoa
    }
    func baseName(reel: Int, kind: LeaderKind, mov: Bool = false) -> String {
        let rangeName = mov ? "Video" : (range == .full ? "Full" : "Video")
        return "\(safeFilename(title))_\(String(format: "R%02d", reel))_\(kind.rawValue.uppercased())_\(rate.label)FPS_\(resolution.id)_Rec709_\(rangeName)"
    }
}

enum FrameRole: String, Codable {
    case headLabel, titleCard, reelCard, notesCard
    case pictureStart, countdown, twoPop, black, headTriangle, tailTriangle, endTitle
    case commag16, comopt16, comopt35, soundStart
}
struct FrameState: Codable {
    let index: Int
    let role: FrameRole
    let seconds: Int
    let remaining: Int
    let phase: Double
    let flash: Bool
}
struct LeaderTimeline {
    let settings: LeaderSettings
    var count: Int { settings.frameCount }
    var headPop: Int { count - settings.rate.frames(2) }
    var tailPop: Int { settings.rate.frames(2) - 1 }
    var pictureStart: Int { settings.rate.frames(2) }
    func scaled(_ referenceFrames24: Int) -> Int {
        (referenceFrames24 * settings.rate.nominal + 12) / 24
    }
    func soundSyncLabel(_ index: Int, kind: LeaderKind) -> String? {
        guard kind == .head else { return nil }
        for (remaining, label) in [
            (172, "16 COMMAG SYNC"),
            (170, "16 COMOPT SYNC"),
            (164, "35 COMOPT SYNC")
        ] where index == count - scaled(remaining) {
            return label
        }
        return nil
    }
    func state(_ index: Int, kind: LeaderKind) -> FrameState {
        let i = max(0, min(count - 1, index))
        func result(_ role: FrameRole, _ seconds: Int = 0, _ phase: Double = 0, _ flash: Bool = false) -> FrameState {
            FrameState(index: i, role: role, seconds: seconds, remaining: count - i, phase: phase, flash: flash)
        }
        if kind == .tail {
            if i == 0 { return result(.tailTriangle) }
            if i == tailPop { return result(.twoPop, 2, 0, true) }
            if i == count - 1 { return result(.endTitle) }
            let metadata = i - settings.rate.frames(8)
            if metadata < 0 { return result(.black) }
            if metadata < scaled(20) { return result(.titleCard) }
            if metadata < scaled(25) { return result(.reelCard) }
            return result(.notesCard)
        }
        if i == 0 { return result(.headLabel) }
        if i < scaled(21) { return result(.titleCard) }
        if i < scaled(26) { return result(.reelCard) }
        if i < pictureStart { return result(.notesCard) }
        if i == pictureStart { return result(.pictureStart, 8) }
        if i == count - 1 { return result(.headTriangle) }
        if i > headPop { return result(.black) }
        if i == headPop { return result(.twoPop, 2, 0, true) }
        if i == count - scaled(144) { return result(.soundStart) }
        // NDF seconds advance by nominal quanta. Actual frame duration stays rational.
        for seconds in (3...8).reversed() {
            let start = count - settings.rate.frames(seconds)
            let end = count - settings.rate.frames(seconds - 1)
            if i >= start && i < end {
                return result(.countdown, seconds, Double(i - start) / Double(end - start), i == start)
            }
        }
        return result(.black)
    }
    func cueFrame(kind: LeaderKind) -> Int { kind == .head ? headPop : tailPop }
}

func safeFilename(_ text: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let result = text.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    let short = String(result.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return short.isEmpty ? "Untitled" : short
}

enum Timecode {
    static func label(_ frame: Int, rate: FrameRate) -> String {
        let n = rate.nominal
        let seconds = frame / n
        return String(format: "%02d:%02d:%02d:%0*d", seconds / 3600, seconds / 60 % 60,
                      seconds % 60, n > 100 ? 3 : 2, frame % n)
    }
    static func parse(_ text: String, rate: FrameRate) throws -> Int {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard parts.count == 4, numbers.count == 4,
              (0...23).contains(numbers[0]), (0...59).contains(numbers[1]),
              (0...59).contains(numbers[2]), (0..<rate.nominal).contains(numbers[3]) else {
            throw LeaderError("时间码须为有效的 HH:MM:SS:FF（NDF），帧号须小于标称帧率。")
        }
        return ((numbers[0] * 60 + numbers[1]) * 60 + numbers[2]) * rate.nominal + numbers[3]
    }
}
