import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_engine.dart';

/// 端侧流式识别引擎：sherpa-onnx 流式 Zipformer（zh int8，chunk-16）。
///
/// - 识别器（模型）进程内加载一次、全局复用；每次按住说话建一个
///   [sherpa.OnlineStream]，松手后释放。
/// - 录音用 record 的 16kHz mono PCM16 流，逐块喂入解码，partial 文本
///   经 [partialText] 广播（endpoint 静音断句后自动定稿并继续监听）。
/// - 输出无标点（流式 transducer 特性），注入后可再编辑。
class SherpaStreamingAsr implements StreamingAsrEngine {
  SherpaStreamingAsr._(this.modelDir);

  final String modelDir;

  static sherpa.OnlineRecognizer? _recognizer;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _pcmSub;
  sherpa.OnlineStream? _stream;

  /// endpoint 静音断句后已定稿的文本（多次断句顺序拼接）。
  final StringBuffer _segments = StringBuffer();

  final StreamController<String> _partialCtrl =
      StreamController<String>.broadcast();
  bool _stopped = true;

  @override
  Stream<String> get partialText => _partialCtrl.stream;

  /// 加载识别器（幂等，进程内一次）。模型文件必须已通过
  /// [AsrModelManager.isReady] 校验，否则抛 [StateError]。
  static Future<void> ensureLoaded(String modelDir) async {
    if (_recognizer != null) return;
    // FFI 绑定必须先初始化（Flutter 走 DynamicLibrary.process()），
    // 否则 OnlineRecognizer 抛 "Please initialize sherpa-onnx first"。
    sherpa.initBindings();
    final sw = Stopwatch()..start();
    final recognizer = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$modelDir/encoder.int8.onnx',
          decoder: '$modelDir/decoder.onnx',
          joiner: '$modelDir/joiner.int8.onnx',
        ),
        tokens: '$modelDir/tokens.txt',
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      ),
      decodingMethod: 'greedy_search',
      enableEndpoint: true,
      // 按住说话场景：静音 1.2s 判定断句（句间停顿即定稿），长句 20s 兜底
      rule1MinTrailingSilence: 2.4,
      rule2MinTrailingSilence: 1.2,
      rule3MinUtteranceLength: 20,
    ));
    debugPrint('[DSH][asr] recognizer loaded in ${sw.elapsedMilliseconds}ms');
    _recognizer = recognizer;
  }

  /// 创建会话（每次按住说话一个实例）。
  static Future<SherpaStreamingAsr> create(String modelDir) async {
    await ensureLoaded(modelDir);
    return SherpaStreamingAsr._(modelDir);
  }

  @override
  Future<void> start() async {
    final recognizer = _recognizer;
    if (recognizer == null) {
      throw StateError('sherpa recognizer not loaded');
    }
    _stopped = false;
    _segments.clear();
    _stream = recognizer.createStream();
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
    if (!_partialCtrl.isClosed) _partialCtrl.add(text.trim());
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
    debugPrint('[DSH][asr] session stop, final=${finalText.length} chars');
    return finalText.trim();
  }

  @override
  Future<void> dispose() async {
    if (!_partialCtrl.isClosed) await _partialCtrl.close();
    await _recorder.dispose();
  }

  /// 静态文本快照（浮层展示当前累计文本用）。
  String get currentText => _segments.toString();

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
