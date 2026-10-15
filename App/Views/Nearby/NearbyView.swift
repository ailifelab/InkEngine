import SwiftUI
import InkCore

struct NearbyView: View {
    @ObservedObject var service: NearbyService
    @ObservedObject var model: AppModel
    @State private var remember = false
    @State private var confirmingSync = false
    @State private var confirmAfterConnecting = false
    @State private var showLocalDocuments = false
    @State private var localFolderID: UUID?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if let received = model.availableReceivedSync {
                    Section("已收到 · \(received.count) 个文件") {
                        Label(received.title, systemImage: received.entry.isFolder ? "folder" : "doc.text")
                        #if os(iOS)
                        Text("已保存到本机文稿。历史记录中按文件名或目录别名查找，无需再用系统文件选择器导入。")
                            .font(.caption).foregroundStyle(.secondary)
                        #else
                        Text("可从历史记录打开收到的副本；另存为后关联你选择的本地文件。").font(.caption).foregroundStyle(.secondary)
                        #endif
                        Button(received.entry.isFolder ? "打开目录" : "打开文件") {
                            // 历史全部固定时仍可打开收到的目录，章节不依赖历史条目是否被保留。
                            #if os(iOS)
                            if received.entry.isFolder && !model.history.entries.contains(where: { $0.id == received.entry.id }) {
                                localFolderID = received.entry.id; showLocalDocuments = true
                            } else { Task { if await model.openReceivedSync() { model.showNearby = false; dismiss() } } }
                            #else
                            Task { if await model.openReceivedSync() { model.showNearby = false; dismiss() } }
                            #endif
                        }.disabled(service.transferring).accessibilityIdentifier("openReceivedSync")
                    }.listRowBackground(model.readingTheme.sidebar)
                }
                #if os(iOS)
                Section("文件保存位置") {
                    Text("同步收到的文件和目录保存在这台设备的 App 内，可以离线编辑、阅读和朗读。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("查看本机文稿") { localFolderID = nil; showLocalDocuments = true }.accessibilityIdentifier("browseLocalDocuments")
                }.listRowBackground(model.readingTheme.sidebar)
                #endif
                if let entry = model.pendingSync {
                    Section("待同步内容") {
                        Label(selectionTitle(entry), systemImage: entry.isFolder ? "folder" : "doc.text")
                        if entry.isFolder, let folder = model.novels.first(where: { $0.id == entry.id }) {
                            Text("\(folder.orderedBooks(from: model.books).count) 个文件 · 保留章节目录").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("选择设备后需要确认。只发送这一文件或目录，双方有修改时保留冲突副本。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.listRowBackground(model.readingTheme.sidebar)
                }
                Section("同一局域网直传") {
                    Text(service.status).font(.callout)
                    if !service.running { Button("开始发现附近设备") { service.start() }.buttonStyle(KeycapButtonStyle(selected: true)) }
                    else { Button("重新发现") { service.stop(); service.start() } }
                    Text("请保持两端 App 前台且设备唤醒。首次连接时，另一端也需要开始发现并核对配对码；两端记住配对后，打开 App 就能发现设备。同步始终需要手动确认。局域网权限可在系统设置中调整。")
                        .font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(model.readingTheme.sidebar)
                if let code = service.pairingCode {
                    Section("配对 \(service.peerName)") {
                        Text(code).font(.system(size: 38, weight: .semibold, design: .monospaced)).tracking(6)
                        Text("在两台设备上核对这 6 位码完全一致。确认后允许此设备收发文稿。")
                        Toggle("记住此设备", isOn: $remember)
                        Text("两端都选择记住可在以后自动认证。只保存本应用生成的配对密钥，不读取账号密码；不开启时仅本次会话信任。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("配对码一致，确认信任") { service.confirm(remember: remember) }.buttonStyle(KeycapButtonStyle(selected: true))
                        Button("取消配对", role: .cancel) { service.cancel() }
                    }.listRowBackground(model.readingTheme.sidebar)
                } else if service.awaitingPeer { Section { ProgressView("等待对方确认配对…"); Button("取消") { service.cancel() } }.listRowBackground(model.readingTheme.sidebar) }
                if service.ready {
                    Section("已加密连接 · \(service.peerName)") {
                        Button("继续对方当前文稿") { service.requestCurrent(documentID: model.pendingHandoff); model.pendingHandoff = nil }
                        if model.pendingSync != nil {
                            Button("确认同步到 \(service.peerName)…") { confirmingSync = true }
                                .disabled(service.transferring).accessibilityIdentifier("confirmSyncSelection")
                        } else if let book = model.book {
                            Button("同步当前文稿到 \(service.peerName)…") { model.pendingSync = .init(id: book.id); confirmingSync = true }
                                .disabled(service.transferring).accessibilityIdentifier("syncCurrentToPeer")
                        }
                        Text("收到的正文与段落位置会保存为离线副本。双方修改时保留冲突副本；同步不会扫描或发送整个书库。")
                            .font(.caption).foregroundStyle(.secondary)
                        if service.transferring { ProgressView("传输中 \(service.completedFiles)/\(service.totalFiles)…") }
                        Button("取消传输 / 断开") { service.cancel() }
                    }.listRowBackground(model.readingTheme.sidebar)
                } else if service.running && service.pairingCode == nil && !service.awaitingPeer {
                    Section("附近设备") {
                        ForEach(service.peers) { peer in Button { confirmAfterConnecting = model.pendingSync != nil; service.connect(peer) } label: { Label(peer.name, systemImage: "desktopcomputer") } }
                        if service.peers.isEmpty { Text("暂无设备。请在另一端也打开此面板并开始发现。") }
                        Button("取消连接") { service.cancel() }
                    }.listRowBackground(model.readingTheme.sidebar)
                }
                if !service.trustedNames.isEmpty { Section("已记住设备") { ForEach(service.trustedNames, id: \.self) { Text($0) }; Button("撤销全部设备信任", role: .destructive) { service.forgetAll() } }.listRowBackground(model.readingTheme.sidebar) }
                if let error = service.error { Section("可重试的错误") { Text(error).foregroundStyle(.red); Button("清除提示") { service.error = nil } }.listRowBackground(model.readingTheme.sidebar) }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            .background(model.readingTheme.background.ignoresSafeArea()).foregroundStyle(model.readingTheme.foreground)
            .navigationTitle("附近设备")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(model.readingTheme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { if service.transferring { service.cancel() }; model.showNearby = false; dismiss() } label: { Text("完成").frame(minWidth: 40).fixedSize(horizontal: true, vertical: false) }
                        .buttonStyle(KeycapButtonStyle(compact: true))
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("closeNearby")
                }
                #if os(iOS)
                .sharedBackgroundVisibility(.hidden)
                #endif
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showLocalDocuments) {
            LocalDocumentsView(model: model, folderID: localFolderID, onClose: { showLocalDocuments = false }) { model.showNearby = false; dismiss() }.buttonStyle(KeycapButtonStyle())
        }
        #endif
        .onChange(of: service.ready) { _, ready in
            if ready && confirmAfterConnecting && model.pendingSync != nil { confirmAfterConnecting = false; confirmingSync = true }
        }
        .alert("同步到 \(service.peerName)？", isPresented: $confirmingSync) {
            Button("确认同步") { Task { await model.confirmSync() } }.accessibilityIdentifier("performSync")
            Button("取消", role: .cancel) { }
        } message: {
            if let entry = model.pendingSync { Text("将《\(selectionTitle(entry))》同步到此设备。冲突版本会同时保留。") }
        }
        .frame(minWidth: 300, idealWidth: 510, minHeight: 420, idealHeight: 620)
    }
    private func selectionTitle(_ entry: RecentEntry) -> String {
        entry.isFolder ? model.novels.first(where: { $0.id == entry.id })?.alias ?? "目录" : model.books.first(where: { $0.id == entry.id })?.fileName ?? "当前文稿"
    }

}
