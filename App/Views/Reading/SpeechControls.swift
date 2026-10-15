import SwiftUI
import InkCore

struct SpeechBar: View {
    @ObservedObject var speech: SpeechEngine
    @ObservedObject var model: AppModel
    @Binding var showSettings: Bool
    var compact = false
    var includesSettings = true
    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            SpeechSpeedControl(speech: speech, showSettings: $showSettings, includesSettings: includesSettings, labelWidth: 36)
            Button { speech.previous() } label: { Image(systemName: "backward.end.fill").frame(width: 24) }.accessibilityLabel("上一段")
            Button {
                if speech.playing { speech.paused ? speech.resume() : speech.pause() }
                else { speech.play(from: model.parsed.segmentIndex(at: model.book?.cursor ?? 0)) }
            } label: {
                Image(systemName: speech.playing && !speech.paused ? "pause.fill" : "play.fill")
                    .frame(width: 36)
                    .opacity(speech.preparing && !speech.paused ? 0 : 1)
                    .overlay {
                        if speech.preparing && !speech.paused {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                        }
                    }
            }
                .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
                .accessibilityLabel(speech.playing && !speech.paused ? "暂停朗读" : "开始朗读").accessibilityIdentifier("playPause")
                .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.arguments.contains("--playback-diagnostics") ? speech.playbackEvidence : speech.preparing ? speech.preparationMessage : speech.paused ? "已暂停" : speech.playing ? "正在朗读" : "")
            Button { speech.next() } label: { Image(systemName: "forward.end.fill").frame(width: 24) }.accessibilityLabel("下一段")
            Button { speech.stop() } label: { Image(systemName: "stop.fill").frame(width: 36) }.accessibilityLabel("停止朗读").accessibilityIdentifier("stopSpeech")
        }.buttonStyle(KeycapButtonStyle(compact: true)).fixedSize(horizontal: true, vertical: false)
            .overlay(alignment: .top) {
                if !speech.preparationMessage.isEmpty {
                    Text(speech.preparationMessage).font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule()).fixedSize()
                        .offset(y: -30).allowsHitTesting(false)
                }
            }
    }
}

struct SpeechSpeedControl: View {
    @ObservedObject var speech: SpeechEngine
    @Binding var showSettings: Bool
    var includesSettings = true
    var labelWidth: CGFloat? = nil
    @State private var presented = false
    @Environment(\.paperTheme) private var theme
    var body: some View {
        Button { presented = true } label: {
            Text(String(format: "%g×", speech.rate)).monospacedDigit().frame(width: labelWidth).frame(minWidth: 28)
        }
        .accessibilityLabel("朗读速度").accessibilityIdentifier("speechSpeed")
        .accessibilityValue(String(format: "%.2f", speech.rate))
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("朗读速度").font(.headline)
                    Spacer()
                    Text(String(format: "%.2f×", speech.rate)).monospacedDigit().accessibilityIdentifier("speechSpeedValue")
                }
                Slider(value: $speech.rate, in: 0.5...2, step: 0.05) { Text("朗读速度") }
                    .accessibilityIdentifier("speechSpeedSlider")
                HStack { Text("0.5×"); Spacer(); Text("2×") }.font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button { speech.rate = speed } label: {
                            Text(String(format: "%g×", speed)).frame(maxWidth: .infinity)
                        }.buttonStyle(KeycapButtonStyle(selected: speech.rate == speed, compact: true))
                            .accessibilityIdentifier("speechSpeedPreset-" + String(format: "%.2f", speed))
                    }
                }
                Text("立即调节速度，保留原来的音调和阅读位置。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if includesSettings {
                        Button("朗读设置") { presented = false; showSettings = true }
                    }
                    Spacer()
                    Button("完成") { presented = false }.accessibilityIdentifier("closeSpeechSpeed")
                }.buttonStyle(KeycapButtonStyle(compact: true))
            }.padding(18).frame(width: 280)
                .background(theme.background).foregroundStyle(theme.foreground)
                .presentationBackground(theme.background)
                .presentationCompactAdaptation(.popover)
        }
    }
}

