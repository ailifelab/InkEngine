import SwiftUI
import InkCore

struct PronunciationSettings: View {
    @Environment(\.locale) private var appLocale
    @ObservedObject var speech: SpeechEngine
    @ObservedObject var model: AppModel
    @State private var phrase = ""
    @State private var spoken = ""
    private enum Field { case phrase, spoken }
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss
    private var candidate: PronunciationRule { .init(phrase: phrase.trimmingCharacters(in: .whitespaces), spoken: spoken.trimmingCharacters(in: .whitespaces)) }
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("常用词组纠音已启用")) {
                    Text(L10n.tr("内置 \(PronunciationDictionary.builtins.count) 个词组，覆盖行、长、重、乐、调、藏、传、宿等常见多音字。按完整词组纠音，保留行走、同行等不同用法。"))
                    Button(L10n.tr("试听常见多音字")) { speech.audition("编辑器折行显示行号，行长去银行。重庆的长者重新调整音乐，收藏宝藏，少年逐渐成长。") }
                }.listRowBackground(model.readingTheme.sidebar)
                Section(L10n.tr("添加小说专名或词组")) {
                    TextField(L10n.tr("原词组，例如 折行"), text: $phrase).focused($focusedField, equals: .phrase)
                        .submitLabel(.next).onSubmit { focusedField = .spoken }.accessibilityIdentifier("pronunciationPhrase")
                    TextField(L10n.tr("朗读写法，例如 折航"), text: $spoken).focused($focusedField, equals: .spoken)
                        .submitLabel(.done).onSubmit { focusedField = nil }.accessibilityIdentifier("pronunciationSpoken")
                    Text(L10n.tr("用同音字指定读法，只影响朗读，不会修改正文。更新后旧音频不会用于新读法，下次从当前句继续。"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { speech.audition(candidate.spoken) } label: { Text(L10n.tr("试听")).frame(maxWidth: .infinity) }.disabled(!candidate.isValid)
                        Button {
                            let rule = candidate
                            focusedField = nil
                            var rules = speech.pronunciationRules.filter { $0.phrase != rule.phrase }
                            rules.append(rule); speech.setPronunciationRules(rules); phrase = ""; spoken = ""
                        } label: { Text(L10n.tr("保存纠音")).frame(maxWidth: .infinity) }
                            .disabled(!candidate.isValid).accessibilityIdentifier("savePronunciation")
                    }.accessibilityElement(children: .contain)
                }.listRowBackground(model.readingTheme.sidebar)
                Section(L10n.tr("自定义纠音")) {
                    ForEach(speech.pronunciationRules) { rule in
                        HStack { Text(rule.phrase + " → " + rule.spoken); Spacer(); Button(L10n.tr("删除"), role: .destructive) { speech.setPronunciationRules(speech.pronunciationRules.filter { $0.id != rule.id }) } }
                    }
                }.listRowBackground(model.readingTheme.sidebar)
            }.formStyle(.grouped).scrollContentBackground(.hidden).background(model.readingTheme.background.ignoresSafeArea())
                .accessibilityIdentifier("pronunciationForm")
                .foregroundStyle(model.readingTheme.foreground).listRowBackground(model.readingTheme.sidebar)
                .navigationTitle(L10n.tr("朗读纠音")).toolbar { Button(L10n.tr("完成")) { if speech.auditioning { speech.stop() }; dismiss() } }
        }.frame(minWidth: 320, idealWidth: 520, minHeight: 420)
    }
}
