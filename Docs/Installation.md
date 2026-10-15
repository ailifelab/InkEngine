# 安装、签名与离线使用

## Mac

下载入口：[GitHub Releases 0.3.1](https://github.com/ailifelab/InkEngine/releases/tag/v0.3.1)，包含 DMG 和 SHA-256 校验文件。

本次正式包：`InkEngine-0.3.1-macOS-arm64-local.dmg`。Apple 芯片 Mac（M1 或更新）、macOS 26 或更新。打开 DMG，将 `Ink Engine.app` 拖入 Applications；更新时先退出旧应用再替换。日常只使用 `/Applications/Ink Engine.app`，保留原书库和偏好，不需要 Xcode。

此本地安装包使用临时签名，未进行 Apple 公证。经网络下载或转给另一台 Mac 后，可能需要在系统设置的“隐私与安全性”允许打开。不能宣称已公证，也不能将开发者账号证书装进公开源码。面向其他用户的正式分发需另行准备 Developer ID 签名、公证和依赖许可证合规。

内置 Matcha、ZipVoice；Mac 额外内置 Qwen 测试模型。均本地合成。Qwen 初始朗读语速 1.25 倍，合成吞吐仍慢于实时；准备和分段之间可能等待。

## iPhone / iPad

本次安装为优化 Release 0.3.1（6），使用原正式 Bundle ID 覆盖更新。覆盖更新替换旧程序并保留数据；卸载正式应用会删除它的本机数据。旧语音测试应用已卸载，两台设备各保留一份正式“墨语引擎”。不通过 TestFlight，不存在 TestFlight 的 90 天期限。

本次证书至 **2027-10-08 15:09:41 UTC（北京时间 23:09:41）**，描述文件至同日 15:19:46 UTC，实际取较早日期。用户确认沿用当前签名，不继续续签。建议 2027-09-08 前重新签名并覆盖安装；撤销证书或苹果账号状态变化可能导致提前失效。不能把“一年期证书”理解为任何时间安装都能再用满一年。

开发签名设备需开启开发者模式。苹果可能要求安装后首次启动联网验证；先联网正常打开，再离线使用内置模型和本地文稿。无需将正文发送给语音服务。苹果验证连接失败需排查系统签名验证，不能把它误诊为应用的语音联网失败。

官方规则：[描述文件和首次签名验证](https://developer.apple.com/help/account/provisioning-profiles/provisioning-profile-updates)、[签名和描述文件](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)。

## 本机打包配置

公开 `Config/IPA.json` 不包含作者团队标识。复制成 **被 Git 忽略的** `Config/IPA.local.json`，填写自己的 `team_id`；脚本优先读取本机配置。真实证书与私钥留在系统钥匙串和 Xcode 账号配置中，不放入项目、Git 或发行包说明。

```sh
cp Config/IPA.json Config/IPA.local.json
# 用自己的团队填写本机配置；在 Xcode 中配置自己的账号与设备。
zsh Scripts/package_ios.sh
python3 Scripts/ipa.py inspect Releases/0.3.1/InkEngine-0.3.1-iOS-Release-development.ipa
python3 Scripts/ipa.py install Releases/0.3.1/InkEngine-0.3.1-iOS-Release-development.ipa --device '自己的设备名'
```

普通打包沿用本机已有签名。`--refresh-signing` 允许 Xcode 联网更新签名，`--renew` 还要求实际到期时间延长；若没有延长，会保留旧 IPA 并报错。两者均不会替你接受开发协议，也不会自动部署到所有设备。

`zsh Scripts/package_mac.sh` 构建、校验、生成 DMG 和 SHA-256。`zsh Scripts/install_mac.sh /path/to/Ink\ Engine.app` 校验版本与签名后替换本机正式应用。所有发行文件和签名检查结果放在被 Git 忽略的 `Releases/`。

## 清理与数据

只清理本应用的生成语音、恢复 PCM、Library/Caches、tmp、测试包和构建产物。文稿、书签、阅读位置、纠音规则、历史和配对信息保留。显式维护启动参数 `--clear-generated-caches` 不应作为日常启动参数；清理生成语音之后恢复时需要重新合成。

安全备份仅留本机 `SafetyBackups/`，不进 Git，也不进入 DMG 或 IPA。个人删除的文稿按本人确认保持删除，不自动回填旧备份。
