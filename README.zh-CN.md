# LosslessMusic

**让 Mac 的音频输出跟随 Apple Music 的无损曲目自动切换。**

[English](README.md) · 简体中文

LosslessMusic 是一个轻量的 macOS 菜单栏应用，根据识别到的当前 Apple Music 曲目格式，自动调整音频输出设备的采样率和位深。歌曲切换到不同采样率时，无需反复打开“音频 MIDI 设置”手动调整。

## 功能

- 自动跟随当前曲目识别到的无损格式。
- 在紧凑菜单中显示输出设备名称、采样率和音源位深。
- 通过 **输出设备** 切换系统输出设备，当前设备显示勾选。
- 设备接入、拔出后更新可用列表，排除蓝牙设备。
- 支持在仅提供 24-bit 输出的 DAC 上播放 16-bit 音源。
- Music 已在播放时启动应用，也能尝试恢复播放信息。
- 仅在菜单栏运行，没有主窗口或 Dock 图标，无需注册账户或安装第三方依赖。

## 环境要求

- **macOS 27.0 及以上**，这是当前项目设置的最低系统版本。
- 在 Apple Music 中开启**无损音频**；如需播放更高规格的曲目，选择 **Hi-Res Lossless**。
- 支持曲目所需采样率的输出设备，例如 USB DAC 或音频接口。

### Dolby Atmos 设置

**Dolby Atmos 可以保持“自动”，不需要一律关闭。** 使用不支持自动 Atmos 播放的普通立体声 DAC 时，Music 会选择立体声版本；已开启无损且曲目提供无损版本时，会使用 ALAC。避免选择“始终开启”，让 Music 根据输出设备选择合适的格式。参见 [Apple 的 Dolby Atmos 说明](https://support.apple.com/zh-cn/109354)。

## 构建与运行

当前开发环境为 **Xcode 27.1**，使用 Swift 6 语言模式。

1. 克隆或下载仓库，打开 `LosslessMusic.xcodeproj`。
2. 选择 **LosslessMusic** scheme 和 **My Mac**。
3. 在 **Signing & Capabilities** 中选择自己的开发团队；签名有需要时修改 bundle identifier。
4. Run，然后在 Music 中播放无损曲目。

保持项目现有的 App Sandbox 关闭设置，当前日志读取方式需要这一配置。

## 使用

点击菜单栏图标，查看输出设备名称和识别到的曲目格式。通过 **输出设备** 切换系统输出设备，通过 **Quit** 退出。设备名称较长时，悬停可查看全名。

应用会在后台持续工作。出现等待提示，表示还未取得所需的播放或格式信息；当前曲目没有已知 ALAC 规格时，保持原有输出格式。

菜单显示的是**音源位深**。因此，16-bit 曲目在仅支持 24-bit 的 DAC 上使用 24-bit 输出时，菜单仍显示 `16-bit`。

## 使用须知

- 切换系统输出设备或调整格式也会影响其他应用，并可能造成短暂音频中断。
- 识别依赖 Music 日志。部分本地或离线曲目可能没有足够信息，macOS 更新也可能影响兼容性。
- 应用采用当前曲目识别到的最高可用 ALAC 规格，不提供独占输出，也不保证 bit-perfect。
- 退出时不会恢复之前的设备格式。
- 应用不发起网络请求，不包含分析统计。

反馈问题时，请说明 macOS 版本、设备型号和复现步骤。如需附日志，请先移除个人信息。

## 致谢

本项目受到 vincentneo 的 [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) 和 jordanmgibson 的 [WindowsLosslessSwitcher](https://github.com/jordanmgibson/WindowsLosslessSwitcher) 启发。

本项目不隶属于 Apple，也未经 Apple 背书。

## 许可证

Copyright (C) 2026 LosslessMusic contributors.

采用 **GNU GPL v3.0**，完整条款见 [LICENSE](LICENSE)。本软件不提供担保。
