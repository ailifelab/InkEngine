import AVFoundation
import SwiftUI
import InkCore
import SpeechRuntime
import CryptoKit
import Darwin
#if os(iOS)
import MediaPlayer
import UIKit
#endif

@MainActor final class SpeechEngine: NSObject, ObservableObject {
    @Published private(set) var systemVoices: [AVSpeechSynthesisVoice] = []
    @Published private(set) var recoveryMessage = ""
    @Published private(set) var pronunciationRules: [PronunciationRule] = []
    private var pronunciation = PronunciationDictionary()
    private var pronunciationVersion = ""
    private var systemFallback = false
    private var lastSynthesisFailure = ""
    @Published var rendererMode = "system" {
        didSet {
            preferences.set(rendererMode, forKey: "speechRenderer")
            if rendererMode == "zipvoice" || rendererMode == "zipvoice-male" {
                preferences.set(rendererMode == "zipvoice-male" ? "dylan" : "serena", forKey: "zipVoiceReference")
            }
            guard oldValue != rendererMode else { return }
            stop()
            if modelRatesReady { restoreModelRate() }
            // 先取消旧请求，再由actor串行释放闲置模型；保留当前音色，避免播放中反复加载。
            let selected = rendererMode
            Task {
                if selected != "matcha" { await lightSynthesizer.unload() }
                if selected != "piper" { await maleSynthesizer.unload() }
                if !["zipvoice", "zipvoice-male"].contains(selected) { await zipSynthesizer.unload() }
                #if os(macOS)
                if selected != "qwen" { await qwenSynthesizer.unload() }
                #endif
            }
        }
    }
    @Published var systemVoiceID = "" { didSet { preferences.set(systemVoiceID, forKey: "systemMandarinVoice") } }
    var selectedModel: String {
        get { rendererMode == "zipvoice-male" ? "zipvoice" : rendererMode }
        set {
            if newValue == "zipvoice" {
                rendererMode = preferences.string(forKey: "zipVoiceReference") == "dylan" && zipVoiceMaleReady ? "zipvoice-male" : "zipvoice"
            } else { rendererMode = newValue }
        }
    }
    var selectedZipVoice: String {
        get { rendererMode == "zipvoice-male" ? "dylan" : "serena" }
        set {
            guard newValue == "serena" || (newValue == "dylan" && zipVoiceMaleReady) else { return }
            preferences.set(newValue, forKey: "zipVoiceReference")
            if selectedModel == "zipvoice" { rendererMode = newValue == "dylan" ? "zipvoice-male" : "zipvoice" }
        }
    }
    private var usesSystem: Bool { rendererMode == "system" || systemFallback }
    private var currentVoiceID: String { usesSystem ? systemVoiceID : requestedVoice(for: rendererMode) }
    private let systemRenderer = SystemSpeechRenderer()
    @Published var rate: Float = 1 {
        didSet {
            if modelRatesReady && !restoringModelRate {
                preferences.set(rate, forKey: modelRateKey)
                if selectedModel != "qwen" { preferences.set(rate, forKey: "speechSpeed") }
            }
            updatePlaybackRate(); nowPlaying()
        }
    }
    private var modelRatesReady = false
    private var restoringModelRate = false
    private var modelRateKey: String { "speechSpeed.model." + selectedModel }
    private func restoreModelRate() {
        restoringModelRate = true
        defer { restoringModelRate = false }
        let saved: Float
        if preferences.object(forKey: modelRateKey) != nil { saved = preferences.float(forKey: modelRateKey) }
        else if selectedModel == "qwen" { saved = 1.25 }
        else { saved = preferences.object(forKey: "speechSpeed") == nil ? 1 : preferences.float(forKey: "speechSpeed") }
        rate = min(2, max(0.5, saved))
        preferences.set(rate, forKey: modelRateKey)
    }
    @Published var skipCode = true { didSet { preferences.set(skipCode, forKey: "skipCode") } }
    @Published private(set) var playing = false
    @Published private(set) var paused = false
    @Published private(set) var preparing = false
    @Published private(set) var segmentIndex = 0
    @Published private(set) var spokenRange: NSRange?
    @Published private(set) var renderedFrames: Int64 = 0
    @Published var error: String?
    var onPosition: ((Int) -> Void)?
    var onFinished: ((UUID, UUID) -> Void)?
    var transportGeneration: UUID { ledger.generation }
    var auditioning: Bool { previewText != nil }
    private let preferences: UserDefaults
    private let lightSynthesizer = MatchaSynthesizer()
    private let maleSynthesizer = VitsSynthesizer()
    private let zipSynthesizer = ZipVoiceSynthesizer()
    #if os(macOS)
    private let qwenSynthesizer = QwenSynthesizer()
    #endif
    private var modelReleaseTask: Task<Void, Never>?
    @Published private var idleModelReleases = 0
    private func releaseModelsWhenIdle() {
        modelReleaseTask?.cancel()
        let generation = ledger.generation
        modelReleaseTask = Task { [weak self] in
            // 短暂停顿保留模型；长时间暂停或停止后释放推理内存。
            // PCM及保存的样本位置独立保留，继续时只按需重新加载模型。
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !Task.isCancelled, self.ledger.generation == generation, !self.playing || self.paused else { return }
            await self.lightSynthesizer.unload()
            guard !Task.isCancelled, self.ledger.generation == generation, !self.playing || self.paused else { return }
            await self.maleSynthesizer.unload()
            await self.zipSynthesizer.unload()
            #if os(macOS)
            await self.qwenSynthesizer.unload()
            #endif
            self.idleModelReleases += 1
        }
    }
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var parsed = ParsedText(segments: [], chapters: [])
    private var previewText: ParsedText?
    private var beforeAudition: SpeechCursor?
    private var readingText: ParsedText { previewText ?? parsed }
    private var cursor = SpeechCursor(segment: 0)
    private var planned = SpeechCursor(segment: 0)
    private var ledger = SpeechPlaybackLedger()
    private var cancellation = SynthesisCancellation()
    private var synthesisTask: Task<Void, Never>?
    private var synthesisWatchdog: Task<Void, Never>?
    private var synthesisRequest = UUID()
    private var synthesisStarted = Date.distantPast
    private var systemRetryCount = 0
    #if DEBUG
    private var injectedStall = false
    #endif
    private var inFlight = false
    private var queuedCount = 0
    private var completedFrames: Int64 = 0
    private var clockBase: Int64 = 0
    private var underruns = 0
    private struct BufferedAudio {
        let chunk: NeuralSpeechChunk
        let buffer: AVAudioPCMBuffer
        let start: Int64
        let end: Int64
        let skippedFrames: Int64
        let voice: String
        let speed: Float
        let original: AVAudioPCMBuffer
    }
    private var buffers: [BufferedAudio] = []
    private var activeSynthesisSpeed: Float = 1
    /// 队列可同时存在不同生成倍率的波形。播放器只补足“目标倍率 / 当前波形倍率”，
    /// 不能再次完整加速；位置账本始终记录该波形的实际样本，不随倍率换算。
    private func updatePlaybackRate() {
        if let entry = ledger.current, let buffer = buffers.first(where: { $0.start == entry.start }) {
            activeSynthesisSpeed = buffer.speed
        }
        let desired = rate / activeSynthesisSpeed
        if timePitch.rate != desired { timePitch.rate = desired }
    }
    private var bufferedSeconds: Double {
        buffers.reduce(0) { total, buffer in
            let remaining = max(0, buffer.end - max(ledger.renderedFrames, buffer.start))
            return total + Double(remaining) / 24000 * Double(buffer.speed / rate)
        }
    }
    private var needsRebuild = false
    private struct Checkpoint: Codable {
        let revision: UUID
        let cursor: SpeechCursor
        let digest: String
        let voice: String
        let speed: Float
        let frame: Int64
        var model: String
        let audioFile: String
        let audioDigest: String
        let requestedRenderer: String?
        let requestedVoice: String?
    }
    private var documentID: UUID?
    private var revision: UUID?
    private var initialFrameOffset: Int64 = 0
    private var restoredFrameOffset: Int64 = 0
    private var restoredCursor: SpeechCursor?
    private var restoredPCMVerified = false
    private var resumeCacheStatus = "none"
    private var cachedBuffer: AVAudioPCMBuffer?
    private var cachedAudioDigest = ""
    private let cacheDirectory: URL
    private var lastCheckpointTime = Date.distantPast
    private var sessionRenderer = "system"
    private var sessionVoice = ""
    private func requestedVoice(for renderer: String) -> String {
        switch renderer {
        case "matcha": return "matcha-zh-standard"
        case "piper": return "piper-zh-chaowen"
        case "zipvoice": return "zipvoice-distill-coreml-4"
        case "zipvoice-male": return "zipvoice-distill-coreml-4-dylan"
        case "qwen": return "qwen-06b-coreml-serena"
        default: return systemVoiceID
        }
    }
    private func modelVersion(for voice: String) -> String {
        let model: String
        switch voice {
        case "matcha-zh-standard": model = "matcha-zh-en-6-noise1-vocos-16k-pcm3"
        case "piper-zh-chaowen": model = "piper-zh-chaowen-fp32-22k-pcm1"
        case "zipvoice-distill-coreml-4": model = "zipvoice-coreml-fp16-cpu-1024-4-qwenref352-pcm3"
        case "zipvoice-distill-coreml-4-dylan": model = "zipvoice-coreml-fp16-cpu-1024-4-dylan-natural-ref352-pcm2"
        case "qwen-06b-coreml-serena": model = "qwen-customvoice-coreml-w8-gpu-cpusd-cd32-mcd32-512-256-serena-pcm2"
        default: model = "apple-mandarin-pcm1"
        }
        return model + "-pronunciation-" + pronunciationVersion + "-" + SpeechInput.cacheVersion
    }
    private var timer: Timer?
    private var title = "墨语引擎"
    private var observers: [NSObjectProtocol] = []
    private let audioSessionQueue = DispatchQueue(label: "InkEngine.Speech.AudioSession")
    #if os(iOS)
    private var preparationTask: UIBackgroundTaskIdentifier = .invalid
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    #endif
    private var directory: URL? { Bundle.main.url(forResource: "Speech", withExtension: nil) }
    private var qwenDirectory: URL? { Bundle.main.url(forResource: "SpeechMac", withExtension: nil)?.appendingPathComponent("Qwen") }
    var voiceDescription: String {
        if !usesSystem && rendererMode == "piper" { return "Piper 超文 · 轻量中文男声 · 本地离线" }
        if !usesSystem && rendererMode == "matcha" { return "Matcha · 轻量中文女声 · 本地离线" }
        if !usesSystem && rendererMode == "zipvoice-male" { return "ZipVoice Dylan · 中文男声 · 本地离线" }
        if !usesSystem && rendererMode == "zipvoice" { return "ZipVoice Serena · 中文女声 · 本地离线" }
        if !usesSystem && rendererMode == "qwen" { return "Qwen Serena · 自然中文女声 · 本地离线" }
        return "系统普通话 · \(systemVoices.first(where: { $0.identifier == systemVoiceID })?.name ?? "普通话") · 本地离线"
    }
    var zipVoiceReady: Bool { nativeModelsReady(at: directory?.appendingPathComponent("ZipVoice"), names: ["TextEncoder", "FmDecoder", "Vocos"]) }
    var zipVoiceMaleReady: Bool { zipVoiceReady && directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("ZipVoice/reference-dylan.json").path) } == true }
    var qwenReady: Bool {
        #if os(macOS) && arch(arm64)
        return nativeModelsReady(at: qwenDirectory, names: ["TextProjector", "CodeEmbedder", "MultiCodeEmbedder", "CodeDecoder", "MultiCodeDecoder", "SpeechDecoder"])
        #else
        return false
        #endif
    }
    private func nativeModelsReady(at path: URL?, names: [String]) -> Bool {
        guard let path else { return false }
        return names.allSatisfy { FileManager.default.fileExists(atPath: path.appendingPathComponent($0 + ".mlmodelc").path) }
    }
    var offlineReady: Bool {
        if usesSystem { return !systemVoiceID.isEmpty }
        if rendererMode == "zipvoice" { return zipVoiceReady }
        if rendererMode == "zipvoice-male" { return zipVoiceMaleReady }
        if rendererMode == "qwen" { return qwenReady }
        guard let directory else { return false }
        let file = rendererMode == "matcha" ? "Matcha/model-steps-6.onnx" : "Piper/model.onnx"
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path)
    }
    private var currentSampleOffset: Int64 {
        guard let entry = ledger.current, let buffer = buffers.first(where: { $0.chunk.cursor == entry.chunk.cursor }) else { return 0 }
        return buffer.skippedFrames + ledger.renderedFrames - entry.start
    }
    var preparationMessage: String {
        guard preparing, !paused else { return "" }
        if rendererMode == "qwen", renderedFrames == 0 { return "正在准备 Qwen 音色，首次准备和合成可能需要约一分钟。" }
        if ["zipvoice", "zipvoice-male", "qwen"].contains(rendererMode), renderedFrames == 0 {
            return "正在准备所选音色，首次使用可能需要约半分钟。"
        }
        return "正在准备下一段朗读。"
    }
    var playbackEvidence: String { "Speech|\(ledger.generation.uuidString)|\(renderedFrames)|\(cursor.segment)|\(cursor.offset)|\(paused ? "paused" : preparing ? "preparing" : playing ? "playing" : "stopped")|\(underruns)|\(restoredFrameOffset)|\(currentSampleOffset)|\(restoredCursor?.segment ?? -1)|\(restoredCursor?.offset ?? -1)|\(restoredPCMVerified)|\(resumeCacheStatus)|\(rate)|\(timePitch.rate)|\(usesSystem ? "system" : rendererMode)|\(systemFallback)|\(activeSynthesisSpeed)|\(timer != nil)|\(idleModelReleases)" }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        cacheDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(testing ? "InkEngineUITests/AudioResume" : "InkEngine/AudioResume")
        if testing && ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") { try? FileManager.default.removeItem(at: cacheDirectory) }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: cacheDirectory.path)
        for file in (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
        #endif
        super.init()
        if let data = preferences.data(forKey: "pronunciationRules"), let saved = try? JSONDecoder().decode([PronunciationRule].self, from: data) { pronunciationRules = saved.filter(\.isValid) }
        pronunciation = PronunciationDictionary(custom: pronunciationRules); pronunciationVersion = pronunciation.cacheKey
        systemVoiceID = preferences.string(forKey: "systemMandarinVoice") ?? ""
        // 升级时仅清理已下架音色的音频缓存，不触碰正文、书签或文稿阅读位置。
        for key in preferences.dictionaryRepresentation().keys where key.hasPrefix("kokoroCheckpoint-") {
            if let data = preferences.data(forKey: key), let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data) {
                if checkpoint.voice.hasPrefix("kokoro-zh-") {
                    if checkpoint.audioFile == (checkpoint.audioFile as NSString).lastPathComponent {
                        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(checkpoint.audioFile))
                    }
                } else { preferences.set(data, forKey: key.replacingOccurrences(of: "kokoroCheckpoint-", with: "speechCheckpoint-")) }
            }
            preferences.removeObject(forKey: key)
        }
        if preferences.object(forKey: "speechSpeed") == nil, let oldRate = preferences.object(forKey: "kokoroSpeed") {
            preferences.set(oldRate, forKey: "speechSpeed")
        }
        preferences.removeObject(forKey: "kokoroSpeed")
        refreshVoices()
        let savedRenderer = preferences.string(forKey: "speechRenderer")
        // 退役音色只迁移选择，保留文稿和阅读位置。
        var allowedRenderers = ["system", "matcha", "zipvoice", "zipvoice-male"]
        #if os(macOS) && arch(arm64)
        allowedRenderers.append("qwen")
        #endif
        if savedRenderer == "piper" { rendererMode = "zipvoice-male" }
        else { rendererMode = allowedRenderers.contains(savedRenderer ?? "") ? savedRenderer! : "matcha" }
        if ProcessInfo.processInfo.arguments.contains("--system-speech-ui-testing") { rendererMode = "system" }
        #if DEBUG
        if testing && ProcessInfo.processInfo.arguments.contains("--light-speech-ui-testing") { rendererMode = "matcha" }
        if testing && ProcessInfo.processInfo.arguments.contains("--male-speech-ui-testing") { rendererMode = "zipvoice-male" }
        if testing && ProcessInfo.processInfo.arguments.contains("--zipvoice-ui-testing") { rendererMode = ProcessInfo.processInfo.arguments.contains("--zipvoice-male-ui-testing") ? "zipvoice-male" : "zipvoice" }
        if testing && ProcessInfo.processInfo.arguments.contains("--qwen-ui-testing"), qwenReady { rendererMode = "qwen" }
        #endif
        preferences.removeObject(forKey: "kokoroVoiceID")
        restoreModelRate()
        modelRatesReady = true
        if preferences.object(forKey: "skipCode") != nil { skipCode = preferences.bool(forKey: "skipCode") }
        engine.attach(player); engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.rate = rate; timePitch.pitch = 0
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing, !self.buffers.isEmpty else { return }
                // 音频路由或采样率变化时保留已合成 PCM，并自动重建播放图。
                let wasPaused = self.paused
                self.pause(); self.needsRebuild = true
                if !wasPaused { self.resume() }
            }
        })
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshVoices() } })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing, !self.paused, self.queuedCount == 0, self.inFlight, Date().timeIntervalSince(self.synthesisStarted) > 6 else { return }
                // Native CPU/ANE preparation is allowed to finish under the audio
                // background task; its device compilation can exceed six seconds.
                guard !["zipvoice", "zipvoice-male", "qwen"].contains(self.rendererMode) else { return }
                self.lastSynthesisFailure = "Background recovery interrupted pending synthesis"
                self.recoverSynthesis()
            }
        })
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            let target = command.addTarget { _ in Task { @MainActor in action() }; return .success }
            commandTargets.append((command, target))
        }
        add(center.playCommand) { [weak self] in self?.resume() }
        add(center.pauseCommand) { [weak self] in self?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in guard let self else { return }; self.paused ? self.resume() : self.playing ? self.pause() : self.resume() }
        add(center.stopCommand) { [weak self] in self?.stop() }
        add(center.nextTrackCommand) { [weak self] in self?.next() }
        add(center.previousTrackCommand) { [weak self] in self?.previous() }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        #endif
    }
    func refreshVoices() {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { ["zh-CN", "zh-TW"].contains($0.language) }.sorted {
            if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
            return $0.identifier < $1.identifier
        }
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0.name + "/" + $0.language).inserted }
        let female = Array(unique.filter { $0.gender == .female }.prefix(5))
        let male = Array(unique.filter { $0.gender == .male }.prefix(5))
        // 性别未标注的系统声音只补足空位，全部选项仍不超过十个。
        let other = unique.filter { $0.gender == .unspecified }
        systemVoices = Array((female + male + other).prefix(10))
        let options = systemVoices.map { SpeechVoiceOption(id: $0.identifier, language: $0.language, quality: $0.quality.rawValue, name: $0.name) }
        systemVoiceID = MandarinVoicePolicy.choose(from: options, savedID: systemVoiceID) ?? ""
        if !offlineReady { error = "离线中文音色文件缺失，请重新安装完整应用。" }
    }
    func load(_ text: ParsedText, title: String, documentID: UUID, revision: UUID) {
        stop(); parsed = text; self.title = title; self.documentID = documentID; self.revision = revision
        cursor = SpeechCursor(segment: 0); segmentIndex = 0
    }
    func play(from segment: Int) {
        let readingCursor = previewText == nil ? cursor : beforeAudition ?? cursor
        let target = readingCursor.segment == segment ? readingCursor : SpeechCursor(segment: max(0, segment))
        begin(at: target)
    }
    func playFromBeginning() { begin(at: SpeechCursor(segment: 0), useCheckpoint: false) }
    func audition(_ text: String = "窗外的风带来了雨的气息。她放下手中的书，轻声说：明天，我们再出发。听见文字，也听见句子之间的停顿。") {
        stop()
        let readingCursor = cursor
        previewText = TextParser.parse(text, format: .txt)
        begin(at: SpeechCursor(segment: 0), preview: true)
        beforeAudition = readingCursor
    }
    func setPronunciationRules(_ rules: [PronunciationRule]) {
        // 纠音变化后旧 PCM 的读法已经过期。保留正文位置，下一次从当前句重读；
        // 不把新读法硬套到旧波形的样本位置上。
        let readingCursor = cursor; stop(); cursor = readingCursor
        pronunciationRules = rules.filter(\.isValid)
        pronunciation = PronunciationDictionary(custom: pronunciationRules); pronunciationVersion = pronunciation.cacheKey
        if let data = try? JSONEncoder().encode(pronunciationRules) { preferences.set(data, forKey: "pronunciationRules") }
    }
    private func begin(at target: SpeechCursor, initiallyPaused: Bool = false, preview: Bool = false, useCheckpoint: Bool = true) {
        modelReleaseTask?.cancel(); modelReleaseTask = nil
        let sample = preview ? previewText : nil
        invalidate()
        systemFallback = false; systemRetryCount = 0; recoveryMessage = ""; lastSynthesisFailure = ""
        sessionRenderer = rendererMode; sessionVoice = requestedVoice(for: rendererMode)
        previewText = sample
        guard let directory else { error = "离线中文音色文件缺失，请重新安装完整应用。"; return }
        guard let chunk = readingText.speechChunk(from: target, skipCode: skipCode, renderer: rendererMode) else { return }
        let cached = useCheckpoint && !preview ? cachedCheckpoint(for: chunk) : nil
        if let cached {
            initialFrameOffset = cached.frame; restoredFrameOffset = cached.frame
            restoredCursor = chunk.cursor; restoredPCMVerified = true
        }
        error = nil; cursor = chunk.cursor; planned = chunk.cursor; segmentIndex = chunk.cursor.segment
        playing = true; paused = initiallyPaused; preparing = true
        protectPreparation()
        if initiallyPaused { ledger.pause() }
        let generation = ledger.generation
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.activateAudio()
                guard self.playing, self.ledger.generation == generation else { return }
                try self.engine.start()
                self.startTimer()
                if let cached {
                    self.planned = chunk.next
                    self.scheduleOriginal(cached.buffer, chunk: chunk, generation: generation, voice: self.currentVoiceID, speed: cached.speed)
                }
                self.fillQueue(directory: directory)
                self.nowPlaying()
            } catch {
                guard self.ledger.generation == generation else { return }
                self.fail(error)
            }
        }
    }
    private func protectPreparation() {
        #if os(iOS)
        guard preparationTask == .invalid else { return }
        preparationTask = UIApplication.shared.beginBackgroundTask(withName: "准备下一段朗读") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.playing && !self.paused && self.inFlight { self.recoverSynthesis() }
                self.releasePreparation()
            }
        }
        #endif
    }
    private func releasePreparation() {
        #if os(iOS)
        guard preparationTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(preparationTask); preparationTask = .invalid
        #endif
    }
    private func activateAudio() async throws {
        #if os(iOS)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioSessionQueue.async {
                do {
                    // playback 已支持蓝牙 A2DP 和 AirPlay。HFP 属于输入选项，
                    // 配到纯播放会话会在 iOS 真机触发参数错误 -50。
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
                    try AVAudioSession.sharedInstance().setActive(true)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        #endif
    }
    private func fillQueue(directory: URL) {
        guard playing, !paused, !inFlight else { return }
        // 按音频时长预存，最多六句、约 24 秒；短对话能连续播放，
        // 缓冲足够时暂停推理，避免整本小说持续占用处理器。
        let secondsAhead = bufferedSeconds
        let lookahead: Double = rendererMode == "matcha" ? 12 : 24
        guard queuedCount < 6, secondsAhead < lookahead else { return }
        var candidate = readingText.speechChunk(from: planned, skipCode: skipCode, renderer: rendererMode)
        var spokenText = ""
        while let chunk = candidate {
            spokenText = SpeechInput.preparing(pronunciation.applying(to: chunk.text))
            if SpeechInput.hasSpokenContent(spokenText) { break }
            // 纯标点不送进模型，避免空输入报错；循环跳过，长串标点不会递归占满调用栈。
            planned = chunk.next; candidate = readingText.speechChunk(from: planned, skipCode: skipCode, renderer: rendererMode)
        }
        guard let chunk = candidate else { finishIfDrained(); return }
        inFlight = true
        synthesisRequest = UUID(); synthesisStarted = Date()
        let request = synthesisRequest
        let generation = ledger.generation, cancellation = cancellation
        // 每个请求固定生成倍率；调速不取消已合成的声音，新请求使用新倍率。
        // 原生模型使用适中的语速范围，超出部分由播放器补足。
        let selectedVoice = currentVoiceID, useSystem = usesSystem, useLight = !usesSystem && rendererMode == "matcha", useMale = !usesSystem && rendererMode == "piper"
        let selectedRenderer = useSystem ? "system" : rendererMode
        let speed = SpeechRatePolicy.nativeRate(renderer: useSystem ? "system" : rendererMode, selected: rate)
        let synthesisText = spokenText
        synthesisWatchdog?.cancel()
        synthesisWatchdog = Task { [weak self] in
            // Core ML performs device-specific compilation on first use.
            // Preserve the same source cursor while allowing that initial work.
            try? await Task.sleep(for: .seconds(["zipvoice", "zipvoice-male", "qwen"].contains(selectedRenderer) ? 90 : 12))
            guard !Task.isCancelled, let self, self.synthesisRequest == request, self.playing, self.inFlight else { return }
            self.recoverSynthesis()
        }
        synthesisTask = Task { [weak self, lightSynthesizer, maleSynthesizer, zipSynthesizer] in
            do {
                let start = Date()
                #if DEBUG
                if !useSystem, let self, !self.injectedStall, ProcessInfo.processInfo.arguments.contains("--speech-stall-testing") {
                    self.injectedStall = true
                    try await Task.sleep(for: .seconds(60))
                }
                #endif
                let audio: SpeechAudio
                switch selectedRenderer {
                case "system": guard let self else { return }; audio = try await self.systemRenderer.generate(text: synthesisText, voiceID: selectedVoice)
                case "matcha": audio = try await lightSynthesizer.generate(text: synthesisText, directory: directory.appendingPathComponent("Matcha"), speed: speed, cancellation: cancellation)
                case "piper": audio = try await maleSynthesizer.generate(text: synthesisText, directory: directory.appendingPathComponent("Piper"), speed: speed, cancellation: cancellation)
                case "zipvoice", "zipvoice-male": audio = try await zipSynthesizer.generate(text: synthesisText, directory: directory.appendingPathComponent("ZipVoice"), referenceFile: selectedRenderer == "zipvoice-male" ? "reference-dylan.json" : "reference.json", cancellation: cancellation)
                #if os(macOS)
                case "qwen": guard let self, let modelDirectory = self.qwenDirectory else { throw SpeechFailure.initialization }; audio = try await self.qwenSynthesizer.generate(text: synthesisText, directory: modelDirectory, cancellation: cancellation)
                #endif
                default: throw SpeechFailure.initialization
                }
                #if DEBUG
                print("INK_SYNTH mode=\(useSystem ? "system" : useLight ? "matcha" : useMale ? "piper" : "unknown") speed=\(speed) chars=\(chunk.text.count) seconds=\(Date().timeIntervalSince(start)) audio=\(audio.duration)")
                #endif
                guard let self, self.playing, self.ledger.generation == generation, self.synthesisRequest == request, !cancellation.isCancelled else { return }
                self.synthesisWatchdog?.cancel(); self.systemRetryCount = 0
                self.inFlight = false; self.planned = chunk.next
                self.schedule(audio, chunk: chunk, generation: generation, voice: selectedVoice, speed: speed)
                self.fillQueue(directory: directory)
            } catch is CancellationError { /* A cancelled document or seek owns no playback. */ }
            catch {
                guard let self, self.ledger.generation == generation, self.synthesisRequest == request else { return }
                self.lastSynthesisFailure = String(describing: error)
                NSLog("Speech synthesis failure (%@): %@", selectedRenderer, self.lastSynthesisFailure)
                self.recoverSynthesis()
            }
        }
    }
    /// 只撤销未完成的合成，不清空已经排队的音频和播放代次。
    /// 系统后端从 planned（未读句）接替，因此锁屏恢复不会重读或跳过缓冲内容。
    private func recoverSynthesis() {
        guard playing, inFlight else { return }
        synthesisWatchdog?.cancel(); synthesisRequest = UUID()
        cancellation.cancel(); cancellation = SynthesisCancellation()
        synthesisTask?.cancel(); synthesisTask = nil; systemRenderer.stop(); inFlight = false
        if !usesSystem, !systemVoiceID.isEmpty {
            systemFallback = true
            recoveryMessage = "所选音色准备失败或超时，已用系统普通话从未读处继续。重新开始朗读时会重试所选音色。"
        } else if systemRetryCount < 1 {
            systemRetryCount += 1
            recoveryMessage = "正在恢复朗读，阅读位置保持不变。"
        } else {
            if queuedCount == 0 { cursor = planned; segmentIndex = planned.segment }
            fail(NSError(domain: "InkEngine.Speech", code: 2, userInfo: [NSLocalizedDescriptionKey: "朗读暂时无法恢复。锁屏播放按钮可从未读处重试，或在设置中更换音色。"])); return
        }
        protectPreparation()
        if let directory { fillQueue(directory: directory) }
        startBufferedPlayback(); nowPlaying()
    }
    func audioCacheBytes(documentIDs: Set<UUID>? = nil) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { file in documentIDs == nil || documentIDs!.contains { file.lastPathComponent.hasPrefix($0.uuidString + "-") } }.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    func clearAudioCache(documentIDs: Set<UUID>? = nil) throws {
        if documentIDs == nil || documentID.map({ documentIDs!.contains($0) }) == true { stop(); cachedBuffer = nil; cachedAudioDigest = "" }
        for file in try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            if documentIDs == nil || documentIDs!.contains(where: { file.lastPathComponent.hasPrefix($0.uuidString + "-") }) { try FileManager.default.removeItem(at: file) }
        }
        for key in preferences.dictionaryRepresentation().keys where key.hasPrefix("speechCheckpoint-") {
            if documentIDs == nil || documentIDs!.contains(where: { key == "speechCheckpoint-" + $0.uuidString }) { preferences.removeObject(forKey: key) }
        }
    }
    private func schedule(_ audio: SpeechAudio, chunk: NeuralSpeechChunk, generation: UUID, voice: String, speed: Float) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)), let channel = buffer.floatChannelData?[0] else { fail(SpeechFailure.generation); return }
        buffer.frameLength = buffer.frameCapacity
        audio.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        scheduleOriginal(buffer, chunk: chunk, generation: generation, voice: voice, speed: speed)
    }
    private func scheduleOriginal(_ buffer: AVAudioPCMBuffer, chunk: NeuralSpeechChunk, generation: UUID, voice: String, speed: Float) {
        guard let channel = buffer.floatChannelData?[0] else { fail(SpeechFailure.generation); return }
        let skip = min(initialFrameOffset, max(0, Int64(buffer.frameLength) - 1))
        initialFrameOffset = 0
        if skip > 0, let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength - AVAudioFrameCount(skip)), let destination = trimmed.floatChannelData?[0] {
            trimmed.frameLength = trimmed.frameCapacity
            destination.update(from: channel.advanced(by: Int(skip)), count: Int(trimmed.frameLength))
            schedule(trimmed, chunk: chunk, generation: generation, skippedFrames: skip, voice: voice, speed: speed, original: buffer)
        } else { schedule(buffer, chunk: chunk, generation: generation, voice: voice, speed: speed) }
    }
    private func schedule(_ buffer: AVAudioPCMBuffer, chunk: NeuralSpeechChunk, generation: UUID, skippedFrames: Int64 = 0, voice: String, speed: Float, original: AVAudioPCMBuffer? = nil) {
        let start = ledger.scheduledFrames
        guard ledger.append(chunk, frames: Int64(buffer.frameLength), generation: generation) else { return }
        let end = ledger.scheduledFrames
        buffers.append(BufferedAudio(chunk: chunk, buffer: buffer, start: start, end: end, skippedFrames: skippedFrames, voice: voice, speed: speed, original: original ?? buffer))
        queuedCount += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playing, self.ledger.generation == generation else { return }
                self.completedFrames = max(self.completedFrames, end)
                self.queuedCount = max(0, self.queuedCount - 1)
                self.buffers.removeAll(where: { $0.end == end })
                self.updatePosition()
                if self.queuedCount == 0 {
                    // 空队列也会推进音频时钟；断粮时重置节点并保留账本基准，
                    // 避免后续合成补入时把静音时长误算成已经读过的正文。
                    self.player.stop(); self.clockBase = end
                    self.protectPreparation()
                    if self.inFlight && !self.paused { self.underruns += 1; self.preparing = true }
                }
                if let directory = self.directory { self.fillQueue(directory: directory) }
                self.finishIfDrained()
            }
        }
        startBufferedPlayback()
    }
    private func startBufferedPlayback() {
        guard !paused, queuedCount > 0 else { return }
        guard !engine.isRunning || !player.isPlaying else { return }
        // 开始前准备两个音频块，避免短标题播完后等待首个长段落而断粮。
        let secondsAhead = bufferedSeconds
        guard secondsAhead >= 5 || queuedCount >= 2 || readingText.speechChunk(from: planned, skipCode: skipCode, renderer: rendererMode) == nil else { return }
        do { if !engine.isRunning { try engine.start() } }
        catch { fail(error); return }
        updatePlaybackRate()
        preparing = false; player.play(); releasePreparation(); updatePosition()
    }
    private func startTimer() {
        timer?.invalidate()
        guard !paused else { timer = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePosition() }
        }
        timer?.tolerance = 0.03
    }
    private func updatePosition() {
        guard playing, !paused else { return }
        // A hardware configuration change can stop the engine before any PCM
        // is queued. Restart it when buffered audio arrives, retaining the ledger.
        if queuedCount > 0 && !engine.isRunning { startBufferedPlayback() }
        let frame = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0)?.sampleTime }.map { $0 + clockBase } ?? completedFrames
        ledger.render(to: max(frame, completedFrames), generation: ledger.generation)
        renderedFrames = ledger.renderedFrames
        updatePlaybackRate()
        guard let entry = ledger.current else { return }
        if cursor != entry.chunk.cursor || spokenRange == nil {
            cursor = entry.chunk.cursor; segmentIndex = cursor.segment; spokenRange = entry.chunk.spokenRange
            if previewText == nil { onPosition?(entry.chunk.sourceOffset) }
            nowPlaying()
        }
        if Date().timeIntervalSince(lastCheckpointTime) >= 1 { saveCheckpoint() }
        if let directory { fillQueue(directory: directory) }
    }
    func pause() {
        guard playing, !paused else { return }
        updatePosition(); player.pause(); ledger.pause(); paused = true
        timer?.invalidate(); timer = nil
        saveCheckpoint(); nowPlaying()
        releaseModelsWhenIdle()
    }
    func resume() {
        modelReleaseTask?.cancel(); modelReleaseTask = nil
        guard playing else { begin(at: cursor); return }
        if !paused {
            if inFlight && queuedCount == 0 { recoverSynthesis() }
            else if queuedCount > 0 && !player.isPlaying { paused = true; ledger.pause() }
            else { return }
        }
        if needsRebuild { rebuildBufferedPlayback() }
        let generation = ledger.generation
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.activateAudio()
                guard self.playing, self.ledger.generation == generation else { return }
                if !self.engine.isRunning { try self.engine.start() }
                self.paused = false; self.ledger.resume()
                self.startTimer()
                self.startBufferedPlayback()
                if let directory = self.directory { self.fillQueue(directory: directory) }
                self.updatePosition(); self.finishIfDrained(); self.nowPlaying()
            } catch { if self.ledger.generation == generation { self.fail(error) } }
        }
    }
    func stop() {
        let readingCursor = previewText == nil ? nil : beforeAudition
        updatePosition(); saveCheckpoint(); invalidate()
        if let readingCursor { cursor = readingCursor; segmentIndex = readingCursor.segment }
        nowPlaying()
        releaseModelsWhenIdle()
    }
    private func invalidate() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--background-audio-probe") { print("INK_TRANSPORT_INVALIDATE " + Thread.callStackSymbols.prefix(8).joined(separator: " | ")) }
        #endif
        releasePreparation()
        systemRenderer.stop(); cancellation.cancel(); synthesisTask?.cancel(); synthesisTask = nil
        synthesisWatchdog?.cancel(); synthesisWatchdog = nil; synthesisRequest = UUID()
        ledger.reset(); cancellation = SynthesisCancellation()
        player.stop(); engine.pause(); timer?.invalidate(); timer = nil
        queuedCount = 0; completedFrames = 0; clockBase = 0; underruns = 0; inFlight = false; buffers = []; needsRebuild = false
        activeSynthesisSpeed = 1; updatePlaybackRate()
        initialFrameOffset = 0; restoredFrameOffset = 0; restoredCursor = nil; restoredPCMVerified = false; cachedBuffer = nil; resumeCacheStatus = "none"
        playing = false; paused = false; preparing = false; spokenRange = nil; renderedFrames = 0; previewText = nil; beforeAudition = nil
    }
    private func rebuildBufferedPlayback() {
        let remaining = buffers.filter { $0.end > ledger.renderedFrames }
        let frame = ledger.renderedFrames
        systemRenderer.stop(); cancellation.cancel(); synthesisTask?.cancel(); synthesisTask = nil
        player.stop(); ledger.reset(); ledger.pause(); cancellation = SynthesisCancellation()
        buffers = []; queuedCount = 0; completedFrames = 0; clockBase = 0; renderedFrames = 0; inFlight = false; needsRebuild = false
        if let last = remaining.last { planned = last.chunk.next }
        for entry in remaining {
            let offset = Int(max(0, frame - entry.start))
            let count = Int(entry.buffer.frameLength) - offset
            guard count > 0, let original = entry.buffer.floatChannelData?[0],
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            channel.update(from: original.advanced(by: offset), count: count)
            schedule(buffer, chunk: entry.chunk, generation: ledger.generation, skippedFrames: entry.skippedFrames + Int64(offset), voice: entry.voice, speed: entry.speed, original: entry.original)
        }
    }
    private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func saveCheckpoint() {
        guard playing, previewText == nil, let documentID, let revision,
              let entry = ledger.current, let buffer = buffers.first(where: { $0.chunk.cursor == entry.chunk.cursor }) else { return }
        let filename = documentID.uuidString + "-" + digest("\(revision)-\(entry.chunk.cursor.segment)-\(entry.chunk.cursor.offset)-\(buffer.voice)-\(buffer.speed)") + ".pcm"
        let url = cacheDirectory.appendingPathComponent(filename)
        if cachedBuffer !== buffer.original {
            do {
                // 保存真实波形：开源模型每次合成可能含随机激励，重合成不能保证样本对齐。
                guard let samples = buffer.original.floatChannelData?[0] else { throw SpeechFailure.generation }
                let bytes = Data(bytes: samples, count: Int(buffer.original.frameLength) * MemoryLayout<Float>.size)
                // 直接保存 Float32，避免音频文件格式转换改变波形位；支持的 Apple 架构均为小端。
                #if os(iOS)
                try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                #else
                try bytes.write(to: url, options: .atomic)
                #endif
                cachedAudioDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                cachedBuffer = buffer.original
                // iOS 枚举可能把 /var 标准化成 /private/var；同目录只比较文件名，
                // 防止两种等价 URL 使清理逻辑误删刚刚保存的续读波形。
                for old in (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent.hasPrefix(documentID.uuidString + "-") && old.lastPathComponent != filename {
                    try? FileManager.default.removeItem(at: old)
                }
            } catch {
                self.error = "续读音频未能保存：\(error.localizedDescription)"
                return
            }
        }
        let checkpoint = Checkpoint(revision: revision, cursor: entry.chunk.cursor, digest: digest(entry.chunk.text), voice: buffer.voice, speed: buffer.speed,
                                    frame: buffer.skippedFrames + ledger.renderedFrames - entry.start, model: modelVersion(for: buffer.voice), audioFile: filename, audioDigest: cachedAudioDigest,
                                    requestedRenderer: sessionRenderer, requestedVoice: sessionVoice)
        if let data = try? JSONEncoder().encode(checkpoint) { preferences.set(data, forKey: "speechCheckpoint-\(documentID.uuidString)") }
        lastCheckpointTime = Date()
    }
    private func cachedCheckpoint(for chunk: NeuralSpeechChunk) -> (buffer: AVAudioPCMBuffer, frame: Int64, speed: Float)? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let documentID,
           let data = preferences.data(forKey: "speechCheckpoint-\(documentID.uuidString)"),
           let stored = try? JSONDecoder().decode(Checkpoint.self, from: data) {
            print("Speech resume saved=\(stored.cursor) requested=\(chunk.cursor) frame=\(stored.frame) revOK=\(stored.revision == revision)")
        }
        #endif
        guard let documentID, let revision, let data = preferences.data(forKey: "speechCheckpoint-\(documentID.uuidString)"),
              let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data), checkpoint.revision == revision,
              checkpoint.model == modelVersion(for: checkpoint.voice), checkpoint.cursor == chunk.cursor, checkpoint.digest == digest(chunk.text),
              checkpoint.frame >= 0, checkpoint.speed.isFinite, (0.65...1.5).contains(checkpoint.speed),
              checkpoint.audioFile == URL(fileURLWithPath: checkpoint.audioFile).lastPathComponent,
              checkpoint.audioFile.hasPrefix(documentID.uuidString + "-"), checkpoint.audioFile.hasSuffix(".pcm") else { resumeCacheStatus = "metadata mismatch or absent"; return nil }
        // 用户主动换音色时不恢复旧波形；自动救援则保留当时的系统音色和准确样本位置。
        // 旧版缓存没有所选后端记录，仍只允许恢复与当前音色完全一致的波形。
        let restoresFallback = checkpoint.voice != currentVoiceID
        guard (checkpoint.requestedRenderer == nil || checkpoint.requestedRenderer == rendererMode),
              (checkpoint.requestedVoice == nil || checkpoint.requestedVoice == requestedVoice(for: rendererMode)),
              !restoresFallback || (rendererMode != "system" && checkpoint.requestedRenderer == rendererMode && checkpoint.requestedVoice == requestedVoice(for: rendererMode) && checkpoint.voice == systemVoiceID && systemVoices.contains(where: { $0.identifier == checkpoint.voice }))
        else { resumeCacheStatus = "selected voice changed"; return nil }
        do {
            let bytes = try Data(contentsOf: cacheDirectory.appendingPathComponent(checkpoint.audioFile))
            let frames = bytes.count / MemoryLayout<Float>.size
            guard bytes.count.isMultiple(of: MemoryLayout<Float>.size), frames > checkpoint.frame, frames <= 24000 * 180,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else { resumeCacheStatus = "invalid PCM length"; return nil }
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == checkpoint.audioDigest else {
                resumeCacheStatus = "PCM hash mismatch"; return nil
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: bytes.count))
            // 元信息和波形摘要均验证后才切后端，损坏缓存不会改变下一次朗读的选择。
            if restoresFallback {
                systemFallback = true
                recoveryMessage = "已从系统普通话救援音频的原位置继续。重新开始朗读时会重试所选音色。"
            }
            resumeCacheStatus = "verified"
            return (buffer, max(0, checkpoint.frame), checkpoint.speed)
        } catch { resumeCacheStatus = error.localizedDescription; return nil }
    }
    private func finishIfDrained() {
        if playing && !paused && queuedCount == 0 && !inFlight && readingText.speechChunk(from: planned, skipCode: skipCode, renderer: rendererMode) == nil {
            if previewText != nil { stop(); return }
            let next = planned
            let finishedID = documentID, finishedRevision = revision
            if let documentID { preferences.removeObject(forKey: "speechCheckpoint-\(documentID.uuidString)") }
            if previewText == nil, let last = parsed.segments.last { onPosition?(NSMaxRange(last.sourceRange)) }
            stop(); cursor = next
            if let finishedID, let finishedRevision { onFinished?(finishedID, finishedRevision) }
        }
    }
    private func fail(_ failure: Error) { stop(); error = failure.localizedDescription }
    #if DEBUG && os(macOS)
    func runNativeMacProbe() async {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--native-mac-probe") else { return }
        let url = cacheDirectory.deletingLastPathComponent().appendingPathComponent("Speech-native-mac-probe.json")
        var events: [[String: Any]] = []
        func record(_ phase: String) {
            events.append(["phase": phase, "evidence": playbackEvidence, "date": Date().timeIntervalSince1970])
            if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(120)
            while !condition() {
                if let error { throw NSError(domain: "NativeMacProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                guard Date() < deadline else { throw SpeechFailure.generation }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        do {
            let expectedVoice = rendererMode
            let initialRate = rate
            guard initialRate == (expectedVoice == "qwen" ? 1.25 : 1) else { throw SpeechFailure.generation }
            rendererMode = "matcha"; rate = 1.1
            rendererMode = "zipvoice"; rate = 1.15
            rendererMode = "zipvoice-male"
            guard rate == 1.15 else { throw SpeechFailure.generation }
            #if arch(arm64)
            if qwenReady {
                rendererMode = "qwen"
                guard rate == 1.25 else { throw SpeechFailure.generation }
            }
            #endif
            rendererMode = "matcha"
            guard rate == 1.1 else { throw SpeechFailure.generation }
            rendererMode = expectedVoice
            record("model-rates-independent")
            rate = expectedVoice == "qwen" ? 1.25 : 1
            play(from: 1); record("started")
            try await waitFor { renderedFrames > 4800 }
            guard rendererMode == expectedVoice, !usesSystem, !systemFallback else { throw SpeechFailure.generation }
            record("playing-native")
            pause(); let frame = currentSampleOffset, frozen = renderedFrames
            rate = 1.25; try await Task.sleep(for: .seconds(1))
            guard paused, frame == currentSampleOffset, renderedFrames == frozen else { throw SpeechFailure.generation }
            record("paused-speed-stable"); resume()
            try await waitFor { renderedFrames > frozen + 2400 }; pause()
            let saved = cursor, savedFrame = currentSampleOffset
            stop(); play(from: saved.segment)
            try await waitFor { renderedFrames > 2400 }
            guard restoredPCMVerified, restoredCursor == saved, restoredFrameOffset == savedFrame,
                  rendererMode == expectedVoice, !usesSystem, !systemFallback else { throw SpeechFailure.generation }
            record("cached-PCM-recovered")
            pause()
            let expectedParagraph = parsed.adjacentParagraph(from: segmentIndex, forward: true)
            next()
            guard expectedParagraph != nil, segmentIndex == expectedParagraph, paused, renderedFrames == 0 else { throw SpeechFailure.generation }
            record("paused-next-paragraph"); resume()
            try await waitFor { renderedFrames > 4800 }
            guard rendererMode == expectedVoice, !usesSystem, !systemFallback else { throw SpeechFailure.generation }
            record("seek-native"); stop(); record("passed")
        } catch { stop(); record("failed: " + error.localizedDescription) }
    }
    #endif
    #if DEBUG && os(iOS)
    /// Save the actual device-generated PCM for local intelligibility comparison.
    func runVoiceQualityProbe() async {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--speech-quality-probe"),
              let directory, ["matcha", "piper"].contains(rendererMode) else { return }
        let backend = rendererMode
        let cases = [
            "夜风穿过窗棂，书页轻轻翻动。他在门前站了一会儿，终于敲响了那扇沉重的木门。她低声问：“你怎么现在才来？”他摇了摇头，没有回答。",
            "好，走吧。等一下，为什么？因为我还没有找到银行行长留下的那份重要文件。",
            "银行行长走过长街，重新检查沉重的木门。他觉得宿舍的床板很结实。",
            "石隙藏身终被缚，铜声劝死未援人。"
        ]
        let folder = cacheDirectory.deletingLastPathComponent()
        let reportURL = folder.appendingPathComponent("Speech-quality-probe.json")
        var rows: [[String: Any]] = []
        for (index, text) in cases.enumerated() {
            let prepared = SpeechInput.preparing(pronunciation.applying(to: text)), start = Date()
            do {
                let audio = backend == "matcha"
                    ? try await lightSynthesizer.generate(text: prepared, directory: directory.appendingPathComponent("Matcha"), cancellation: SynthesisCancellation())
                    : try await maleSynthesizer.generate(text: prepared, directory: directory.appendingPathComponent("Piper"), cancellation: SynthesisCancellation())
                let elapsed = Date().timeIntervalSince(start)
                let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count))!
                buffer.frameLength = buffer.frameCapacity
                audio.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                let file = "Speech-quality-\(backend)-\(index).wav"
                try AVAudioFile(forWriting: folder.appendingPathComponent(file), settings: format.settings).write(from: buffer)
                rows.append(["index": index, "text": text, "prepared": prepared, "file": file, "synthesisSeconds": elapsed,
                             "audioSeconds": audio.duration, "footprintMiB": Self.probeFootprint()])
            } catch { rows.append(["index": index, "error": error.localizedDescription]) }
            let report: [String: Any] = ["backend": backend, "model": modelVersion(for: requestedVoice(for: backend)),
                                        "date": Date().timeIntervalSince1970, "device": UIDevice.current.model, "rows": rows]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL, options: .atomic) }
        }
    }
    /// 持续试听，不运行前置计时，也不在恢复断言结束后自动停播。
    func runNativeListeningProbe() async {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--native-listening-test") else { return }
        let url = cacheDirectory.deletingLastPathComponent().appendingPathComponent("Speech-native-listening-probe.json")
        var rows: [[String: Any]] = []
        rate = 1
        if ProcessInfo.processInfo.arguments.contains("--light-speech-ui-testing") { rendererMode = "matcha" }
        else { rendererMode = ProcessInfo.processInfo.arguments.contains("--zipvoice-male-ui-testing") || ProcessInfo.processInfo.arguments.contains("--male-speech-ui-testing") ? "zipvoice-male" : "zipvoice" }
        playFromBeginning()
        for _ in 0..<120 {
            rows.append(["date": Date().timeIntervalSince1970, "evidence": playbackEvidence,
                         "error": error ?? "", "recovery": recoveryMessage, "synthesisFailure": lastSynthesisFailure,
                         "applicationState": UIApplication.shared.applicationState.rawValue,
                         "protectedData": UIApplication.shared.isProtectedDataAvailable,
                         "outputVolume": AVAudioSession.sharedInstance().outputVolume,
                         "route": AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue },
                         "bufferedSeconds": bufferedSeconds, "footprintMiB": Self.probeFootprint(),
                         "engineRunning": engine.isRunning, "playerPlaying": player.isPlaying,
                         "queuedCount": queuedCount, "completedFrames": completedFrames, "clockBase": clockBase])
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            if !playing { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }
    /// 真机计时使用实际合成器，隔离用户资料库和音频缓存。
    func runPerformanceProbe() async {
        let nativeProbe = ProcessInfo.processInfo.arguments.contains("--zipvoice-ui-testing")
        let rateProbe = ProcessInfo.processInfo.arguments.contains("--speech-rate-performance-probe")
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              (ProcessInfo.processInfo.arguments.contains("--speech-performance-probe") || rateProbe),
              let directory = Bundle.main.url(forResource: "Speech", withExtension: nil) else { return }
        let text = "夜风穿过窗棂，书页轻轻翻动。他在门前站了一会儿，终于敲响了那扇沉重的木门。"
        let url = cacheDirectory.deletingLastPathComponent().appendingPathComponent(rateProbe ? "Speech-native-rate-probe.json" : "Speech-performance-probe.json")
        let matcha = MatchaSynthesizer(), piper = VitsSynthesizer(), system = SystemSpeechRenderer(), zip = ZipVoiceSynthesizer()
        var rows: [[String: Any]] = []
        func write() {
            let report: [String: Any] = ["device": UIDevice.current.model, "system": UIDevice.current.systemVersion, "date": Date().timeIntervalSince1970, "voice": ProcessInfo.processInfo.arguments.contains("--zipvoice-male-ui-testing") ? "dylan" : "serena", "modelVersion": ProcessInfo.processInfo.arguments.contains("--zipvoice-male-ui-testing") ? "zipvoice-coreml-fp16-cpu-1024-4-dylan-natural-ref352-pcm2" : "zipvoice-coreml-fp16-cpu-1024-4-qwenref352-pcm3", "computeUnits": ProcessInfo.processInfo.arguments.contains("--zipvoice-gpu-probe") ? "cpuAndGPU" : "cpuOnly", "cpuPercentConvention": "100 percent equals one CPU core; whole process during synthesis", "text": text, "rows": rows]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        }
        let speeds: [Float] = rateProbe ? [1, 1.25, 1.5] : [1]
        for backend in nativeProbe ? ["zipvoice"] : rateProbe ? ["matcha", "piper"] : ["matcha", "piper", "system"] {
            for speed in speeds {
            for iteration in 0...4 {
                let start = Date()
                let cpuStart = Self.probeCPUSeconds()
                let baselineMemory = Self.probeFootprint()
                do {
                    let audio: SpeechAudio
                    switch backend {
                    case "zipvoice":
                        var samples: [Float] = []
                        for part in ["夜风穿过窗棂，书页轻轻翻动。", "他在门前站了一会儿，", "终于敲响了那扇沉重的木门。"] {
                            samples += try await zip.generate(text: part, directory: directory.appendingPathComponent("ZipVoice"), referenceFile: ProcessInfo.processInfo.arguments.contains("--zipvoice-male-ui-testing") ? "reference-dylan.json" : "reference.json", cancellation: SynthesisCancellation()).samples
                        }
                        audio = SpeechAudio(samples: samples, sampleRate: 24000)
                    case "matcha": audio = try await matcha.generate(text: text, directory: directory.appendingPathComponent("Matcha"), speed: speed, cancellation: SynthesisCancellation())
                    case "piper": audio = try await piper.generate(text: text, directory: directory.appendingPathComponent("Piper"), speed: speed, cancellation: SynthesisCancellation())
                    default: audio = try await system.generate(text: text, voiceID: systemVoiceID)
                    }
                    rows.append(["backend": backend, "speed": speed, "iteration": iteration, "synthesisSeconds": Date().timeIntervalSince(start), "audioSeconds": audio.duration, "samples": audio.samples.count, "footprintMiB": Self.probeFootprint(), "baselineFootprintMiB": baselineMemory, "processLifetimePeakFootprintMiB": Self.probePeakFootprint(), "cpuSeconds": Self.probeCPUSeconds() - cpuStart, "averageCPUPercent": 100 * (Self.probeCPUSeconds() - cpuStart) / max(0.001, Date().timeIntervalSince(start)), "thermal": ProcessInfo.processInfo.thermalState.rawValue])
                    if iteration == 0, backend == "zipvoice" {
                        let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1)!
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count))!
                        buffer.frameLength = buffer.frameCapacity
                        audio.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                        let file = try AVAudioFile(forWriting: url.deletingLastPathComponent().appendingPathComponent("Speech-performance-audio.wav"), settings: format.settings)
                        try file.write(from: buffer)
                    }
                } catch { rows.append(["backend": backend, "iteration": iteration, "error": error.localizedDescription]); write(); return }
                write()
            }
            }
        }
        rows.append(["phase": "passed"]); write()
    }
    /// Whole-process CPU time; 100% in the report means one occupied CPU core.
    private static func probeCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    /// Kernel high-water mark since process launch, including model loading.
    private static func probePeakFootprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
    }
    private static func probeFootprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    /// 后台先检查轻量模型的真实 PCM，再模拟开源合成卡住并在同一播放代次恢复。
    /// 全程使用隔离测试文稿，不修改用户正文。
    func runBackgroundProbe() async {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--background-speech-testing") else { return }
        let url = cacheDirectory.deletingLastPathComponent().appendingPathComponent("Background-speech-probe.json")
        var rows: [[String: Any]] = []
        func record(_ phase: String) {
            rows.append(["phase": phase, "date": Date().timeIntervalSince1970, "evidence": playbackEvidence, "state": UIApplication.shared.applicationState.rawValue, "thermal": ProcessInfo.processInfo.thermalState.rawValue, "protectedData": UIApplication.shared.isProtectedDataAvailable])
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        }
        do {
            let native = ProcessInfo.processInfo.arguments.contains("--zipvoice-ui-testing")
            rate = 1.25; rendererMode = native ? (ProcessInfo.processInfo.arguments.contains("--zipvoice-male-ui-testing") ? "zipvoice-male" : "zipvoice") : "matcha"; playFromBeginning(); record("started-matcha")
            let started = Date(); var backgroundSeconds = 0; var lastFrame: Int64 = 0
            while backgroundSeconds < 110 && Date().timeIntervalSince(started) < 300 {
                try await Task.sleep(for: .seconds(5))
                if let error { throw NSError(domain: "BackgroundSpeechProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                if UIApplication.shared.applicationState == .background && renderedFrames > lastFrame { backgroundSeconds += 5 }
                lastFrame = renderedFrames; record("matcha-sample")
            }
            guard backgroundSeconds >= 110, !usesSystem, underruns == 0 else { throw SpeechFailure.generation }
            record(native ? "zipvoice-background-passed" : "matcha-background-passed")
            if native { pause(); record("passed"); return }
            stop(); rendererMode = "piper"; injectedStall = false; playFromBeginning()
            let generation = transportGeneration; record("started-stall")
            let recoveryStart = Date()
            while Date().timeIntervalSince(recoveryStart) < 40 && (!systemFallback || renderedFrames <= 4800) {
                try await Task.sleep(for: .seconds(2)); record("recovery-sample")
                if let error { throw NSError(domain: "BackgroundSpeechProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
            }
            guard systemFallback, renderedFrames > 4800, transportGeneration == generation,
                  UIApplication.shared.applicationState == .background else { throw SpeechFailure.generation }
            record("stall-background-recovered"); pause(); record("passed")
        } catch { stop(); record("failed: " + error.localizedDescription) }
    }
    /// XCTest 无法连接时使用的真机探针，只允许隔离测试资料库，不打开用户文稿。
    func runDeviceProbe() async {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--speech-device-probe") else { return }
        let url = cacheDirectory.deletingLastPathComponent().appendingPathComponent("Speech-device-probe.json")
        var events: [[String: Any]] = []
        func record(_ phase: String, _ details: [String: Any] = [:]) {
            var event = details
            event["phase"] = phase; event["evidence"] = playbackEvidence
            events.append(event)
            if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url, options: .atomic)
            }
            NSLog("Speech device probe: %@ %@", phase, String(describing: event))
        }
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw NSError(domain: "SpeechDeviceProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
        }
        func waitFor(_ reason: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(60)
            while !condition() {
                if let error { throw NSError(domain: "SpeechDeviceProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
                try require(Date() < deadline, "Timeout: " + reason)
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        do {
            let expectedRenderer = rendererMode
            record("started", ["device": UIDevice.current.model, "system": UIDevice.current.systemVersion])
            // 在 iOS 真机复现旧音频配置；后续检查均走产品实际的开始和继续路径。
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
                record("legacy-accepted")
            } catch {
                let native = error as NSError
                record("legacy-rejected", ["domain": native.domain, "code": native.code, "error": native.localizedDescription])
            }
            rate = 1
            play(from: 1)
            try await waitFor("native PCM playback") { renderedFrames > 4800 }
            if expectedRenderer != "system" {
                try require(rendererMode == expectedRenderer && !usesSystem && !systemFallback, "Requested backend did not produce the playing PCM")
            }
            record("playing", ["route": AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }])
            if expectedRenderer != "system" {
                let beforeGraphPause = renderedFrames, sameGeneration = ledger.generation
                engine.pause()
                try await waitFor("audio graph restart with retained PCM") { renderedFrames > beforeGraphPause + 4800 }
                try require(ledger.generation == sameGeneration && !usesSystem && !systemFallback,
                            "Audio graph restart changed the voice or playback generation")
                record("audio-graph-recovered")
            }
            pause()
            let frozen = renderedFrames, sample = currentSampleOffset, generation = ledger.generation
            rate = 1.25
            try await Task.sleep(for: .seconds(1))
            try require(paused && renderedFrames == frozen && currentSampleOffset == sample && ledger.generation == generation, "Pause or speed changed the audio position")
            record("paused-speed-stable")
            resume()
            try await waitFor("resume") { renderedFrames > frozen + 2400 }
            record("resumed")
            pause()
            let saved = cursor, savedFrame = currentSampleOffset
            record("saved-PCM", ["segment": saved.segment, "offset": saved.offset, "sample": savedFrame])
            stop(); play(from: saved.segment)
            try await waitFor("cached PCM recovery") { renderedFrames > 2400 }
            record("restored-PCM", ["expectedSegment": saved.segment, "expectedOffset": saved.offset, "expectedSample": savedFrame])
            try require(restoredPCMVerified && restoredCursor == saved && restoredFrameOffset == savedFrame, "Cached waveform or sample offset changed")
            record("cached-PCM-recovered")
            pause()
            let expected = parsed.adjacentParagraph(from: segmentIndex, forward: true)
            next()
            try require(expected != nil && segmentIndex == expected && paused && renderedFrames == 0, "Paused paragraph seek moved to an incorrect position")
            record("paused-next-paragraph")
            resume()
            try await waitFor("seek playback") { renderedFrames > 4800 }
            let paragraph = segmentIndex
            try await waitFor("continuous next paragraph") { segmentIndex > paragraph }
            try require(underruns == 0, "Synthesis queue ran out between paragraphs")
            if expectedRenderer != "system" {
                try require(rendererMode == expectedRenderer && !usesSystem && !systemFallback, "Requested backend fell back while reading consecutive paragraphs")
            }
            record("continuous-paragraphs")
            stop()
            record("passed")
        } catch {
            stop()
            let native = error as NSError
            record("failed", ["domain": native.domain, "code": native.code, "error": native.localizedDescription])
        }
    }
    #endif
    func seek(to index: Int, notifyPosition: Bool = true) { seek(to: SpeechCursor(segment: min(max(0, index), max(0, parsed.segments.count - 1))), notifyPosition: notifyPosition) }
    func seek(toSourceOffset offset: Int, notifyPosition: Bool = true) { seek(to: parsed.speechCursor(at: offset), notifyPosition: notifyPosition) }
    private func seek(to target: SpeechCursor, notifyPosition: Bool) {
        let wasPlaying = playing, wasPaused = paused
        stop(); cursor = target; segmentIndex = target.segment
        if let chunk = parsed.speechChunk(from: target, skipCode: skipCode, renderer: rendererMode), notifyPosition { onPosition?(chunk.sourceOffset) }
        if wasPlaying { begin(at: target, initiallyPaused: wasPaused, useCheckpoint: false) }
    }
    func next() { if let next = parsed.adjacentParagraph(from: segmentIndex, forward: true) { seek(to: next) } else { stop() } }
    func previous() { seek(to: parsed.adjacentParagraph(from: segmentIndex, forward: false) ?? 0) }
    private func nowPlaying() {
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = playing ? [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: "墨语引擎 · 第 \(segmentIndex + 1) 段", MPNowPlayingInfoPropertyPlaybackRate: paused ? 0 : rate] : nil
        if !playing { audioSessionQueue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } }
        #endif
    }
}
