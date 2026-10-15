import SwiftUI
import Network
import CryptoKit
import Security
import LocalAuthentication
import InkCore
#if os(iOS)
import UIKit
#endif

struct NearbyPeer: Identifiable {
    var id: String
    var name: String
    var endpoint: NWEndpoint
}

@MainActor private enum IdentityStorage {
    static let service = "org.ailifelab.inkengine.identity"
    static func load(allowInteraction: Bool) throws -> Curve25519.Signing.PrivateKey? {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        context.localizedReason = "读取墨语引擎自己保存的设备配对密钥"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "signing", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            .merging([kSecUseAuthenticationContext as String: context]) { _, new in new }
        #if os(macOS)
        // 本地临时签名使用旧文件型钥匙串；LAContext 单独不能禁止它的 ACL 授权框。
        // 所有调用都在 MainActor 同步执行，仅在本次后台读取期间禁止交互并恢复原值。
        var previousInteraction: DarwinBoolean = true
        if !allowInteraction {
            let status = SecKeychainGetUserInteractionAllowed(&previousInteraction)
            guard status == errSecSuccess else { throw accessError(status) }
            let disabled = SecKeychainSetUserInteractionAllowed(false)
            guard disabled == errSecSuccess else { throw accessError(disabled) }
        }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) } }
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw accessError(status) }
        guard let data = result as? Data else { throw accessError(errSecDecode) }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
    private static func accessError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            "无法读取本应用保存的设备配对密钥（\(status)）。请在“附近设备”中点击设备重新连接，按系统提示授权；也可撤销设备信任后重新配对。不会读取你的账号密码。"])
    }
    // 仅用户明确选择记住配对时写入钥匙串，启动和临时配对不持久化身份。
    static func save(_ key: Curve25519.Signing.PrivateKey) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "signing"]
        let values: [String: Any] = [kSecValueData as String: key.rawRepresentation, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "无法保存钥匙串身份（\(status)），本次连接仍可临时配对。"] ) }
    }
}

@MainActor final class NearbyService: ObservableObject {
    @Published var peers: [NearbyPeer] = []
    @Published var running = false
    @Published var status = "开始发现后，系统可能请求局域网权限。"
    @Published var peerName = ""
    @Published var pairingCode: String?
    @Published var ready = false
    @Published var awaitingPeer = false
    @Published var transferring = false
    @Published var error: String?
    @Published var trustedNames: [String] = []
    var isTesting = false
    var currentDocument: ((UUID?) async throws -> Manuscript?)?
    var receiveDocument: ((Manuscript, String) async throws -> String)?
    var receiveTransfer: ((PreparedTransfer) async throws -> String)?
    @Published private(set) var completedFiles = 0
    @Published private(set) var totalFiles = 0
    private var incomingTransfer: PreparedTransfer?
    private var incomingFiles: Set<UUID> = []
    private var receiptWaiter: (UUID, CheckedContinuation<Void, Error>)?
    private var commitTask: Task<Void, Never>?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var frameDecoder = FrameDecoder()
    private var identity = Curve25519.Signing.PrivateKey()
    private var identityLoaded = false
    private let loadIdentity: @MainActor (Bool) throws -> Curve25519.Signing.PrivateKey?
    private let saveIdentity: @MainActor (Curve25519.Signing.PrivateKey) throws -> Void
    private let preferences: UserDefaults
    private let deviceID: UUID
    private var handshake: SessionHandshake?
    private var channel: SecureChannel?
    private var remote: PeerHello?
    private var localAccepted = false, remoteAccepted = false
    private var timer: Task<Void, Never>?
    private var transferID: UUID?
    private var sessionToken = UUID()
    private var receivedTransfers: Set<UUID> = []
    private var trusts: [String: String]
    private var names: [String: String]

