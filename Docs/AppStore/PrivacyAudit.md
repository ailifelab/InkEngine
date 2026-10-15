# 隐私申报与源码依据

核对日期：2026-10-15。这是当前源码的静态核对，最终商店 Archive 仍需 Xcode Privacy Report 与 SDK 核对，不把源码搜索当完整网络抓包或 Apple 验证。

| 信息 | 用途与去向 | 源码依据 |
| --- | --- | --- |
| 文稿、修改和快照 | 本机编辑、阅读、恢复；Mac 原文件访问及导出由用户选择 | Sources/InkCore/Persistence、App/Services/Documents |
| 进度、书签、历史、纠音与语速 | 本机持久化与听读；所选同步项目可带给配对设备 | App/Models/AppModel.swift、App/Speech/SpeechEngine.swift |
| 生成音频、PCM 恢复缓存 | 本机缓存与断点续播，可清理 | App/Speech/SpeechEngine.swift |
| 设备名、随机设备 ID、公钥与信任记录 | 局域网发现、身份核对与配对；记住的设备可能自动重新发现 | App/Services/Nearby/NearbyService.swift |
| 配对私钥 | 用户选择记住配对时保存于本应用钥匙串；撤销信任不承诺擦除旧钥匙串记录 | NearbyService.IdentityStorage / forgetAll |
| 正文合成 | 内置 Matcha/ZipVoice/Qwen 本机运行，无 URLSession 云端 TTS 调用 | App/Speech、Vendor/SpeechRuntime/Sources |
| 支持邮件/官网 | 用户主动打开外部网站/邮件；应避免附带正文、密钥等敏感材料 | 隐私说明与支持入口 |

## App Store Connect 填写建议

按当前无账号、广告、埋点、开发者服务器和自动诊断上报的实现，应用内常规使用拟填 **Data Not Collected / 不收集数据**。Apple 的收集口径以开发者/第三方能在设备外访问并保留的数据为准；不能把“有本机数据”等同于收集，也不能把“没有互联网服务器”等同于没有任何传输。局域网配对传输和主动外部分享必须在政策中披露。

最终确认第三方运行库无自动遥测，并依据 Apple 问卷判断用户主动的点对点内容传输及偶发支持邮件的适用例外；不满足例外时按用途申报相应内容/联系信息，不可仍勾零收集。无跟踪域名、无广告标识符，不添加 ATT 弹窗。无需登录，也不存在需要删除的服务端用户账号，不为满足表单虚构账号删除功能。

## Required Reason APIs

| 类别与原因 | 实际用途 |
| --- | --- |
| UserDefaults / CA92.1 | 本应用偏好、阅读状态与配对记录；不跨应用取值。本次移除从系统全局 defaults 读取 AppleActionOnDoubleClick，改用原生窗口缩放动作。 |
| FileTimestamp / C617.1 | 本机书库索引、缓存与快照元数据。 |
| FileTimestamp / 3B52.1 | 用户授权的原文件和目录变更观察。 |

未因“可能用到”而声明磁盘容量、键盘列表或系统启动时间。现有安装二进制可见 stat/fstat 与 UserDefaults；新商店候选须再次核查静态依赖，发现其他 Required Reason API 必须先确定调用用途再声明。

## 权限与安全

- `NSLocalNetworkUsageDescription` 说明已确认配对的设备间加密传输；Bonjour `_inkengine._tcp`。
- Mac 已启用沙盒、用户选择文件读写、应用作用域书签、网络客户端和服务器；网络权限用于附近同步。
- iOS `UIBackgroundModes=audio` 仅用于实际朗读，锁屏和中断恢复需最终候选再测。
- 未声明麦克风、相机、定位、通讯录或 ATT 权限。
- 若选择已登录云盘中的文件，文件提供器或系统备份可能联网；政策不能声称所有操作永远不联网。
- 已记住设备的启动/前台重新发现与“每次必须主动点开始发现”不同，政策按实际行为披露。
