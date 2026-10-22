import SwiftUI
import InkCore
import AVFoundation

struct SpeechSettings: View {
    @Environment(\.locale) private var appLocale
    @ObservedObject var speech: SpeechEngine
    @ObservedObject var model: AppModel
    @State private var showPronunciation = false
    @State private var showPrivacy = false
    @State private var choosingModel = false
    @State private var choosingZipVoice = false
    @State private var choosingSystemVoice = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            Form {
                Section(L10n.tr("语言")) {
                    LanguagePicker()
                    Text(L10n.tr("立即生效，下次打开仍会保留。只切换界面语言，文稿内容和朗读音色保持不变。"))
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(model.readingTheme.sidebar)
                Section {
                    Button(L10n.tr("隐私与使用说明"), systemImage: "hand.raised") { showPrivacy = true }.accessibilityIdentifier("speechPrivacyPolicy")
                }
                Section(L10n.tr("普通话音色")) {
                    if !speech.offlineReady { Text(L10n.tr("离线音色文件缺失")).foregroundStyle(.secondary) }
                    Group {
                        selectionHeader(L10n.tr("语音模型"), value: selectedModelName, expanded: $choosingModel, identifier: "speechRendererPicker")
                        if choosingModel {
                            choice(L10n.tr("系统语音"), value: "system", selection: $speech.selectedModel, identifier: "speechModel-system")
                            if speech.zipVoiceMaleReady { choice("ZipVoice", value: "zipvoice", selection: $speech.selectedModel, identifier: "speechModel-zipvoice") }
                            #if os(macOS) && arch(arm64)
                            if speech.qwenReady { choice(L10n.tr("Qwen · 测试模型"), value: "qwen", selection: $speech.selectedModel, identifier: "speechModel-qwen") }
                            #endif
                        }
                        if speech.selectedModel == "zipvoice" {
                            selectionHeader(L10n.tr("音色"), value: speech.selectedZipVoice == "dylan" ? L10n.tr("Dylan · 京腔男声") : L10n.tr("Serena · 温柔女声"), expanded: $choosingZipVoice, identifier: "zipVoicePicker")
                            if choosingZipVoice {
                                choice(L10n.tr("Serena · 温柔女声"), value: "serena", selection: $speech.selectedZipVoice, identifier: "zipVoice-serena")
                                if speech.zipVoiceMaleReady { choice(L10n.tr("Dylan · 京腔男声"), value: "dylan", selection: $speech.selectedZipVoice, identifier: "zipVoice-dylan") }
                            }
                        } else if speech.rendererMode == "qwen" {
                            selectionLabel(L10n.tr("音色"), value: L10n.tr("Serena · 中文女声"))
                        }
                        if speech.rendererMode == "system" {
                            selectionHeader(L10n.tr("音色"), value: speech.systemVoices.first(where: { $0.identifier == speech.systemVoiceID }).map(voiceName) ?? speech.voiceDescription, expanded: $choosingSystemVoice, identifier: "systemMandarinVoicePicker")
                            if choosingSystemVoice {
                                Section(L10n.tr("女声")) { systemVoiceChoices(.female) }
                                Section(L10n.tr("男声")) { systemVoiceChoices(.male) }
                                Section(L10n.tr("其他系统音色")) { systemVoiceChoices(.unspecified) }
                            }
                            Text(L10n.tr("显示此设备已提供的普通话与台湾国语音色，每种性别最多五个。更多男声、女声可在系统设置 → 辅助功能 → 朗读与语音 → 声音 → 中文中下载；返回后会自动刷新。")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(speech.voiceDescription).font(.caption).accessibilityIdentifier("selectedVoice")
                    Button(L10n.tr("试听所选音色")) { speech.audition() }.disabled(!speech.offlineReady).accessibilityIdentifier("audition")
                    Text(L10n.tr("ZipVoice 提供本地男声和女声；Apple 芯片 Mac 还提供 Qwen Serena。所有音色均本地离线，倍率立即生效；合成失败会用系统音色从未读处继续。原生音色首次使用需要准备，之后会复用缓存。Qwen 测试模型目前速度低于实时，适合逐段试听，连续阅读会等待下一段。"))
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(model.readingTheme.sidebar)
                Section(L10n.tr("听读")) {
                    Slider(value: $speech.rate, in: 0.5...2, step: 0.05) { Text(L10n.tr("语速")) }
                    Text(L10n.tr("语速 \(speech.rate, specifier: "%.2f") 倍 · 立即生效")).font(.caption)
                    Text(L10n.tr("加速时保留完整发音，由播放器调速。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L10n.tr("跳过 Markdown 代码块"), isOn: $speech.skipCode)
                    Text(L10n.tr("来电或耳机拔出后暂停；点击继续恢复。"))
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(model.readingTheme.sidebar)
                Section(L10n.tr("字号")) { Slider(value: $model.fontSize, in: 14...34, step: 1) { Text(L10n.tr("字号")) }.accessibilityIdentifier("fontSizeSlider"); Text("\(Int(model.fontSize)) pt") }.listRowBackground(model.readingTheme.sidebar)
                Section(L10n.tr("朗读纠音")) {
                    Button { showPronunciation = true } label: {
                        Text(L10n.tr("常用多音字与自定义词组")).frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("pronunciationSettings")
                    Text(L10n.tr("常用词组纠音默认开启；少见人名、地名可以单独添加。")).font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(model.readingTheme.sidebar)
                if !speech.recoveryMessage.isEmpty { Text(speech.recoveryMessage).font(.caption).foregroundStyle(.secondary) }
                if let error = speech.error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            .background(model.readingTheme.background.ignoresSafeArea())
            .listRowBackground(model.readingTheme.sidebar)
            .accessibilityIdentifier("speechSettingsForm")
            // 展开模型或音色后，把标题移到安全可视区顶部，让选项紧随其后。
            // 标题始终存在，避免滚向刚插入、尚未完成布局的选项行而失效。
            .onChange(of: expandedSelector) { _, identifier in
                guard let identifier else { return }
                withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo(identifier, anchor: .top) }
            }
            .navigationTitle(L10n.tr("阅读与朗读"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                InkPanelDoneToolbar(identifier: "closeSpeechSettings") {
                    if speech.auditioning { speech.stop() }
                    dismiss()
                }
            }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 420, idealHeight: 560)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onAppear { speech.refreshVoices() }
        .sheet(isPresented: $showPrivacy) { PrivacyView().appLocalized() }
        .sheet(isPresented: $showPronunciation) { PronunciationSettings(speech: speech, model: model).buttonStyle(KeycapButtonStyle()).appLocalized() }
    }
    /// 同时只展开一个选择列表，避免模型列表把音色入口和选项挤出表单可视区。
    private var expandedSelector: String? {
        if choosingModel { return "speechRendererPicker" }
        if choosingZipVoice { return "zipVoicePicker" }
        if choosingSystemVoice { return "systemMandarinVoicePicker" }
        return nil
    }
    private var selectedModelName: String {
        switch speech.selectedModel {
        case "zipvoice": "ZipVoice"
        case "qwen": L10n.tr("Qwen · 测试模型")
        default: L10n.tr("系统语音")
        }
    }
    private func selectionLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
    private func selectionHeader(_ title: String, value: String, expanded: Binding<Bool>, identifier: String) -> some View {
        Button {
            let opening = !expanded.wrappedValue
            choosingModel = false; choosingZipVoice = false; choosingSystemVoice = false
            expanded.wrappedValue = opening
        } label: {
            HStack(spacing: 8) {
                selectionLabel(title, value: value)
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier).id(identifier)
    }
    private func choice(_ title: String, value: String, selection: Binding<String>, identifier: String) -> some View {
        Button {
            selection.wrappedValue = value
            // 选定模型即收起模型列表，下一步音色入口保持可见；音色列表保留勾选供对照。
            if identifier.hasPrefix("speechModel-") { choosingModel = false }
        } label: {
            HStack {
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "checkmark").opacity(selection.wrappedValue == value ? 1 : 0)
            }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            .accessibilityAddTraits(selection.wrappedValue == value ? [.isSelected] : [])
    }
    private func voiceName(_ voice: AVSpeechSynthesisVoice) -> String {
        voice.name + (voice.gender == .unspecified ? "" : (voice.language == "zh-TW" ? L10n.tr(" · 台湾国语") : L10n.tr(" · 普通话")))
    }
    private func systemVoiceChoices(_ gender: AVSpeechSynthesisVoiceGender) -> some View {
        ForEach(speech.systemVoices.filter { $0.gender == gender }, id: \.identifier) { voice in
            choice(voiceName(voice), value: voice.identifier, selection: $speech.systemVoiceID, identifier: "systemVoice-" + voice.identifier)
        }
    }

}

