#if os(macOS)
import Foundation
import CoreML
import NativeQwen

/// Six local Core ML components. Never downloads weights or sends narration.
public actor QwenSynthesizer {
    private var model: Qwen3TTSCoreMLModel?
    private var loadedDirectory: URL?
    public init() {}
    public func unload() { model?.unload(); model = nil; loadedDirectory = nil }
    public func generate(text: String, directory: URL, cancellation: SynthesisCancellation) async throws -> SpeechAudio {
        if cancellation.isCancelled { throw CancellationError() }
        if loadedDirectory != directory { unload() }
        if model == nil {
            model = try await Qwen3TTSCoreMLModel.fromPretrained(localPath: directory.path, offlineMode: true, computeUnits: .cpuAndGPU, speechDecoderComputeUnits: .cpuOnly)
            loadedDirectory = directory
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard let model else { throw SpeechFailure.initialization }
        let samples = try autoreleasepool {
            try model.synthesize(text: text, language: "chinese", temperature: 0.9, maxTokens: model.maximumAudioFrames,
                                 isCancelled: { cancellation.isCancelled })
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), samples.contains(where: { abs($0) > 0.0001 }) else { throw SpeechFailure.generation }
        return SpeechAudio(samples: samples, sampleRate: 24000)
    }
}
#endif
