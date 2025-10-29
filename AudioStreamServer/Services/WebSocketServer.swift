//
//  WebSocketServer.swift
//  AudioStreamServer
//
//  Created by 0xav10086 on 2025/10/29.
//

import Foundation
import Network
import Combine

class WebSocketServer: ObservableObject {
    // MARK: - 发布属性
    @Published var connectedClients: [ClientInfo] = []
    @Published var isRunning: Bool = false
    @Published var errorMessage: String?
    @Published var totalBytesSent: Int64 = 0
    @Published var activeConnections: Int = 0
    
    // MARK: - 服务器组件
    private var listener: NWListener?
    private var clientConnections: [UUID: NWConnection] = [:]
    private var audioCaptureService: AudioCaptureService?
    
    // MARK: - 配置
    private let port: NWEndpoint.Port = 65533
    private let queue = DispatchQueue(label: "WebSocketServer", qos: .userInitiated)
    
    // MARK: - 统计信息
    private var startTime: Date?
    private var totalPacketsSent: Int64 = 0
    private var lastStatsUpdate: Date = Date()
    
    // FIX: 确保 cancellables 是 internal 访问级别，供 ContentView 使用
    var cancellables = Set<AnyCancellable>()
    
    // MARK: - 客户端信息
    struct ClientInfo: Identifiable {
        let id = UUID()
        let connection: NWConnection
        let connectTime: Date
        var deviceInfo: String = "等待识别..."
        var bytesReceived: Int64 = 0
        var lastActivity: Date = Date()
        var isActive: Bool = true
        
        // 计算属性：连接时长
        var connectionDuration: TimeInterval {
            return Date().timeIntervalSince(connectTime)
        }
    }
    
    // MARK: - 初始化
    init() {}
    
    deinit {
        stop()
    }
    