    init(preferences: UserDefaults = .standard,
         loadIdentity: @escaping @MainActor (Bool) throws -> Curve25519.Signing.PrivateKey? = IdentityStorage.load,
         saveIdentity: @escaping @MainActor (Curve25519.Signing.PrivateKey) throws -> Void = IdentityStorage.save) {
        self.preferences = preferences; self.loadIdentity = loadIdentity; self.saveIdentity = saveIdentity
        trusts = preferences.dictionary(forKey: "trustedPeers") as? [String: String] ?? [:]
        names = preferences.dictionary(forKey: "trustedNames") as? [String: String] ?? [:]
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            // 文件/UI 回归用临时身份，不能读取真实配对钥匙串或改变用户设备身份。
            identity = Curve25519.Signing.PrivateKey(); deviceID = UUID()
            trusts = [:]; names = [:]; isTesting = true
            return
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--nearby-integration") {
            identity = Curve25519.Signing.PrivateKey(); deviceID = UUID()
            trusts = [:]; names = [:]
            return
        }
        #endif
        // 普通启动只创建临时身份。真正连接已记住的设备时才读取本应用的钥匙串记录。
        if let raw = preferences.string(forKey: "deviceID"), let id = UUID(uuidString: raw) { deviceID = id }
        else { deviceID = UUID(); preferences.set(deviceID.uuidString, forKey: "deviceID") }
        trustedNames = Array(names.values).sorted()
    }
    func connectionIdentity(allowInteraction: Bool) throws -> Curve25519.Signing.PrivateKey {
        guard !isTesting, !trusts.isEmpty, !identityLoaded else { return identity }
        guard let remembered = try loadIdentity(allowInteraction) else {
            throw NSError(domain: "InkEngine.Pairing", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "已记住设备，但本机配对密钥不存在。请撤销设备信任后重新核对配对码。原文稿与钥匙串记录不会被改动。"])
        }
        identity = remembered; identityLoaded = true
        return identity
    }
    private var localName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }
    private var parameters: NWParameters {
        let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
        return parameters
    }
    func discoverRememberedDevices() {
        guard !isTesting, !trustedNames.isEmpty else { return }
        start()
    }
    func start() {
        guard !running else { return }
        guard !isTesting else { status = "UI 测试不触发局域网授权。"; return }
        do {
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: "\(localName) · \(deviceID.uuidString.prefix(6))", type: "_inkengine._tcp")
            listener.newConnectionHandler = { [weak self] incoming in Task { @MainActor in
                guard let self, self.running, self.connection == nil else { incoming.cancel(); return }
                self.attach(incoming)
            } }
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in self?.networkState(state) } }
            self.listener = listener; listener.start(queue: .main)
            let browser = NWBrowser(for: .bonjour(type: "_inkengine._tcp", domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in Task { @MainActor in
                guard let self else { return }
                self.peers = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint, !name.hasSuffix(String(self.deviceID.uuidString.prefix(6))) else { return nil }
                    return NearbyPeer(id: name, name: name, endpoint: result.endpoint)
                }.sorted { $0.name < $1.name }
            } }
            browser.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                if case let .waiting(error) = state { self?.status = "发现受阻：\(error)。检查局域网权限、Wi-Fi 与防火墙，然后重试。" }
                if case let .failed(error) = state { self?.error = "发现失败：\(error)"; self?.stop() }
            } }
            self.browser = browser; browser.start(queue: .main); running = true
            status = "正在寻找附近设备。请让两端 App 保持前台，并连接同一局域网。"
        } catch { self.error = error.localizedDescription; stop() }
    }
    private func networkState(_ state: NWListener.State) {
        switch state {
        case .failed(let error): self.error = "监听失败：\(error)"; stop()
        case .waiting(let error): status = "局域网不可用：\(error)。可在系统设置中检查权限，再重试。"
        default: break
        }
    }
    func stop() {
        disconnect(); listener?.cancel(); browser?.cancel(); listener = nil; browser = nil; running = false; peers = []
    }
    func connect(_ peer: NearbyPeer) { disconnect(); peerName = peer.name; attach(NWConnection(to: peer.endpoint, using: parameters), allowIdentityInteraction: true) }
    private func attach(_ connection: NWConnection, allowIdentityInteraction: Bool = false) {
        self.connection = connection; sessionToken = UUID(); let token = sessionToken
        status = "正在安全连接…"; frameDecoder = FrameDecoder(); receivedTransfers = []
        do { handshake = try SessionHandshake(identity: connectionIdentity(allowInteraction: allowIdentityInteraction), deviceID: deviceID, name: localName) }
        catch { fail(error); return }
        connection.stateUpdateHandler = { [weak self] state in Task { @MainActor in
            guard let self, self.sessionToken == token else { return }
            switch state {
            case .ready:
                do { try self.sendFrame(JSONEncoder().encode(self.handshake!.hello), type: 0); self.receive(token) }
                catch { self.fail(error) }
            case .failed(let error): self.fail(error)
            case .waiting(let error): self.status = "连接等待：\(error)。源设备可能休眠或网络不可达。"
            case .cancelled: self.disconnect()
            default: break
            }
        } }
        connection.start(queue: .main); armTimeout(seconds: 30, note: "连接超时。检查源设备是否休眠、网络权限与 Wi-Fi，然后重试。")
    }
    private func receive(_ token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in Task { @MainActor in
            guard let self, self.sessionToken == token else { return }
            if let error { self.fail(error); return }
            do { if let data { for frame in try self.frameDecoder.append(data) { try self.process(frame, token: token) } } }
            catch { self.fail(error); return }
            if complete { self.status = "连接已断开。已保存的副本可离线使用，可重新发现并连接。"; self.disconnect(); return }
            self.receive(token)
        } }
    }
    private func process(_ frame: Data, token: UUID) throws {
        guard let type = frame.first else { throw InkError.invalidFrame }
        let payload = frame.dropFirst()
        if type == 0 {
            guard channel == nil, payload.count < 4096, let handshake else { throw InkError.authentication }
            let remote = try JSONDecoder().decode(PeerHello.self, from: payload)
            channel = try handshake.establish(with: remote); self.remote = remote; peerName = remote.name
            if let expected = trusts[remote.deviceID.uuidString] {
                guard expected == remote.identityKey.base64EncodedString() else { throw InkError.authentication }
                localAccepted = true; try send(TransferMessage(.accept)); status = "已验证记住的设备，等待对方确认。"
            } else {
                pairingCode = channel?.pairingCode; status = "在两台设备上核对相同的 6 位码，再确认配对。"
            }
            armTimeout(seconds: 120, note: "配对超时，连接已关闭。可重新连接。")
        } else if type == 1 {
            guard let channel else { throw InkError.authentication }
            let message = try channel.open(Data(payload))
            if message.kind == .reject || message.kind == .cancel { disconnect(); status = "对方取消了连接或传输，本地文稿仍保留。"; return }
            if message.kind == .accept { remoteAccepted = true; updateReady(); return }
            guard ready else { throw InkError.unpaired }
            switch message.kind {
            case .requestCurrent, .requestDocument:
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let document = try await self.currentDocument?(message.kind == .requestDocument ? message.documentID : nil)
                        guard self.sessionToken == token, self.ready else { return }
                        if let document, document.trashedAt == nil { self.sendDocument(document) }
                        else { try self.send(TransferMessage(.receipt, note: "对方没有打开可传输的文稿。")) }
                    } catch { self.fail(error) }
                }
            case .document:
                guard let document = message.document, let checksum = message.checksum, let id = message.transferID else { throw InkError.invalidDocument }
                guard !receivedTransfers.contains(id) else { return }
                receivedTransfers.insert(id); transferring = true; status = "正在校验并保存离线副本…"
                Task { [weak self] in
                    guard let self, self.sessionToken == token, self.ready else { return }
                    do {
                        let note = try await self.receiveDocument?(document, checksum) ?? "已接收"
                        guard self.sessionToken == token else { return }
                        self.transferring = false; self.status = note; self.timer?.cancel()
                        try self.send(TransferMessage(.receipt, transferID: id, note: note))
                    } catch { self.fail(error) }
                }
            case .beginTransfer:
                guard incomingTransfer == nil, !transferring, let manifest = message.manifest, message.transferID == manifest.id else { throw InkError.invalidFrame }
                let checked = try manifest.validated()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineTransfers/" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                incomingTransfer = PreparedTransfer(manifest: checked, directory: directory); incomingFiles = []
                totalFiles = checked.items.count; completedFiles = 0; transferring = true
                status = "正在接收《\(checked.title)》，完整校验后保存。"
                armTimeout(seconds: 60, note: "目录传输超时，未提交的文件已丢弃。")
                try send(TransferMessage(.receipt, transferID: manifest.id))
            case .transferDocument:
                guard let transfer = incomingTransfer, let document = message.document, let checksum = message.checksum,
                      let receipt = message.transferID, let item = transfer.manifest.items.first(where: { $0.documentID == document.id }),
                      !incomingFiles.contains(document.id), checksum == item.checksum else { throw InkError.invalidDocument }
                let checked = try document.validated()
                guard checked.trashedAt == nil, checked.checksum == item.checksum, checked.content.utf8.count == item.byteCount else { throw InkError.invalidDocument }
                try JSONEncoder().encode(checked).write(to: transfer.documentURL(document.id), options: .atomic)
                incomingFiles.insert(document.id); completedFiles = incomingFiles.count
                status = "已接收 \(completedFiles)/\(totalFiles) 个文件，尚未提交。"
                armTimeout(seconds: 60, note: "目录传输超时，未提交的文件已丢弃。")
                try send(TransferMessage(.receipt, transferID: receipt))
            case .commitTransfer:
                guard let transfer = incomingTransfer, incomingFiles == Set(transfer.manifest.items.map(\.documentID)), let id = message.transferID, let receiveTransfer else { throw InkError.invalidDocument }
                status = "正在保存已校验的文件…"
                armTimeout(seconds: 120, note: "保存确认超时。请重新连接检查接收端结果。")
                commitTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let note = try await receiveTransfer(transfer)
                        guard self.sessionToken == token, !Task.isCancelled else { return }
                        transfer.remove(); self.incomingTransfer = nil; self.incomingFiles = []
                        self.transferring = false; self.timer?.cancel(); self.status = note
                        try self.send(TransferMessage(.receipt, transferID: id, note: note))
                        self.commitTask = nil
                    } catch { if self.sessionToken == token { self.fail(error) } }
                }
            case .receipt:
                if let waiter = receiptWaiter, waiter.0 == message.transferID {
                    receiptWaiter = nil; timer?.cancel()
                    if let note = message.note { status = note }
                    waiter.1.resume(); return
                }
                if message.transferID == transferID || message.transferID == nil { transferring = false; timer?.cancel(); status = message.note ?? "对方已保存"; transferID = nil }
            default: break
            }
        } else { throw InkError.invalidFrame }
    }
    func confirm(remember: Bool) {
        guard channel != nil, let remote else { return }
        do {
            if remember && !isTesting {
                try saveIdentity(identity); identityLoaded = true
                trusts[remote.deviceID.uuidString] = remote.identityKey.base64EncodedString()
                names[remote.deviceID.uuidString] = remote.name
                preferences.set(trusts, forKey: "trustedPeers"); preferences.set(names, forKey: "trustedNames")
                trustedNames = Array(names.values).sorted()
            }
            localAccepted = true; pairingCode = nil; awaitingPeer = true
            try send(TransferMessage(.accept)); updateReady()
        } catch { self.error = error.localizedDescription }
    }
    private func updateReady() {
        ready = localAccepted && remoteAccepted
        if ready { timer?.cancel(); pairingCode = nil; awaitingPeer = false; status = "安全连接已建立。请选择继续阅读或手动同步文件。" }
    }
    func requestCurrent(documentID: UUID? = nil) {
        guard ready else { return }
        do {
            transferring = true; status = "正在请求对方文稿…"
            try send(TransferMessage(documentID == nil ? .requestCurrent : .requestDocument, documentID: documentID))
            armTimeout(seconds: 45, note: "接收超时。源设备可能休眠或离线，请重试。")
        } catch { fail(error) }
    }
    /// 只有确认同步之后才调用。每个文件等到暂存确认再发送下一个，最后提交整个清单。
    func push(_ transfer: PreparedTransfer) async throws {
        guard ready, !transferring else { throw InkError.unpaired }
        let token = sessionToken
        transferring = true; completedFiles = 0; totalFiles = transfer.manifest.items.count
        defer { transfer.remove(); if sessionToken == token { transferring = false; timer?.cancel() } }
        try await sendAndWait(TransferMessage(.beginTransfer, transferID: transfer.manifest.id, manifest: transfer.manifest))
        for item in transfer.manifest.items {
            try Task.checkCancellation()
            guard sessionToken == token, ready else { throw CancellationError() }
            let document = try await Task.detached { try transfer.document(item) }.value
            status = "正在同步 \(completedFiles + 1)/\(totalFiles)：\(item.relativePath)"
            try await sendAndWait(TransferMessage(.transferDocument, document: document, transferID: UUID()))
            completedFiles += 1
        }
        status = "文件已发送，等待对方保存…"
        try await sendAndWait(TransferMessage(.commitTransfer, transferID: UUID()), seconds: 120)
    }
    private func sendAndWait(_ message: TransferMessage, seconds: UInt64 = 60) async throws {
        guard ready, receiptWaiter == nil, let id = message.transferID else { throw InkError.unpaired }
        try await withCheckedThrowingContinuation { continuation in
            receiptWaiter = (id, continuation)
            do {
                try send(message)
                armTimeout(seconds: seconds, note: "同步超时，请重新连接检查。未提交的文件会丢弃，冲突版本会保留。")
            } catch { receiptWaiter = nil; continuation.resume(throwing: error) }
        }
    }
    private func sendDocument(_ book: Manuscript) {
        guard ready else { return }
        do {
            let id = UUID(); transferID = id; transferring = true; status = "正在加密发送 \(book.title)…"
            try send(TransferMessage(.document, document: book, transferID: id))
            armTimeout(seconds: 45, note: "未收到保存确认。副本可能已保存，请重连同步确认，不会直接覆盖冲突版本。")
        } catch { fail(error) }
    }
    private func send(_ message: TransferMessage) throws {
        guard let channel else { throw InkError.authentication }
        try sendFrame(channel.seal(message), type: 1)
    }
    private func sendFrame(_ payload: Data, type: UInt8) throws {
        guard let connection else { throw InkError.authentication }
        var data = Data([type]); data.append(payload)
        let token = sessionToken
        connection.send(content: try FrameDecoder.frame(data), completion: .contentProcessed { [weak self] error in
            if let error { Task { @MainActor in if self?.sessionToken == token { self?.fail(error) } } }
        })
    }
    private func armTimeout(seconds: UInt64, note: String) {
        timer?.cancel(); timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.disconnect(); self.status = note
        }
    }
    func cancel() { try? send(TransferMessage(.cancel)); disconnect(); status = "已取消。已有离线副本和原文件均保留。" }
    func forgetAll() {
        trusts = [:]; names = [:]; trustedNames = []
        preferences.removeObject(forKey: "trustedPeers"); preferences.removeObject(forKey: "trustedNames")
        identity = Curve25519.Signing.PrivateKey(); identityLoaded = false
        disconnect(); status = "已撤销设备信任。下次连接需重新核对配对码。"
    }
    func disconnect() {
        sessionToken = UUID(); timer?.cancel(); timer = nil
        commitTask?.cancel(); commitTask = nil
        incomingTransfer?.remove(); incomingTransfer = nil; incomingFiles = []
        let waiter = receiptWaiter; receiptWaiter = nil; waiter?.1.resume(throwing: CancellationError())
        let old = connection; connection = nil; old?.stateUpdateHandler = nil; old?.cancel()
        channel = nil; handshake = nil; remote = nil; ready = false; pairingCode = nil
        localAccepted = false; remoteAccepted = false; awaitingPeer = false; transferring = false; transferID = nil
    }
    private func fail(_ error: Error) { self.error = error.localizedDescription; disconnect(); status = "连接失败，可重试。书库未向未配对设备开放。" }
}

