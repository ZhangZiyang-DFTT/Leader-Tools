import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox
import CLeader

final class LeaderMovieWriter {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private let timecode: AVAssetWriterInput
    private let settings: LeaderSettings
    private let token: CancellationToken
    private let cue: Int
    private var audioFormat: CMAudioFormatDescription?
    private var finished = false
    private var frameDuration: CMTime {
        CMTime(value: Int64(settings.rate.denominator), timescale: Int32(settings.rate.numerator))
    }
    init(url: URL, settings: LeaderSettings, reel: Int, kind: LeaderKind, token: CancellationToken) throws {
        self.settings = settings; self.token = token
        cue = LeaderTimeline(settings: settings).cueFrame(kind: kind)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let output: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: settings.resolution.width, AVVideoHeightKey: settings.resolution.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: settings.rate.value]
        ]
        guard writer.canApply(outputSettings: output, forMediaType: .video) else {
            throw LeaderError("当前系统无法编码该规格的 ProRes 422 HQ。")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: output)
        video.expectsMediaDataInRealTime = false
        video.mediaTimeScale = Int32(settings.rate.numerator)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10,
            kCVPixelBufferWidthKey as String: settings.resolution.width,
            kCVPixelBufferHeightKey as String: settings.resolution.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        var tcFormat: CMTimeCodeFormatDescription?
        let duration = CMTime(value: Int64(settings.rate.denominator), timescale: Int32(settings.rate.numerator))
        guard CMTimeCodeFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32, frameDuration: duration,
            frameQuanta: UInt32(settings.rate.nominal), flags: 0, extensions: nil,
            formatDescriptionOut: &tcFormat) == noErr, let tcFormat else {
            throw LeaderError("无法创建 NDF 时间码轨。")
        }
        timecode = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFormat)
        timecode.expectsMediaDataInRealTime = false
        video.addTrackAssociation(withTrackOf: timecode, type: AVAssetTrack.AssociationType.timecode.rawValue)
        guard writer.canAdd(video), writer.canAdd(timecode) else { throw LeaderError("MOV 轨道不可用。") }
        writer.add(video); writer.add(timecode)
        if settings.audio {
            var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 3, mFramesPerPacket: 1, mBytesPerFrame: 3, mChannelsPerFrame: 1,
                mBitsPerChannel: 24, mReserved: 0)
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &audioFormat) == noErr else {
                throw LeaderError("无法创建 PCM 音频格式。")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
            ], sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw LeaderError("MOV 音频轨不可用。") }
            writer.add(input); audio = input
        } else { audio = nil }
        guard writer.startWriting() else { throw LeaderError(writer.error?.localizedDescription ?? "MOV 启动失败。") }
        writer.startSession(atSourceTime: .zero)
        var start = Int32(settings.startFrame(reel: reel, kind: kind)).bigEndian
        let data = withUnsafeBytes(of: &start) { Data($0) }
        var timing = CMSampleTimingInfo(duration: CMTimeMultiply(duration, multiplier: Int32(settings.frameCount)),
                                       presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let sample = try Self.sample(data: data, format: tcFormat, samples: 1, bytesPerSample: 4, timing: &timing)
        try ready(timecode)
        guard timecode.append(sample) else { throw failure() }
        timecode.markAsFinished()
        if let audio, let audioFormat {
            // The short leader's PCM fits in one block; finishing it up front avoids
            // interleaver back-pressure deadlocks between sequential track producers.
            let count = LeaderAudio.sample(frame: settings.frameCount, rate: settings.rate)
            let start = LeaderAudio.sample(frame: cue, rate: settings.rate)
            let end = LeaderAudio.sample(frame: cue + 1, rate: settings.rate)
            var pcm = Data(count: start * 3)
            pcm.append(LeaderAudio.pcm(count: end - start, tone: true))
            pcm.append(Data(count: (count - end) * 3))
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                                            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            let buffer = try Self.sample(data: pcm, format: audioFormat, samples: count,
                                         bytesPerSample: 3, timing: &timing)
            try ready(audio)
            guard audio.append(buffer) else { throw failure() }
            audio.markAsFinished()
        }
    }
    deinit { if !finished { writer.cancelWriting() } }
    private func failure() -> LeaderError { LeaderError(writer.error?.localizedDescription ?? "ProRes MOV 编码失败。") }
    private func ready(_ input: AVAssetWriterInput) throws {
        let start = Date()
        while !input.isReadyForMoreMediaData {
            if token.isCancelled { throw LeaderError("导出已取消。") }
            guard writer.status == .writing else { throw failure() }
            guard Date().timeIntervalSince(start) < 60 else { throw LeaderError("MOV 编码等待超时。") }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
    func append(renderer: LeaderRenderer, frame: Int) throws {
        try ready(video)
        guard let pool = adaptor.pixelBufferPool else { throw failure() }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw LeaderError("MOV 像素缓冲分配失败。") }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, []); throw LeaderError("MOV 像素缓冲不可写。")
        }
        lt_fill_v210(renderer.pixels, base, UInt32(renderer.width), UInt32(renderer.height),
                     UInt32(CVPixelBufferGetBytesPerRow(buffer)))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        guard adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(frame))) else {
            throw failure()
        }
    }
    func finish() throws {
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(settings.frameCount)))
        let completion = DispatchSemaphore(value: 0)
        writer.finishWriting { completion.signal() }
        let deadline = Date().addingTimeInterval(120)
        while completion.wait(timeout: .now() + 0.1) == .timedOut {
            if token.isCancelled { writer.cancelWriting(); throw LeaderError("导出已取消。") }
            if Date() >= deadline {
                writer.cancelWriting()
                throw LeaderError("MOV 收尾超时，未完成文件已保留。")
            }
        }
        guard writer.status == .completed else { throw failure() }
        finished = true
    }
    private static func sample(data: Data, format: CMFormatDescription, samples: Int, bytesPerSample: Int,
                               timing: inout CMSampleTimingInfo) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { throw LeaderError("MOV 数据缓冲分配失败。") }
        let status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        var size = bytesPerSample
        var sample: CMSampleBuffer?
        guard status == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: samples, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { throw LeaderError("MOV 样本创建失败。") }
        return sample
    }
}

