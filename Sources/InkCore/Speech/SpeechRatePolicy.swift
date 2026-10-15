import Foundation

/// Matcha直接缩短声学时长可能吞掉短音节。加速时保留正常语速的完整波形，
/// 播放器按“所选倍率 / 本块生成倍率”调速；暂停和续读仍使用原始PCM样本。
public enum SpeechRatePolicy {
    public static func nativeRate(renderer: String, selected: Float) -> Float {
        guard selected.isFinite else { return 1 }
        switch renderer {
        case "matcha": return min(1, max(0.65, selected))
        case "piper": return min(1.5, max(0.65, selected))
        default: return 1
        }
    }
}
