import SwiftUI

/// Policies remain readable without opening a website or transmitting manuscripts.
struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected = 0
    private var policy: String {
        let name = selected == 0 ? "privacy-zh-Hans" : "usage-zh-Hans"
        guard let url = Bundle.main.url(forResource: name, withExtension: "md", subdirectory: "Legal"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "说明文件缺失，请联系技术支持。"
        }
        return text
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("说明类型", selection: $selected) {
                    Text("隐私政策").tag(0)
                    Text("使用与开源").tag(1)
                }.pickerStyle(.segmented).padding()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(policy.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                            if paragraph.hasPrefix("# ") {
                                Text(String(paragraph.dropFirst(2))).font(.title2.bold())
                            } else if paragraph.hasPrefix("## ") {
                                Text(String(paragraph.dropFirst(3))).font(.headline)
                            } else {
                                Text(paragraph).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Link("官网与技术支持", destination: URL(string: "https://ailifelab.com/apps/inkengine/")!)
                        Text("点击链接将打开网站并联网。").font(.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled).padding()
                }.id(selected)
            }
            .navigationTitle("隐私与使用说明")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 480, idealHeight: 680)
        #endif
    }
}
