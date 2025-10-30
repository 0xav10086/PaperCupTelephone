# AudioStreamServer - 纸杯电话 🎧

一个 macOS 应用，将系统音频通过 WebSocket 流式传输到 iPad 设备。

## 功能特性

- 🎵 实时系统音频捕获
- 🌐 WebSocket 音频流传输  
- 📱 iPad 网页客户端
- 🎨 实时音频可视化

## 下载安装

1. 下载 [AudioStreamServer.dmg](AudioStreamServer.dmg)
2. 双击 DMG 文件
3. 将应用拖拽到 Applications 文件夹
4. 启动应用并按照提示授权权限

## 使用方法

1. 在 Mac 上启动 AudioStreamServer
2. 点击"启动服务器"按钮
3. 在 iPad Safari 中打开显示的 URL
4. 点击页面开始音频播放

## 系统要求

- macOS 11.0 或更高版本
- 需要 BlackHole 虚拟音频驱动（可选，用于系统音频捕获）

## 开发者信息

使用 SwiftUI 和 Network.framework 构建。
