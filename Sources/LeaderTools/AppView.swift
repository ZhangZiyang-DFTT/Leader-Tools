import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import ImageIO

@MainActor final class AppModel: ObservableObject {
    @Published var settings = LeaderSettings()
    @Published var kind: LeaderKind = .head
    @Published var reel = 1
    @Published var frame = 0
    @Published var preview: CGImage?
    @Published var playing = false
    @Published var exporting = false
    @Published var progress = ExportProgress(completed: 0, total: 1, bytes: 0, message: "就绪")
    @Published var error: String?
    @Published var result: URL?
    @Published var destination: URL?
    @Published var rateSelection = "24/1"
    @Published var customRate = "24"
    @Published var resolutionSelection = "1920x1080"
    @Published var rateError: String?
    private var previewRenderer: LeaderRenderer?
    private var cancellation: CancellationToken?
    private var playbackStart: Date?
    private var playbackFrame = 0

    var validation: String? {
        if let rateError { return rateError }
        do { _ = try settings.validated(); return nil } catch { return error.localizedDescription }
    }
    var previewReels: ClosedRange<Int> {
        let first = max(1, min(23, settings.firstReel))
        return first...max(first, min(23, settings.lastReel))
    }
    var role: FrameRole { LeaderTimeline(settings: settings).state(frame, kind: kind).role }
    var roleLabel: String {
        switch role {
        case .headLabel: return "HEAD"
        case .titleCard: return "片名"
        case .reelCard: return "本号"
        case .notesCard: return "备注 / 出品方"
        case .commag16: return "16 COMMAG SYNC"
        case .comopt16: return "16 COMOPT SYNC"
        case .comopt35: return "35 COMOPT SYNC"
        case .soundStart: return "SOUND START"
        case .pictureStart: return "PICTURE START"
        case .countdown: return "倒计时"
        case .twoPop: return "2-POP"
        case .black: return "纯黑"
        case .headTriangle: return "片头边界三角"
        case .tailTriangle: return "片尾边界三角"
        case .endTitle: return "END OF REEL"
        }
    }
    var timecode: String {
        Timecode.label(settings.startFrame(reel: reel, kind: kind) + frame, rate: settings.rate)
    }
    func refresh() {
        guard settings.frameCount > 0 else { return }
        frame = min(frame, settings.frameCount - 1)
        reel = max(previewReels.lowerBound, min(reel, previewReels.upperBound))
        let aspect = Double(settings.resolution.width) / Double(max(1, settings.resolution.height))
        guard aspect.isFinite, aspect >= 1, aspect <= 4 else { return }
        let w = 1152, h = Int((1152 / aspect).rounded())
        do {
            if previewRenderer?.width != w || previewRenderer?.height != h {
                previewRenderer = try LeaderRenderer(width: w, height: h)
            }
            previewRenderer?.render(settings: settings, reel: reel, kind: kind, frame: frame)
            preview = try previewRenderer?.image()
        } catch { self.error = error.localizedDescription }
    }
    func selectRate() {
        do {
            settings.rate = try FrameRate.parse(rateSelection == "custom" ? customRate : rateSelection)
            rateError = nil
        } catch { rateError = error.localizedDescription }
    }
    func selectResolution() {
        if let r = Resolution.presets.first(where: { $0.id == resolutionSelection }) { settings.resolution = r }
    }
    func togglePlay() {
        playing.toggle()
        if playing {
            if frame == settings.frameCount - 1 { frame = 0 }
            playbackStart = Date(); playbackFrame = frame
        }
    }
    func tick() {
        guard playing, let start = playbackStart else { return }
        frame = min(settings.frameCount - 1, playbackFrame + Int(Date().timeIntervalSince(start) * settings.rate.value))
        if frame == settings.frameCount - 1 { playing = false }
        refresh()
    }
    func seek(_ index: Int) { playing = false; frame = max(0, min(settings.frameCount - 1, index)); refresh() }
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "选择输出文件夹"
        if let destination { panel.directoryURL = destination }
        if panel.runModal() == .OK { destination = panel.url }
    }
    func export() {
        if let validation { error = validation; return }
        if destination == nil { chooseDestination() }
        guard let destination else { return }
        playing = false
        let snapshot = settings
        let token = CancellationToken()
        cancellation = token
        exporting = true; result = nil
        progress = .init(completed: 0, total: snapshot.totalFrames, bytes: 0, message: "准备导出")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let exporter = LeaderExporter(token: token)
                var lastReport = Date.distantPast
                let url = try exporter.run(settings: snapshot, parent: destination) { p in
                    if p.completed == p.total || Date().timeIntervalSince(lastReport) > 0.12 {
                        lastReport = Date()
                        DispatchQueue.main.async { self?.progress = p }
                    }
                }
                DispatchQueue.main.async {
                    self?.exporting = false; self?.result = url
                    self?.progress.message = "导出完成"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.exporting = false; self?.error = error.localizedDescription
                    self?.progress.message = token.isCancelled ? "已取消" : "导出未完成"
                }
            }
        }
    }
    func cancel() { cancellation?.cancel(); progress.message = "正在停止，保留已完成文件" }
    func chooseLogo() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false; panel.prompt = "选择 Logo"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20_000_000 else { throw LeaderError("Logo 最大 20 MB。") }
                let data = try Data(contentsOf: url)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) > 0 else { throw LeaderError("无法读取 Logo。") }
                settings.logoData = data
            } catch { self.error = error.localizedDescription }
        }
    }
    func savePreset() {
        if let validation { error = validation; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = safeFilename(settings.title) + ".leader.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(settings).write(to: url, options: .atomic)
            } catch { self.error = error.localizedDescription }
        }
    }
    func loadPreset() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let s = try JSONDecoder().decode(LeaderSettings.self, from: Data(contentsOf: url)).validated()
                settings = s; customRate = s.rate.rational
                rateSelection = FrameRate.presets.contains(s.rate) ? s.rate.rational : "custom"
                resolutionSelection = Resolution.presets.contains(where: { $0.id == s.resolution.id }) ? s.resolution.id : "custom"
                frame = 0; reel = s.firstReel; rateError = nil; refresh()
            } catch { self.error = "无法载入预设：\(error.localizedDescription)" }
        }
    }
}