enum LeaderAudio {
    static func sample(frame: Int, rate: FrameRate) -> Int {
        let n = Int64(frame) * Int64(rate.denominator) * 48000
        return Int((n + Int64(rate.numerator) / 2) / Int64(rate.numerator))
    }
    static func pcm(count: Int, tone: Bool) -> Data {
        var data = Data(capacity: count * 3)
        for i in 0..<count {
            let v = tone ? Int32((sin(Double(i) * 2 * .pi * 1000 / 48000) * 0.1 * 8_388_607).rounded()) : 0
            data.append(UInt8(truncatingIfNeeded: v)); data.append(UInt8(truncatingIfNeeded: v >> 8))
            data.append(UInt8(truncatingIfNeeded: v >> 16))
        }
        return data
    }
    static func writeWave(to url: URL, frames: Int, cue: Int, rate: FrameRate) throws {
        let count = sample(frame: frames, rate: rate)
        let start = sample(frame: cue, rate: rate), end = sample(frame: cue + 1, rate: rate)
        var data = Data()
        func ascii(_ s: String) { data.append(Data(s.utf8)) }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let bytes = count * 3
        ascii("RIFF"); u32(UInt32(36 + bytes + bytes % 2)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(48000); u32(144000); u16(3); u16(24); ascii("data"); u32(UInt32(bytes))
        data.append(Data(count: start * 3))
        data.append(pcm(count: end - start, tone: true))
        data.append(Data(count: (count - end) * 3 + bytes % 2))
        try data.write(to: url, options: .atomic)
    }
}
