import SwiftUI
import InkCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor extension DocumentWorkspace {
    func closePane(_ pane: UUID, window: UUID) async {
        guard let layout = self.window(window), layout.panes.count > 1,
              let source = layout.panes.first(where: { $0.id == pane }),
              let other = layout.panes.first(where: { $0.id != pane }),
              let index = windows.firstIndex(where: { $0.id == window }) else { return }
        // Closing a view merges its tabs; only explicit tab close discards a document.
        for tab in source.tabs { insert(tab.id, into: window, pane: other.id) }
        windows[index].panes.removeAll { $0.id == pane }
        await focus(window: window, pane: other.id); await checkpoint()
    }

    func reload(_ id: UUID) async {
        guard let model = sessions[id], !savingDocuments.contains(id) else { return }
        model.commitEditing()
        let text = model.editorText
        do {
            let loaded = try await library.repository.reloadLocalFile(id)
            guard model.editorText == text else { throw InkError.invalidDocument }
            model.savedBaseline = loaded; model.book = loaded; model.editorText = loaded.content
            model.textLength = loaded.content.utf16.count; model.dirty = false; model.isNewDraft = false
            model.editorPosition = min(model.editorPosition, model.textLength); model.editorNavigationID = UUID()
            try await library.repository.removeWorkingDraft(id)
            await model.reparse()
        } catch { failure = error.localizedDescription }
    }

    func rename(_ id: UUID, name: String) async {
        guard !savingDocuments.contains(id), let model = sessions[id], Manuscript.validFileName(name) else { failure = InkError.invalidDocument.localizedDescription; return }
        model.commitEditing()
        do {
            if let source = try await library.repository.sourceURL(id) {
                let target = source.deletingLastPathComponent().appendingPathComponent(name)
                guard target != source else { return }
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
                guard !(try await library.repository.sourceHasChanges(id)) else { throw InkError.invalidDocument }
                var coordinationError: NSError?, moveError: Error?
                NSFileCoordinator().coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordinationError) { old, new in
                    do { try FileManager.default.moveItem(at: old, to: new) } catch { moveError = error }
                }
                if let error = coordinationError ?? moveError as NSError? { throw error }
                do {
                    guard var baseline = model.savedBaseline else { throw InkError.invalidDocument }
                    try baseline.configure(fileName: name, highlightOverride: baseline.highlightOverride)
                    try await library.repository.save(baseline)
                    try await library.repository.attachSource(target, to: id)
                    model.savedBaseline = baseline; model.sourcePath = target.path
                } catch {
                    try? FileManager.default.moveItem(at: target, to: source)
                    throw error
                }
            }
            if var current = model.book {
                try current.configure(fileName: name, highlightOverride: current.highlightOverride); model.book = current
                if model.isNewDraft { model.savedBaseline?.fileName = name; model.savedBaseline?.title = current.title }
            }
            try await model.stashWorkingDraft(); await model.refresh()
        } catch { failure = error.localizedDescription }
    }

    func deleteFile(_ id: UUID, window: UUID) async {
        guard !savingDocuments.contains(id) else { return }
        do {
            guard let source = try await library.repository.sourceURL(id) else { return }
            // Every reference participates so no live clone keeps editing a removed file.
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            guard !windows.contains(where: { $0.id != window && $0.panes.contains(where: { $0.tabs.contains(where: { $0.id == id }) }) }) else {
                failure = L10n.tr("请先关闭其他窗口中的此文稿，再删除文件。"); return
            }
            guard await close([id], window: window, rememberClosed: false) else { return }
            #if os(macOS)
            try FileManager.default.trashItem(at: source, resultingItemURL: nil)
            try await library.repository.setTrashed(id, trashed: true)
            await library.removeRecent(id)
            #else
            _ = try await library.repository.deleteLocalEntry(.init(id: id))
            #endif
            forgetClosedTabs(for: id)
            await library.refresh()
        } catch { failure = error.localizedDescription }
    }

    func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    func openContainingFolder(_ id: UUID, window: UUID? = nil) async {
        do {
            guard let source = try await library.repository.sourceURL(id) else { return }
            #if os(macOS)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.directoryURL = source.deletingLastPathComponent()
            let response = await withCheckedContinuation { continuation in
                if let window = NSApp.keyWindow { panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
                else { panel.begin { continuation.resume(returning: $0) } }
            }
            if response == .OK, let folder = panel.url { await library.importFolder(folder, alias: folder.lastPathComponent) }
            #else
            guard folderWindow == nil else { return }
            folderInitialURL = source.deletingLastPathComponent(); folderWindow = window ?? focusedWindow
            #endif
        } catch { failure = error.localizedDescription }
    }

    func openExternally(_ id: UUID) async {
        do {
            guard let source = try await library.repository.sourceURL(id) else { return }
            #if os(macOS)
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            guard NSWorkspace.shared.open(source) else { throw CocoaError(.fileReadUnknown) }
            #else
            guard await UIApplication.shared.open(source) else { throw CocoaError(.fileReadUnknown) }
            #endif
        } catch { failure = error.localizedDescription }
    }

    #if os(macOS)
    func reveal(_ id: UUID) async {
        do {
            guard let url = try await library.repository.sourceURL(id) else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { failure = error.localizedDescription }
    }
    func openTerminal(_ id: UUID) async {
        do {
            guard let source = try await library.repository.sourceURL(id),
                  let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            let access = source.startAccessingSecurityScopedResource()
            let directory = source.deletingLastPathComponent()
            NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
                if access { source.stopAccessingSecurityScopedResource() }
                if let error { Task { @MainActor in self?.failure = error.localizedDescription } }
            }
        } catch { failure = error.localizedDescription }
    }
    #endif

    func printDocument(_ id: UUID) {
        guard let model = sessions[id] else { return }
        model.commitEditing()
        #if os(macOS)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        view.string = model.editorText; view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        NSPrintOperation(view: view).run()
        #else
        let formatter = UISimpleTextPrintFormatter(text: model.editorText)
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = formatter
        controller.present(animated: true, completionHandler: nil)
        #endif
    }
}
