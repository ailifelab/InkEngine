import SwiftUI
import InkCore

struct SpeechBar: View {
    @Environment(\.locale) private var appLocale
    @ObservedObject var speech: SpeechEngine
    @ObservedObject var model: AppModel
    @Binding var showSettings: Bool
    var compact = false
    var includesSettings = true
    @Environment(\.paperTheme) private var theme
    private var playingHere: Bool { model.ownsSpeech && speech.playing }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            playbackButtons(tight: false)
            if compact { playbackButtons(tight: true) }
        }
            .overlay(alignment: .top) {
                if model.ownsSpeech && !speech.preparationMessage.isEmpty {
                    Text(speech.preparationMessage).font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule()).fixedSize(horizontal: false, vertical: true)
                        .offset(y: -30).allowsHitTesting(false)
                }
            }
    }
    /// 听书底栏使用独立的大触控区；窄窗口缩小间距，仍保留全部操作和单行倍速。
    private func playbackButtons(tight: Bool) -> some View {
        let side: CGFloat = tight ? 44 : 56
        let main: CGFloat = tight ? 64 : 80
        return HStack(spacing: tight ? 6 : 12) {
            SpeechSpeedControl(speech: speech, showSettings: $showSettings, includesSettings: includesSettings, labelWidth: tight ? 56 : 64, targetHeight: side)
            Button { Task { await model.stepSpeech(forward: false) } } label: {
                Image(systemName: "backward.end.fill").frame(width: side, height: side)
            }.accessibilityLabel(L10n.tr("上一段")).accessibilityIdentifier("speechPrevious")
            Button { Task { await model.toggleSpeech() } } label: {
                Image(systemName: playingHere && !speech.paused ? "pause.fill" : "play.fill")
                    .font(.system(size: tight ? 28 : 34, weight: .bold))
                    .frame(width: main, height: main)
                    .opacity(model.ownsSpeech && speech.preparing && !speech.paused ? 0 : 1)
                    .background(theme.highlight, in: Circle())
                    .foregroundStyle(theme.background)
                    .overlay {
                        if model.ownsSpeech && speech.preparing && !speech.paused {
                            ProgressView().tint(theme.background).accessibilityHidden(true)
                        }
                    }
            }.buttonStyle(.plain)
                .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
                .accessibilityLabel(playingHere && !speech.paused ? L10n.tr("暂停朗读") : L10n.tr("开始朗读")).accessibilityIdentifier("playPause")
                .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.arguments.contains("--playback-diagnostics") ? speech.playbackEvidence : model.ownsSpeech && speech.preparing ? speech.preparationMessage : model.ownsSpeech && speech.paused ? L10n.tr("已暂停") : playingHere ? L10n.tr("正在朗读") : "")
            Button { Task { await model.stepSpeech(forward: true) } } label: {
                Image(systemName: "forward.end.fill").frame(width: side, height: side)
            }.accessibilityLabel(L10n.tr("下一段")).accessibilityIdentifier("speechNext")
            Button { model.stopOwnedSpeech() } label: {
                Image(systemName: "stop.fill").frame(width: side, height: side)
            }.accessibilityLabel(L10n.tr("停止朗读")).accessibilityIdentifier("stopSpeech")
        }.font(.system(size: tight ? 20 : 24, weight: .semibold))
            .buttonStyle(SpeechTransportButtonStyle()).fixedSize(horizontal: true, vertical: false)
    }

}

struct SpeechSpeedControl: View {
    @Environment(\.locale) private var appLocale
    @ObservedObject var speech: SpeechEngine
    @Binding var showSettings: Bool
    var includesSettings = true
    var labelWidth: CGFloat? = nil
    var targetHeight: CGFloat = 44
    @State private var presented = false
    @Environment(\.paperTheme) private var theme
    var body: some View {
        Button { presented = true } label: {
            Text(String(format: "%g×", speech.rate)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: max(56, labelWidth ?? 56), minHeight: targetHeight)
                .padding(.horizontal, 6)
        }
        .accessibilityLabel(L10n.tr("朗读速度")).accessibilityIdentifier("speechSpeed")
        .accessibilityValue(String(format: "%.2f", speech.rate))
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L10n.tr("朗读速度")).font(.headline)
                    Spacer()
                    Text(String(format: "%.2f×", speech.rate)).monospacedDigit().accessibilityIdentifier("speechSpeedValue")
                }
                Slider(value: $speech.rate, in: 0.5...2, step: 0.05) { Text(L10n.tr("朗读速度")) }
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
                Text(L10n.tr("立即调节速度，保留原来的音调和阅读位置。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if includesSettings {
                        Button(L10n.tr("朗读设置")) { presented = false; showSettings = true }
                    }
                    Spacer()
                    Button(L10n.tr("完成")) { presented = false }.accessibilityIdentifier("closeSpeechSpeed")
                }.buttonStyle(WorkspaceControlStyle())
            }.padding(18).frame(width: 280)
                .background(theme.background).foregroundStyle(theme.foreground)
                .presentationBackground(theme.background)
                .presentationCompactAdaptation(.popover)
        }
    }
}


