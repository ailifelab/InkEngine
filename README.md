# 墨语引擎 · Ink Engine

Swift 原生小说编辑与离线听读应用，支持 Apple 芯片 Mac、iPhone 和 iPad。当前本地交付版本为 0.3.1（6），要求 macOS / iOS / iPadOS 26 或更新、Xcode 26 或更新。项目使用一个多平台应用目标、SwiftUI 界面和共享 InkCore。

Mac 打开和编辑用户选择的原文件；手机和平板提供本机文稿及目录管理。支持文本编辑、Markdown 阅读、书签、阅读位置恢复、查找替换和附近设备手动同步。应用没有云端账户服务；附近设备同步需要用户主动操作与系统本地网络权限。

## 离线声音

| 模型 | 可用音色 | 平台 | 当前执行方式 |
| --- | --- | --- | --- |
| Matcha | 中文女声 | Mac、iPhone、iPad | 作者六步 ONNX 模型，CPU 两线程 |
| ZipVoice | Serena 女声、Dylan 男声 | Mac、iPhone、iPad | Core ML 四步、CPU |
| Qwen 0.6B | Serena 女声，测试模型 | Apple 芯片 Mac | Core ML decoder 使用 GPU，vocoder 使用 CPU |

菜单按模型分组，同一模型的音色在二级菜单切换。各模型独立记住语速。Qwen 初始播放语速 1.25 倍；当前合成仍慢于实时，适合分段试听，不能保证连续长篇不等待。语速由播放器调整，不裁切音节。系统音色可手动选择，也用于合成失败后的提示与恢复。Piper 已撤下。

当前参数、性能口径和验证范围见 [语音配置](Docs/Speech/Approved-Voices-20261015.md)。测试样本通过不代表所有文本都不会漏字；少见人名与多音字可以添加自定义纠音。

## 构建

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 Scripts/generate_project.py
zsh Scripts/test.sh core
# 本机依赖和模型齐全后构建：
zsh Scripts/build.sh mac
```

手机和平板界面测试请先用 `xcrun simctl list devices available` 获取自己的模拟器，再设置 `SIMULATOR_ID` 运行 `Scripts/test.sh iphone` 或 `ipad`。

`Sources/InkCore` 和核心测试不需要模型或签名账号。完整应用依赖本地 `Vendor/SpeechRuntime/Frameworks` 和模型资源，它们不进入源码 Git。当前 `prepare_speech.py --install` 只能恢复锁定清单中的上游档案，并非完整恢复所有 Core ML 转换产物。新克隆尚需补齐转换资源；不要把仅有源码的克隆描述成可立即打包的版本。来源、恢复边界及发布前事项见 [开源准备](Docs/OpenSource/Preparation.md)。

签名配置与安装、升级、续签、离线使用说明见 [安装说明](Docs/Installation.md)。模型准备可能联网下载；资源完整后的构建与内置语音推理可离线进行。首次苹果签名验证与应用内语音联网是不同环节。

## 目录

- `App/`：SwiftUI 应用、原生编辑器、播放引擎和资源。
- `Sources/InkCore/`、`Tests/`：共享核心与测试。
- `Vendor/SpeechRuntime/`：运行库封装、上游源码、依赖和模型锁定清单。
- `Scripts/`：工程生成、依赖校验、测试、打包和源码隐私审计。
- `Config/`：公开配置模板与忽略的本机签名配置。
- `Docs/`：安装、声音参数和开源准备说明；历史设备测试记录留在本机。
- `Releases/`、`build/`、`SafetyBackups/`：本机交付、临时产物、安全备份，均不进入 Git。

## 源码公开状态

本项目原创源码按 **GNU GPL-3.0-or-later** 开源，见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。第三方文件保留各自的版权和许可证；其中 eSpeak NG 为 GPL-3.0-or-later。公开仓库仅提供源码、必要品牌资源与依赖来源记录，不包含模型权重、预编译运行库、个人签名安装包或文稿。签名证书、私钥、描述文件与设备名单不随源码公开。

源代码：https://github.com/ailifelab/InkEngine
产品介绍：https://ailifelab.com/apps/inkengine/
