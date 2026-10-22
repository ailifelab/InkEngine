// Compile against the Release InkCore objects. Uses a disposable library only.
import Foundation
import InkCore

@main struct LibraryBenchmark {
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("InkLibraryBenchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Novel")
        let count = Int(CommandLine.arguments.dropFirst().first ?? "500") ?? 500
        for index in 0..<count {
            let folder = source.appendingPathComponent("卷\(index / 50)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(String(repeating: "窗外的风带来了雨的气息，继续阅读下一段文字。\n", count: 40).utf8)
                .write(to: folder.appendingPathComponent("第\(index)章.md"))
        }
        let repository = try LibraryRepository(root: temporary.appendingPathComponent("Library"))
        let imported = try await repository.importFolder(source, alias: "性能测试", linkOriginals: true)
        let history = try await repository.recentHistory()
        _ = try await repository.refreshLinkedFolders()
        _ = try await repository.linkedFolderDirectories()
        _ = try await repository.list()
        func measure(_ label: String, _ work: () async throws -> Void) async throws {
            var times: [Double] = []
            for _ in 0..<21 {
                let start = ContinuousClock.now
                try await work()
                let elapsed = start.duration(to: .now).components
                times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
            times.sort()
            print("\(label) median_ms=\(times[10]) p95_ms=\(times[19])")
        }
        print("chapters=\(count) directories=\((count + 49) / 50 + 1)")
        try await measure("unchanged_additions_scan") { _ = try await repository.refreshLinkedFolders() }
        try await measure("directory_watch_inventory") { _ = try await repository.linkedFolderDirectories() }
        try await measure("cached_book_list") { _ = try await repository.list() }
        try await measure("combined_refresh") {
            _ = try await repository.refreshLinkedFolders()
            _ = try await repository.linkedFolderDirectories()
            _ = try await repository.list()
            _ = try await repository.collections()
            _ = try await repository.recentHistory()
        }
        let after = try await repository.list()
        let afterHistory = try await repository.recentHistory()
        precondition(after.count == count && Set(after.map(\.id)) == Set(imported.collection.entries.map(\.documentID)))
        precondition(afterHistory == history, "Measurements must not change history")
    }
}