struct LeaderRootView: View {
    @StateObject private var model = AppModel()
    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()
    private let panel = Color(white: 0.115)
    private let base = Color(white: 0.085)
    private let rule = Color.white.opacity(0.10)
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(rule).frame(height: 1)
            HStack(spacing: 0) {
                inspector.frame(width: 340)
                Rectangle().fill(rule).frame(width: 1)
                previewPane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(rule).frame(height: 1)
            exportBar
        }
        .background(base)
        .foregroundStyle(Color(white: 0.91))
        .font(.system(size: 12))
        .tint(Color(red: 0.25, green: 0.78, blue: 0.72))
        .preferredColorScheme(.dark)
        .frame(minWidth: 1040, minHeight: 740)
        .onAppear { model.refresh() }
        .onReceive(timer) { _ in model.tick() }
        .onChange(of: model.settings) { _ in model.refresh() }
        .onChange(of: model.kind) { _ in model.seek(0) }
        .onChange(of: model.reel) { _ in model.refresh() }
        .alert("Leader Tools", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 23, weight: .medium))
                .foregroundStyle(Color(red: 0.25, green: 0.78, blue: 0.72))
            Text("Leader Tools").font(.system(size: 20, weight: .semibold))
            Text("1.1.5 · 10 SEC · NDF").font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary).padding(.leading, 6)
            Spacer()
            icon("folder", "载入预设", action: model.loadPreset).disabled(model.exporting)
            icon("square.and.arrow.down", "保存预设", action: model.savePreset).disabled(model.exporting)
            icon("doc.text.magnifyingglass", "规范与交付说明") {
                if let url = Bundle.main.url(forResource: "Guide", withExtension: "html") { NSWorkspace.shared.open(url) }
            }
        }.padding(.horizontal, 22).frame(height: 60).background(panel)
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("项目信息") {
                    field("片名 · \(model.settings.title.count)/15") { TextField("影片名称", text: $model.settings.title) }
                    field("出品方 / 工作室") { TextField("可留空", text: $model.settings.company) }
                    HStack {
                        if let data = model.settings.logoData, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 68, height: 42)
                        }
                        Button(action: model.chooseLogo) { Label("Logo", systemImage: "photo.badge.plus") }
                        if model.settings.logoData != nil {
                            icon("xmark", "移除 Logo") { model.settings.logoData = nil }
                        }
                        Spacer()
                    }
                    field("备注 · \(model.settings.notes.count)/400") {
                        TextEditor(text: $model.settings.notes).font(.system(size: 12))
                            .frame(height: 95).border(Color.white.opacity(0.15))
                    }
                    HStack(spacing: 12) {
                        field("从第几本") { TextField("", value: $model.settings.firstReel, format: .number.grouping(.never)) }
                        field("到第几本") { TextField("", value: $model.settings.lastReel, format: .number.grouping(.never)) }
                    }
                    HStack {
                        Toggle("片头 Head", isOn: $model.settings.generateHead)
                        Toggle("片尾 Tail", isOn: $model.settings.generateTail)
                    }.toggleStyle(.checkbox).padding(.top, 3)
                }
                section("画面与时基") {
                    field("帧率") {
                        Picker("", selection: $model.rateSelection) {
                            ForEach(FrameRate.presets, id: \.rational) { Text($0.label + " FPS").tag($0.rational) }
                            Text("自定义").tag("custom")
                        }.labelsHidden().onChange(of: model.rateSelection) { _ in model.selectRate() }
                        if model.rateSelection == "custom" {
                            TextField("24000/1001", text: $model.customRate)
                                .onChange(of: model.customRate) { _ in model.selectRate() }
                        }
                    }
                    field("分辨率") {
                        Picker("", selection: $model.resolutionSelection) {
                            ForEach(Resolution.presets) { Text($0.label).tag($0.id) }
                            Text("自定义尺寸").tag("custom")
                        }.labelsHidden().onChange(of: model.resolutionSelection) { _ in model.selectResolution() }
                        if model.resolutionSelection == "custom" {
                            HStack {
                                TextField("宽", value: $model.settings.resolution.width, format: .number.grouping(.never))
                                Text("×").foregroundStyle(.secondary)
                                TextField("高", value: $model.settings.resolution.height, format: .number.grouping(.never))
                            }
                        }
                    }
                    HStack {
                        Text("画面缩放").foregroundStyle(.secondary)
                        Slider(value: $model.settings.scale, in: 0.7...1, step: 0.01)
                        Text("\(Int((model.settings.scale * 100).rounded()))%")
                            .monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    Toggle("时钟帧位色标", isOn: $model.settings.accent).toggleStyle(.checkbox)
                    HStack {
                        Text("\(model.settings.frameCount) 帧").monospacedDigit()
                        Spacer()
                        Text(String(format: "%.6f 秒", model.settings.duration)).monospacedDigit()
                    }.foregroundStyle(.secondary)
                }
                section("交付格式") {
                    Toggle("TIFF 序列", isOn: $model.settings.exportTIFF).toggleStyle(.checkbox)
                    field("位深与存储") {
                        Text("10-bit 有效精度 / 16-bit TIFF 兼容容器")
                            .foregroundStyle(.secondary)
                    }
                    field("信号范围 · Rec.709 RGB") {
                        Picker("", selection: $model.settings.range) {
                            ForEach(SignalRange.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden()
                    }
                    Toggle("Deflate 无损压缩", isOn: $model.settings.compressed).toggleStyle(.checkbox)
                        .disabled(!model.settings.exportTIFF)
                    Toggle("MOV · ProRes 422 HQ · Video", isOn: $model.settings.exportMOV).toggleStyle(.checkbox)
                    Toggle("同步音轨 / WAV · 48k / 24-bit", isOn: $model.settings.audio).toggleStyle(.checkbox)
                }
            }.padding(20)
        }.background(panel).textFieldStyle(.roundedBorder).disabled(model.exporting)
    }
    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("", selection: $model.kind) {
                    ForEach(LeaderKind.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).frame(width: 220).labelsHidden()
                Spacer()
                Stepper(value: $model.reel, in: model.previewReels) {
                    Text("第 \(model.reel) 本").monospacedDigit().frame(minWidth: 55)
                }.fixedSize()
            }.padding(20)
            GeometryReader { geometry in
                let aspect = Double(model.settings.resolution.width) / Double(max(1, model.settings.resolution.height))
                let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 9
                let fitWidth = min(geometry.size.width, geometry.size.height * safeAspect)
                let fitHeight = fitWidth / safeAspect
                ZStack {
                    Color(white: 0.055)
                    if let image = model.preview {
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                            .frame(width: fitWidth, height: fitHeight)
                            .background(Color.black).border(Color.white.opacity(0.19), width: 1)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }.padding(.horizontal, 20)
            HStack {
                Text(model.roleLabel).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.role == .twoPop ? Color.yellow : Color.secondary)
                Spacer()
                Text("\(model.settings.resolution.width) × \(model.settings.resolution.height)")
                Text(" / ").foregroundStyle(.tertiary)
                Text(model.settings.rate.label + " FPS")
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            VStack(spacing: 14) {
                HStack(spacing: 9) {
                    icon("backward.end.fill", "首帧") { model.seek(0) }
                    icon("chevron.left", "上一帧") { model.seek(model.frame - 1) }
                    icon(model.playing ? "pause.fill" : "play.fill", model.playing ? "暂停" : "播放", action: model.togglePlay)
                    icon("chevron.right", "下一帧") { model.seek(model.frame + 1) }
                    icon("forward.end.fill", "末帧") { model.seek(model.settings.frameCount - 1) }
                    Spacer()
                    Text("FRAME").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    TextField("", value: Binding(get: { model.frame + 1 }, set: { model.seek($0 <= 1 ? 0 : $0 - 1) }),
                              format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 65).monospacedDigit()
                    Text("/ \(model.settings.frameCount)").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(model.frame) }, set: { model.seek(Int($0.rounded())) }),
                       in: 0...Double(max(1, model.settings.frameCount - 1)), step: 1)
                HStack(spacing: 12) {
                    Button("首帧") { model.seek(0) }
                    if model.kind == .head {
                        Button("片名") { model.seek(1) }
                        Button("PICTURE START") { model.seek(model.settings.rate.frames(2)) }
                    }
                    Button("2-POP") { model.seek(LeaderTimeline(settings: model.settings).cueFrame(kind: model.kind)) }
                    Button("末帧") { model.seek(model.settings.frameCount - 1) }
                    Spacer()
                    Text(model.timecode + " NDF")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }.padding(20)
            if let validation = model.validation {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(validation).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }.foregroundStyle(.orange).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }
    private var exportBar: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: model.exporting ? "arrow.triangle.2.circlepath" : (model.result == nil ? "circle" : "checkmark.circle.fill"))
                        .foregroundStyle(model.result == nil ? Color.secondary : Color.green)
                    Text(model.exporting || model.result != nil ? model.progress.message : "\(model.settings.reelCount) 本 · \(model.settings.kinds.count) 种 · \(model.settings.totalFrames) 帧")
                        .lineLimit(1)
                    if model.exporting {
                        Text(String(format: "%.1f%%", Double(model.progress.completed) / Double(max(1, model.progress.total)) * 100))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if model.exporting {
                    ProgressView(value: Double(model.progress.completed), total: Double(max(1, model.progress.total)))
                        .progressViewStyle(.linear).frame(maxWidth: 420)
                } else {
                    Text(model.destination?.path ?? "尚未选择输出文件夹")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 10)
            if let result = model.result {
                icon("folder.badge.checkmark", "在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
            }
            if model.exporting {
                Button("停止导出", role: .destructive, action: model.cancel)
            } else {
                icon("folder.badge.plus", "输出位置", action: model.chooseDestination)
                Button(action: model.export) {
                    Label("生成", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).disabled(model.validation != nil)
            }
        }.padding(.horizontal, 22).frame(height: 80).background(panel)
    }
    private func icon(_ symbol: String, _ tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 27, height: 27) }
            .buttonStyle(.borderless).help(tooltip).accessibilityLabel(tooltip)
    }
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            content()
            Rectangle().fill(rule).frame(height: 1).padding(.top, 6)
        }
    }
    private func field<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity)
        }
    }
}