#if DEBUG && targetEnvironment(simulator)
// 仅模拟器显式启用的集成测试：使用生产 TCP、分帧和认证路径，
// 不触发 Bonjour 发现、系统授权或持久配对身份。
extension NearbyService {
    var integrationConnected: Bool { connection != nil }
    func integrationListen(port: UInt16) throws {
        precondition(ProcessInfo.processInfo.arguments.contains("--nearby-integration"))
        let local = parameters
        local.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: local)
        listener.newConnectionHandler = { [weak self] incoming in Task { @MainActor in
            guard let self, self.connection == nil else { incoming.cancel(); return }
            self.attach(incoming)
        } }
        listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
            if case .ready = state { self?.status = "integration-listening" }
            if case let .failed(error) = state { self?.fail(error) }
        } }
        self.listener = listener; running = true; listener.start(queue: .main)
    }
    func integrationConnect(port: UInt16) {
        error = nil
        connect(NearbyPeer(id: "loopback", name: "Simulator loopback", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)))
    }
    func integrationCancelStaged(_ transfer: PreparedTransfer) async throws {
        defer { transfer.remove() }
        try await sendAndWait(TransferMessage(.beginTransfer, transferID: transfer.manifest.id, manifest: transfer.manifest))
        let document = try transfer.document(transfer.manifest.items[0])
        try await sendAndWait(TransferMessage(.transferDocument, document: document, transferID: UUID()))
        cancel()
    }
    func integrationUnpairedRequest() throws { try send(TransferMessage(.requestCurrent)) }
    func integrationSendCurrent() async throws {
        guard let document = try await currentDocument?(nil) else { throw InkError.invalidDocument }
        sendDocument(document)
    }
    func integrationInterrupt(_ document: Manuscript) async throws {
        guard ready, let channel, let connection else { throw InkError.unpaired }
        var payload = Data([1]); payload.append(try channel.seal(TransferMessage(.document, document: document, transferID: UUID())))
        let frame = try FrameDecoder.frame(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(frame.prefix(128)), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        cancel()
    }
}
#endif
