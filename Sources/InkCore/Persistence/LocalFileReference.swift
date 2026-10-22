import Foundation
import CryptoKit

struct LocalFileReference: Codable, Sendable {
    var path: String
    var bookmark: Data?
    var encoding: UInt
    var utf8BOM: Bool
    var diskDigest: String
    var contentDigest: String
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    init(url: URL, content: String, data supplied: Data? = nil) throws {
        path = url.path
        #if os(macOS)
        bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        let data = try supplied ?? Data(contentsOf: url)
        encoding = data.starts(with: [0xff, 0xfe]) ? String.Encoding.utf16LittleEndian.rawValue : data.starts(with: [0xfe, 0xff]) ? String.Encoding.utf16BigEndian.rawValue : String.Encoding.utf8.rawValue
        utf8BOM = data.starts(with: [0xef, 0xbb, 0xbf])
        diskDigest = Self.digest(data); contentDigest = Manuscript.digest(content)
    }
    func resolved() throws -> URL {
        guard let bookmark else { return URL(fileURLWithPath: path) }
        var stale = false
        let original = URL(fileURLWithPath: path)
        do {
        #if os(macOS)
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
            // 文件提供器的覆盖保存可能换掉文件身份。仅当原路径仍有读取权限时回退，
            // 不以路径绕过安全作用域，也不把已移动且可正常解析的文件改回旧位置。
            if !FileManager.default.fileExists(atPath: resolved.path), FileManager.default.isReadableFile(atPath: path) { return original }
            return resolved
        } catch {
            if FileManager.default.isReadableFile(atPath: path) { return original }
            throw error
        }
    }
    func encodedContent(_ content: String) throws -> Data {
        var output = Data()
        if encoding == String.Encoding.utf16LittleEndian.rawValue { output.append(contentsOf: [0xff, 0xfe]) }
        else if encoding == String.Encoding.utf16BigEndian.rawValue { output.append(contentsOf: [0xfe, 0xff]) }
        else if utf8BOM { output.append(contentsOf: [0xef, 0xbb, 0xbf]) }
        guard let encoded = content.data(using: String.Encoding(rawValue: encoding)) else { throw InkError.invalidEncoding }
        output.append(encoded)
        return output
    }
    mutating func write(_ content: String) throws {
        let url = try resolved(), access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let output = try encodedContent(content)
        var coordinationError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                guard Self.digest(try Data(contentsOf: target)) == diskDigest else {
                    throw NSError(domain: "InkEngine.LocalFile", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("原文件已被其他应用修改。请先另存当前修改，再重新打开原文件。")])
                }
                try output.write(to: target, options: .atomic)
            } catch { writeError = error }
        }
        if let failure = coordinationError ?? writeError as NSError? { throw failure }
        path = url.path; diskDigest = Self.digest(output); contentDigest = Manuscript.digest(content)
    }
}

public struct BookmarkRecord: Identifiable, Sendable {
    public var id: UUID { bookmark.id }
    public var documentID: UUID
    public var fileName: String
    public var folderID: UUID?
    public var bookmark: ReadingBookmark
}
