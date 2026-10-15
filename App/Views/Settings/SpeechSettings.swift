import SwiftUI
import InkCore
import AVFoundation

struct SpeechSettings: View {
    @ObservedObject var speech: SpeechEngine
    @ObservedObject var model: AppModel
    @State private var showPronunciation = false
    @State private var showPrivacy = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("隐私与使用说明", systemImage: "hand.raised") { showPrivacy = true }.accessibilityIdentifier("speechPrivacyPolicy")
                }
                Section("普通话音色") {
                    if !speech.offlineReady { Text("离线音色文件缺失").foregroundStyle(.secondary) }
                    Group {
                        Picker("语音模型", selection: $speech.selectedModel) {
                            Text("系统语音").tag("system")
                            Text("Matcha").tag("matcha")
                            if speech.zipVoiceMaleReady { Text("ZipVoice").tag("zipvoice") }
                            #if os(macOS) && arch(arm64)
                            if speech.qwenReady { Text("Qwen · 测试模型").tag("qwen") }
                            #endif
                        }.accessibilityIdentifier("speechRendererPicker")
                        if speech.selectedModel == "zipvoice" {
                            Picker("音色", selection: $speech.selectedZipVoice) {
                                Text("Serena · 温柔女声").tag("serena")
                                if speech.zipVoiceMaleReady { Text("Dylan · 京腔男声").tag("dylan") }
                            }.accessibilityIdentifier("zipVoicePicker")
                        } else if speech.rendererMode == "matcha" {
                            Picker("音色", selection: .constant("standard")) { Text("中文女声").tag("standard") }.disabled(true)
                        } else if speech.rendererMode == "qwen" {
                            Picker("音色", selection: .constant("serena")) { Text("Serena · 中文女声").tag("serena") }.disabled(true)
                        }
                        if speech.rendererMode == "system" {
                            Picker("音色", selection: $speech.systemVoiceID) {
                                Section("女声") { ForEach(speech.systemVoices.filter { $0.gender == .female }, id: \.identifier) { voice in Text(voice.name + (voice.language == "zh-TW" ? " · 台湾国语" : " · 普通话")).tag(voice.identifier) } }
                                Section("男声") { ForEach(speech.systemVoices.filter { $0.gender == .male }, id: \.identifier) { voice in Text(voice.name + (voice.language == "zh-TW" ? " · 台湾国语" : " · 普通话")).tag(voice.identifier) } }
                                Section("其他系统音色") { ForEach(speech.systemVoices.filter { $0.gender == .unspecified }, id: \.identifier) { voice in Text(voice.name).tag(voice.identifier) } }
                            }.accessibilityIdentifier("systemMandarinVoicePicker")
                            Text("显示此设备已提供的普通话与台湾国语音色，每种性别最多五个。更多男声、女声可在系统设置 → 辅助功能 → 朗读与语音 → 声音 → 中文中下载；返回后会自动刷新。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(speech.voiceDescription).font(.caption).accessibilityIdentifier("selectedVoice")
                    Button("试听所选音色") { speech.audition() }.disabled(!speech.offlineReady).accessibilityIdentifier("audition")
                    Text("Matcha 提供本地中文女声，ZipVoice 提供男声和女声；Apple 芯片 Mac 还提供 Qwen Serena。所有音色均本地离线，倍率立即生效；合成失败会用系统音色从未读处继续。原生音色首次使用需要准备，之后会复用缓存。Qwen 测试模型目前速度低于实时，适合逐段试听，连续阅读会等待下一段。")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(model.readingTheme.sidebar)
                Section("听读") {
                    Slider(value: $speech.rate, in: 0.5...2, step: 0.05) { Text("语速") }
                    Text("语速 \(speech.rate, specifier: "%.2f") 倍 · 立即生效").font(.caption)
                    Text("加速时保留完整发音，由播放器调速。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("跳过 Markdown 代码块", isOn: $speech.skipCode)
                    Text("来电或耳机拔出后暂停；点击继续恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(model.readingTheme.sidebar)
                Section("字号") { Slider(value: $model.fontSize, in: 14...34, step: 1) { Text("字号") }.accessibilityIdentifier("fontSizeSlider"); Text("\(Int(model.fontSize)) pt") }.listRowBackground(model.readingTheme.sidebar)
                Section("朗读纠音") {
                    Button { showPronunciation = true } label: {
                        Text("常用多音字与自定义词组").frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("pronunciationSettings")
                    Text("常用词组纠音默认开启；少见人名、地名可以单独添加。").font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(model.readingTheme.sidebar)
                if !speech.recoveryMessage.isEmpty { Text(speech.recoveryMessage).font(.caption).foregroundStyle(.secondary) }
                if let error = speech.error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            .background(model.readingTheme.background.ignoresSafeArea())
            .listRowBackground(model.readingTheme.sidebar)
            .accessibilityIdentifier("speechSettingsForm")
            .navigationTitle("阅读与朗读")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(model.readingTheme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { if speech.auditioning { speech.stop() }; dismiss() } label: { Text("完成").frame(minWidth: 40).fixedSize(horizontal: true, vertical: false) }
                        .buttonStyle(KeycapButtonStyle(compact: true))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("closeSpeechSettings")
                }
                #if os(iOS)
                .sharedBackgroundVisibility(.hidden)
                #endif
            }
        }.frame(minWidth: 300, idealWidth: 480, minHeight: 420, idealHeight: 560)
        .onAppear { speech.refreshVoices() }
        .sheet(isPresented: $showPrivacy) { PrivacyView() }
        .sheet(isPresented: $showPronunciation) { PronunciationSettings(speech: speech, model: model).buttonStyle(KeycapButtonStyle()) }
    }
}

