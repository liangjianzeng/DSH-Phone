import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../config.dart';
import 'asr_engine.dart';
import 'asr_model_manager.dart';
import 'hotword_corrector.dart';

/// 端侧流式识别引擎：sherpa-onnx 流式 Zipformer（zh int8，chunk-16）。
///
/// - 识别器（模型）进程内加载一次、全局复用；每次按住说话建一个
///   [sherpa.OnlineStream]，松手后释放。
/// - 录音用 record 的 16kHz mono PCM16 流，逐块喂入解码，partial 文本
///   经 [partialText] 广播（endpoint 静音断句后自动定稿并继续监听）。
/// - 输出无标点（流式 transducer 特性），注入后可再编辑。
///
/// 识别增强档位（[ensureLoaded] 的 [enhanced]）与热词：
/// - sherpa-onnx 流式（Online）API 不支持 LM（LM 仅在离线 API 可用），
///   因此增强档位在同一模型上启用 beam search + blankPenalty：
///   - 解码 greedy_search → modified_beam_search（maxActivePaths 加大）；
///   - blankPenalty 抑制静音过度吞字。
/// - 热词两路（详见 [HotwordCorrector]）：词表内热词经 per-stream
///   [sherpa.OnlineRecognizer.createStream] 交 ContextGraph 偏置（需 beam，
///   故有词表内热词时标准档也自动切 beam）；词表外生僻字热词（模型打不出
///   的字）在输出端做同音后校正。每次按住说话从设置读最新热词表，改热词
///   即时生效。
class SherpaStreamingAsr implements StreamingAsrEngine {
  SherpaStreamingAsr._(this.modelDir, this.enhanced);

  final String modelDir;

  /// 当前会话是否增强档位（决定 start 时是否传热词）。
  final bool enhanced;

  static sherpa.OnlineRecognizer? _recognizer;

  /// 已加载识别器的形态签名（enhanced/hotwords/greedy，见 ensureLoaded）。
  static String? _loadedSignature;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _pcmSub;
  sherpa.OnlineStream? _stream;

  /// 词表外生僻字热词的同音后校正器（start 时按最新热词表配置）。
  final HotwordCorrector _corrector = HotwordCorrector();

  /// endpoint 静音断句后已定稿的文本（多次断句顺序拼接）。
  final StringBuffer _segments = StringBuffer();

  final StreamController<String> _partialCtrl =
      StreamController<String>.broadcast();
  bool _stopped = true;

  @override
  Stream<String> get partialText => _partialCtrl.stream;

