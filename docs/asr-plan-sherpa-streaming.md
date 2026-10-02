# 实现方案：B 路线 —— sherpa-onnx 流式 Zipformer 语音输入

日期：2026-10-02
前置调研：[asr-on-device-research.md](./asr-on-device-research.md)
状态：方案设计，未实施

## 1. sherpa-onnx 流式 Zipformer 具体情况

### 1.1 技术原理（为什么它能在手机上真流式）

- **Zipformer transducer**（RNN-T 变体）：encoder 流式运行，每次只处理一个固定 chunk 的音频帧，配合有限长度的左上下文，**不需要听完整段音频**；decoder/joiner 极小，逐 token 增量解码。
- 官方多数据集中文版采用 `chunk-16-left-128` 配置（encoder 帧为 40ms 一帧）：**出字粒度约 0.6s，上下文约 5s**——这就是「边说边出字」的物理来源；双语 small 版还提供 chunk 32/64/96 三档（chunk 越大越准、越慢）。
- int8 量化 ONNX + ONNX Runtime 推理，纯 CPU（可配 `numThreads`），无 NPU/GPU 依赖，任何 Android 8+ 机型行为一致——**这正是摆脱 ROM 差异的关键**。

### 1.2 候选模型档位（官方发布，含真实 CER）

CER 来自 icefall 官方 RESULTS.md（multi_zh-hans 训练，transducer greedy 解码）：

| 模型 | 参数量 | int8 体积（encoder+decoder+joiner） | 流式 CER | 备注 |
|---|---|---|---|---|
| `streaming-zipformer-zh-xlarge-int8-2025-06-30` | ~700M | **~735 MB** | test_net 6.89% / test_meeting 5.85%（离线解码） | 手机可跑但下载/内存负担大，不推荐 |
| `streaming-zipformer-zh-int8-2025-06-30`（large） | ~160M | **~160 MB** | **test_net 8.54% / test_meeting 7.91%**，aishell-1 test 1.91% | ⭐ 主推：准确度/体积平衡 |
| `streaming-zipformer-multi-zh-hans-2023-12-12` | ~69M | **~69 MB** | 未公布（同数据集非流式 69M 版 ~8.2%） | 轻量选项 |
| `streaming-zipformer-bilingual-zh-en-2023-02-20` | — | ~190 MB | 未公布 | 需要中英混说时选 |
| `streaming-zipformer-small-bilingual-zh-en-2023-02-16` | — | **~47 MB** | 未公布 | 最小可用，英文混说弱 |
| `streaming-zipformer-zh-14M-2023-02-23` | 14M | **~25 MB** | 未公布（老模型） | 快速验证用 |

**默认建议：`streaming-zipformer-zh-int8-2025-06-30`（large，~160MB）**。小米 13（骁龙 8 Gen 2）跑 int8 流式推理解码余量充足；首次下载 160MB 走 hf-mirror.com 镜像，国内可达。

### 1.3 Flutter 插件与 API（官方 flutter-examples/streaming_asr 的实际用法）

```dart
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

// 1. 初始化（一次）
final recognizer = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
  modelConfig: sherpa.OnlineModelConfig(
    transducer: sherpa.OnlineTransducerModelConfig(
      encoder: '$dir/encoder.int8.onnx',
      decoder: '$dir/decoder.onnx',
      joiner: '$dir/joiner.int8.onnx',
    ),
    tokens: '$dir/tokens.txt',
    numThreads: 2,
    provider: 'cpu',
  ),
  decodingMethod: 'modified_beam_search',
  enableEndpointDetection: true,   // 静音自动断句
));

// 2. 每次按住说话：建流 → 喂音频 → 解码循环
final stream = recognizer.createStream();
// record 插件录 16kHz mono 16bit PCM 流，每块喂入：
stream.acceptWaveform(sampleRate: 16000, samples: chunk);
while (recognizer.isReady(stream)) recognizer.decode(stream);
final partial = recognizer.getResult(stream).text;  // ← 实时回显
if (recognizer.isEndpoint(stream)) { /* 静音断句：取稿、reset，可继续说 */ }

// 3. 松手：inputFinished → 取终稿
stream.inputFinished();
```

插件按 ABI 分包（`sherpa_onnx_android_arm64` 等），minSdk 兼容 23，无系统权限以外的新要求。`RECORD_AUDIO` 权限与 `<queries>` 声明项目里已有。

### 1.4 已知短板（如实评估）

