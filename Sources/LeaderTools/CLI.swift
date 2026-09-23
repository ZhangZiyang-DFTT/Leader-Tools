import Foundation
import CLeader
import AVFoundation
import ImageIO

enum LeaderCLI {
    static func run(_ args: [String]) throws {
        if args.first == "--self-test", args.count == 2 {
            try selfTest(URL(fileURLWithPath: args[1], isDirectory: true)); return
        }
        if args.first == "--review-stills", args.count == 2 {
            try reviewStills(URL(fileURLWithPath: args[1], isDirectory: true)); return
        }
        if args.first == "--verify" {
            for file in args.dropFirst() {
                let v = try verify(URL(fileURLWithPath: file))
                print("\(file): \(v.width)x\(v.height) \(v.bits)-bit min=\(v.min) max=\(v.max) unique=\(v.unique)")
            }
            return
        }
        if args.first == "--help" {
            print("""
            Leader Tools 1.1.6 / 10 nominal seconds / NDF
            --generate --output PATH [--title TEXT] [--company TEXT] [--notes TEXT] [--logo PATH]
              [--reels FIRST:LAST] [--fps 24000/1001] [--size 1920x1080] [--storage 16]
              [--mov|--mov-only] [--head-only|--tail-only] [--no-audio] [--no-compress]
              [--video] [--mono] [--scale 0.94] [--preset PATH]
            --self-test PATH
            --review-stills PATH
            --verify FILE ...
            """); return
        }
        guard args.first == "--generate" else { throw LeaderError("Unknown command. Use --help.") }
        var s = LeaderSettings(), output: URL?
        var i = 1
        while i < args.count {
            let key = args[i]
            switch key {
            case "--mov": s.exportMOV = true
            case "--mov-only": s.exportMOV = true; s.exportTIFF = false
            case "--head-only": s.generateHead = true; s.generateTail = false
            case "--tail-only": s.generateHead = false; s.generateTail = true
            case "--no-audio": s.audio = false
            case "--no-compress": s.compressed = false
            case "--video": s.range = .video
            case "--mono": s.accent = false
            default:
                guard i+1 < args.count else { throw LeaderError("Missing value: \(key)") }
                let v = args[i+1]
                switch key {
                case "--output": output = URL(fileURLWithPath: v, isDirectory: true)
                case "--title": s.title = v
                case "--company": s.company = v
                case "--notes": s.notes = v
                case "--logo": s.logoData = try Data(contentsOf: URL(fileURLWithPath: v))
                case "--preset": s = try JSONDecoder().decode(LeaderSettings.self, from: Data(contentsOf: URL(fileURLWithPath: v)))
                case "--fps": s.rate = try FrameRate.parse(v)
                case "--reels":
                    let p = v.split(separator: ":", omittingEmptySubsequences: false)
                    guard p.count == 2, let a = Int(p[0]), let b = Int(p[1]) else { throw LeaderError("--reels 1:3") }
                    s.firstReel = a; s.lastReel = b
                case "--size":
                    let p = v.lowercased().split(separator: "x", omittingEmptySubsequences: false)
                    guard p.count == 2, let w = Int(p[0]), let h = Int(p[1]) else { throw LeaderError("--size 1920x1080") }
                    s.resolution = .init(name: "Custom", width: w, height: h)
                case "--storage":
                    guard v == "10" || v == "16" else { throw LeaderError("--storage 10|16") }
                    // Keep old command lines working while normalizing their
                    // output to the compatible 16-bit container.
                    s.storage = .compatible16
                case "--scale":
                    guard let value = Double(v) else { throw LeaderError("Invalid scale") }
                    s.scale = value
                default: throw LeaderError("Unknown option: \(key)")
                }
                i += 1
            }
            i += 1
        }
        guard let output else { throw LeaderError("--output is required") }
        var last = -1
        let result = try LeaderExporter().run(settings: s, parent: output) { p in
            let bucket = p.completed * 20 / max(1,p.total)
            if bucket != last {
                last = bucket
                print(String(format: "%3d%% %@ %.2f MB", p.completed*100/max(1,p.total),p.message,Double(p.bytes)/1e6))
                fflush(stdout)
            }
        }
        print("OUTPUT=\(result.path)")
    }
    struct Verification {
        let width: UInt32, height: UInt32, bits: UInt16, min: UInt16, max: UInt16, unique: UInt32
    }
    static func verify(_ url: URL) throws -> Verification {
        var w: UInt32 = 0, h: UInt32 = 0, unique: UInt32 = 0
        var bits: UInt16 = 0, min: UInt16 = 0, max: UInt16 = 0
        guard lt_check_tiff(url.path,&w,&h,&bits,&min,&max,&unique) == 1 else { throw LeaderError("Invalid TIFF: \(url.path)") }
        return .init(width:w,height:h,bits:bits,min:min,max:max,unique:unique)
    }
    static func selfTest(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = 0
        func check(_ ok: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !ok() { throw LeaderError("TEST FAILED: \(message)") }
        }
        for rate in FrameRate.presets {
            var s = LeaderSettings(); s.rate = rate
            let t = LeaderTimeline(settings: s), n = rate.nominal
            try check(s.frameCount == n*10, "ten nominal seconds")
            try check(abs(s.duration - (rate.denominator == 1 ? 10 : 10.01)) < 1e-8, "rational playback duration")
            try check(t.pictureStart == n*2 && t.headPop == n*8 && t.tailPop == n*2-1, "cue indices")
            try check(Timecode.label(s.startFrame(reel:4,kind:.head),rate:rate).hasPrefix("03:59:50:"), "head TC")
            try check(Timecode.label(s.startFrame(reel:4,kind:.head)+t.pictureStart,rate:rate).hasPrefix("03:59:52:"), "picture start TC")
            try check(Timecode.label(s.startFrame(reel:4,kind:.tail),rate:rate).hasPrefix("04:00:00:"), "independent tail TC")
            for kind in LeaderKind.allCases {
                let states = (0..<s.frameCount).map { t.state($0,kind:kind) }
                try check(states.filter { $0.role == .twoPop }.count == 1, "one pop")
                try check(states.allSatisfy { $0.seconds != 1 }, "no one")
            }
            try check(t.state(0,kind:.head).role == .headLabel, "HEAD first")
            try check(t.state(t.pictureStart,kind:.head).role == .pictureStart, "PICTURE START")
            try check(t.state(s.frameCount-1,kind:.head).role == .headTriangle, "head last triangle")
            try check(t.state(0,kind:.tail).role == .tailTriangle, "tail first triangle")
            try check(t.state(s.frameCount-1,kind:.tail).role == .endTitle, "tail last END OF REEL")
            try check((0..<s.frameCount-1).allSatisfy { t.state($0,kind:.tail).role != .endTitle }, "END OF REEL only last")
            for (r,role) in [(172,FrameRole.countdown),(170,.countdown),(164,.countdown),(144,.soundStart)] {
                try check(t.state(t.count-t.scaled(r),kind:.head).role == role,"EBU sync \(r)")
            }
            for (remaining,label) in [(172,"16 COMMAG SYNC"),(170,"16 COMOPT SYNC"),(164,"35 COMOPT SYNC")] {
                let frame = t.count - t.scaled(remaining)
                try check(t.soundSyncLabel(frame,kind:.head) == label,"one-frame sound indicator \(remaining)")
                try check(t.soundSyncLabel(frame-1,kind:.head) == nil &&
                          t.soundSyncLabel(frame+1,kind:.head) == nil,"sound indicator adjacent frames blank \(remaining)")
                try check(t.soundSyncLabel(frame,kind:.tail) == nil,"head-only sound indicator \(remaining)")
            }
            let angles = LeaderRenderer.tickAngles(n)
            for i in 0..<n {
                let next = i+1 == n ? angles[0]+2 * .pi : angles[i+1]
                try check(abs(next-angles[i]-2 * .pi/Double(n)) < 1e-10,"equal ticks including wrap \(n)")
            }
        }
        let t = LeaderTimeline(settings:LeaderSettings())
        try check((1...20).allSatisfy { t.state($0,kind:.head).role == .titleCard },"title 239-220")
        try check((21...25).allSatisfy { t.state($0,kind:.head).role == .reelCard },"reel 219-215")
        try check((26...47).allSatisfy { t.state($0,kind:.head).role == .notesCard },"notes 214-193")
        let renderer = try LeaderRenderer(width:320,height:240)
        var s = LeaderSettings(); s.resolution = .init(name:"QA",width:320,height:240)
        s.accent = false
        renderer.render(settings:s,reel:4,kind:.head,frame:t.headPop,inverseOverride:false)
        let normal = Array(UnsafeBufferPointer(start:renderer.pixels,count:320*240*4))
        renderer.render(settings:s,reel:4,kind:.head,frame:t.headPop)
        var inversionError: Float = 0
        for p in stride(from:0,to:normal.count,by:4) {
            for c in 0..<3 { inversionError = max(inversionError, abs(normal[p+c]+renderer.pixels[p+c]-1)) }
        }
        try check(inversionError < 1e-6, "2-pop grayscale complement, maximum raster error \(inversionError)")
        try check(true,"2-pop full-canvas grayscale complement")
        s.accent = true
        for rate in FrameRate.presets {
            s.rate = rate
            let timeline = LeaderTimeline(settings:s)
            for (kind,frame) in [(LeaderKind.head,rate.frames(3)),(.head,timeline.headPop),(.tail,timeline.tailPop)] {
                renderer.render(settings:s,reel:4,kind:kind,frame:frame)
                let pixels = renderer.pixels
                let expectedBackground: Float = frame == rate.frames(3) ? 0 : 1
                try check(abs(pixels[0] - expectedBackground) < 1e-6, "flash background \(rate.label)")
                var orange = 0
                var blue = 0
                for p in stride(from:0,to:320*240*4,by:4) {
                    if pixels[p] > pixels[p+1]+0.04 && pixels[p+1] > pixels[p+2]+0.04 { orange += 1 }
                    if pixels[p+2] > pixels[p]+0.04 { blue += 1 }
                }
                try check(orange > 0 && blue == 0, "orange accent survives inversion \(rate.label)")
            }
            renderer.render(settings:s,reel:4,kind:.head,frame:rate.frames(3),inverseOverride:false)
            let before = Array(UnsafeBufferPointer(start:renderer.pixels,count:320*240*4))
            renderer.render(settings:s,reel:4,kind:.head,frame:rate.frames(3))
            for (x,y) in [(200,160),(62,80)] {
                let p = (y*320+x)*4
                try check(abs(before[p]+renderer.pixels[p]-1) < 1e-6,
                          "both clock interiors invert at second boundary")
            }
            let designWidth = 320.0 / 240.0 * 1080.0
            let scale = s.scale
            let smallRadius = min(195.0,designWidth*0.125) + 12
            var outsideChanges = 0
            for y in 0..<240 {
                let designY = ((Double(y)*1080/240-540)/scale)+540
                for x in 0..<320 {
                    let designX = ((Double(x)*1080/240-designWidth/2)/scale)+designWidth/2
                    let mainDistance = hypot(designX-designWidth*0.63,designY-540)
                    let smallDistance = hypot(designX-designWidth*0.195,designY-360)
                    if mainDistance > 397 && smallDistance > smallRadius {
                        let p = (y*320+x)*4
                        if (0..<3).contains(where:{ before[p+$0] != renderer.pixels[p+$0] }) {
                            outsideChanges += 1
                        }
                    }
                }
            }
            try check(outsideChanges == 0,"integer-second flash changes only the two clock disks \(rate.label)")
        }
        s.rate = .init(numerator:24,denominator:1)
        renderer.render(settings:s,reel:4,kind:.head,frame:73)
        let clean = Array(UnsafeBufferPointer(start:renderer.pixels,count:320*240*4))
        s.title = "不得出现在钟面"; s.company = "HIDDEN"; s.notes = "HIDDEN"
        renderer.render(settings:s,reel:5,kind:.head,frame:73)
        try check(clean == Array(UnsafeBufferPointer(start:renderer.pixels,count:clean.count)), "clock has no project text")
        for text in [String(repeating:"中",count:16),"","换\n行"] {
            s.title = text
            do { _ = try s.validated(); throw LeaderError("Invalid title accepted") }
            catch let e as LeaderError { try check(e.message != "Invalid title accepted","title validation") }
        }
        s = LeaderSettings(); s.title = String(repeating:"影",count:15)
        try check(tryValid(s), "15-character title accepted")
        s.storage = .packed10
        let normalized = try s.validated()
        try check(normalized.storage == .compatible16, "legacy packed TIFF preset normalized")
        s.logoData = Data("not an image".utf8)
        try check(!tryValid(s), "invalid logo rejected")
        s.logoData = nil; s.notes = String(repeating:"字",count:401)
        try check(!tryValid(s), "notes length limit")
        s.notes = ""; s.exportTIFF = false
        try check(!tryValid(s), "at least one output required")
        s.exportMOV = true; s.resolution = .init(name:"QA",width:321,height:241)
        try check(!tryValid(s), "odd dimensions rejected for ProRes")
        s.exportMOV = false; s.exportTIFF = true
        try check(tryValid(s), "odd dimensions accepted for TIFF")
        let odd = try LeaderRenderer(width:321,height:241)
        odd.renderRamp()
        let oddFile = root.appendingPathComponent("odd_width_321x241.tif")
        try odd.tiff(to:oddFile,settings:s,description:"Compatible TIFF row QA")
        let oddInfo = try verify(oddFile)
        try check(oddInfo.width == 321 && oddInfo.height == 241 && oddInfo.bits == 16 && oddInfo.unique == 321,
                  "compatible odd-width TIFF")
        let ramp = try LeaderRenderer(width:1024,height:4); ramp.renderRamp()
        for range in SignalRange.allCases {
            for compressed in [false,true] {
                var q = LeaderSettings(); q.range = range; q.compressed = compressed
                let file = root.appendingPathComponent("ramp_compatible16_\(range)_\(compressed).tif")
                try ramp.tiff(to:file,settings:q,description:"1024-code test ramp")
                let info = try verify(file)
                try check(info.bits == 16,"compatible TIFF bit depth")
                try check(info.unique == (range == .full ? 1024 : 877),"quantization codes")
                try check(info.min == (range == .full ? 0 : 4100) &&
                          info.max == (range == .full ? 65535 : 60218), "normalized range endpoints")
                try check(Int((Double(info.min) * 1023 / 65535).rounded()) == (range == .full ? 0 : 64) &&
                          Int((Double(info.max) * 1023 / 65535).rounded()) == (range == .full ? 1023 : 940),
                          "Full reader 10-bit endpoints")
            }
        }
        for r in Resolution.presets {
            try autoreleasepool {
                var s = LeaderSettings(); s.resolution = r; s.title = String(repeating:"影",count:15)
                let renderer = try LeaderRenderer(width:r.width,height:r.height)
                renderer.render(settings:s,reel:4,kind:.head,frame:73)
                let file = root.appendingPathComponent("resolution_\(r.id).tif")
                try renderer.tiff(to:file,settings:s,description:"Resolution QA")
                let info = try verify(file)
                try check(info.width == r.width && info.height == r.height && info.bits == 16 && info.unique > 256,
                          "resolution/precision")
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw LeaderError("TEST FAILED: ImageIO cannot decode \(r.id)")
                }
                try check(image.width == r.width && image.height == r.height,
                          "ImageIO dimensions \(r.id)")
                s.range = .video; s.title = "端点检查"; s.notes = "LEGAL BLACK AND WHITE"
                for frame in [0, 1, 21, 26, 48, 68, 70, 72, 73, 76, 96, 192, 193, 239] {
                    renderer.render(settings:s,reel:4,kind:.head,frame:frame)
                    let legal = root.appendingPathComponent("legal_\(r.id)_\(frame).tif")
                    try renderer.tiff(to:legal,settings:s,description:"Legal endpoint QA")
                    let info = try verify(legal)
                    try check(info.min == 4100 && info.max == (frame == 193 ? 4100 : 60218),
                              "Legal black/white \(r.id) frame \(frame)")
                }
            }
        }
        s = LeaderSettings(); s.title = "批量验证"; s.firstReel = 3; s.lastReel = 4
        s.resolution = .init(name:"QA",width:320,height:240)
        let batch = try LeaderExporter().run(settings:s,parent:root) { _ in }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let m = try decoder.decode(ExportManifest.self,from:Data(contentsOf:batch.appendingPathComponent("manifest.json")))
        try check(m.status == "complete" && m.sequences.count == 4,"multi-reel batch")
        for seq in m.sequences {
            let names = try FileManager.default.contentsOfDirectory(atPath:batch.appendingPathComponent(seq.directory!).path)
            try check(names.count == 240 && names.contains(seq.firstFilename!) && names.contains(seq.lastFilename!),"sequence completeness")
        }
        let token = CancellationToken(); token.cancel()
        do { _ = try LeaderExporter(token:token).run(settings:s,parent:root){_ in}; throw LeaderError("Cancellation ignored") }
        catch let e as LeaderError { try check(e.message != "Cancellation ignored","cancellation") }
        let report = "PASS: \(checks) checks. Ten-second NDF timing, identification cards, one-frame sound indicators at 172/170/164, SOUND START at the six-second reference, reel timecodes, fixed boundaries, uniform clock ticks, clock-only second flashes, full-screen pop with preserved orange digits, compatible 10-bit-effective TIFF precision, ImageIO decoding for all eight dimensions and batch export.\n"
        print(report); try Data(report.utf8).write(to:root.appendingPathComponent("self-test.txt"))
    }
    private static func tryValid(_ settings: LeaderSettings) -> Bool {
        (try? settings.validated()) != nil
    }
    static func reviewStills(_ root: URL) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for r in Resolution.presets {
            try autoreleasepool {
                var s = LeaderSettings(); s.title = "示例影片"; s.notes = "画面版本：正式交付\n声音版本：最终混音\n本段用于检查片名、本号和同步标记。"
                s.resolution = r
                let renderer = try LeaderRenderer(width:r.width,height:r.height)
                for (label,kind,frame) in [
                    ("Head_First",LeaderKind.head,0),("Title",.head,1),("Reel",.head,21),("Notes",.head,26),
                    ("Picture_Start",.head,48),("16_COMMAG",.head,68),("16_COMOPT",.head,70),
                    ("35_COMOPT",.head,76),("Sound_Start",.head,96),("Clock",.head,73),("Second_Flash",.head,72),("2Pop",.head,192),
                    ("Head_Last",.head,239),("Tail_First",.tail,0),("Tail_Last",.tail,239)
                ] {
                    renderer.render(settings:s,reel:4,kind:kind,frame:frame)
                    let base = r.id+"_"+label
                    try renderer.tiff(to:root.appendingPathComponent(base+".tif"),settings:s,description:label)
                    if r.width == 1920 || r.id == "4096x1716" { try renderer.png(to:root.appendingPathComponent(base+".png")) }
                }
            }
        }
    }
}
