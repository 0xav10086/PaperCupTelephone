//
//  HTTPServer.swift (修复版本)
//

import Foundation
import Network

class HTTPServer: ObservableObject {
    // MARK: - 发布属性
    @Published var serverURL: String = ""
    @Published var isRunning: Bool = false
    @Published var errorMessage: String?
    @Published var connectedClients: Int = 0
    
    // MARK: - 服务器组件
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    
    // MARK: - 配置
    private let port: NWEndpoint.Port = 65532
    private let queue = DispatchQueue(label: "HTTPServer", qos: .userInitiated)
    
    // MARK: - 静态资源缓存
    private var cachedFiles: [String: Data] = [:]
    
    // MARK: - 初始化
    init() {
        preloadStaticFiles()
    }
    
    deinit {
        stop()
    }
    
    // MARK: - 预加载静态文件
    private func preloadStaticFiles() {
        let files = ["index.html", "audio-visualizer.css", "audio-visualizer.js"]
        
        for fileName in files {
            if let fileURL = Bundle.main.url(forResource: fileName, withExtension: nil),
               let fileData = try? Data(contentsOf: fileURL) {
                cachedFiles[fileName] = fileData
                print("✅ 预加载文件: \(fileName) - \(fileData.count) 字节")
            } else {
                print("❌ 无法加载文件: \(fileName)")
            }
        }
    }
    
