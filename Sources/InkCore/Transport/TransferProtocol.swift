import Foundation
import CryptoKit

public struct PeerHello: Codable, Sendable {
    public let protocolVersion: Int
    public let deviceID: UUID
    public let name: String
    public let identityKey: Data
    public let ephemeralKey: Data
    public let nonce: Data
    public var signature: Data

    public var signedBytes: Data {
        var data = Data("InkEngine/1|\(deviceID.uuidString)|\(name)|".utf8)
        data.append(identityKey); data.append(ephemeralKey); data.append(nonce)
        return data
    }
    public func verify() throws {
        guard protocolVersion == 1, name.utf8.count < 256, identityKey.count == 32, ephemeralKey.count == 32, nonce.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: identityKey), key.isValidSignature(signature, for: signedBytes) else { throw InkError.authentication }
    }
}

public struct SessionHandshake {
    public let ephemeral: Curve25519.KeyAgreement.PrivateKey
    public let hello: PeerHello

    public init(identity: Curve25519.Signing.PrivateKey, deviceID: UUID, name: String) throws {
        ephemeral = .init()
        var hello = PeerHello(protocolVersion: 1, deviceID: deviceID, name: String(name.prefix(60)), identityKey: identity.publicKey.rawRepresentation,
                              ephemeralKey: ephemeral.publicKey.rawRepresentation, nonce: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, signature: Data())
        hello.signature = try identity.signature(for: hello.signedBytes)
        self.hello = hello
    }

    public func establish(with remote: PeerHello) throws -> SecureChannel {
        try remote.verify()
        guard hello.deviceID != remote.deviceID else { throw InkError.authentication }
        let ordered = [hello.signedBytes, remote.signedBytes].sorted { $0.lexicographicallyPrecedes($1) }
        let transcript = ordered.reduce(into: Data()) { $0.append($1) }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote.ephemeralKey))
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: transcript)), sharedInfo: Data("InkEngine encrypted manuscripts v1".utf8), outputByteCount: 32)
        // 配对码包含握手密钥的认证结果，中间人仅复制公开字段无法伪造相同配对码。
        let authentication = HMAC<SHA256>.authenticationCode(for: transcript, using: key)
        let bytes = Array(authentication)
        let code = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) % 1_000_000
        let first = hello.signedBytes.lexicographicallyPrecedes(remote.signedBytes)
        let forward = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("first-to-second".utf8), outputByteCount: 32)
        let reverse = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("second-to-first".utf8), outputByteCount: 32)
        return SecureChannel(outgoingKey: first ? forward : reverse, incomingKey: first ? reverse : forward,
                             pairingCode: String(format: "%06u", code), sessionID: Data(SHA256.hash(data: transcript)))
    }
}

public struct TransferMessage: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case accept, reject, requestCurrent, requestDocument, document, receipt, cancel, beginTransfer, transferDocument, commitTransfer }
    public var kind: Kind
    public var document: Manuscript?
    public var checksum: String?
    public var documentID: UUID?
    public var transferID: UUID?
    public var note: String?
    public var manifest: TransferManifest?
    public init(_ kind: Kind, document: Manuscript? = nil, documentID: UUID? = nil, transferID: UUID? = nil, note: String? = nil, manifest: TransferManifest? = nil) {
        self.kind = kind; self.document = document; self.documentID = documentID; self.transferID = transferID; self.note = note; self.manifest = manifest
        checksum = document?.checksum
    }
}

private struct EncryptedEnvelope: Codable { var sequence: UInt64; var message: TransferMessage }

public final class SecureChannel {
    public let pairingCode: String
    private let outgoingKey: SymmetricKey
    private let incomingKey: SymmetricKey
    private let sessionID: Data
    private var outgoing: UInt64 = 0, incoming: UInt64 = 0
    public init(outgoingKey: SymmetricKey, incomingKey: SymmetricKey, pairingCode: String, sessionID: Data) { self.outgoingKey = outgoingKey; self.incomingKey = incomingKey; self.pairingCode = pairingCode; self.sessionID = sessionID }
    public func seal(_ message: TransferMessage) throws -> Data {
        outgoing += 1
        let data = try JSONEncoder().encode(EncryptedEnvelope(sequence: outgoing, message: message))
        return try AES.GCM.seal(data, using: outgoingKey, authenticating: sessionID).combined!
    }
    public func open(_ data: Data) throws -> TransferMessage {
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: incomingKey, authenticating: sessionID)
        let envelope = try JSONDecoder().decode(EncryptedEnvelope.self, from: plaintext)
        guard envelope.sequence == incoming + 1 else { throw InkError.replay }
        incoming = envelope.sequence
        return envelope.message
    }
}

public struct FrameDecoder {
    public static let maximumFrame = 32 * 1024 * 1024
    private var buffer = Data()
    private var consumed = 0
    public init() {}
    public static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumFrame else { throw InkError.invalidFrame }
        var length = UInt32(payload.count).bigEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }; data.append(payload); return data
    }
    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard buffer.count - consumed + bytes.count <= Self.maximumFrame + 65540 else { throw InkError.invalidFrame }
        buffer.append(bytes)
        var result: [Data] = []
        while buffer.count - consumed >= 4 {
            let length = buffer[consumed..<consumed + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= Self.maximumFrame else { throw InkError.invalidFrame }
            let end = consumed + 4 + Int(length)
            guard end <= buffer.count else { break }
            result.append(buffer.subdata(in: consumed + 4..<end)); consumed = end
        }
        if consumed > 0 { buffer.removeSubrange(0..<consumed); consumed = 0 }
        return result
    }
}
