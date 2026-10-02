# 调研：长按相机按钮触发端侧 ASR 语音输入（注入 DSH WebView 输入框）

日期：2026-10-02
状态：评估结论，未实施

## 1. 背景与现状盘点

### 已有基础（无需重做）

- **注入链路完整**：`lib/webview_bridges.dart` 中 `composerBridgeJs` 提供 `window.__dshComposerBridge.insertText(text)`，已处理 textarea / contenteditable / 兜底三种情况；Dart 侧调用点在 `webview_screen.dart:1090`。识别完直接调它即可。
- **UI 骨架完整**：`lib/voice_input.dart`（235 行）已有 `VoiceInputDialog`（含 partial 回显、失败降级、MIUI 哨兵逻辑），只需换引擎、改交互。
- **入口可挂**：相机浮动按钮（`webview_screen.dart:1848-1910`）目前只有点击（相册/拍照面板）和拖拽，**`onLongPress` 全项目未被占用**，可直接绑「按住说话」。
- **权限齐备**：`RECORD_AUDIO` 已在 Manifest，`permission_handler` 已在依赖里；minSdk 23。

### 之前为什么挂起（复盘）

`978a72c` 挂起、`3b8338a` 补自动降级，根因是**方案本身依赖 ROM**：`speech_to_text` 插件底层是 Android `SpeechRecognizer`，识别质量完全取决于系统识别服务——原生谷歌服务机型很好，但 MIUI 走小爱大脑，存在误报错误、启动即拒、无转写等不可控行为（见 `voice_input.dart:63-74` 的哨兵逻辑）。**换自托管端侧模型可以根治，而不是继续在系统识别上打补丁。**

## 2. 候选方案对比

| 维度 | A. 系统 SpeechRecognizer（现状） | B. sherpa-onnx 流式 Zipformer | C. sherpa-onnx SenseVoice（离线） | D. whisper.cpp | E. 云端流式 ASR（对照） |
|---|---|---|---|---|---|
| 中文准确度 | 视 ROM，好则高、MIUI 不可控 | 高（流式里最好一档） | **端侧最高一档**，约为 Whisper 中文错误率的一半 | 差（large-v3 中文 CER ~19%，落后开源最优 5–10×） | 最高（含标点/热词） |
| 实时回显 | ✅ partial | ✅ **真流式**，边说边出字 | ⚠️ 非流式，可做 1–2s 增量「伪流式」 | ⚠️ Android 流式 RTF ≈ 5–7（比实时慢 5 倍），实际不可用 | ✅ |
| 松手后出稿延迟 | 即时 | 即时（partial 已基本是终稿） | 亚秒～1s（169× realtime） | 慢 | 即时 |
| 模型体积 | 0 | 约 20–200 MB（选型决定） | 约 100–200 MB（int8） | 500 MB+ | 0 |
| 完全离线 | 视 ROM | ✅ | ✅ | ✅ | ❌ |
| 不依赖 ROM | ❌（挂起根因） | ✅ | ✅ | ✅ | ✅（依赖网络） |
| 集成成本 | 已完成（代码保留） | 中：插件 + 模型下载管理 | 中：同插件，换引擎 | 高：自编 JNI/FFI | 低～中 |
| 主要风险 | ROM 行为不可控 | 体积、首用需下载 | 无流式、体验略钝 | 中文准确度 + 速度双差 | 隐私、DSH 本地自托管定位冲突 |

> 数据来源：SenseVoice 中文 ~7.8% CER / 169× realtime、约为 Whisper 一半错误率（funasr.com 基准）；Whisper large-v3 中文 CER ~18.9%（ruoqijin.com 2025–2026 ASR 综述）；whisper.cpp Android 流式 RTF 5–7（ggml-org/whisper.cpp discussion #3567）。具体数字以自测为准。

### 各方案要点

**A. 系统 SpeechRecognizer（`speech_to_text`，现有代码）**
优点是零成本、partial 支持好；致命伤是质量上限由 ROM 决定，无法承诺「识别准确度高」。建议保留为**兜底通道**（sherpa-onnx 模型未下载完成时启用），现有降级逻辑直接复用。

**B. sherpa-onnx + 流式 Zipformer（推荐主方案）**
官方 Flutter 插件 `sherpa_onnx`（^1.13.8，Apache-2.0，支持 Android arm64 分 ABI 包）。流式模型可选：
- `sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30`（最新中文流式，准但大）
- `icefall-asr-zipformer-wenetspeech-streaming-small`（小，快，CER 稍高）
- 中英双语 `streaming-zipformer-bilingual-zh-en-2023-02-20`（若需要混说英文）

真流式：每 40–80ms 音频块增量解码，partial 回调驱动 UI 回显，**天然满足「实时回显 + 边说边纠」**；松手时 partial 已接近终稿，注入无感延迟。纯端侧、无网络、与 ROM 无关。

