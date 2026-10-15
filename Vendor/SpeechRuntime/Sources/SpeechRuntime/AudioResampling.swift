import Foundation
import AVFoundation

extension SpeechAudio {
    /// 所有后端统一到24 kHz，播放、暂停和持久化都使用同一套样本坐标。
    func resampled(to targetRate: Int = 24000) throws -> SpeechAudio {
        guard sampleRate != targetRate else { return self }
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: Double(targetRate), channels: 1)!
        let capacity = Int(ceil(Double(samples.count) * Double(targetRate) / Double(sampleRate))) + 64
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)), let input = source.floatChannelData?[0],
              let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(capacity)), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else { throw SpeechFailure.generation }
        source.frameLength = source.frameCapacity; samples.withUnsafeBufferPointer { input.update(from: $0.baseAddress!, count: $0.count) }
        var used = false, error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if used { status.pointee = .endOfStream; return nil }; used = true; status.pointee = .haveData; return source
        }
        if let error { throw error }
        guard target.frameLength > 0, let channel = target.floatChannelData?[0] else { throw SpeechFailure.generation }
        return SpeechAudio(samples: Array(UnsafeBufferPointer(start: channel, count: Int(target.frameLength))), sampleRate: targetRate)
    }
}
