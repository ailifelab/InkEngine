# App Store 准备记录

更新：2026-10-15。准备范围为 iPhone / iPad / Apple 芯片 Mac，实际首批平台、定价和销售地区待产品负责人确认。这里是提交资料包，不代表已经上传、通过验证或获得审核批准。当前已发布的 0.3.1 build 6 DMG 和本地开发签名 IPA 不是商店发行包。

## 已准备

- 应用内可离线打开的[隐私政策](../../App/Resources/Legal/privacy-zh-Hans.md)、[使用与开源说明](../../App/Resources/Legal/usage-zh-Hans.md)，历史页、声音设置和 Mac 应用菜单均提供入口。
- 应用隐私清单 `App/Resources/PrivacyInfo.xcprivacy` 已纳入工程资源。清单不等于 App Store Connect 隐私问卷，也不替代第三方 SDK 审查。
- [商店文案](Metadata.json)、[审核说明](ReviewNotes.md)、[隐私申报依据](PrivacyAudit.md)、[提交前待办](SubmissionChecklist.md)。
- 已补齐已识别组件许可文本、哈希清单和应用离线“开源许可”页；执行 `python3 Scripts/prepare_legal.py --check` 可核对。该检查不等于上游授权或完整 SBOM。
- `Config/AppStoreExportOptions.plist` 是本地导出模板，没有团队、证书或账号密钥；使用独立归档目录，不覆盖现有离线发行包。

## 仍不能直接提交的事项

1. **依赖分发许可**：Matcha 的 Sherpa 静态运行库含 eSpeak GPL-3.0-or-later。现有项目沿用 GPL 的决定继续有效，但不能据此宣称所有第三方权利人已授权 App Store 分发。需先核实沿用 GPL 的具体商店分发安排、对应源码和是否需要补充授权；必要时再替换依赖。eSpeak 组织内已有 GPL 扩展上架案例，不能仅凭 GPL 字样要求更换音色，见 [本轮处理记录](DependencyDistribution.md)。仅隐藏 Matcha 菜单不等于移除链接依赖。原创代码若采用商店例外或双重许可，须由其权利人明确决定，并复核所有贡献及第三方代码；本次未更改 LICENSE。
2. **签名与后台**：本机检查只有 Apple Development 与 Developer ID Application，未找到 App Store 分发身份。需要开发者后台 App ID、App Store Connect 应用记录、有效分发证书及描述文件。Developer ID 不等于 App Store 分发证书。认证材料只留本机与 Apple 后台，不进 Git。
3. **负责人资料**：首批平台/售价/地区、公开支持邮箱、审核联系人、版权主体、欧盟交易者身份及适用备案资料待确认。政策暂沿用官网该产品已配置的公开邮箱；上线前确认可收信。源码提交后可使用 Metadata.json 中的 GitHub 公开政策 URL；官网专属隐私路由尚未发布，不能填不存在的地址。
4. **加密与地区**：局域网协议使用 CryptoKit Curve25519、HKDF-SHA256、AES-GCM，不应回答“没有使用加密”。按 Apple 当前问卷核实豁免及地区要求；未盲填 ITSAppUsesNonExemptEncryption=false。
5. **最终商店候选**：用最终依赖归档后重新生成 Privacy Report、验证 SDK/API 使用、签名、体积、离线播放和持续播放，提供同一候选的真机截图及回归结果。Qwen 仍为慢于实时的实验功能，商店正式版本是否保留须明确；不要把当前测试标签原样当完成的商店功能。

## 官方依据（2026-10-15 核对）

- [审核准则](https://developer.apple.com/app-store/review/guidelines/)
- [App Privacy 填写口径](https://developer.apple.com/app-store/app-privacy-details/)
- [Required Reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
- [加密出口申报](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [中国大陆合规信息](https://developer.apple.com/help/app-store-connect/manage-compliance-information/view-china-mainland-compliance-information/)
- [FSF 关于 App Store 条款与 GPL 冲突的说明](https://www.fsf.org/blogs/licensing/more-about-the-app-store-gpl-enforcement)（历史说明，不作为当前项目获得额外授权的证明）

## 后续归档方式

确认上述事项并解决依赖后，在 Xcode Organizer 对正式 Archive 先 Validate，再导出/上传 App Store Connect。保留 dSYM 和归档，不使用 `Scripts/ipa.py` 的 development/ad-hoc 安装流程冒充商店导出。

本地准备归档示例（`TEAM` 使用本人配置，不提交实际值；`BUILD` 必须大于后台已上传编号）：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project InkEngine.xcodeproj -scheme InkEngine -configuration Release \
  -destination 'generic/platform=iOS' -archivePath Releases/AppStore/InkEngine-iOS.xcarchive \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_IDENTITY='Apple Distribution' CURRENT_PROJECT_VERSION="$BUILD" archive
# Mac 使用 generic/platform=macOS、ARCHS=arm64，并在 Xcode 选择 Mac App Store 分发身份。
# 先经 Organizer Validate 和 Privacy Report，再使用填写了本人团队的本地 ExportOptions 导出。
```

没有调用自动上传或提交审核，也没有代签开发者协议。
