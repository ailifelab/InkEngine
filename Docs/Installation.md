# Installation and signing

Source version: **0.3.3 (9)**. Published installers and checksums are listed on [GitHub Releases](https://github.com/ailifelab/InkEngine/releases).

## Mac

Requires Apple silicon and macOS 26 or later. Quit the previous app, open the DMG and drag Ink Engine.app to Applications. Application data and preferences remain in the existing app container. Check the SHA-256 before installation. Developer ID signing and notarization status must be checked for each release independently.

## iPhone / iPad

Requires iOS / iPadOS 26 or later. The existing packaging workflow uses development signing: installation is restricted to devices already included in the provisioning profile and requires Developer Mode. It is not a universal installer. First launch may require online signature verification; certificates can expire or be revoked. Local documents and bundled voices work offline.

Never publish provisioning profiles, signing reports or device lists. An explicitly unsigned IPA requires the recipient to sign the application and embedded code with their own valid Apple credentials and a matching provisioning profile before installation. Simulator apps and App Store exports are not general sideloading packages.

## 本机打包配置

公开 `Config/IPA.json` 不包含作者团队标识。复制成 **被 Git 忽略的** `Config/IPA.local.json`，填写自己的 `team_id`；脚本优先读取本机配置。真实证书与私钥留在系统钥匙串和 Xcode 账号配置中，不放入项目、Git 或发行包说明。

```sh
cp Config/IPA.json Config/IPA.local.json
# 用自己的团队填写本机配置；在 Xcode 中配置自己的账号与设备。
zsh Scripts/package_ios.sh
python3 Scripts/ipa.py inspect Releases/0.3.3/InkEngine-0.3.3-iOS-Release-development.ipa
python3 Scripts/ipa.py install Releases/0.3.3/InkEngine-0.3.3-iOS-Release-development.ipa --device '自己的设备名'
```

普通打包沿用本机已有签名。`--refresh-signing` 允许 Xcode 联网更新签名，`--renew` 还要求实际到期时间延长；若没有延长，会保留旧 IPA 并报错。两者均不会替你接受开发协议，也不会自动部署到所有设备。

`zsh Scripts/package_mac.sh` 构建、校验、生成 DMG 和 SHA-256。`zsh Scripts/install_mac.sh /path/to/Ink\ Engine.app` 校验版本与签名后替换本机正式应用。所有发行文件和签名检查结果放在被 Git 忽略的 `Releases/`。

## 清理与数据

Mac 编译和调试产物放在 `build.noindex/`，避免混入 Spotlight。构建、测试、打包结束会取消构建副本的 Launch Services 注册；安装成功后会删除已完成的构建 `.app`，正式入口始终是 `/Applications/Ink Engine.app`。安装包和压缩回滚备份保留。旧工具使用的 `build/` 通过符号链接兼容同一目录。

只清理本应用的生成语音、恢复 PCM、Library/Caches、tmp、测试包和构建产物。文稿、书签、阅读位置、纠音规则、历史和配对信息保留。显式维护启动参数 `--clear-generated-caches` 不应作为日常启动参数；清理生成语音之后恢复时需要重新合成。

安全备份仅留本机 `SafetyBackups/`，不进 Git，也不进入 DMG 或 IPA。个人删除的文稿按本人确认保持删除，不自动回填旧备份。
