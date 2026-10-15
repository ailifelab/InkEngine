import Foundation
import SherpaOnnxC

/// 轻量中文VITS/Piper：中文拼音词典作前端，直接生成音频；不使用英语声音模拟中文。
/// actor隔离模型，原生回调支持取消；速度传给时长预测器，直接合成较短或较长的波形。
public actor VitsSynthesizer {
    private var handle: OpaquePointer?
    private var coverage: ChineseLexiconCoverage?
    private let noiseScale: Float, durationNoise: Float
    private let espeakFrontend: Bool
    public init(noiseScale: Float = 0.667, durationNoise: Float = 0.8, espeakFrontend: Bool = false) {
        self.noiseScale = min(1.5, max(0, noiseScale)); self.durationNoise = min(1.5, max(0, durationNoise))
        self.espeakFrontend = espeakFrontend
    }
    /// 不再使用该音色时释放模型与词典；下一次选择时按需加载。
    public func unload() {
        if let handle { SherpaOnnxDestroyOfflineTts(handle) }
        handle = nil; coverage = nil
    }
    deinit { if let handle { SherpaOnnxDestroyOfflineTts(handle) } }
    private func prepare(_ directory: URL) throws {
        guard handle == nil else { return }
        var strings: [UnsafeMutablePointer<CChar>] = []
        func c(_ value: String) -> UnsafePointer<CChar> {
            let pointer = strdup(value)!; strings.append(pointer); return UnsafePointer(pointer)
        }
        func path(_ name: String) throws -> UnsafePointer<CChar> {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { throw SpeechFailure.missing(name) }
            return c(file.path)
        }
        defer { strings.forEach { free($0) } }
        let models = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "onnx" }
        guard models.count == 1, let model = models.first else { throw SpeechFailure.missing("VITS模型") }
        var config = SherpaOnnxOfflineTtsConfig()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--tts-frontend-audit") { config.model.debug = 1 }
        #endif
        config.model.vits.model = c(model.path)
        config.model.vits.tokens = try path("tokens.txt")
        if espeakFrontend {
            // Huayan 的模型使用 eSpeak 音素，不能送入超文模型的拼音 ID。
            config.model.vits.data_dir = try path(FileManager.default.fileExists(atPath: directory.appendingPathComponent("espeak-ng-data").path) ? "espeak-ng-data" : "../espeak-ng-data")
        } else { config.model.vits.lexicon = try path("lexicon.txt") }
        config.model.vits.noise_scale = noiseScale; config.model.vits.noise_scale_w = durationNoise; config.model.vits.length_scale = 1
        // 底层静音缩放会按幅度删除样本，可能误伤轻声；保留模型完整波形。
        config.model.num_threads = 2; config.model.provider = c("cpu")
        let rules = ["phone.fst", "date.fst", "number.fst"].map { directory.appendingPathComponent($0).path }
        for rule in rules where !FileManager.default.fileExists(atPath: rule) { throw SpeechFailure.missing((rule as NSString).lastPathComponent) }
        config.rule_fsts = c(rules.joined(separator: ",")); config.max_num_sentences = 3; config.silence_scale = 1
        let validatedCoverage = ChineseLexiconCoverage(lexicon: try String(contentsOf: directory.appendingPathComponent(espeakFrontend ? "coverage-lexicon.txt" : "lexicon.txt"), encoding: .utf8))
        guard let handle = SherpaOnnxCreateOfflineTts(&config) else { throw SpeechFailure.initialization }
        self.handle = handle
        coverage = validatedCoverage
    }
    public func generate(text: String, directory: URL, speaker: Int = 0, speed: Float = 1, cancellation: SynthesisCancellation) throws -> SpeechAudio {
        if cancellation.isCancelled { throw CancellationError() }; try prepare(directory)
        if cancellation.isCancelled { throw CancellationError() }
        try coverage?.validate(text, chineseOnly: true)
        var config = SherpaOnnxGenerationConfig(); config.sid = Int32(speaker); config.speed = min(1.5, max(0.65, speed)); config.silence_scale = 1
        let callback: SherpaOnnxGeneratedAudioProgressCallbackWithArg = { _, _, _, context in
            guard let context else { return 0 }
            return Unmanaged<SynthesisCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 0 : 1
        }
        guard let audio = text.withCString({ SherpaOnnxOfflineTtsGenerateWithConfig(handle, $0, &config, callback, Unmanaged.passUnretained(cancellation).toOpaque()) }) else { throw SpeechFailure.generation }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        if cancellation.isCancelled { throw CancellationError() }
        guard audio.pointee.n > 0, audio.pointee.sample_rate > 0, let samples = audio.pointee.samples else { throw SpeechFailure.generation }
        let output = Array(UnsafeBufferPointer(start: samples, count: Int(audio.pointee.n)))
        guard output.allSatisfy(\.isFinite), output.contains(where: { abs($0) > 0.0001 }) else { throw SpeechFailure.generation }
        return try SpeechAudio(samples: output, sampleRate: Int(audio.pointee.sample_rate)).resampled()
    }
}
