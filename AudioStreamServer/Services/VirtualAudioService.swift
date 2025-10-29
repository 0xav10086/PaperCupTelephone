//
//  VirtualAudioService.swift (修复版本)
//

import Foundation
import AVFoundation
import Combine

class AudioCaptureService: NSObject, ObservableObject {
    // MARK: - 发布属性
    @Published var audioLevel: Double = 0.0
    @Published var isCapturing: Bool = false
    @Published var errorMessage: String?
    @Published var audioFormat: String = "未配置"
    @Published var bufferStatus: String = "空闲"
    
    // MARK: - 音频配置
    private let bufferSize: AVAudioFrameCount = 256
    private var audioFormatDesc: AVAudioFormat?
    
    // MARK: - 音频引擎组件
    private var audioEngine: AVAudioEngine?
    
    // MARK: - 音频数据处理
    private var audioBufferSubject = PassthroughSubject<Data, Never>()
    var audioDataPublisher: AnyPublisher<Data, Never> {
        audioBufferSubject.eraseToAnyPublisher()
    }
    
    // MARK: - 统计信息
    private var totalFramesCaptured: Int64 = 0
    private var lastProcessTime: Date?
    private var bufferQueue: [Data] = []
    private let maxBufferQueueSize = 10
    
    // MARK: - 音频格式属性
    var sampleRate: Double {
        return audioFormatDesc?.sampleRate ?? 48000.0
    }
    
    var channelCount: UInt32 {
        return audioFormatDesc?.channelCount ?? 2
    }
    
    // MARK: - 生命周期
    override init() {
        super.init()
        setupAudioSession()
    }
    
    deinit {
        stopCapture()
    }
    
    // MARK: - 公共方法
    func startCapture() throws {
            guard !isCapturing else { return }
            
            do {
                print("🎧 开始音频捕获...")
                
                // 重置状态
                resetCaptureState()
                
                // 创建并配置音频引擎
                try setupAudioEngine()
                
                // 启动音频引擎
                try audioEngine?.start()
                
                // 在主线程更新状态
                DispatchQueue.main.async {
                    self.isCapturing = true
                    self.errorMessage = nil
                    self.bufferStatus = "运行中"
                }
                
                print("✅ 音频捕获已启动 - 格式: \(self.audioFormat)")
                
            } catch {
                let errorMsg = "❌ 启动音频捕获失败: \(error.localizedDescription)"
                
                // 在主线程更新错误信息
                DispatchQueue.main.async {
                    self.errorMessage = errorMsg
                    self.bufferStatus = "错误"
                }
                
                print(errorMsg)
                throw error
            }
        }
        
        func stopCapture() {
            guard isCapturing else { return }
            
            print("🛑 停止音频捕获...")
            
            audioEngine?.stop()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine = nil
            
            // 在主线程更新状态
            DispatchQueue.main.async {
                self.isCapturing = false
                self.audioLevel = 0.0
                self.bufferStatus = "已停止"
            }
            
            bufferQueue.removeAll()
            
            print("✅ 音频捕获已停止")
    }
    
    // MARK: - 音频会话配置
    private func setupAudioSession() {
        print("✅ macOS 音频会话配置完成")
    }
    
    // MARK: - 音频引擎配置
    private func setupAudioEngine() throws {
        audioEngine = AVAudioEngine()
        
        guard let audioEngine = audioEngine else {
            throw NSError(domain: "AudioCaptureService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建音频引擎"])
        }
        
        let inputNode = audioEngine.inputNode
        
        // 获取输入格式
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioCaptureService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "输入节点格式无效"])
        }
        
        audioFormatDesc = inputFormat
        updateAudioFormatDisplay()
        
        print("🎛️ 音频输入格式: \(inputFormat.description)")
        
        // 安装音频捕获tap
        installAudioTap(inputNode: inputNode, format: inputFormat)
        
        // 连接节点（虽然我们不需要输出，但保持引擎运行）
        audioEngine.connect(inputNode, to: audioEngine.mainMixerNode, format: inputFormat)
        
        // 准备音频引擎
        audioEngine.prepare()
    }
    
    private func installAudioTap(inputNode: AVAudioInputNode, format: AVAudioFormat) {
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] (buffer, time) in
            self?.processAudioBuffer(buffer, time: time)
        }
    }
    
    // 在 processAudioBuffer 中立即发送数据，不等待缓冲区积累
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard isCapturing else { return }
        
        // 立即更新处理时间
        lastProcessTime = Date()
        
        // 计算音频电平
        calculateAudioLevel(from: buffer)
        
        // 立即转换并发送音频数据（不等待缓冲区积累）
        if let audioData = convertToAudioData(buffer: buffer) {
            totalFramesCaptured += Int64(buffer.frameLength)
            audioBufferSubject.send(audioData)
        }
        
        // 移除缓冲区队列管理，直接发送
    }
    
    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) {
            guard let channelData = buffer.floatChannelData?[0] else { return }
            
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0.0
            
            for i in 0..<frameLength {
                let sample = channelData[i]
                sum += sample * sample
            }
            
            let rms = sqrt(sum / Float(frameLength))
            let db = 20.0 * log10(rms + 1e-10)
            let normalizedLevel = max(0.0, min(1.0, (db + 60.0) / 60.0))
            
            // 在主线程更新音频电平
            DispatchQueue.main.async {
                self.audioLevel = Double(normalizedLevel)
            }
    }
    
    private func convertToAudioData(buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        
        let frameLength = Int(buffer.frameLength)
        let dataSize = frameLength * MemoryLayout<Float>.size
        
        return channelData.withMemoryRebound(to: UInt8.self, capacity: dataSize) { pointer in
            return Data(bytes: pointer, count: dataSize)
        }
    }
    
    private func manageBufferQueue(_ audioData: Data) {
        bufferQueue.append(audioData)
        
        // 限制队列大小
        if bufferQueue.count > maxBufferQueueSize {
            bufferQueue.removeFirst()
        }
        
        // 更新缓冲区状态
        updateBufferStatus()
    }
    
    private func updateBufferStatus() {
            let status: String
            if bufferQueue.count == 0 {
                status = "空闲"
            } else if bufferQueue.count < maxBufferQueueSize / 2 {
                status = "正常"
            } else {
                status = "繁忙(\(bufferQueue.count)/\(maxBufferQueueSize))"
            }
            
            // 在主线程更新缓冲区状态
            DispatchQueue.main.async {
                self.bufferStatus = status
            }
    }
    
    private func updateAudioFormatDisplay() {
        guard let format = audioFormatDesc else {
            audioFormat = "未配置"
            return
        }
        
        audioFormat = "\(Int(format.sampleRate))Hz • \(format.channelCount)声道 • 32-bit Float"
    }
    
    private func resetCaptureState() {
        totalFramesCaptured = 0
        lastProcessTime = nil
        bufferQueue.removeAll()
        audioLevel = 0.0
    }
}
