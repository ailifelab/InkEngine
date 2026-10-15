import Foundation
import Darwin
import SherpaOnnxC

/// Research executable only; does not add a voice or model to the application.
enum ZipVoiceBenchmark {
    private final class Progress {
        let started = DispatchTime.now().uptimeNanoseconds
        private let lock = NSLock()
        private(set) var firstAudio: Double?
        private(set) var chunks: [(time: Double, samples: Int)] = []
        func receive(_ samples: UnsafePointer<Float>?, count: Int) {
            guard let samples, count > 0 else { return }
            let values = UnsafeBufferPointer(start: samples, count: count)
            guard values.contains(where: { abs($0) > 0.0001 }) else { return }
            lock.lock(); defer { lock.unlock() }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            if firstAudio == nil { firstAudio = elapsed }
            chunks.append((elapsed, count))
        }
    }

    static func run(_ arguments: [String]) throws {
        guard arguments.count > 3 else { throw Failure.arguments }
        func option(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let referencePath = option("--reference"), let referenceText = option("--reference-text") else { throw Failure.arguments }
        let steps = Int(option("--steps") ?? "4") ?? 4
        guard (1...32).contains(steps) else { throw Failure.arguments }
        let directory = URL(fileURLWithPath: arguments[1])
        let output = URL(fileURLWithPath: arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let text = arguments[3]
        var strings: [UnsafeMutablePointer<CChar>] = []
        func c(_ value: String) -> UnsafePointer<CChar> {
            let pointer = strdup(value)!; strings.append(pointer); return UnsafePointer(pointer)
        }
        defer { strings.forEach { free($0) } }
        func path(_ name: String) throws -> UnsafePointer<CChar> {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.missing(file.path) }
            return c(file.path)
        }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.zipvoice.encoder = try path("encoder.int8.onnx")
        config.model.zipvoice.decoder = try path("decoder.int8.onnx")
        config.model.zipvoice.tokens = try path("tokens.txt")
        config.model.zipvoice.lexicon = try path("lexicon.txt")
        config.model.zipvoice.data_dir = try path("espeak-ng-data")
        config.model.zipvoice.vocoder = try path("vocos_24khz.onnx")
        config.model.num_threads = 2; config.model.provider = c("cpu")
        config.max_num_sentences = 3; config.silence_scale = 1
        let loadStart = DispatchTime.now().uptimeNanoseconds
        guard let handle = SherpaOnnxCreateOfflineTts(&config) else { throw Failure.initialization }
        defer { SherpaOnnxDestroyOfflineTts(handle) }
        let loadSeconds = Double(DispatchTime.now().uptimeNanoseconds - loadStart) / 1e9
        guard let wave = referencePath.withCString({ SherpaOnnxReadWave($0) }) else { throw Failure.missing(referencePath) }
        defer { SherpaOnnxFreeWave(wave) }
        var generation = SherpaOnnxGenerationConfig()
        generation.speed = 1; generation.silence_scale = 1; generation.num_steps = Int32(steps)
        generation.reference_audio = wave.pointee.samples
        generation.reference_audio_len = wave.pointee.num_samples
        generation.reference_sample_rate = wave.pointee.sample_rate
        generation.reference_text = c(referenceText)
        generation.extra = c("{\"min_char_in_sentence\":10}")
        var rows: [[String: Any]] = []
        let callback: SherpaOnnxGeneratedAudioProgressCallbackWithArg = { samples, count, _, context in
            guard let context else { return 0 }
            Unmanaged<Progress>.fromOpaque(context).takeUnretainedValue().receive(samples, count: Int(count))
            return 1
        }
        for iteration in 0...4 {
            let progress = Progress()
            let cpuStart = cpuSeconds()
            guard let audio = text.withCString({ SherpaOnnxOfflineTtsGenerateWithConfig(handle, $0, &generation, callback, Unmanaged.passUnretained(progress).toOpaque()) }) else { throw Failure.generation }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - progress.started) / 1e9
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
            guard audio.pointee.n > 0, audio.pointee.sample_rate > 0, let samples = audio.pointee.samples else { throw Failure.generation }
            let values = UnsafeBufferPointer(start: samples, count: Int(audio.pointee.n))
            guard values.allSatisfy(\.isFinite), values.contains(where: { abs($0) > 0.0001 }) else { throw Failure.generation }
            let duration = Double(audio.pointee.n) / Double(audio.pointee.sample_rate)
            // A whole-waveform result without an early callback is ready at return.
            let first = progress.firstAudio ?? elapsed
            let row: [String: Any] = ["iteration": iteration, "synthesis_seconds": elapsed, "first_audio_seconds": first,
                                      "audio_seconds": duration, "rtf": elapsed / duration, "cpu_seconds": cpuSeconds() - cpuStart,
                                      "peak_rss_mib": peakRSS(), "callback_chunks": progress.chunks.map { ["time": $0.time, "samples": Double($0.samples)] }]
            rows.append(row)
            let report: [String: Any] = ["backend": "ZipVoice-Distill INT8 / Swift / ONNX CPU", "steps": steps, "threads": 2,
                                         "load_seconds": loadSeconds, "text": text, "reference_text": referenceText,
                                         "reference_seconds": Double(wave.pointee.num_samples) / Double(wave.pointee.sample_rate), "rows": rows]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
            if iteration == 0 {
                let destination = output.appendingPathComponent("sample.wav").path
                let saved = destination.withCString { SherpaOnnxWriteWave(samples, audio.pointee.n, audio.pointee.sample_rate, $0) }
                guard saved == 1 else { throw Failure.generation }
            }
            print("ZIP steps=\(steps) iteration=\(iteration) first=\(first) synthesis=\(elapsed) audio=\(duration) RTF=\(elapsed/duration) peakRSS=\(peakRSS())MiB")
            fflush(stdout)
            if elapsed > 30 { break }
        }
    }
    private enum Failure: Error { case arguments, missing(String), initialization, generation }
    private static func cpuSeconds() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    private static func peakRSS() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_maxrss) / 1_048_576
    }
}
