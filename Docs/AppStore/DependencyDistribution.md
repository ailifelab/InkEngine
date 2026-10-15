# 第三方依赖分发处理记录

核对日期：2026-10-15。结论：当前已有的开源许可授予相应范围内的权利，但没有取得本项目的额外 App Store 分发授权，也未完成商店分发安排确认。下列补充工作不等于收到权利人的许可回复。

## 本轮已经落实

- 固定已知直接语音依赖、权重、转换代码及已识别的原生子依赖，记录在 `Vendor/SpeechRuntime/distribution-licenses.json`。每份本地许可文本都有 SHA-256；预编译库的完整传递依赖清单仍待上游核实，不将这份直接清单称为完整 SBOM。
- 补入 **Piper phonemize 的 MIT 文本**，以及 eSpeak 固定提交中的 **Unicode 数据、BSD-2-Clause 和 Apache 文本**。保留 ONNX Runtime v1.28.1 原始 ThirdPartyNotices.txt；它是上游通知汇编，不将其中每个可选组件自动认定为当前 Apple 二进制中的实际链接项。原 GPL、Apache、ONNX MIT 和各模型许可继续保留。
- 生成 `App/Resources/Legal/third-party-notices.md`，包含原项目 GPL 与各组件完整许可、来源和适配改动说明；应用离线说明增加“开源许可”页。
- `python3 Scripts/prepare_legal.py --check` 核对许可文本哈希及生成内容；`Scripts/build.sh` 和公开 IPA 配置的准备流程调用此检查。没有修改私有签名配置。
- 未改变语音权重、前端、断句、模型参数、工程链接依赖或已安装正式版。没有代上游添加例外，也没有替换本项目 GPL。

## 依赖关系与授权边界

| 组件 | 已核实的许可记录 | 处理结论 |
| --- | --- | --- |
| Sherpa 1.13.8 | Apache-2.0 | 此许可只覆盖对应代码，不替代其静态依赖许可；具体预编译资产来源需完整对应。 |
| ONNX Runtime 1.28.1 | MIT | 按原许可保留版权和许可文本；不因发布商店版自动需要另购商业许可。 |
| Piper phonemize wrapper | 固定提交的 LICENSE.md 为 MIT，Copyright 2023 Michael Hansen | 不能将整个音素链标成 GPL，也不能反过来用包装层 MIT 覆盖 eSpeak 的 GPL。 |
| eSpeak NG fork、音素/词典数据 | GPL-3.0-or-later，另有 Unicode/BSD 通知 | 按 GPL 路径处理来源、构建和用户权利；商店具体安排待核实。fork 的 ucd-tools/COPYING 也是 GPL，不能将其整体误标为 BSD。 |
| Matcha / ZipVoice / Qwen / speech-swift / Mobius | 所存对应声明为 Apache-2.0 | 保留来源、许可与适配说明；不把代码/权重许可自动解释为任意第三方声纹或商标授权。Mobius 的精确原始代码修订缺失，不能伪造 commit。 |
| ZipVoice 使用的 Vocos 24kHz | MIT，Copyright 2023 Charactr Inc. | 与 Matcha 随模型提供的声码器来源分别记录，不将所有 Vocos 资源统一标成 Apache。 |

## 关键新证据：同类 GPL 组件确有上架案例

