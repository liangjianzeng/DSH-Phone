import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/asr/hotword_corrector.dart';

/// 词表：用与手机同款的模型 tokens.txt（环境变量 DSH_TOKENS 指向文件），
/// 缺省时用内置迷你词表跑通同音校正主逻辑。
void main() {
  final tokensPath = Platform.environment['DSH_TOKENS'];

  Future<String> prepareVocab() async {
    final dir = Directory.systemTemp.createTempSync('asr_vocab');
    if (tokensPath != null && File(tokensPath).existsSync()) {
      File(tokensPath).copySync('${dir.path}/tokens.txt');
    } else {
      // 迷你词表：常用字在表内，彤/熠 不在（模拟真实模型词表形态）
      File('${dir.path}/tokens.txt').writeAsStringSync('''
<blk> 0
<sos/eos> 1
<unk> 2
大 1977
小 1949
同 1857
异 961
人 100
工 101
智 102
能 103
''');
    }
    return dir.path;
  }

  test('词表外生僻字热词走同音校正：大同小异 → 大彤小熠', () async {
    final dir = await prepareVocab();
    final c = HotwordCorrector();
    await c.configure(dir, ['大彤小熠']);
    // 彤/熠 不在词表 → 不进解码器
    expect(c.decoderHotwords, isEmpty);
    expect(c.apply('这话大同小异吧'), '这话大彤小熠吧');
    expect(c.apply('大彤小熠真棒'), '大彤小熠真棒'); // 幂等
    expect(c.apply('今天天气不错'), '今天天气不错'); // 不相关文本不动
  });

  test('词表内热词走解码器偏置（不进校正）', () async {
    final dir = await prepareVocab();
    final c = HotwordCorrector();
    await c.configure(dir, ['人工智能']);
    expect(c.decoderHotwords, ['人工智能']);
    expect(c.apply('人工智能'), '人工智能');
  });

  test('长词优先：并存短词长词时按长词整体替换', () async {
    final dir = await prepareVocab();
    final c = HotwordCorrector();
    await c.configure(dir, ['大彤小熠好', '大彤小熠']);
    // 5 字窗口与「大彤小熠好」同音 → 长词整体替换，而非短词先切碎
    expect(c.apply('大同小异好'), '大彤小熠好');
    expect(c.apply('大同小异'), '大彤小熠');
  });

  test('纯英文热词丢弃（模型编码与同音都不支持）', () async {
    final dir = await prepareVocab();
    final c = HotwordCorrector();
    await c.configure(dir, ['DeepSeek']);
    expect(c.decoderHotwords, isEmpty);
    expect(c.apply('deepseek'), 'deepseek');
  });
}
