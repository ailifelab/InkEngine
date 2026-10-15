import Foundation
import SpeechRuntime
#if os(macOS)
import Darwin
#endif

@main struct Probe {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data(("SpeechProbe failed: \(error)\n").utf8)); exit(1) }
    }
    static func run() async throws {
        let arguments = CommandLine.arguments
        if arguments.contains("--zipvoice-benchmark") { try ZipVoiceBenchmark.run(arguments); return }
        guard arguments.count >= 3 else { fatalError("SpeechProbe model-directory output.wav [text] [--speaker ID]") }
        let text = arguments.count > 3 ? arguments[3] : "窗外的风带来了雨的气息。她放下手中的书，轻声说：明天，我们再出发。听见文字，也听见句子之间的停顿。2026年10月10日，我们在银行门口见面。"
        let start = Date()
        let speedIndex = arguments.firstIndex(of: "--speed")
        let speed: Float = speedIndex.flatMap { $0 + 1 < arguments.count ? Float(arguments[$0 + 1]) : nil } ?? 1
        let speakerIndex = arguments.firstIndex(of: "--speaker")
        let speaker = speakerIndex.flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 0
        guard speaker >= 0 else { fatalError("Speaker ID must be nonnegative") }
        func floatOption(_ flag: String, default value: Float) -> Float {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return value }
            return Float(arguments[i + 1]) ?? value
        }
        let matcha = MatchaSynthesizer(noiseScale: floatOption("--tts-noise", default: 1))
        let vits = VitsSynthesizer(noiseScale: floatOption("--tts-noise", default: 0.667), durationNoise: floatOption("--tts-duration-noise", default: 0.8), espeakFrontend: arguments.contains("--vits-espeak"))
        let zipvoice = ZipVoiceSynthesizer()
        #if os(macOS)
        let qwen = QwenSynthesizer()
        #endif
        var texts = [text]
        if let index = arguments.firstIndex(of: "--chunks-json"), index + 1 < arguments.count {
            texts = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
            guard !texts.isEmpty, texts.joined() == text else { throw SpeechFailure.unsupportedText }
        }
        func generateOne(text: String) async throws -> SpeechAudio {
            if arguments.contains("--zipvoice-coreml") { return try await zipvoice.generate(text: text, directory: URL(fileURLWithPath: arguments[1]), referenceFile: arguments.contains("--zipvoice-male") ? "reference-dylan.json" : "reference.json", cancellation: SynthesisCancellation()) }
            #if os(macOS)
            if arguments.contains("--qwen-coreml") { return try await qwen.generate(text: text, directory: URL(fileURLWithPath: arguments[1]), cancellation: SynthesisCancellation()) }
            #endif
            if arguments.contains("--vits") { return try await vits.generate(text: text, directory: URL(fileURLWithPath: arguments[1]), speaker: speaker, speed: speed, cancellation: SynthesisCancellation()) }
            if arguments.contains("--matcha") { return try await matcha.generate(text: text, directory: URL(fileURLWithPath: arguments[1]), speed: speed, cancellation: SynthesisCancellation()) }
            return try await matcha.generate(text: text, directory: URL(fileURLWithPath: arguments[1]), speed: speed, cancellation: SynthesisCancellation())
        }
        func generate() async throws -> SpeechAudio {
            if texts.count == 1 { return try await generateOne(text: text) }
            var output: [Float] = []
            for part in texts {
                let audio = try await generateOne(text: part)
                guard audio.sampleRate == 24000 else { throw SpeechFailure.generation }
                output.append(contentsOf: audio.samples)
            }
            return SpeechAudio(samples: output, sampleRate: 24000)
        }
        let audio = try await generate()
        func writeWave(_ audio: SpeechAudio, to destination: URL) throws {
            var data = Data()
            func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
            func uint<T: FixedWidthInteger>(_ n: T) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
            ascii("RIFF"); uint(UInt32(36 + audio.samples.count * 2)); ascii("WAVEfmt "); uint(UInt32(16)); uint(UInt16(1)); uint(UInt16(1)); uint(UInt32(audio.sampleRate)); uint(UInt32(audio.sampleRate * 2)); uint(UInt16(2)); uint(UInt16(16)); ascii("data"); uint(UInt32(audio.samples.count * 2))
            for sample in audio.samples { uint(Int16(max(-1, min(1, sample)) * 32767)) }
            try data.write(to: destination)
        }
        try writeWave(audio, to: URL(fileURLWithPath: arguments[2]))
        let backend = arguments.contains("--zipvoice-coreml") ? "ZipVoice-Distill 4 steps / CoreML" : arguments.contains("--qwen-coreml") ? "Qwen CustomVoice Serena / CoreML" : arguments.contains("--vits") ? "VITS/Piper Chinese" : "Matcha zh-en, 6 steps"
        print("\(backend), speaker=\(speaker), speed=\(speed), \(audio.sampleRate) Hz, \(audio.samples.count) samples, \(audio.duration)s audio, \(Date().timeIntervalSince(start))s synthesis")
        if arguments.contains("--benchmark") {
            for iteration in 1...4 {
                let start = Date()
                let next = try await generate()
                print("BENCH warm=\(iteration) synthesis=\(Date().timeIntervalSince(start)) audio=\(next.duration)")
                if arguments.contains("--benchmark-audio") {
                    let base = URL(fileURLWithPath: arguments[2]).deletingPathExtension().path
                    try writeWave(next, to: URL(fileURLWithPath: base + "-warm\(iteration).wav"))
                }
            }
        }
        if arguments.contains("--verify-repeat") {
            let repeated = try await generate()
            print("Repeat generation identical: \(repeated.samples == audio.samples). Resume always uses retained PCM.")
        }
        if arguments.contains("--verify-unload") {
            #if os(macOS)
            print("MEMORY loadedMiB=\(footprint())")
            #endif
            await matcha.unload(); await vits.unload()
            await zipvoice.unload()
            #if os(macOS)
            await qwen.unload()
            #endif
            #if os(macOS)
            print("MEMORY unloadedMiB=\(footprint())")
            #endif
            let reloaded = try await generate()
            guard !reloaded.samples.isEmpty else { throw SpeechFailure.generation }
            print("Reloaded synthesis: \(reloaded.samples.count) samples, \(reloaded.duration)s")
        }
    }
    #if os(macOS)
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    #endif
}