Apple 商店仍有 [eSpeak-NG（id6444089174）](https://apps.apple.com/us/app/espeak-ng/id6444089174)。其 [组织内 iOS 项目许可说明](https://github.com/espeak-ng/espeak-ng-ios-app/blob/master/LICENSE.md) 明确区分：静态链接 eSpeak 的 Audio Unit Extension 为 GPLv3，通过 XPC 通信的 Application 为 MIT。

这推翻了“仅因 GPL 就必须先更换声音或购买额外许可”的预设，但不证明我们采用相同安排：我们当前把 Sherpa/eSpeak 链入同一个应用，也不能直接继承那个项目的 MIT 应用层许可或假定上架本身是通用许可例外。FSF 的 2010 年冲突说明只能作为历史背景，不能单独证明当前每个 App Store 分发方案均被禁止。

因此，本轮不擅自改造语音链、不把咨询等同于授权。优先询问已有 GPL 商店分发方案的具体依据，以及 Sherpa 二进制的精确源码/构建清单，再决定是否真的需要额外授权或技术替换。

## 已发送、待上游确认的两项

1. 向 `espeak-ng/espeak-ng-ios-app` 询问其 GPL 商店分发在 EULA、源码/构建可得性和平台限制方面的公开安排；如本项目需要额外许可，询问真正有权授权的联系人及范围。不要求维护者代表全部贡献者担保。
2. 向 `k2-fsa/sherpa-onnx` 核对两个已使用 Apple 静态 XCFramework 的精确来源、构建参数、传递依赖与通知清单；询问是否已有覆盖所用组件的商店分发记录或受支持的不含 eSpeak 构建方式。

经账号持有人明确授权，2026-10-15 已使用 GitHub 账号 `wood-kite` 发布并重新读取核对标题、正文、作者及目标仓库：

| 上游 | 公开询问 | 发布日期（北京时间） | 当前记录 |
| --- | --- | --- | --- |
| eSpeak NG iOS | [#63：GPL 商店分发安排](https://github.com/espeak-ng/espeak-ng-ios-app/issues/63) | 2026-10-15 20:02 | 已发送，待回复；未取得额外许可。 |
| sherpa-onnx | [#4053：Apple 预编译资产的许可与对应源码](https://github.com/k2-fsa/sherpa-onnx/issues/4053) | 2026-10-15 20:03 | 已发送，待回复；精确资产/源码对应关系未确认。 |

本机 `Releases/AppStore/Permissions20261015/` 保存发送正文及读取核对记录；内容不包含文稿、签名密钥、设备标识或费用承诺。本轮没有替他人签署或接受条款。以上为发布时核对状态，不代表自动持续监控或取得授权。

## 收到回复后怎样才算完成

收到上游回复后，分别记录回复人的权限、覆盖的提交/数据/平台、许可条件与原始链接。维护者泛泛表示“应该可以”或商店通过记录不自动等于覆盖全部权利人的授权。若沿用 GPL，应完成最终二进制相对应的源码、构建和资源恢复信息，并核对商店实际条款；若采用额外许可，则须保存范围明确的有效文本。若只能技术移除该组件，则先做音素覆盖与真机试听回归，不能用删 UI 或删许可文件冒充依赖移除。

原已公开 DMG 的 GPL 对应源码/构建恢复缺口仍需补齐，本轮许可清单和源代码链接没有将该缺口自动消除。当前没有把它或商店候选标记为已完成所有分发义务。

## 本轮验证

- macOS arm64 Release 与 iOS arm64 模拟器 Release 均构建成功；两端产物包含与源文件一致的完整离线许可。未更新物理设备或正式安装版。
- Mac 实际打开“开源许可”，验证全文滚动到末尾、返回开头和关闭。完整文本使用原生只读文本控件，避免长 SwiftUI 列表的无障碍滚动异常。iOS 本轮仅确认编译与资源打包，未声明真机界面验收。
- 许可哈希/生成一致性检查、公开源码敏感信息审计及 Git 空白检查通过。

## 固定来源

- [Sherpa eSpeak 构建配方](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/cmake/espeak-ng-for-piper.cmake)：`ed530aa113046142eb5115cf2fc9157854d0ffe1`。
- [Sherpa Piper 构建配方](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/cmake/piper-phonemize.cmake)：`f3ff95afc03640bc1399e113e83361192a2fafb4`。
- [固定 Piper 包装层许可](https://github.com/csukuangfj/piper-phonemize/blob/f3ff95afc03640bc1399e113e83361192a2fafb4/LICENSE.md)。
- [固定 eSpeak 许可](https://github.com/csukuangfj/espeak-ng/blob/ed530aa113046142eb5115cf2fc9157854d0ffe1/COPYING)、[Unicode 通知](https://github.com/csukuangfj/espeak-ng/blob/ed530aa113046142eb5115cf2fc9157854d0ffe1/COPYING.UCD)。
