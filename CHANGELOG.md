# 更新记录

## 0.3.3（Mac 12 / iOS 9）

- Mac 移除 Qwen 模型与选择入口，保留 ZipVoice 双音色与系统语音；旧 Qwen 选择自动迁移到 ZipVoice，模型缺失时使用系统语音。
- 精简 Mac 安装包；iOS 既有未签名安装包保持 build 9。

- 修复 macOS 原生编辑器复用时，切换主题后纸面、正文与列标尺未立即同步。
- 新增深色、暖色、绿色与白色主题的纸面像素回归测试，并检查文稿内容保持不变。
- 安装要求保持为 Apple 芯片 Mac / macOS 26，iPhone、iPad / iOS、iPadOS 26。

## 0.3.2（8）

- 修复 iOS 内置框架最低系统版本元数据，供 App Store 处理。
- 已公开 Developer ID 签名且经 Apple 公证的 macOS DMG。
