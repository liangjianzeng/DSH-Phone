import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_phone/asr/asr_model_manager.dart';

/// 模型完整性判定（纯函数）：尺寸清单 × 实际大小 → 需要（重新）下载的文件。
/// 钉死的场景来自评审结论——一次截断/0 字节文件就让识别器永久卡死、
/// 重试又"已存在跳过"，必须把损坏纳入 missing。
void main() {
  group('filesNeedingDownload（模型完整性判定）', () {
    const files = ['a.txt', 'b.onnx'];

    List<String> need(Map<String, int?> actual, Map<String, int>? manifest) =>
        AsrModelManager.filesNeedingDownload(
            files: files, actualSizes: actual, manifest: manifest);

    test('全部存在且与清单相符 → 无缺口', () {
      expect(need({'a.txt': 10, 'b.onnx': 20}, {'a.txt': 10, 'b.onnx': 20}),
          isEmpty);
    });

    test('缺文件 → 需要下载', () {
      expect(need({'a.txt': 10, 'b.onnx': null}, {'a.txt': 10, 'b.onnx': 20}),
          ['b.onnx']);
    });

    test('0 字节文件（截断典型形态）→ 需要下载', () {
      expect(need({'a.txt': 0, 'b.onnx': 20}, {'a.txt': 10, 'b.onnx': 20}),
          ['a.txt']);
    });

    test('实际尺寸与清单不符（截断/文件系统异常）→ 需要下载', () {
      expect(need({'a.txt': 10, 'b.onnx': 19}, {'a.txt': 10, 'b.onnx': 20}),
          ['b.onnx']);
    });

    test('旧装无清单：文件存在且 >0 即就绪，不强制重下 160MB', () {
      expect(need({'a.txt': 10, 'b.onnx': 20}, null), isEmpty);
    });

    test('无清单时 0 字节仍判损坏（清单缺失不放松 0 字节底线）', () {
      expect(need({'a.txt': 0, 'b.onnx': 20}, null), ['a.txt']);
    });

    test('清单只记了部分文件：其余仅查存在/非 0', () {
      expect(need({'a.txt': 10, 'b.onnx': 5}, {'a.txt': 10}), isEmpty);
    });

    test('清单记录尺寸为 0 视为无记录（不反向卡死健康文件）', () {
      expect(need({'a.txt': 10, 'b.onnx': 5}, {'a.txt': 10, 'b.onnx': 0}),
          isEmpty);
    });
  });
}