    // MARK: - 公共方法
    // MARK: - 公共方法（确保在主线程更新状态）
        func start() throws {
            guard !isRunning else { return }
            
            do {
                print("🔌 启动WebSocket服务器...")
                
                // 创建 WebSocket 服务器
                let parameters = NWParameters(tls: nil)
                parameters.allowLocalEndpointReuse = true
                parameters.includePeerToPeer = true
                
                // 配置 WebSocket 选项
                let webSocketOptions = NWProtocolWebSocket.Options()
                webSocketOptions.autoReplyPing = true
                webSocketOptions.maximumMessageSize = 65536
                
                parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
                
                listener = try NWListener(using: parameters, on: port)
                
                setupListenerCallbacks()
                listener?.start(queue: queue)
                
                // 在主线程更新状态
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.errorMessage = nil
                    self.startTime = Date()
                }
                
                print("✅ WebSocket服务器已启动 - 端口: \(port)")
                
            } catch {
                let errorMsg = "❌ 启动WebSocket服务器失败: \(error.localizedDescription)"
                
                // 在主线程更新错误信息
                DispatchQueue.main.async {
                    self.errorMessage = errorMsg
                }
                
                print(errorMsg)
                throw error
            }
        }
        
        func stop() {
            guard isRunning else { return }
            
            print("🛑 停止WebSocket服务器...")
            
            listener?.cancel()
            listener = nil
            
            // 关闭所有客户端连接
            for (_, connection) in clientConnections {
                connection.cancel()
            }
            clientConnections.removeAll()
            
            // 在主线程更新 @Published 属性
            DispatchQueue.main.async {
                self.connectedClients.removeAll()
                self.activeConnections = 0
                self.isRunning = false
                self.totalBytesSent = 0
            }
            
            // 取消音频订阅
            cancellables.removeAll()
            
            startTime = nil
            totalPacketsSent = 0
            
            print("✅ WebSocket服务器已停止")
        }
    
    // MARK: - 音频服务集成
    func setAudioCaptureService(_ service: AudioCaptureService) {
        self.audioCaptureService = service
        setupAudioSubscription()
    }
    
    // MARK: - 私有方法
    private func setupListenerCallbacks() {
        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("✅ WebSocket服务器监听就绪")
                case .failed(let error):
                    let errorMsg = "❌ WebSocket服务器错误: \(error.localizedDescription)"
                    self?.errorMessage = errorMsg
                    print(errorMsg)
                    self?.stop()
                case .cancelled:
                    print("ℹ️ WebSocket服务器已取消")
                case .waiting(let error):
                    print("⏳ WebSocket服务器等待: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
            let clientId = UUID()
            let clientInfo = ClientInfo(
                connection: connection,
                connectTime: Date(),
                deviceInfo: "等待识别..."
            )
            
            // 存储连接
            clientConnections[clientId] = connection
            
            // 在主线程更新 @Published 属性
            DispatchQueue.main.async {
                self.connectedClients.append(clientInfo)
                self.activeConnections = self.clientConnections.count
            }
            
            print("📱 新的客户端连接，ID: \(clientId)，当前连接数: \(clientConnections.count)")
            
            setupConnectionCallbacks(connection, clientId: clientId)
            connection.start(queue: queue)
            
            // 发送音频格式信息给新客户端
            sendAudioFormat(to: connection)
    }
    
    private func setupConnectionCallbacks(_ connection: NWConnection, clientId: UUID) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("✅ 客户端连接就绪: \(clientId)")
                self?.updateClientInfo(connection, clientId: clientId)
                self?.startReceivingMessages(from: connection, clientId: clientId)
            case .failed(let error):
                print("❌ 客户端连接失败: \(error.localizedDescription)")
                self?.removeConnection(clientId: clientId)
            case .cancelled:
                print("ℹ️ 客户端连接已取消: \(clientId)")
                self?.removeConnection(clientId: clientId)
            default:
                break
            }
        }
    }
    
    private func updateClientInfo(_ connection: NWConnection, clientId: UUID) {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return }
        
        let deviceInfo: String
        switch endpoint {
        case .hostPort(let host, let port):
            deviceInfo = "iPad - \(host):\(port)"
        case .service(let name, _, _, _):
            deviceInfo = name
        case .unix(let path):
            deviceInfo = path
        @unknown default:
            deviceInfo = "移动设备"
        }
        
        // 立即更新客户端信息
        DispatchQueue.main.async {
            if let index = self.connectedClients.firstIndex(where: { $0.id == clientId }) {
                self.connectedClients[index].deviceInfo = deviceInfo
                self.connectedClients[index].lastActivity = Date()
                self.connectedClients[index].isActive = true
            }
        }
        
        print("📍 客户端连接: \(deviceInfo)")
    }
    
    private func removeConnection(clientId: UUID) {
            guard let connection = clientConnections[clientId] else { return }
            
            connection.cancel()
            clientConnections.removeValue(forKey: clientId)
            
            // 在主线程更新 @Published 属性
            DispatchQueue.main.async {
                self.connectedClients.removeAll { $0.id == clientId }
                self.activeConnections = self.clientConnections.count
            }
            
            print("📱 客户端已断开，ID: \(clientId)，剩余连接数: \(clientConnections.count)")
    }
    
    private func setupAudioSubscription() {
        audioCaptureService?.audioDataPublisher
            .receive(on: queue)
            .sink { [weak self] audioData in
                self?.broadcastAudioData(audioData)
            }
            .store(in: &cancellables)
        
        print("🎵 音频数据订阅已建立")
    }
    
    private func broadcastAudioData(_ audioData: Data) {
        guard !clientConnections.isEmpty else { return }
        
        let bytesToAdd = Int64(audioData.count)
        
        // 立即在主线程更新统计信息
        DispatchQueue.main.async {
            self.totalPacketsSent += 1
            self.totalBytesSent += bytesToAdd
            
            // 同时更新所有活跃客户端的接收字节数
            for (clientId, _) in self.clientConnections {
                if let index = self.connectedClients.firstIndex(where: { $0.id == clientId }) {
                    self.connectedClients[index].bytesReceived += bytesToAdd
                    self.connectedClients[index].lastActivity = Date()
                }
            }
        }
        
        // 向所有客户端广播音频数据
        for (clientId, connection) in clientConnections {
            sendAudioData(audioData, to: connection, clientId: clientId)
        }
    }
    
    private func sendAudioData(_ audioData: Data, to connection: NWConnection, clientId: UUID) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "audioData",
            metadata: [metadata]
        )
        
        connection.send(
            content: audioData,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed({ [weak self] error in
                if let error = error {
                    print("❌ 发送音频数据失败到客户端 \(clientId): \(error)")
                    // 发送失败时移除连接
                    self?.removeConnection(clientId: clientId)
                }
            })
        )
    }
    
    private func sendAudioFormat(to connection: NWConnection) {
        guard let audioService = audioCaptureService else { return }
        
        let formatMessage = AudioFormatMessage(
            sampleRate: audioService.sampleRate,
            channels: audioService.channelCount,
            format: "float32"
        )
        
        sendTextMessage(formatMessage, to: connection)
    }
    
    private func sendTextMessage<T: Encodable>(_ message: T, to connection: NWConnection) {
        do {
            let jsonData = try JSONEncoder().encode(message)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                print("❌ 无法将JSON数据转换为字符串")
                return
            }
            
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: "controlMessage",
                metadata: [metadata]
            )
            
            connection.send(
                content: jsonString.data(using: .utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed({ error in
                    if let error = error {
                        print("❌ 发送文本消息失败: \(error)")
                    }
                })
            )
            
        } catch {
            print("❌ 编码消息失败: \(error)")
        }
    }
    
    private func startReceivingMessages(from connection: NWConnection, clientId: UUID) {
        connection.receiveMessage { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            
            if let data = data, let context = context {
                self.processReceivedMessage(
                    data: data,
                    context: context,
                    from: connection,
                    clientId: clientId
                )
            }
            
            if let error = error {
                print("❌ 接收消息错误: \(error)")
                self.removeConnection(clientId: clientId)
            } else {
                // 继续接收下一条消息
                self.startReceivingMessages(from: connection, clientId: clientId)
            }
        }
    }
    
    private func processReceivedMessage(data: Data, context: NWConnection.ContentContext,
                                      from connection: NWConnection, clientId: UUID) {
        // 获取 WebSocket 元数据
        let webSocketMetadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
        
        switch webSocketMetadata?.opcode {
        case .text:
            if let message = String(data: data, encoding: .utf8) {
                handleTextMessage(message, from: connection, clientId: clientId)
            }
        case .binary:
            handleBinaryMessage(data, from: connection, clientId: clientId)
        case .ping:
            print("🏓 收到Ping来自客户端 \(clientId)")
            // 自动回复Pong（由WebSocket选项处理）
        case .pong:
            print("🏓 收到Pong来自客户端 \(clientId)")
        default:
            print("📨 收到未知类型的消息来自客户端 \(clientId)")
        }
        
        // 更新客户端活动时间
        if let index = connectedClients.firstIndex(where: { $0.id == clientId }) {
            DispatchQueue.main.async {
                self.connectedClients[index].lastActivity = Date()
                self.connectedClients[index].bytesReceived += Int64(data.count)
            }
        }
    }
    
    private func handleTextMessage(_ message: String, from connection: NWConnection, clientId: UUID) {
        print("📝 收到文本消息来自客户端 \(clientId): \(message)")
        
        // 解析JSON消息
        guard let data = message.data(using: .utf8) else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                handleJSONMessage(json, from: connection, clientId: clientId)
            }
        } catch {
            print("❌ 解析JSON消息失败: \(error)")
        }
    }
    
    private func handleJSONMessage(_ message: [String: Any], from connection: NWConnection, clientId: UUID) {
        guard let type = message["type"] as? String else { return }
        
        switch type {
        case "client_info":
            if let deviceInfo = message["device_info"] as? String {
                updateClientDeviceInfo(clientId: clientId, deviceInfo: deviceInfo)
            }
        case "ping":
            // 回复pong
            let pongMessage = ["type": "pong", "timestamp": Date().timeIntervalSince1970] as [String: Any]
            if let pongData = try? JSONSerialization.data(withJSONObject: pongMessage) {
                sendTextMessage(pongData, to: connection)
            }
        default:
            print("❓ 未知消息类型: \(type)")
        }
    }
    
    private func handleBinaryMessage(_ data: Data, from connection: NWConnection, clientId: UUID) {
        print("📦 收到二进制数据来自客户端 \(clientId)，大小: \(data.count) 字节")
        // 这里可以处理客户端发送的二进制数据（如果有需要）
    }
    
    private func updateClientDeviceInfo(clientId: UUID, deviceInfo: String) {
        if let index = connectedClients.firstIndex(where: { $0.id == clientId }) {
            DispatchQueue.main.async {
                self.connectedClients[index].deviceInfo = deviceInfo
            }
            print("📱 客户端 \(clientId) 设备信息: \(deviceInfo)")
        }
    }
    
    // 工具方法 - 在主线程安全的字节格式化
    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
    
    // MARK: - 公共统计方法
    var uptime: TimeInterval {
        return startTime.map { Date().timeIntervalSince($0) } ?? 0
    }
    
    var packetsPerSecond: Double {
        let uptime = self.uptime
        return uptime > 0 ? Double(totalPacketsSent) / uptime : 0
    }
}

// MARK: - 消息协议
struct AudioFormatMessage: Codable {
    let type: String
    let sampleRate: Double
    let channels: UInt32
    let format: String
    
    init(sampleRate: Double, channels: UInt32, format: String) {
        self.type = "audio_config"
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = format
    }
}

struct AudioDataMessage: Codable {
    let type: String
    let timestamp: TimeInterval
    let data: Data
    
    init(timestamp: TimeInterval, data: Data) {
        self.type = "audio_data"
        self.timestamp = timestamp
        self.data = data
    }
}

struct ServerInfoMessage: Codable {
    let type: String
    let version: String
    let uptime: TimeInterval
    let clients: Int
    
    init(uptime: TimeInterval, clients: Int) {
        self.type = "server_info"
        self.version = "1.0.0"
        self.uptime = uptime
        self.clients = clients
    }
}