**C. sherpa-onnx + SenseVoice-Small（离线高精度）**
阿里 FunASR 的 SenseVoice-Small 在中文上显著优于 Whisper（错误率约一半），速度 ~169× realtime，手机上几秒录音亚秒级出稿，且自带标点。缺点是非流式。可以做**「伪流式」**：录音中每 1–2 秒对已录 buffer 增量转写刷新回显，尾部文字会被后续结果修正——这就是「实时回显 + 纠正」的另一种实现。

**D. whisper.cpp**：中文准确度和移动端流式速度双双落后，中文场景排除。

**E. 云端流式（讯飞 / 阿里 Paraformer 实时 / 腾讯）**：准确度和工程成熟度天花板，但 DSH 是本地 SSH 隧道自托管、隐私敏感场景，云端上传音频与产品定位冲突；且要付费 key。仅作对照，不建议。

### ⭐ 推荐组合：B + C（同插件双引擎）

录音中用流式 Zipformer 出 partial 实时回显 → 松手后用 SenseVoice 对整段音频重识别一次做**终稿纠正**，两者都走 `sherpa_onnx` 插件，一套运行时两个模型。若嫌模型体积大，裁剪为单方案：

- 预算小 → 只上 B 的 small 模型（流式体验优先）
- 预算大 → 只上 C + 伪流式（准确度优先）

## 3. 交互设计（长按相机按钮）

微信式「按住说话」：

```
长按月相按钮 onLongPressStart
  ├─ 请求麦克风权限（已有逻辑）
  ├─ 弹出录音浮层：波形/音量动画 + 实时 partial 文本回显
  ├─ onLongPressEnd / onLongPressCancel
  │    ├─ 上滑取消 → 丢弃
  │    └─ 正常松手 → final 文本 → composerBridge.insertText() 注入，不自动发送
```

- 浮层直接改造现有 `VoiceInputDialog`（partial 渲染、降级、取消都写好了）。
- 注入仍走 `__dshComposerBridge.insertText`，不自动发送，用户可再手动编辑——保留现有行为。
- 相机按钮原有单击（相册/拍照）不受影响，长按手势当前空闲。

## 4. 模型分发与工程细节

- **不打包进 APK**（避免 +200 MB）：首次使用语音时弹窗确认，从 GitHub releases / HuggingFace 镜像下载 zip 到 app 私有目录（`sherpa-onnx` 官方 Flutter 示例即此模式），显示进度；下载失败时回落方案 A。
- ABI：只保留 arm64-v8a 也能显著省体积（目标机型小米 13 / Android 12+ 均为 arm64）。
- 运行时：解码放 isolate，避免阻塞 UI 线程；`OnlineRecognizer` 流式对象随会话创建销毁。
- Feature flag：恢复 `voiceInputEnabled`（webview_screen.dart:41），或改为 `voiceInputMode = system | onnx | off` 三态便于灰度。

## 5. 工作量估计

| 项 | 估时 |
|---|---|
| sherpa_onnx 插件接入 + 模型下载管理 | 1–1.5 天 |
| VoiceInputDialog 改造（流式 partial 驱动 + 波形 UI） | 1 天 |
| 长按手势接线 + 注入回归测试 | 0.5 天 |
| （可选）SenseVoice 终稿纠正 | +1 天 |
| 真机验证（小米 13 + WiFi 设备）、MIUI 专项 | 0.5 天 |
| **合计（单引擎 B）** | **约 3 天** |
| **合计（B+C 双引擎）** | **约 4 天** |

## 6. 结论

1. **主方案：sherpa-onnx 流式 Zipformer（B）**，必要时叠加 SenseVoice 终稿纠正（B+C）。
2. 系统 SpeechRecognizer 降级为兜底通道，现有代码直接复用。
3. whisper.cpp（中文差、移动端流式不可用）与云端 ASR（定位冲突）排除。
4. 交互采用长按相机按钮「按住说话」，注入复用现有 composer bridge，无需动 Web 端。

## 参考来源

- [sherpa_onnx (pub.dev)](https://pub.dev/packages/sherpa_onnx)
- [sherpa-onnx Flutter 示例（含流式 Zipformer / SenseVoice）](https://github.com/k2-fsa/sherpa-onnx/blob/master/flutter/sherpa_onnx/example/example.md)
- [流式 Zipformer 模型列表（含 2025-06-30 中文版）](https://github.com/k2-fsa/sherpa/blob/master/docs/source/onnx/pretrained_models/online-transducer/zipformer-transducer-models.rst)
- [FunASR vs Whisper 中文基准（SenseVoice ~7.8% CER / 169× RT）](https://www.funasr.com/en/blog/funasr-vs-whisper-benchmark.html)
- [SenseVoice vs Whisper（CJK 准确度对比）](https://whispernotes.app/blog/sensevoice-fastest-cjk-transcription)
- [ASR 2025–2026 综述（Whisper 中文 CER 落后 5–10×）](https://ruoqijin.com/blog/asr-deep-dive-2025-2026)
- [whisper.cpp Android 流式 RTF 5–7 讨论](https://github.com/ggml-org/whisper.cpp/discussions/3567)
