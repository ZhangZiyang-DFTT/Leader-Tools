import Foundation

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
struct ExportProgress {
    var completed: Int
    var total: Int
    var bytes: Int64
    var message: String
}
struct SequenceManifest: Codable {
    var kind: LeaderKind
    var reel: Int
    var frameCount: Int
    var directory: String?
    var movie: String?
    var firstFilename: String?
    var lastFilename: String?
    var startFrame: Int
    var startTimecode: String
    var endTimecode: String
    var cueIndexZeroBased: Int
    var cueTimecode: String
    var cueAudioSample48k: Int
    var frameMap: String
}
struct ExportManifest: Codable {
    var application = "Leader Tools"
    var version = "1.1.6"
    var profile = "10-second NDF digital adaptation with EBU Tech 3203 reference markers"
    var created: Date
    var status: String
    var settings: LeaderSettings
    var actualDurationSeconds: Double
    var bytesWritten: Int64
    var sequences: [SequenceManifest]
    var notes: [String]
}
final class LeaderExporter {
    let token: CancellationToken
    private let fm = FileManager.default
    init(token: CancellationToken = .init()) { self.token = token }
    private func checkDisk(_ root: URL, reserve: Int64) throws {
        if token.isCancelled { throw LeaderError("导出已取消。") }
        let attrs = try fm.attributesOfFileSystem(forPath: root.path)
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > reserve + 1_000_000_000 else { throw LeaderError("磁盘可用空间不足。") }
    }
    private func fileSize(_ file: URL) -> Int64 {
        (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    func run(settings input: LeaderSettings, parent: URL, progress: (ExportProgress) -> Void) throws -> URL {
        let s = try input.validated()
        let timeline = LeaderTimeline(settings: s)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if s.exportTIFF && !s.compressed { try checkDisk(parent, reserve: s.rawBytes) }
        let stamp = DateFormatter(); stamp.dateFormat = "yyyyMMdd_HHmmss"
        let name = "\(safeFilename(s.title))_\(stamp.string(from: Date()))_\(UUID().uuidString.prefix(6))"
        let root = parent.appendingPathComponent(name + ".partial", isDirectory: true)
        let final = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var manifest = ExportManifest(created: Date(), status: "in_progress", settings: s,
            actualDurationSeconds: s.duration, bytesWritten: 0, sequences: [], notes: [
                "NDF: ten nominal seconds = 10 * nominal fps frames. Rational sample duration is denominator/numerator.",
                "For 1000/1001 rates, 10 nominal seconds play for 10.01 SI seconds. No duplicated or dropped frames.",
                "Head first frame = R:00:00:00 minus 10 nominal seconds; PICTURE START = minus 8; FFOA = R:00:00:00.",
                "Tail is independently timecode-anchored at R:00:00:00, per user delivery convention; not the actual picture end TC.",
                "Tail index 0 immediately follows LFOA. Tail pop index = 2 * nominal fps - 1.",
                "Head last frame is a down triangle; tail first frame is an up triangle. These digital boundaries are fixed.",
                "16 COMMAG SYNC, 16 COMOPT SYNC and 35 COMOPT SYNC each overlay one normal clock frame at remaining 172, 170 and 164 reference frames.",
                "SOUND START remains at the EBU START position: 144 reference frames before FFOA, scaled by nominal fps/24, nearest frame.",
                "Second boundaries invert only the two clock disks. The 2-pop inverts the whole canvas. Orange frame digits keep their color in both cases.",
                "TIFF RGB has Rec.709 ICC, no alpha, Full 0-1023 or Video 64-940.",
                "MOV is ProRes 422 HQ: native 10-bit v210 input, Rec.709 YCbCr, Video range; named Video to match encoding.",
                "TIFF 16-bit container: both ranges use round(q10*65535/1023). Legal/Video black 4100, white 60218 recover 64/940 when read as Full and rounded to 10-bit. Solid black/white use endpoints; antialiasing and gray fills retain intermediate codes.",
                "Resolve 21.1 Full ProRes decoding was measured as q10*64/65535. An optional DCTL in Resolve_Full_Readback restores q10/1023. Apply only to that MOV Full decoding path, never TIFF or Video/Auto. Native MOV remains Legal 64/940, not 64/941.",
                "TIFF suffixes are absolute NDF timecode frame counts, not a counter reset to zero. CSV records exact TC for every frame.",
                "MOV contains a timecode track associated with video. HFR quanta above 60 may be displayed differently by receiving software.",
                "Optional audio: 48kHz, 24-bit PCM mono, one-frame 1kHz pulse at -20dBFS peak; WAV and MOV share sample placement.",
                "This is not a complete certified EBU/SMPTE physical film leader; see the included guide."
            ])
        let manifestURL = root.appendingPathComponent("manifest.json")
        func saveManifest() throws { try encoder.encode(manifest).write(to: manifestURL, options: .atomic) }
        try saveManifest()
        var completed = 0
        let reserve = Int64(s.resolution.width * s.resolution.height) * 16 + 262_144
        let renderer = try LeaderRenderer(width: s.resolution.width, height: s.resolution.height)
        do {
            if s.exportMOV {
                let readback = root.appendingPathComponent("Resolve_Full_Readback", isDirectory: true)
                try fm.createDirectory(at: readback, withIntermediateDirectories: false)
                for name in ["LeaderTools_Resolve_Full_ProRes_Q10.dctl", "Resolve_Full_Readme.txt"] {
                    guard let source = Bundle.main.url(forResource: name, withExtension: nil) else {
                        throw LeaderError("缺少读取校正资源：\(name)，请重新安装完整应用。")
                    }
                    let destination = readback.appendingPathComponent(name)
                    try fm.copyItem(at: source, to: destination)
                    manifest.bytesWritten += fileSize(destination)
                }
            }
            for reel in s.firstReel...s.lastReel {
                for kind in s.kinds {
                    let reelDir = String(format: "R%02d", reel)
                    let base = s.baseName(reel: reel, kind: kind)
                    let tiffDir = s.exportTIFF ? "\(reelDir)/TIFF10_COMPAT/\(base)" : nil
                    let movieFile = s.exportMOV ? "\(reelDir)/ProRes422HQ/\(s.baseName(reel: reel, kind: kind, mov: true)).mov" : nil
                    for path in [tiffDir, movieFile.map { ($0 as NSString).deletingLastPathComponent }].compactMap({ $0 }) {
                        try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
                    }
                    let start = s.startFrame(reel: reel, kind: kind), cue = timeline.cueFrame(kind: kind)
                    func filename(_ index: Int) -> String { base + String(format: ".%08d.tif", start + index) }
                    let csvName = "\(reelDir)/\(base)_frames.csv"
                    manifest.sequences.append(.init(kind: kind, reel: reel, frameCount: s.frameCount,
                        directory: tiffDir, movie: movieFile,
                        firstFilename: s.exportTIFF ? filename(0) : nil,
                        lastFilename: s.exportTIFF ? filename(s.frameCount - 1) : nil,
                        startFrame: start, startTimecode: Timecode.label(start, rate: s.rate),
                        endTimecode: Timecode.label(start + s.frameCount - 1, rate: s.rate),
                        cueIndexZeroBased: cue, cueTimecode: Timecode.label(start + cue, rate: s.rate),
                        cueAudioSample48k: LeaderAudio.sample(frame: cue, rate: s.rate), frameMap: csvName))
                    try saveManifest()
                    let movieURL = movieFile.map { root.appendingPathComponent($0) }
                    let moviePartial = movieURL?.appendingPathExtension("partial")
                    let movie = try moviePartial.map {
                        try LeaderMovieWriter(url: $0, settings: s, reel: reel, kind: kind, token: token)
                    }
                    var csv = "index_zero_based,absolute_frame,timecode,filename,time_seconds,role,countdown_seconds,relative_to_picture_frames\n"
                    for i in 0..<s.frameCount {
                        try checkDisk(root, reserve: reserve)
                        let state = timeline.state(i, kind: kind)
                        try autoreleasepool {
                            renderer.render(settings: s, reel: reel, kind: kind, frame: i)
                            if let tiffDir {
                                let file = root.appendingPathComponent(tiffDir).appendingPathComponent(filename(i))
                                let temp = file.appendingPathExtension("partial")
                                let description = "Leader Tools 1.1.6; \(base); index=\(i); absoluteFrame=\(start+i); tc=\(Timecode.label(start+i, rate:s.rate)); fps=\(s.rate.rational); NDF; role=\(state.role.rawValue); storage=16bit-container; effectivePrecision=10bit"
                                try renderer.tiff(to: temp, settings: s, description: description)
                                try fm.moveItem(at: temp, to: file)
                                manifest.bytesWritten += fileSize(file)
                            }
                            try movie?.append(renderer: renderer, frame: i)
                        }
                        let relative = kind == .head ? i - s.frameCount : i + 1
                        csv += "\(i),\(start+i),\(Timecode.label(start+i, rate:s.rate)),\(s.exportTIFF ? filename(i) : ""),\(String(format:"%.9f",Double(i)/s.rate.value)),\(state.role.rawValue),\(state.seconds),\(relative)\n"
                        completed += 1
                        progress(.init(completed: completed, total: s.totalFrames,
                            bytes: manifest.bytesWritten + (moviePartial.map(fileSize) ?? 0),
                            message: "第 \(reel) \(kind.reelSuffix) · \(i+1) / \(s.frameCount)"))
                    }
                    try movie?.finish()
                    if let movieURL, let moviePartial {
                        try fm.moveItem(at: moviePartial, to: movieURL)
                        manifest.bytesWritten += fileSize(movieURL)
                    }
                    let csvURL = root.appendingPathComponent(csvName)
                    try Data(csv.utf8).write(to: csvURL, options: .atomic)
                    manifest.bytesWritten += fileSize(csvURL)
                    if s.audio {
                        let wave = root.appendingPathComponent("\(reelDir)/\(base)_SYNC.wav")
                        try LeaderAudio.writeWave(to: wave, frames: s.frameCount, cue: cue, rate: s.rate)
                        manifest.bytesWritten += fileSize(wave)
                    }
                    let review = root.appendingPathComponent("Review")
                    try fm.createDirectory(at: review, withIntermediateDirectories: true)
                    renderer.render(settings: s, reel: reel, kind: kind, frame: kind == .head ? s.rate.frames(3)+1 : s.frameCount-1)
                    let preview = review.appendingPathComponent(base + ".png")
                    try renderer.png(to: preview)
                    manifest.bytesWritten += fileSize(preview)
                    try saveManifest()
                }
            }
            manifest.status = "complete"
            let payload = manifest.bytesWritten
            var data = try encoder.encode(manifest)
            while manifest.bytesWritten != payload + Int64(data.count) {
                manifest.bytesWritten = payload + Int64(data.count)
                data = try encoder.encode(manifest)
            }
            try data.write(to: manifestURL, options: .atomic)
            try fm.moveItem(at: root, to: final)
            progress(.init(completed: completed, total: s.totalFrames, bytes: manifest.bytesWritten, message: "导出完成"))
            return final
        } catch {
            manifest.status = token.isCancelled ? "cancelled" : "failed"
            manifest.notes.append(error.localizedDescription)
            try? saveManifest()
            throw LeaderError(error.localizedDescription + "\n输出位置：\(root.path)")
        }
    }
}
