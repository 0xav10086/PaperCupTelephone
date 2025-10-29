class ModernAudioVisualizer {
    constructor() {
        this.audioContext = null;
        this.analyser = null;
        this.socket = null;
        this.isPlaying = false;
        this.isConnected = false;
        this.animationId = null;
        this.bufferLength = null;
        this.dataArray = null;
        this.canvas = null;
        this.canvasCtx = null;
        
        this.init();
    }
    
    init() {
        console.log('🎧 初始化现代音频可视化器');
        this.setupCanvas();
        this.setupWebSocket();
        this.setupEventListeners();
    }
    
    setupCanvas() {
        this.canvas = document.getElementById('visualizer');
        this.canvasCtx = this.canvas.getContext('2d');
        
        // 设置画布大小为窗口大小
        this.resizeCanvas();
    }
    
    resizeCanvas() {
        this.canvas.width = window.innerWidth;
        this.canvas.height = window.innerHeight;
    }
    
    setupWebSocket() {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = `${protocol}//${window.location.hostname}:65533`;
        
        console.log('🔌 连接WebSocket:', wsUrl);
        this.socket = new WebSocket(wsUrl);
        
        this.socket.onopen = () => {
            console.log('✅ WebSocket连接成功');
            this.isConnected = true;
            this.updateStatus('已连接 - 点击开始', 'connected');
        };
        
        this.socket.onmessage = (event) => {
            if (event.data instanceof Blob) {
                this.handleAudioData(event.data);
            } else {
                try {
                    const message = JSON.parse(event.data);
                    if (message.type === 'audio_config') {
                        console.log(`🎛️ 音频配置: ${message.sampleRate}Hz, ${message.channels}声道`);
                    }
                } catch (e) {
                    // 忽略非JSON消息
                }
            }
        };
        
        this.socket.onclose = () => {
            console.log('❌ 连接断开');
            this.isConnected = false;
            this.updateStatus('连接已断开');
            this.stopAudio();
        };
        
        this.socket.onerror = (error) => {
            console.error('❌ WebSocket错误:', error);
            this.updateStatus('连接错误');
        };
    }
    
    async startAudio() {
        if (!this.isConnected) {
            this.updateStatus('未连接服务器');
            return;
        }
        
        try {
            console.log('🎵 启动音频上下文...');
            
            // 创建音频上下文
            this.audioContext = new (window.AudioContext || window.webkitAudioContext)({
                sampleRate: 48000
            });
            
            // 创建分析器
            this.analyser = this.audioContext.createAnalyser();
            this.analyser.fftSize = 2048;
            this.analyser.smoothingTimeConstant = 0.8;
            
            // 创建增益节点（控制音量）
            this.gainNode = this.audioContext.createGain();
            this.gainNode.gain.value = 1.0;
            
            // 创建脚本处理器用于播放
            this.scriptProcessor = this.audioContext.createScriptProcessor(4096, 1, 1);
            this.audioBuffer = [];
            
            this.scriptProcessor.onaudioprocess = (event) => {
                if (!this.isPlaying) return;
                
                const outputBuffer = event.outputBuffer;
                const channelData = outputBuffer.getChannelData(0);
                const samplesNeeded = outputBuffer.length;
                
                // 从缓冲区获取数据
                const available = Math.min(this.audioBuffer.length, samplesNeeded);
                
                if (available > 0) {
                    for (let i = 0; i < available; i++) {
                        channelData[i] = this.audioBuffer[i];
                    }
                    this.audioBuffer.splice(0, available);
                    
                    // 剩余部分填充静音
                    for (let i = available; i < samplesNeeded; i++) {
                        channelData[i] = 0;
                    }
                } else {
                    // 没有数据时输出静音
                    for (let i = 0; i < samplesNeeded; i++) {
                        channelData[i] = 0;
                    }
                }
                
                // 将输出连接到分析器进行可视化
                this.analyser.getByteFrequencyData(this.dataArray);
            };
            
            // 连接节点
            this.scriptProcessor.connect(this.gainNode);
            this.gainNode.connect(this.analyser);
            this.analyser.connect(this.audioContext.destination);
            
            // 初始化可视化数据
            this.bufferLength = this.analyser.frequencyBinCount;
            this.dataArray = new Uint8Array(this.bufferLength);
            
            this.isPlaying = true;
            this.updateStatus('正在播放音频...', 'playing');
            
            // 开始动画循环
            this.animate();
            
            console.log('✅ 音频播放已启动');
            
        } catch (error) {
            console.error('❌ 启动音频失败:', error);
            this.updateStatus('音频启动失败: ' + error.message);
        }
    }
    
    stopAudio() {
        this.isPlaying = false;
        
        if (this.animationId) {
            cancelAnimationFrame(this.animationId);
            this.animationId = null;
        }
        
        if (this.scriptProcessor) {
            this.scriptProcessor.disconnect();
            this.scriptProcessor = null;
        }
        
        if (this.audioContext) {
            this.audioContext.close().then(() => {
                this.audioContext = null;
                console.log('⏹️ 音频已停止');
            });
        }
        
        this.audioBuffer = [];
        this.updateStatus('音频已停止');
    }
    
    async handleAudioData(blob) {
        try {
            const arrayBuffer = await blob.arrayBuffer();
            const float32Data = new Float32Array(arrayBuffer);
            
            // 添加到播放缓冲区
            this.audioBuffer.push(...float32Data);
            
            // 限制缓冲区大小以减少延迟
            const maxBufferSize = 48000 * 0.5; // 最多缓存0.5秒音频
            if (this.audioBuffer.length > maxBufferSize) {
                this.audioBuffer = this.audioBuffer.slice(-maxBufferSize);
            }
            
        } catch (error) {
            console.error('❌ 处理音频数据失败:', error);
        }
    }
    
    animate() {
        this.animationId = requestAnimationFrame(() => this.animate());
        
        if (!this.isPlaying || !this.analyser) return;
        
        // 获取频率数据
        this.analyser.getByteFrequencyData(this.dataArray);
        
        // 绘制可视化
        this.draw();
    }
    
    draw() {
        const width = this.canvas.width;
        const height = this.canvas.height;
        
        // 清除画布
        this.canvasCtx.fillStyle = 'rgb(0, 0, 0)';
        this.canvasCtx.fillRect(0, 0, width, height);
        
        const barWidth = (width / this.bufferLength) * 2.5;
        let barHeight;
        let x = 0;
        
        for (let i = 0; i < this.bufferLength; i++) {
            barHeight = this.dataArray[i];
            
            // 创建渐变颜色
            const hue = i / this.bufferLength * 360;
            this.canvasCtx.fillStyle = `hsl(${hue}, 100%, 50%)`;
            
            // 绘制频带条
            this.canvasCtx.fillRect(x, height - barHeight, barWidth, barHeight);
            
            x += barWidth + 1;
        }
        
        // 添加一些视觉效果
        this.addSpecialEffects();
    }
    
    addSpecialEffects() {
        const width = this.canvas.width;
        const height = this.canvas.height;
        
        // 添加光晕效果
        const gradient = this.canvasCtx.createRadialGradient(
            width / 2, height / 2, 0,
            width / 2, height / 2, width / 2
        );
        gradient.addColorStop(0, 'rgba(255, 255, 255, 0.1)');
        gradient.addColorStop(1, 'rgba(0, 0, 0, 0)');
        
        this.canvasCtx.fillStyle = gradient;
        this.canvasCtx.fillRect(0, 0, width, height);
        
        // 添加粒子效果
        this.drawParticles();
    }
    
    drawParticles() {
        const width = this.canvas.width;
        const height = this.canvas.height;
        
        for (let i = 0; i < this.bufferLength; i += 10) {
            const value = this.dataArray[i];
            const x = Math.random() * width;
            const y = Math.random() * height;
            const radius = value / 255 * 5;
            
            this.canvasCtx.beginPath();
            this.canvasCtx.arc(x, y, radius, 0, 2 * Math.PI);
            this.canvasCtx.fillStyle = `rgba(255, 255, 255, ${value / 255 * 0.5})`;
            this.canvasCtx.fill();
        }
    }
    
    updateStatus(message, className = '') {
        const statusElement = document.getElementById('status');
        if (statusElement) {
            statusElement.textContent = message;
            statusElement.className = `status ${className}`;
        }
    }
    
    setupEventListeners() {
        // 点击页面启动音频
        document.addEventListener('click', async () => {
            if (!this.isPlaying) {
                await this.startAudio();
            }
        });
        
        // 窗口大小改变时重置画布
        window.addEventListener('resize', () => {
            this.resizeCanvas();
        });
        
        // 防止页面滚动
        document.addEventListener('touchmove', (e) => {
            e.preventDefault();
        }, { passive: false });
    }
}

// 全局初始化
let audioVisualizer = null;

document.addEventListener('DOMContentLoaded', () => {
    console.log('🚀 页面加载完成');
    audioVisualizer = new ModernAudioVisualizer();
});