1. **无标点**：流式 transducer 只出汉字（含数字/字母），注入的是无标点文本。缓解：a) 输入框场景可接受，用户注入后可再编辑；b) 可选叠加 sherpa-onnx 离线标点模型（ct-transformer，另计体积）；c) 这也是叠加 SenseVoice 终稿纠正的又一个理由（其自带标点）。
2. **数字/日期格式**：训练为字符级，输出「二零二六年」这类汉字数字而非 `2026`。
3. **热词/专有名词**：无开箱热词支持；DSH 领域词（如自托管相关名词）识别不准时只能靠用户改。
4. **长句上下文**：左上下文 ~5s，远超普通指令场景，实际无损。

## 2. 实现方案（DSH-Phone 落地）

### 2.1 新增/改动文件

| 文件 | 内容 | 状态 |
|---|---|---|
| `lib/asr/asr_engine.dart` | 抽象接口：`start()/stop()/partialStream/finalText()` | 新增 |
| `lib/asr/sherpa_streaming_asr.dart` | OnlineRecognizer 封装（建流/喂流/endpoint/释放），isolate 内跑解码 | 新增 |
| `lib/asr/system_asr.dart` | 现有 `speech_to_text` 逻辑抽出来实现同接口 | 由 `voice_input.dart` 重构 |
| `lib/asr/model_manager.dart` | 模型下载（GitHub release + hf-mirror 兜底）、解压、版本校验、进度流 | 新增 |
| `lib/voice_input.dart` | 改造为「按住说话」浮层：波形动画 + partial 回显 + 上滑取消 | 改造 |
| `lib/webview_screen.dart` | 相机按钮接 `onLongPressStart/End/MoveUpdate`（上滑取消手势）；`voiceInputEnabled` 改三态 `voiceInputMode: off/system/onnx` | 改动 |
| `pubspec.yaml` | 加 `sherpa_onnx`、`record`（PCM 流录音）；`speech_to_text` 保留 | 改动 |

### 2.2 交互时序

```
长按月相按钮（onLongPressStart）
  ├─ 权限 OK → 弹录音浮层（振动反馈）
  ├─ 若模型未就绪 → 提示「首次使用需下载 ~160MB」→ 进度条 → 就绪（失败回落 system_asr）
  ├─ record 开始 16k PCM 流 → isolate 建流喂流
  ├─ partial 文本实时刷浮层（~0.6s 出字粒度），endpoint 断句后追加并 reset
  ├─ onLongPressMoveUpdate：手指上移超阈值 → 浮层变「松开取消」
  ├─ onLongPressEnd：
  │    ├─ 取消态 → 丢弃，pop
  │    └─ 正常松手 → inputFinished → 终稿 → pop(finalText)
  └─ WebViewScreen 收到 finalText → composerBridge.insertText()（现链路，不自动发送）
```

### 2.3 模型分发（不打包进 APK，首次使用下载，支持断点续传）

**原则：APK 不含任何权重；模型文件齐全且校验通过后，语音能力才真正启用。**

- **按文件下载**：一个模型仅 4 个文件（`encoder.int8.onnx` / `decoder.onnx` / `joiner.int8.onnx` / `tokens.txt`），大头只有 encoder（large 档 ~160MB）。按文件下载粒度细，单文件重下代价小。
- **断点续传**：GitHub Releases 与 HuggingFace（`hf-mirror.com` 国内镜像）均支持 HTTP `Range: bytes=offset-`。下载到 `models/asr/<name>/xxx.onnx.part`，完成后 rename 落盘；`.part` 文件与元数据（url / 已下字节 / etag）持久化在私有目录，**App 被杀、断网、切后台，重启后从断点继续**。
- **实现选 `background_downloader`**（官方维护，底层 Android WorkManager/DownloadManager）：内置断点续传、后台继续下载、进度/暂停/恢复事件流，不用手写 Range 协议。（备选：`dio` + `ResponseType.stream` 手写续传，控制粒度细但要自管跨会话状态，不推荐。）
- **下载源**：主源 GitHub Releases（`asr-models` tag），兜底 `hf-mirror.com` 镜像；走系统网络，与 SSH 隧道无关。
- **启用门槛（状态机）**：
  1. `missing`：文件不全 → 长按入口显示「首次使用需下载 ~160MB」引导页（含 WiFi-only 开关、剩余空间检查，要求空闲 ≥ 2× 模型体积）；
  2. `downloading`：进度条 + 可暂停，断点续传；
  3. `verifying`：文件齐全 → 初始化一次 `OnlineRecognizer` 试加载 → 成功则写版本标记 `models/asr/<name>/READY`；
  4. `ready`：启用流式引擎，入口切换为「按住说话」；
  5. 校验/加载失败 → 自动删除模型目录回到 `missing`，回落 `system_asr` 保证流程不断。