    // MARK: - 公共方法
    func start() throws {
        guard !isRunning else { return }
        
        do {
            print("🌐 启动HTTP服务器...")
            
            // 创建 TCP 服务器
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true
            
            listener = try NWListener(using: parameters, on: port)
            
            setupListenerCallbacks()
            listener?.start(queue: queue)
            
            DispatchQueue.main.async {
                self.isRunning = true
                self.errorMessage = nil
            }
            
            updateServerURL()
            print("✅ HTTP服务器已启动 - 端口: \(port)")
            
        } catch {
            let errorMsg = "❌ 启动HTTP服务器失败: \(error.localizedDescription)"
            DispatchQueue.main.async {
                self.errorMessage = errorMsg
            }
            print(errorMsg)
            throw error
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        print("🛑 停止HTTP服务器...")
        
        listener?.cancel()
        listener = nil
        
        // 关闭所有连接
        for (_, connection) in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        
        DispatchQueue.main.async {
            self.isRunning = false
            self.serverURL = ""
            self.connectedClients = 0
        }
        
        print("✅ HTTP服务器已停止")
    }
    
    // MARK: - 私有方法
    private func setupListenerCallbacks() {
        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("✅ HTTP服务器监听就绪")
                case .failed(let error):
                    let errorMsg = "❌ HTTP服务器错误: \(error.localizedDescription)"
                    self?.errorMessage = errorMsg
                    print(errorMsg)
                    self?.stop()
                case .cancelled:
                    print("ℹ️ HTTP服务器已取消")
                case .waiting(let error):
                    print("⏳ HTTP服务器等待: \(error.localizedDescription)")
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
        let connectionID = ObjectIdentifier(connection)
        activeConnections[connectionID] = connection
        
        updateClientCount()
        setupConnectionCallbacks(connection)
        connection.start(queue: queue)
        
        print("📱 新的HTTP连接，当前连接数: \(activeConnections.count)")
    }

    private func setupConnectionCallbacks(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("✅ HTTP连接就绪: \(connection.endpoint)")
                self?.receiveHTTPRequest(connection)
            case .failed(let error):
                print("❌ HTTP连接失败: \(error.localizedDescription)")
                self?.removeConnection(connection)
            case .cancelled:
                print("ℹ️ HTTP连接已取消")
                self?.removeConnection(connection)
            default:
                break
            }
        }
    }

    private func receiveHTTPRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            
            if let data = data, let requestString = String(data: data, encoding: .utf8) {
                print("📨 收到HTTP请求: \(requestString.prefix(200))...")
                self.handleHTTPRequest(requestString, connection: connection)
            } else if let error = error {
                print("❌ 接收HTTP请求错误: \(error)")
                self.removeConnection(connection)
            } else {
                print("⚠️ 收到空数据或无法解码的请求")
                self.sendErrorResponse(connection, status: "400 Bad Request")
            }
        }
    }
    
    private func handleHTTPRequest(_ requestString: String, connection: NWConnection) {
        let lines = requestString.components(separatedBy: .newlines)
        guard let firstLine = lines.first else {
            sendErrorResponse(connection, status: "400 Bad Request")
            return
        }
        
        let components = firstLine.components(separatedBy: .whitespaces)
        guard components.count >= 2 else {
            sendErrorResponse(connection, status: "400 Bad Request")
            return
        }
        
        let method = components[0]
        var path = components[1]
        
        // 规范化路径
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        
        // 移除查询参数
        if let questionMarkRange = path.range(of: "?") {
            path = String(path[..<questionMarkRange.lowerBound])
        }
        
        print("🌐 HTTP请求: \(method) \(path)")
        
        // 路由处理
        switch path {
        case "/", "/index.html":
            serveFile("index.html", connection: connection)
        case "/audio-visualizer.css":
            serveFile("audio-visualizer.css", connection: connection)
        case "/audio-visualizer.js":
            serveFile("audio-visualizer.js", connection: connection)
        case "/status":
            serveStatusJSON(connection)
        default:
            // 对于所有其他路径，返回主页面
            print("🔀 未知路径: \(path)，返回主页面")
            serveFile("index.html", connection: connection)
        }
    }
    
    private func serveFile(_ fileName: String, connection: NWConnection) {
        guard let fileData = cachedFiles[fileName] else {
            print("❌ 找不到静态文件: \(fileName)")
            serve404(connection)
            return
        }
        
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        
        let contentType: String
        switch fileExtension {
        case "html":
            contentType = "text/html; charset=utf-8"
        case "css":
            contentType = "text/css; charset=utf-8"
        case "js":
            contentType = "application/javascript"
        default:
            contentType = "application/octet-stream"
        }
        
        let responseHeader = "HTTP/1.1 200 OK\r\n" +
                           "Content-Type: \(contentType)\r\n" +
                           "Content-Length: \(fileData.count)\r\n" +
                           "Connection: keep-alive\r\n" +
                           "Cache-Control: no-cache\r\n" +
                           "\r\n"
        
        guard let headerData = responseHeader.data(using: .utf8) else {
            print("❌ 无法编码响应头")
            return
        }
        
        // 创建复合数据：头部 + 文件内容
        var responseData = Data()
        responseData.append(headerData)
        responseData.append(fileData)
        
        // 一次性发送完整响应
        connection.send(content: responseData, completion: .contentProcessed({ [weak self] error in
            if let error = error {
                print("❌ 发送响应失败: \(error)")
                self?.removeConnection(connection)
            } else {
                print("✅ 成功提供文件: \(fileName)")
                // 保持连接活跃，等待下一个请求
                self?.receiveHTTPRequest(connection)
            }
        }))
    }
    
    private func serveStatusJSON(_ connection: NWConnection) {
        let status: [String: Any] = [
            "server": [
                "running": isRunning,
                "clients": connectedClients,
                "url": serverURL
            ],
            "timestamp": Date().timeIntervalSince1970
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: status, options: .prettyPrinted)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            
            let response = "HTTP/1.1 200 OK\r\n" +
                         "Content-Type: application/json\r\n" +
                         "Content-Length: \(jsonString.utf8.count)\r\n" +
                         "Connection: close\r\n" +
                         "\r\n" +
                         jsonString
            
            sendResponse(connection, content: response)
            
        } catch {
            print("❌ 序列化状态JSON失败: \(error)")
            sendErrorResponse(connection, status: "500 Internal Server Error")
        }
    }
    
    private func serve404(_ connection: NWConnection) {
        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>404 Not Found</title>
            <style>
                body { 
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif; 
                    text-align: center; 
                    padding: 50px; 
                    background: linear-gradient(135deg, #667eea, #764ba2);
                    color: white;
                }
                h1 { font-size: 3em; margin-bottom: 20px; }
            </style>
        </head>
        <body>
            <h1>404 - 页面未找到</h1>
            <p>请求的页面不存在，请检查URL是否正确。</p>
            <p><a href="/" style="color: white;">返回首页</a></p>
        </body>
        </html>
        """
        
        let response = "HTTP/1.1 404 Not Found\r\n" +
                     "Content-Type: text/html; charset=utf-8\r\n" +
                     "Content-Length: \(htmlContent.utf8.count)\r\n" +
                     "Connection: close\r\n" +
                     "\r\n" +
                     htmlContent
        
        sendResponse(connection, content: response)
    }
    
    private func sendErrorResponse(_ connection: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\n" +
                     "Connection: close\r\n" +
                     "\r\n"
        
        sendResponse(connection, content: response)
    }
    
    private func sendResponse(_ connection: NWConnection, content: String) {
        guard let data = content.data(using: .utf8) else {
            print("❌ 无法编码HTTP响应")
            return
        }
        
        connection.send(content: data, completion: .contentProcessed({ [weak self] error in
            if let error = error {
                print("❌ 发送HTTP响应失败: \(error)")
            }
            // 对于非keep-alive连接，关闭连接
            if content.contains("Connection: close") {
                self?.removeConnection(connection)
            }
        }))
    }
    
    private func removeConnection(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        activeConnections.removeValue(forKey: connectionID)
        connection.cancel()
        
        updateClientCount()
        print("📱 HTTP连接已关闭，剩余连接数: \(activeConnections.count)")
    }
    
    private func updateClientCount() {
        DispatchQueue.main.async {
            self.connectedClients = self.activeConnections.count
        }
    }
    
    private func updateServerURL() {
        var addresses: [String] = []
        
        // 获取本机IP地址
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            DispatchQueue.main.async {
                self.serverURL = "http://localhost:\(self.port)"
            }
            return
        }
        
        defer { freeifaddrs(ifaddr) }
        
        var currentPtr = ifaddr
        while currentPtr != nil {
            let interface = currentPtr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // 选择所有网络接口
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let address = String(cString: hostname)
                    if address != "127.0.0.1" && address != "0.0.0.0" {
                        addresses.append("http://\(address):\(port)")
                    }
                }
            }
            currentPtr = interface.ifa_next
        }
        
        // 显示找到的地址，如果没有找到则使用localhost
        let finalURL = addresses.isEmpty ? "http://localhost:\(port)" : addresses.joined(separator: " 或 ")
        
        DispatchQueue.main.async {
            self.serverURL = finalURL
        }
        
        print("📍 服务器地址: \(finalURL)")
    }
}
