import Foundation
import AVFoundation
import SherpaOnnxC

/// Matcha 中文英文模型与 Vocos 声码器；actor 串行执行，使用两条 CPU 线程，本地离线。
public actor MatchaSynthesizer {
    private var handle: OpaquePointer?
    private var coverage: ChineseLexiconCoverage?
    private let noiseScale: Float
    private let acousticModelFile: String
    public init(noiseScale: Float = 1, acousticModelFile: String = "model-steps-6.onnx") {
        self.noiseScale = min(1.5, max(0, noiseScale)); self.acousticModelFile = acousticModelFile
    }
    /// 在actor中释放，等待正在执行的原生调用结束，避免销毁仍被使用的模型。
    public func unload() {
        if let handle { SherpaOnnxDestroyOfflineTts(handle) }
        handle = nil; coverage = nil
    }
    deinit { if let handle { SherpaOnnxDestroyOfflineTts(handle) } }
    private func prepare(_ directory: URL) throws {
        guard handle == nil else { return }
        var strings: [UnsafeMutablePointer<CChar>] = []
        func path(_ name: String) throws -> UnsafePointer<CChar> {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { throw SpeechFailure.missing(name) }
            let pointer = strdup(file.path)!; strings.append(pointer); return UnsafePointer(pointer)
        }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOfflineTtsConfig()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--tts-frontend-audit") { config.model.debug = 1 }
        #endif
        guard ["model-steps-3.onnx", "model-steps-6.onnx"].contains(acousticModelFile) else { throw SpeechFailure.initialization }
        config.model.matcha.acoustic_model = try path(acousticModelFile)
        config.model.matcha.vocoder = try path("vocos-16khz-univ.onnx")
        config.model.matcha.tokens = try path("tokens.txt")
        config.model.matcha.lexicon = try path("lexicon.txt")
        config.model.matcha.data_dir = try path(FileManager.default.fileExists(atPath: directory.appendingPathComponent("espeak-ng-data").path) ? "espeak-ng-data" : "../espeak-ng-data")
        config.model.matcha.noise_scale = noiseScale; config.model.matcha.length_scale = 1
        let rules = ["date-zh.fst", "number-zh.fst", "phone-zh.fst"].map { directory.appendingPathComponent($0).path }.joined(separator: ",")
        let rulePointer = strdup(rules)!, provider = strdup("cpu")!; strings.append(rulePointer); strings.append(provider)
        config.rule_fsts = UnsafePointer(rulePointer); config.model.provider = UnsafePointer(provider)
        // 底层静音缩放会按幅度删除样本，可能误伤轻声；保留模型完整波形。
        config.model.num_threads = 2; config.max_num_sentences = 3; config.silence_scale = 1
        let validatedCoverage = ChineseLexiconCoverage(lexicon: try String(contentsOf: directory.appendingPathComponent("lexicon.txt"), encoding: .utf8))
        guard let handle = SherpaOnnxCreateOfflineTts(&config) else { throw SpeechFailure.initialization }
        self.handle = handle
        coverage = validatedCoverage
    }
    public func generate(text: String, directory: URL, speed: Float = 1, cancellation: SynthesisCancellation) throws -> SpeechAudio {
        if cancellation.isCancelled { throw CancellationError() }
        try prepare(directory)
        if cancellation.isCancelled { throw CancellationError() }
        try coverage?.validate(text)
        var config = SherpaOnnxGenerationConfig(); config.sid = 0; config.speed = min(1.5, max(0.65, speed)); config.silence_scale = 1
        let callback: SherpaOnnxGeneratedAudioProgressCallbackWithArg = { _, _, _, context in
            guard let context else { return 0 }
            return Unmanaged<SynthesisCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 0 : 1
        }
        guard let audio = text.withCString({ SherpaOnnxOfflineTtsGenerateWithConfig(handle, $0, &config, callback, Unmanaged.passUnretained(cancellation).toOpaque()) }) else { throw SpeechFailure.generation }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        if cancellation.isCancelled { throw CancellationError() }
        guard audio.pointee.n > 0, audio.pointee.sample_rate == 16000, let samples = audio.pointee.samples else { throw SpeechFailure.generation }
        let output = Array(UnsafeBufferPointer(start: samples, count: Int(audio.pointee.n)))
        guard output.allSatisfy(\.isFinite), output.contains(where: { abs($0) > 0.0001 }) else { throw SpeechFailure.generation }
        // 模型输出16 kHz，统一重采样到播放器的24 kHz；后续样本账本只使用播放器坐标。
        return try SpeechAudio(samples: output, sampleRate: 16000).resampled()
    }
}