- 「语音输入设置」提供删除模型、切换档位（large ↔ small）、WiFi-only 开关。

### 2.4 降级链（复用现有代码）

```
onnx 模型就绪？ ──否/加载失败──→ system_asr（现有 speech_to_text + MIUI 哨兵）
      │是                                │仍失败
      └─ 录音/解码异常 ─────────────────→ 提示 + 页面内麦克风入口提示（现逻辑）
```

## 3. 效果预期

### 3.1 准确度

| 场景 | 预期表现 |
|---|---|
| 安静环境、普通话短句指令（主要场景，5–30 字） | 实际错误率低于 test_net 流式基准 8.54%（该基准含嘈杂会议/长语音），日常短句预期 **3–6% 字错率**，且**每次识别结果稳定一致**（不像 ROM 服务黑盒） |
| 嘈杂/远场 | 与基准 test_meeting 7.91% 量级相当，可用但不完美 |
| 中英混说 | 默认中文 large 不含英文，混说会错；需要的话切双语模型 |
| 对比现状 | 系统识别在谷歌服务机型上准确度接近，但 **MIUI 上「能不能用」都不保证**——本方案把下限从「随机」抬到「稳定 ~95%」 |

### 3.2 延迟与实时性

- 首字延迟：按住后约 **0.5–1s** 出第一段 partial（chunk 0.6s + 首次推理）。
- 回显粒度：约 **0.6s 更新一次**，连续滚动出字，说错可实时看到——满足「实时回显」。
- 松手到注入：**< 0.5s**（终稿与最后一个 partial 差异极小）。

### 3.3 资源占用（小米 13 实测前的估计）

- 运行内存：模型 int8 ~160MB + 运行时，预计峰值 **300–400MB**；仅在按住期间占用，松手可释放。
- CPU：解码线程 2 个，按住期间中等负载；无持续后台消耗（对比：系统识别同样是按住即用，体感无差异）。
- 电量/流量：录音期间与系统方案相当；模型下载一次性 160MB。

### 3.4 体验闭环（相对挂起前版本的净变化）

1. 长按相机按钮即说即显（旧版是点击→菜单→弹窗，多一步）；
2. 出字速度和稳定性不随 ROM 漂移，MIUI 专项问题（误报/启动即拒/无转写）从机制上消除，降级逻辑仅作保险；
3. 无标点是唯一可感知的退化，可用 SenseVoice 终稿纠正（+1 天/+150MB）补齐。

## 4. 实施排期

| 阶段 | 内容 | 估时 |
|---|---|---|
| P1 引擎接入 | sherpa_onnx + record 接入，`sherpa_streaming_asr.dart`，官方示例跑通 | 1 天 |
| P2 模型管理 | 下载/解压/版本/镜像兜底 + 首次启用引导 UI | 1 天 |
| P3 交互接线 | 按住说话浮层改造、长按手势、上滑取消、注入回归 | 1 天 |
| P4 验证 | 小米 13 真机 + WiFi 设备：延迟/内存实测、嘈杂环境、降级链、连续说 3 段不停顿 | 0.5 天 |
| （可选 P5） | SenseVoice 终稿纠正 + 标点 | +1 天 |
| **合计** | 单引擎 B | **~3.5 天** |

## 5. 验收标准

1. 小米 13：长按→说话→松手，文本注入输入框，全程无卡顿，松手后 0.5s 内出稿；
2. 同一句话连续 5 次识别结果一致（稳定性验收）；
3. 飞行模式下全流程可用（真端侧验收）；
4. 模型未下载/下载失败时自动走系统识别，流程不断；
6. 断点续传：下载中途杀掉 App / 断网，重进后从断点继续，不重新下载；校验通过前入口不可用。
5. 单击相机按钮的相册/拍照功能无回归。

## 参考来源

- [icefall multi_zh-hans RESULTS.md（CER 原始数据）](https://github.com/k2-fsa/icefall/blob/master/egs/multi_zh-hans/ASR/RESULTS.md)
- [sherpa-onnx 流式 Zipformer 模型列表与体积](https://github.com/k2-fsa/sherpa/blob/master/docs/source/onnx/pretrained_models/online-transducer/zipformer-transducer-models.rst)
- [sherpa-onnx Flutter 流式示例源码](https://github.com/k2-fsa/sherpa-onnx/tree/master/flutter-examples/streaming_asr)
- [sherpa_onnx pub.dev](https://pub.dev/packages/sherpa_onnx)
