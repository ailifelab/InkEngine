# 当前目录的开源准备

项目结构保持原位，不复制到另一棵公开目录，不把本机安装目录或个人文稿目录当源码仓库。按作者授权将审计后的源码发布至 ailifelab/InkEngine；Mac 的 ad-hoc 临时签名 DMG 按作者授权放入 GitHub Releases，安装包不进入 Git 源码历史；个人开发签名 IPA、证书与描述文件不公开。

## Git 边界

可公开的是应用与核心源码、合成测试、通用脚本、工程、配置模板、已批准品牌资源、依赖锁定清单、来源和许可证。作者签名配置已迁入忽略的 `Config/IPA.local.json`，公开工程不写作者 DEVELOPMENT_TEAM。

`.gitignore` 排除证书、私钥、描述文件、设备及签名结果、发行包、模型和运行库二进制、下载及转换缓存、原始测试结果、截图、旧设备记录、个人备份、Xcode 用户状态。个人文稿管理测试和硬编码本机文稿路径已从公共测试源码移除。

忽略规则不是秘密保险箱：不要对私密文件执行 `git add -f`。提交前运行 `python3 Scripts/audit_public_source.py --staged`；全候选检查用不带参数的命令。审计只输出文件名和规则，不输出检测到的秘密。新加入的资源须再次审计。

## 第三方来源与许可证

| 组件 | 许可 | 记录 |
| --- | --- | --- |
| sherpa-onnx 1.13.8 | Apache-2.0 | Vendor/SpeechRuntime/Licenses 与 runtime-lock.json |
| ONNX Runtime 1.28.1 | MIT | 同上 |
| eSpeak NG、音素词典与链接组件 | GPL-3.0-or-later | espeak-ng-GPL-3.0.txt 与内置 THIRD-PARTY-NOTICES.txt |
| Matcha 与当前声码器 | Apache-2.0（上游声明） | Matcha/SOURCE.json 和 LICENSE |
| ZipVoice、Vocos、Qwen 参考音色 | 各自 Apache-2.0 文本 | ZipVoice 目录中的来源及独立 LICENSE |
| Qwen 与 speech-swift 原生运行库 | Apache-2.0 | SpeechMac/Qwen 和 Sources/NativeQwen 中的来源及许可 |

已识别的语音依赖与许可文本哈希见 `Vendor/SpeechRuntime/distribution-licenses.json`；应用内完整许可由 `Scripts/prepare_legal.py` 生成。当前直接清单不是全部静态依赖的完整 SBOM。商店分发核对的新证据、已准备的询问信与尚未获得的授权见 [依赖分发处理](../AppStore/DependencyDistribution.md)。

eSpeak 的 [上游许可](https://github.com/espeak-ng/espeak-ng/blob/master/COPYING) 需要单独遵守。公开二进制涉及对应依赖源码和构建方式，保留许可文本和上游链接不能替代完成这些义务。源码许可证不能抹去组件各自的许可。未来 App Store 分发与当前离线个人安装分开评估，不宣称“GPL 自动适合商店上架”。

## 从新克隆恢复完整应用的边界

根目录 InkCore 可直接 `swift test`，不依赖证书和模型。完整应用当前资源清单保存在 runtime-lock.json、各模型 SOURCE.json；权重、原生框架和编译产物不进 Git。

`Scripts/prepare_speech.py --install` 仅恢复其 artifacts 数组覆盖的档案。它尚不能从空克隆一条命令恢复 ZipVoice / Qwen 的全部 Core ML 编译产物和参考音色资源，eSpeak 数据归档的独立恢复入口也需补齐。**这项是公开发行前明确的待办，不把现有本机全资源构建当作全新克隆可复现的证明。**

转换源码保持在 `Scripts/NativeSpeech/`，上游和权重修订、尺寸与 SHA-256 保留在 SOURCE.json。发布完整恢复流程时，需要固定转换环境依赖、提供授权允许的资源下载或重建步骤、验证 fresh clone 和资源校验。当前不把几十 GB 的实验环境或个人签名包塞入 Git 来掩盖这项缺口。

本项目原创源码已确定采用 GPL-3.0-or-later，完整文本见根目录 LICENSE。第三方许可保持独立。后续完整应用发行仍需完成干净环境依赖恢复，并针对二进制发行方式核对 GPL 对应源码和品牌资源许可。实际设备名单、证书标识、到期检查原始记录和安装回执只在本机 Releases 中。
