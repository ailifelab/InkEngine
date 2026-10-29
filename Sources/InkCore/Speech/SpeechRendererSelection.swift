import Foundation

/// Resolve saved renderer choices without modifying document data or reading positions.
public enum SpeechRendererSelection {
    public static func restored(_ saved: String?, zipVoiceReady: Bool, maleReady: Bool) -> String {
        switch saved {
        case "qwen", "zipvoice": return zipVoiceReady ? "zipvoice" : "system"
        case "piper", "zipvoice-male": return maleReady ? "zipvoice-male" : zipVoiceReady ? "zipvoice" : "system"
        default: return "system"
        }
    }
}
