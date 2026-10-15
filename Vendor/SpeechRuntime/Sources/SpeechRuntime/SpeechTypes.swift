import Foundation

public struct SpeechAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public init(samples: [Float], sampleRate: Int) { self.samples = samples; self.sampleRate = sampleRate }
    public var duration: Double { Double(samples.count) / Double(sampleRate) }
}

/// 原生合成回调与 actor 并发读取取消状态，锁保护共享标记。
public final class SynthesisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public enum SpeechFailure: LocalizedError {
    case missing(String), initialization, generation, unsupportedText
    public var errorDescription: String? {
        switch self {
        case .missing(let name): return "离线中文音色文件缺失：\(name)。请重新安装完整应用。"
        case .initialization: return "离线中文音色无法加载。"
        case .unsupportedText: return "当前开源音色的词典不能完整识别这段正文，已尝试改用系统普通话。"
        case .generation: return "这段文字未能生成有效的语音。"
        }
    }
}

