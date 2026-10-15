import Foundation

/// 通用 ZIP 打包，使用存储格式逐个写入文件；不会把整部小说再拼成一个内存缓冲区。
public enum ZIPArchive {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        return crc
    }
    private static func crc(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data { value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 0xff)] }
        return value ^ UInt32.max
    }
    public static func write(to url: URL, paths: [String], contents: (Int) throws -> Data) throws {
        guard !paths.isEmpty, paths.count < 65535, Set(paths).count == paths.count, paths.allSatisfy(TransferManifest.safePath) else { throw InkError.invalidDocument }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var central = Data(), offset: UInt32 = 0
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        do {
            for (index, path) in paths.enumerated() {
                let body = try contents(index), name = Data(path.utf8)
                guard body.count <= 20 * 1024 * 1024, name.count < 65536 else { throw InkError.invalidDocument }
                let checksum = crc(body), size = UInt32(body.count)
                var header = Data()
                append(UInt32(0x04034b50), to: &header); append(UInt16(20), to: &header); append(UInt16(0x800), to: &header)
                append(UInt16(0), to: &header); append(UInt16(0), to: &header); append(UInt16(0x21), to: &header)
                append(checksum, to: &header); append(size, to: &header); append(size, to: &header)
                append(UInt16(name.count), to: &header); append(UInt16(0), to: &header); header.append(name)
                try handle.write(contentsOf: header); try handle.write(contentsOf: body)
                append(UInt32(0x02014b50), to: &central); append(UInt16(20), to: &central); append(UInt16(20), to: &central); append(UInt16(0x800), to: &central)
                append(UInt16(0), to: &central); append(UInt16(0), to: &central); append(UInt16(0x21), to: &central)
                append(checksum, to: &central); append(size, to: &central); append(size, to: &central)
                append(UInt16(name.count), to: &central); append(UInt16(0), to: &central); append(UInt16(0), to: &central)
                append(UInt16(0), to: &central); append(UInt16(0), to: &central); append(UInt32(0), to: &central); append(offset, to: &central); central.append(name)
                let next = UInt64(offset) + UInt64(header.count) + UInt64(body.count)
                guard next <= UInt32.max else { throw InkError.invalidDocument }; offset = UInt32(next)
            }
            try handle.write(contentsOf: central)
            var end = Data(); append(UInt32(0x06054b50), to: &end)
            append(UInt16(0), to: &end); append(UInt16(0), to: &end); append(UInt16(paths.count), to: &end); append(UInt16(paths.count), to: &end)
            append(UInt32(central.count), to: &end); append(offset, to: &end); append(UInt16(0), to: &end)
            try handle.write(contentsOf: end)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
}
