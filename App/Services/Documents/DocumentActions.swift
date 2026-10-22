import SwiftUI
import InkCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PreparedFile: Identifiable { let id = UUID(); let url: URL }

@MainActor enum DocumentActions {
    static func clearTemporaryExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineExport")
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    static func prepare(_ book: Manuscript, fileName: String? = nil) throws -> PreparedFile {
        let name = fileName ?? book.fileName
        guard Manuscript.validFileName(name) else { throw InkError.invalidDocument }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineExport/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(book.content.utf8).write(to: url, options: .atomic)
        return PreparedFile(url: url)
    }
    static func prepare(_ transfer: PreparedTransfer) async throws -> PreparedFile {
        defer { transfer.remove() }
        return try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineExport/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                if transfer.manifest.collection == nil {
                    let document = try transfer.document(transfer.manifest.items[0])
                    let url = directory.appendingPathComponent(document.fileName)
                    try Data(document.content.utf8).write(to: url, options: .atomic)
                    return PreparedFile(url: url)
                }
                var name = transfer.manifest.title.map { "/\\:\0".contains($0) ? "_" : String($0) }.joined()
                while name.utf8.count > 180 { name.removeLast() }
                if name == "." || name == ".." || name.isEmpty { name = L10n.tr("小说目录") }
                let url = directory.appendingPathComponent(name + ".zip")
                try ZIPArchive.write(to: url, paths: transfer.manifest.items.map { name + "/" + $0.relativePath }) { index in
                    try Task.checkCancellation()
                    return Data(try transfer.document(transfer.manifest.items[index]).content.utf8)
                }
                return PreparedFile(url: url)
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }.value
    }
    #if os(macOS)
    static func previewHTML(_ book: Manuscript, source: URL?, completion: @escaping @MainActor @Sendable (Error?) -> Void) throws {
        let url: URL
        if let source { url = source }
        else {
            // 无原文件的应用文稿复用同一预览目录，避免每次预览产生一份长期残留的副本。
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineExport/HTMLPreview/" + book.id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent(book.fileName)
            try Data(book.content.utf8).write(to: url, options: .atomic)
        }
        let access = url.startAccessingSecurityScopedResource()
        // HTML默认关联可能是源码编辑器；使用HTTPS关联明确找到系统默认浏览器。
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else {
            if access { url.stopAccessingSecurityScopedResource() }
            throw NSError(domain: "InkEngine.Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("未找到系统默认浏览器。")])
        }
        // 浏览器可能延后回应打开请求，不让文稿操作等待外部应用；失败仍回传界面。
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if access { url.stopAccessingSecurityScopedResource() }
            Task { @MainActor in completion(error) }
        }
    }
    static func saveAs(_ book: Manuscript, validate: ((URL) async throws -> Void)? = nil) async throws -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = book.fileName
        panel.canCreateDirectories = true; panel.isExtensionHidden = false; panel.allowsOtherFileTypes = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineUITests/Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            panel.directoryURL = directory
        }
        #endif
        // 不限制内容类型，让用户输入的完整文件名和自定义扩展名原样保存。
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                // 系统面板恢复目录后再次指定隔离位置，避免使用作者上次保存的小说目录。
                panel.directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineUITests/Exports", isDirectory: true)
            }
            #endif
        }
        guard response == .OK, let url = panel.url else { return nil }
        guard Manuscript.validFileName(url.lastPathComponent) else { throw InkError.invalidDocument }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineUITests/Exports", isDirectory: true)
            guard url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
                throw NSError(domain: "InkEngine.UITest", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("测试另存仅允许写入隔离的 Exports 目录。")])
            }
        }
        #endif
        try await validate?(url)
        try Data(book.content.utf8).write(to: url, options: .atomic)
        return url
    }
    static func share(_ file: PreparedFile) {
        guard let view = NSApp.keyWindow?.contentView else { return }
        NSSharingServicePicker(items: [file.url]).show(relativeTo: NSRect(x: view.bounds.maxX - 90, y: view.bounds.maxY - 45, width: 30, height: 30), of: view, preferredEdge: .minY)
    }
    #endif
}

#if os(iOS)
struct SystemExporter: UIViewControllerRepresentable {
    var file: PreparedFile
    var completion: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        init(_ completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            #if DEBUG
            print("INK_EXPORT_PICK " + (urls.first?.lastPathComponent ?? "nil"))
            #endif
            completion(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            #if DEBUG
            print("INK_EXPORT_CANCEL")
            #endif
            completion(nil)
        }
    }
}
struct SystemShare: UIViewControllerRepresentable {
    var file: PreparedFile
    var completion: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

#if os(iOS)
struct DocumentFileName: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paperTheme) private var theme
    @State var fileName: String
    let completion: (String) -> Void
    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.tr("完整文件名（含扩展名）"), text: $fileName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("fileNameField")
                    .listRowBackground(theme.sidebar)
            }
            .scrollContentBackground(.hidden).background(theme.background.ignoresSafeArea())
            .foregroundStyle(theme.foreground)
            .navigationTitle(L10n.tr("另存为"))
            .toolbarBackground(theme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("下一步")) { completion(fileName) }
                        .disabled(!Manuscript.validFileName(fileName)).accessibilityIdentifier("confirmFileName")
                }
            }
        }.presentationDetents([.medium])
    }
}
#endif