  /// 加载识别器。模型文件必须已通过 [AsrModelManager.isReady] 校验，
  /// 否则抛 [StateError]。同档位幂等（进程内一次）；切换 [enhanced] 档位
  /// 会释放旧识别器并重新加载。
  static Future<void> ensureLoaded(String modelDir,
      {bool enhanced = false, bool hotwordsActive = false}) async {
    // 加载形态签名：仅增强 / 仅热词（也需 beam）/ 纯贪心。任一变化重载，
    // 相同签名幂等——start() 每次可放心调用做档位对齐。
    final signature =
        enhanced ? 'enhanced' : (hotwordsActive ? 'hotwords' : 'greedy');
    if (_recognizer != null && _loadedSignature == signature) return;
    // FFI 绑定必须先初始化（Flutter 走 DynamicLibrary.process()），
    // 否则 OnlineRecognizer 抛 "Please initialize sherpa-onnx first"。
    sherpa.initBindings();
    final sw = Stopwatch()..start();
    final beam = enhanced || hotwordsActive;
    final recognizer = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$modelDir/encoder.int8.onnx',
          decoder: '$modelDir/decoder.onnx',
          joiner: '$modelDir/joiner.int8.onnx',
        ),
        tokens: '$modelDir/tokens.txt',
        // 热词编码单元：本模型词表为字符级（含 byte fallback），cjkchar 让
        // EncodeHotwords 把热词逐字切分成 token；缺省空串会让热词编码直接
        // 失败（1.13.8 EncodeHotwords 实测）。
        modelingUnit: 'cjkchar',
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      ),
      // 热词（ContextGraph 偏置）只在 modified_beam_search 下生效（1.13.8
      // 源码 InitOnlineStream 实测，greedy 静默忽略）——因此"有词表内热词"
      // 的标准档位同样切 beam（8 路，开销可控）。
      decodingMethod: beam ? 'modified_beam_search' : 'greedy_search',
      maxActivePaths: enhanced ? 16 : 8,
      hotwordsScore: 3.0,
      blankPenalty: enhanced ? 0.5 : 0.0,
      enableEndpoint: true,
      // 按住说话场景：静音 1.2s 判定断句（句间停顿即定稿），长句 20s 兜底
      rule1MinTrailingSilence: 2.4,
      rule2MinTrailingSilence: 1.2,
      rule3MinUtteranceLength: 20,
    ));
    _recognizer?.free();
    _recognizer = recognizer;
    _loadedSignature = signature;
    debugPrint('[DSH][asr] recognizer loaded ($signature) '
        'in ${sw.elapsedMilliseconds}ms');
  }

  /// 创建会话（每次按住说话一个实例）。
  static Future<SherpaStreamingAsr> create(String modelDir,
      {bool enhanced = false}) async {
    await ensureLoaded(modelDir, enhanced: enhanced);
    return SherpaStreamingAsr._(modelDir, enhanced);
  }

  /// 启动完成后预热：模型文件已下载时在**后台 isolate** 预读文件到 OS 页缓存
  /// （按块读取并丢弃），**不阻塞主线程/UI、不导致启动黑屏**；首次按住说话
  /// 创建识别器时文件已在内存，IO 更快、卡顿更短。模型未下载（首次启动）
  /// 跳过，待首次使用时走下载引导后再加载。失败不阻塞启动。
  static Future<void> warmup() async {
    try {
      if (!await AsrModelManager.isReady()) return;
      final dir = await AsrModelManager.modelDir();
      await Isolate.run(() => _preloadFiles(dir));
      debugPrint('[DSH][asr] warmup: model files preloaded to page cache');
    } catch (e) {
      debugPrint('[DSH][asr] warmup skipped: $e');
    }
  }

  /// 后台 isolate：分块读取模型文件并丢弃，把文件页拉进 OS 页缓存。
  static void _preloadFiles(String dir) {
    for (final f in AsrModelManager.files) {
      final file = File(p.join(dir, f));
      if (!file.existsSync()) continue;
      try {
        final raf = file.openSync();
        try {
          // 每次读 1MB，读到 EOF（返回空）为止；不一次性整读，避免内存尖峰
          while (raf.readSync(1 << 20).isNotEmpty) {}
        } finally {
          raf.closeSync();
        }
      } catch (_) {}
    }
  }

  @override
  Future<void> start() async {
    _stopped = false;
    _segments.clear();
    // 从设置读取热词表（改动即时生效，无需重载识别器），归一化后分流
    // （sherpa 按换行切分每个热词，逗号连写会被当成一个整体热词而失效）：
    // - 词表内热词 → beam 解码器 ContextGraph 偏置（识别器若是 greedy，
    //   按 hotwords 档位自动重载，标准档也会升级为轻量 beam）；
    // - 词表外生僻字热词（如「彤/熠」等名字用字，模型物理打不出）→
    //   识别输出做同音后校正（见 HotwordCorrector）。
    final hotwordList = _normalizeHotwords(await SSHConfig.loadHotwords());
    await _corrector.configure(modelDir, hotwordList);
    await ensureLoaded(modelDir,
        enhanced: enhanced,
        hotwordsActive: _corrector.decoderHotwords.isNotEmpty);
    final recognizer = _recognizer;
    if (recognizer == null) {
      throw StateError('sherpa recognizer not loaded');
    }
    _stream = recognizer.createStream(
        hotwords: _corrector.decoderHotwords.join('\n'));
    final pcmStream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      autoGain: true,
      echoCancel: true,
      noiseSuppress: true,
    ));
    _pcmSub = pcmStream.listen(_onPcmChunk);
    debugPrint('[DSH][asr] session start');
  }

  /// PCM16LE 字节块 → [-1,1] Float32，喂入解码循环，产出 partial。
  void _onPcmChunk(Uint8List bytes) {
    final stream = _stream;
    final recognizer = _recognizer;
    if (_stopped || stream == null || recognizer == null || bytes.isEmpty) {
      return;
    }
    stream.acceptWaveform(
        samples: _pcm16ToFloat32(bytes), sampleRate: 16000);
    _decodeDrain(recognizer, stream);

    var text = _segments.toString() + recognizer.getResult(stream).text;
    if (recognizer.isEndpoint(stream)) {
      // 静音断句：当前句定稿、拼接，识别器状态复位后继续听下一句
      final segment = recognizer.getResult(stream).text.trim();
      if (segment.isNotEmpty) _segments.write(segment);
      recognizer.reset(stream);
      text = _segments.toString();
      debugPrint('[DSH][asr] endpoint, segment=$segment');
    }
    if (!_partialCtrl.isClosed) {
      _partialCtrl.add(_corrector.apply(text).trim());
    }
  }

  void _decodeDrain(sherpa.OnlineRecognizer recognizer,
      sherpa.OnlineStream stream) {
    var guard = 0;
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
      if (++guard > 10000) break; // 防御：异常时避免死循环
    }
  }

  @override
  Future<String> stop() async {
    _stopped = true;
    await _pcmSub?.cancel();
    _pcmSub = null;
    try {
      await _recorder.stop();
    } catch (e) {
      debugPrint('[DSH][asr] recorder stop error: $e');
    }
    final stream = _stream;
    final recognizer = _recognizer;
    var finalText = _segments.toString();
    if (stream != null && recognizer != null) {
      stream.inputFinished();
      _decodeDrain(recognizer, stream);
      finalText += recognizer.getResult(stream).text;
      stream.free();
    }
    _stream = null;
    final corrected = _corrector.apply(finalText).trim();
    debugPrint('[DSH][asr] session stop, final=${corrected.length} chars');
    return corrected;
  }

  @override
  Future<void> dispose() async {
    if (!_partialCtrl.isClosed) await _partialCtrl.close();
    await _recorder.dispose();
  }

  /// 静态文本快照（浮层展示当前累计文本用）。
  String get currentText => _segments.toString();

  /// 把热词表归一化为逐词列表：兼容用户以逗号/斜杠/换行/全角逗号混填的词表，
  /// 去掉空串与重复项——sherpa 按换行（含 '/'，CreateStream 会把斜杠转义成
  /// 换行）切分每个热词，逗号连写会被当成一个整体热词导致不生效。
  static List<String> _normalizeHotwords(String raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final w in raw.split(RegExp(r'[,，/\n\r]'))) {
      final t = w.trim();
      if (t.isNotEmpty && seen.add(t)) out.add(t);
    }
    return out;
  }

  static Float32List _pcm16ToFloat32(Uint8List bytes) {
    final sampleCount = bytes.length ~/ 2;
    final data = ByteData.sublistView(bytes);
    final samples = Float32List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return samples;
  }
}
