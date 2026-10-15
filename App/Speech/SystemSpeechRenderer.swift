import AVFoundation
import SpeechRuntime

/// 系统普通话也先生成 PCM，所有后端共用播放器与样本账本，
/// 暂停、跳读、调速及缓存续读始终使用同一套位置坐标。
@MainActor final class SystemSpeechRenderer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending: CheckedContinuation<SpeechAudio, Error>?
    private var generation = UUID()
    override init() { super.init(); synthesizer.delegate = self }
    func stop() {
        generation = UUID(); synthesizer.stopSpeaking(at: .immediate)
        pending?.resume(throwing: CancellationError()); pending = nil
    }
    func generate(text: String, voiceID: String) async throws -> SpeechAudio {
        stop()
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID), ["zh-CN", "zh-TW"].contains(voice.language) else { throw SpeechFailure.initialization }
        let token = generation
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.preUtteranceDelay = 0; utterance.postUtteranceDelay = 0
        let collector = SpeechPCMCollector()
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            synthesizer.write(utterance) { [weak self] audio in
                guard let buffer = audio as? AVAudioPCMBuffer else { return }
                if buffer.frameLength > 0 { collector.append(buffer); return }
                Task { @MainActor in
                    guard let self, self.generation == token, self.pending != nil else { return }
                    do {
                        let result = try await Task.detached(priority: .utility) { try collector.audio() }.value
                        guard self.generation == token else { return }
                        self.pending?.resume(returning: result); self.pending = nil
                    } catch {
                        guard self.generation == token else { return }
                        self.pending?.resume(throwing: error); self.pending = nil
                    }
                }
            }
        }
    }
}

private final class SpeechPCMCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        sampleRate = buffer.format.sampleRate
        let count = Int(buffer.frameLength)
        if let channel = buffer.floatChannelData?[0] { samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count)) }
        else if let channel = buffer.int16ChannelData?[0] { samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count).map { Float($0) / 32768 }) }
    }
    func audio() throws -> SpeechAudio {
        lock.lock(); let values = samples, rate = sampleRate; lock.unlock()
        guard !values.isEmpty, rate > 0,
              let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(values.count)),
              let channel = input.floatChannelData?[0],
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(values.count) * 24000 / rate) + 64)),
              let converter = AVAudioConverter(from: source, to: target) else { throw SpeechFailure.generation }
        input.frameLength = input.frameCapacity
        values.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        var supplied = false, error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard result != .error, output.frameLength > 0, let samples = output.floatChannelData?[0] else { throw error ?? SpeechFailure.generation as NSError }
        return SpeechAudio(samples: Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))), sampleRate: 24000)
    }
}
