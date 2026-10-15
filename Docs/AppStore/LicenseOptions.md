# 商店依赖分发待决策

当前仓库继续按用户选定的 GPL-3.0-or-later 开源，本次未替换许可证、移除已认可声音或改变现有离线发行包。

## 已证实的依赖

`SpeechRuntime/Package.swift` 对 iOS/macOS 都链接 Sherpa 原生库。MatchaSynthesizer 调用 Sherpa OfflineTts API，配置 lexicon、tokens 和 espeak-ng-data；Piper 即使不在菜单中，VitsSynthesizer 源码仍调用同一原生运行库。实际已安装 Mac 二进制包含 eSpeak 符号，不能用“界面不显示”作为移除依赖的证据。

上游锁定版本 [sherpa-onnx v1.13.8 CMakeLists.txt](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/CMakeLists.txt) 在 ENABLE_TTS 下直接 include espeak-ng-for-piper 与 piper-phonemize；没有证实一个可以直接关闭 eSpeak 且完整保留当前模型能力的现成开关。Matcha 中英模型走 [MatchaTtsLexicon](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/sherpa-onnx/csrc/offline-tts-matcha-impl.h) 分支，因此替换需要真实前端和词汇覆盖回归，不能仅删除资源目录。

## 优先核实 GPL 分发安排

本轮发现 eSpeak NG 组织的 iOS 应用仍在 App Store 提供，且其 Extension 明确采用 GPLv3。不能仅凭历史冲突说明，就预设所有方案必须换模型或购买另一份许可。先核对该方案与我们同进程静态链接方案的差异、当前条款及对应源码义务；处理记录和询问范围见 [DependencyDistribution.md](DependencyDistribution.md)。此案例不是对我们的授权，也不自动表明拆成扩展就能解决问题。

## 备选方向（仅在确需调整时）

A. **保留声音，替换前端/运行库依赖**：保留当前权重、断句、波形和播放基线；实现或移植许可兼容的文本前端/推理路径，避免链接 eSpeak 及其派生组件。对中文常用字、多音字、数字、日期、中英混读和生僻字重新做覆盖、音素和听感对照，再比较 iPhone/iPad CPU、峰值内存和连贯性。效果合格后才作为商店候选。不能先承诺替换后与当前效果完全一致。

B. **独立商店版仅提供 ZipVoice**：从商店目标的构建图中真正剔除 Sherpa/Matcha/Piper 和 GPL 资源，重新审计 ZipVoice 前端及全部 transitive dependencies；原离线 GPL 版保留现状。该方向会改变商店音色范围，需要负责人决定。

C. **取得额外分发授权**：由相关组件权利人提供适用于本次 App Store 分发的授权或例外；我们不能代替上游权利人添加许可。单独给原创代码加例外不改变第三方 GPL 条款。

无论 A 或 B，原项目 GPL 的 App Store 条款适配、贡献来源和模型/参考声音权利仍需一并核对。原创代码的权利人可决定额外许可，但此前的 GPL 开源授权不会因此被撤回。不把用户同意采用 GPL 推断成其已经同意新增分发例外。

## 验收证据

最终归档应提供精确依赖清单、完整对应源码/构建信息与第三方许可证，记录模型和参考声音来源，检查最终二进制/资源内无应剔除组件，再用最终候选完成三端回归。以上是实际发布条件，当前资料包未声称这些条件已经满足。