/// 播放操作用实色文字、底色和边框区分触控区域，不依赖细小的工具栏图标。
private struct SpeechTransportButtonStyle: ButtonStyle {
    @Environment(\.paperTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(theme.foreground)
            .background(theme.foreground.opacity(configuration.isPressed ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.foreground.opacity(0.18)) }
            .contentShape(Rectangle())
    }
}

/// 半开听书的下半屏提供大尺寸播放、跳转、倍速与停止操作。
struct TabletopSpeechControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechEngine
    @State private var showSettings = false
    var body: some View {
        GeometryReader { geometry in
            let diameter = min(144, max(72, geometry.size.height * 0.4))
            ZStack(alignment: .bottomTrailing) {
                HStack(spacing: max(20, geometry.size.width * 0.08)) {
                    TabletopSeekButton(model: model, forward: false)
                    Button { Task { await model.toggleSpeech() } } label: {
                        Image(systemName: speech.paused ? "play.fill" : "pause.fill")
                            .font(.system(size: diameter * 0.32, weight: .semibold))
                            .frame(width: diameter, height: diameter)
                            .background(model.readingTheme.highlight.opacity(0.15), in: Circle())
                            .overlay { if speech.preparing && !speech.paused { ProgressView().scaleEffect(1.4) } }
                    }.buttonStyle(.plain)
                        .disabled(speech.scrubbing)
                        .accessibilityLabel(speech.paused ? L10n.tr("开始朗读") : L10n.tr("暂停朗读"))
                        .accessibilityIdentifier("playPause")
                        .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing") ? speech.playbackEvidence : "")
                    TabletopSeekButton(model: model, forward: true)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    SpeechSpeedControl(speech: speech, showSettings: $showSettings, includesSettings: false, labelWidth: 76, targetHeight: 64)
                        .font(.system(size: 20, weight: .semibold)).frame(minHeight: 64)
                        .buttonStyle(SpeechTransportButtonStyle())
                    Spacer()
                    Button { model.stopOwnedSpeech() } label: {
                        Image(systemName: "stop.fill").font(.title2.bold()).frame(width: 76, height: 64)
                    }.buttonStyle(SpeechTransportButtonStyle())
                        .accessibilityLabel(L10n.tr("停止朗读")).accessibilityIdentifier("stopSpeech")
                }.padding(18)
            }.foregroundStyle(model.readingTheme.highlight)
                .background(model.readingTheme.sidebar)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("tabletopSpeechControls")
    }
}

private struct TabletopSeekButton: View {
    @ObservedObject var model: AppModel
    let forward: Bool
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var pressing = false
    @State private var repeatTask: Task<Void, Never>?
    @State private var repeated = false
    var body: some View {
        Image(systemName: forward ? "forward.fill" : "backward.fill")
            .font(.system(size: 34, weight: .bold)).frame(width: 80, height: 80)
            .background(model.readingTheme.foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(model.readingTheme.foreground.opacity(0.2)) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressing) { _, value, _ in value = true }
                .onChanged { _ in
                    guard repeatTask == nil else { return }
                    repeated = false
                    repeatTask = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                        guard model.ownsSpeech else { return }
                        repeated = true
                        model.speech.beginScrubbing()
                        var ticks = 0
                        while !Task.isCancelled {
                            seek(paragraphs: min(8, 1 + ticks / 4))
                            ticks += 1
                            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
                        }
                    }
                }
                .onEnded { _ in
                    repeatTask?.cancel(); repeatTask = nil
                    if repeated { model.speech.endScrubbing() }
                    else { Task { await model.stepSpeech(forward: forward) } }
                })
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel(forward ? L10n.tr("下一段") : L10n.tr("上一段"))
            .accessibilityIdentifier(forward ? "tabletopSeekForward" : "tabletopSeekBackward")
            .accessibilityAction { Task { await model.stepSpeech(forward: forward) } }
            .onChange(of: pressing) { _, value in
                if !value {
                    // Normal releases finish in onEnded; this also handles system cancellation.
                    DispatchQueue.main.async {
                        if !pressing, repeatTask != nil { finish(resume: false) }
                    }
                }
            }
            .onChange(of: scenePhase) { _, value in if value != .active { finish(resume: false) } }
            .onDisappear { finish(resume: false) }
    }
    private func finish(resume: Bool) {
        repeatTask?.cancel(); repeatTask = nil
        if repeated { model.speech.endScrubbing(resume: resume) }
    }
    private func seek(paragraphs: Int) {
        guard model.ownsSpeech, model.speech.scrubbing else { return }
        var index = model.speech.segmentIndex
        for _ in 0..<paragraphs {
            guard let next = model.parsed.adjacentParagraph(from: index, forward: forward) else { break }
            index = next
        }
        guard model.parsed.segments.indices.contains(index), index != model.speech.segmentIndex else { return }
        model.speech.updateScrubbing(toSourceOffset: model.parsed.segments[index].sourceRange.location)
    }
}
