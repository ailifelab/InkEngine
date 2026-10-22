#if os(iOS)
import SwiftUI
import InkCore
import UniformTypeIdentifiers

/// Pick a directory before writing, so another open buffer can never be overwritten by an exporter.
struct WorkspaceSaveSheet: View {
    @ObservedObject var workspace: DocumentWorkspace
    let snapshot: Manuscript
    @State private var name: String
    @State private var choosingFolder = false
    @State private var replacementFolder: URL?
    @State private var error: String?
    init(workspace: DocumentWorkspace, snapshot: Manuscript) {
        self.workspace = workspace; self.snapshot = snapshot
        _name = State(initialValue: snapshot.fileName)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.tr("文件名"), text: $name).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("workspaceSaveName")
                Button(L10n.tr("选择保存目录…")) { choosingFolder = true }
                    .disabled(!Manuscript.validFileName(name)).accessibilityIdentifier("workspaceSaveFolder")
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(L10n.tr("另存为…"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("取消")) { workspace.finishExport(nil) }.accessibilityIdentifier("workspaceSaveCancel") } }
        }
        .sheet(isPresented: $choosingFolder) {
            WorkspaceFolderPicker { folder in
                choosingFolder = false
                guard let folder else { return }
                let access = folder.startAccessingSecurityScopedResource()
                let exists = FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
                if access { folder.stopAccessingSecurityScopedResource() }
                if exists { replacementFolder = folder }
                else { write(folder) }
            }
        }
        .alert(L10n.tr("替换已有文件？"), isPresented: Binding(get: { replacementFolder != nil }, set: { _ in })) {
            Button(L10n.tr("取消"), role: .cancel) { replacementFolder = nil }
            Button(L10n.tr("替换"), role: .destructive) {
                if let folder = replacementFolder { replacementFolder = nil; write(folder) }
            }
        } message: { Text(name) }
        .interactiveDismissDisabled()
    }
    private func write(_ folder: URL) {
        Task {
            do { try await workspace.writeExport(snapshot, folder: folder, name: name) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct WorkspaceFolderPicker: UIViewControllerRepresentable {
    var directoryURL: URL? = nil
    let completion: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator; picker.allowsMultipleSelection = false; picker.directoryURL = directoryURL
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(nil) }
    }
}
#endif
