#if os(macOS)
import Foundation
import Darwin

/// 监视当前文件及父目录，兼容编辑器通过原子替换保存。没有定时轮询。
@MainActor final class LocalFileObserver {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?
    private let url: URL
    private let access: Bool
    private var fingerprint: String?
    private let changed: @MainActor () -> Void

    init(url: URL, changed: @escaping @MainActor () -> Void) {
        self.url = url; self.changed = changed
        access = url.startAccessingSecurityScopedResource()
        fingerprint = Self.signature(url)
        for path in [url.path, url.deletingLastPathComponent().path] {
            let descriptor = Darwin.open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleCheck() }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources.append(source); source.resume()
        }
    }

    private static func signature(_ url: URL) -> String? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(values[.systemFileNumber] ?? ""):\(values[.size] ?? ""):\(modified)"
    }
    private func scheduleCheck() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let current = Self.signature(url)
            guard current != fingerprint else { return }
            fingerprint = current; changed()
        }
    }
    deinit {
        pending?.cancel()
        for source in sources { source.cancel() }
        if access { url.stopAccessingSecurityScopedResource() }
    }
}
#endif
