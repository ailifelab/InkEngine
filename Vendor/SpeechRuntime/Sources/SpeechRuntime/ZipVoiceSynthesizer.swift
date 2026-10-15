import Foundation
import CoreML

/// ZipVoice-Distill: local Core ML text/flow/Vocos models, four Euler steps.
public actor ZipVoiceSynthesizer {
    private struct Reference: Decodable { let text: String; let frames: Int; let features: [Float]; let gain: Float }
    private var textEncoder: MLModel?, flowDecoder: MLModel?, vocoder: MLModel?
    private var frontend: ZipVoiceFrontend?
    private var reference: Reference?
    private var fft: NativeISTFT?
    private var loadedReferenceFile = ""
    private var loadedDirectory: URL?
    private let tokenCapacity = 128, frameCapacity = 1024
    public init() {}
    public func unload() {
        textEncoder = nil; flowDecoder = nil; vocoder = nil; frontend = nil
        reference = nil; fft = nil; loadedDirectory = nil; loadedReferenceFile = ""
    }
    private func prepare(_ directory: URL, referenceFile: String) throws {
        if loadedDirectory != directory { unload() }
        if textEncoder != nil {
            if loadedReferenceFile != referenceFile { try loadReference(directory, file: referenceFile) }
            return
        }
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        #if DEBUG
        // Explicit isolated foreground benchmark only; normal narration stays on CPU.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--zipvoice-gpu-probe") {
            configuration.computeUnits = .cpuAndGPU
        }
        #endif
        // Paired inputs showed large CPU/ANE drift in these exported graphs.
        // Use the verified CPU route until accelerator parity is established.
        // Core ML CPU also supports background narration without GPU access.
        func load(_ name: String) throws -> MLModel {
            let file = directory.appendingPathComponent(name + ".mlmodelc")
            guard FileManager.default.fileExists(atPath: file.path) else { throw SpeechFailure.missing(file.lastPathComponent) }
            return try MLModel(contentsOf: file, configuration: configuration)
        }
        let text = try load("TextEncoder"), flow = try load("FmDecoder"), vocos = try load("Vocos")
        let front = try ZipVoiceFrontend(tokens: String(contentsOf: directory.appendingPathComponent("tokens.txt"), encoding: .utf8),
                                         lexicon: String(contentsOf: directory.appendingPathComponent("lexicon.txt"), encoding: .utf8))
        fft = try NativeISTFT(); frontend = front
        try loadReference(directory, file: referenceFile)
        textEncoder = text; flowDecoder = flow; vocoder = vocos; loadedDirectory = directory
    }
    private func loadReference(_ directory: URL, file: String) throws {
        guard ["reference.json", "reference-dylan.json"].contains(file) else { throw SpeechFailure.unsupportedText }
        let ref = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: directory.appendingPathComponent(file)))
        guard (1..<frameCapacity).contains(ref.frames), ref.features.count == ref.frames * 100,
              ref.features.allSatisfy(\.isFinite), ref.gain.isFinite, ref.gain > 0, ref.gain <= 1 else { throw SpeechFailure.initialization }
        reference = ref; loadedReferenceFile = file
    }
    public func generate(text: String, directory: URL, referenceFile: String = "reference.json", cancellation: SynthesisCancellation) throws -> SpeechAudio {
        try autoreleasepool { try generateWithinPool(text: text, directory: directory, referenceFile: referenceFile, cancellation: cancellation) }
    }
    private func generateWithinPool(text: String, directory: URL, referenceFile: String, cancellation: SynthesisCancellation) throws -> SpeechAudio {
        if cancellation.isCancelled { throw CancellationError() }
        try prepare(directory, referenceFile: referenceFile)
        guard let frontend, let reference, let textEncoder, let flowDecoder, let vocoder, let fft else { throw SpeechFailure.initialization }
        let prompt = try frontend.encode(reference.text), tokens = prompt + (try frontend.encode(text))
        guard tokens.count + 1 <= tokenCapacity else { throw SpeechFailure.unsupportedText }
        // Match the upstream duration-ratio expansion, including its one pad
        // embedding for the duration remainder. Do not shorten any syllables.
        let frames = Int(ceil(Double(reference.frames) / Double(prompt.count) * Double(tokens.count)))
        guard frames <= frameCapacity, frames > reference.frames + 1 else { throw SpeechFailure.unsupportedText }
        let tokenInput = try MLMultiArray(shape: [1, NSNumber(value: tokenCapacity)], dataType: .int32)
        let tokenPointer = tokenInput.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<tokenCapacity { tokenPointer[i] = i < tokens.count ? tokens[i] : 0 }
        var tokenMask = [Float](repeating: 1, count: tokenCapacity)
        for i in 0..<tokens.count { tokenMask[i] = 0 }
        let encoded = try predict(textEncoder, ["tokens": tokenInput, "padding_mask": array(tokenMask, [1, tokenCapacity])], "token_embeds")
        guard encoded.count == tokenCapacity * 100 else { throw SpeechFailure.generation }
        var condition = [Float](repeating: 0, count: frameCapacity * 100)
        let duration = frames / tokens.count
        for f in 0..<frames {
            let tokenIndex = min(tokens.count, f / duration)
            for c in 0..<100 { condition[f * 100 + c] = encoded[[0, NSNumber(value: tokenIndex), NSNumber(value: c)]].floatValue }
        }
        var speech = [Float](repeating: 0, count: frameCapacity * 100)
        speech.replaceSubrange(0..<reference.features.count, with: reference.features)
        var mask = [Float](repeating: 1, count: frameCapacity)
        for i in 0..<frames { mask[i] = 0 }
        let speechArray = try array(speech, [1, frameCapacity, 100]), conditionArray = try array(condition, [1, frameCapacity, 100])
        let maskArray = try array(mask, [1, frameCapacity]), guidance = try array([3], [1])
        var noise = [Float](repeating: 0, count: frameCapacity * 100)
        #if DEBUG
        var probeSeed: UInt64 = 20261014
        let useProbeSeed = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            && ProcessInfo.processInfo.arguments.contains("--zipvoice-parity-probe")
        func probeUniform() -> Float {
            if useProbeSeed {
                probeSeed ^= probeSeed << 13; probeSeed ^= probeSeed >> 7; probeSeed ^= probeSeed << 17
                // Both integers are exactly representable; keep the result inside (0, 1).
                return Float((probeSeed >> 40) + 1) / 16_777_218
            }
            return Float.random(in: Float.leastNonzeroMagnitude..<1)
        }
        #else
        func probeUniform() -> Float { Float.random(in: Float.leastNonzeroMagnitude..<1) }
        #endif
        for i in stride(from: 0, to: noise.count, by: 2) {
            let radius = sqrt(-2 * log(probeUniform()))
            let angle = 2 * Float.pi * probeUniform()
            noise[i] = radius * cos(angle); noise[i + 1] = radius * sin(angle)
        }
        let times: [Float] = (0...4).map { let t = Float($0) / 4; return 0.5 * t / (1 - 0.5 * t) }
        for step in 0..<4 {
            if cancellation.isCancelled { throw CancellationError() }
            let velocity = try predict(flowDecoder, ["t": array([times[step]], [1]), "x": array(noise, [1, frameCapacity, 100]),
                                                     "text_condition": conditionArray, "speech_condition": speechArray,
                                                     "guidance_scale": guidance, "padding_mask": maskArray], "v")
            guard velocity.count == noise.count else { throw SpeechFailure.generation }
            let values = try CoreMLTensor.floats(velocity)
            for i in noise.indices { noise[i] += values[i] * (times[step + 1] - times[step]) }
        }
        if cancellation.isCancelled { throw CancellationError() }
        let targetFrames = frames - reference.frames
        var features = [Float](repeating: 0, count: 100 * targetFrames)
        for c in 0..<100 { for f in 0..<targetFrames { features[c * targetFrames + f] = noise[(f + reference.frames) * 100 + c] * 10 } }
        let result = try vocoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": array(features, [1, 100, targetFrames])]))
        guard let real = result.featureValue(for: "real")?.multiArrayValue, let imaginary = result.featureValue(for: "imag")?.multiArrayValue else { throw SpeechFailure.generation }
        // Read by logical index so non-contiguous Core ML outputs are safe.
        let pcm = try fft.reconstruct(real: CoreMLTensor.floats(real),
                                      imaginary: CoreMLTensor.floats(imaginary), frames: targetFrames).map { $0 * reference.gain }
        if cancellation.isCancelled { throw CancellationError() }
        guard pcm.contains(where: { abs($0) > 0.0001 }) else { throw SpeechFailure.generation }
        return SpeechAudio(samples: pcm, sampleRate: 24000)
    }
    private func array(_ values: [Float], _ shape: [Int]) throws -> MLMultiArray {
        guard values.allSatisfy(\.isFinite) else { throw SpeechFailure.generation }
        let output = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        guard output.count == values.count else { throw SpeechFailure.generation }
        let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
        values.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: values.count) }
        return output
    }
    private func predict(_ model: MLModel, _ inputs: [String: MLMultiArray], _ name: String) throws -> MLMultiArray {
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let output = result.featureValue(for: name)?.multiArrayValue else { throw SpeechFailure.generation }
        return output
    }
}
