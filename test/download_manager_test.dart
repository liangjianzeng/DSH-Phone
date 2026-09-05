import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/download_manager.dart';

void main() {
  group('DownloadProgress.fraction', () {
    test('进度比例正确', () {
      final p = DownloadProgress(25, 100);
      expect(p.fraction, closeTo(0.25, 1e-9));
    });

    test('总量未知时返回 0', () {
      final p = DownloadProgress(10, 0);
      expect(p.fraction, 0);
    });

    test('超过总量时钳制为 1', () {
      final p = DownloadProgress(120, 100);
      expect(p.fraction, 1.0);
    });

    test('负数进度钳制为 0', () {
      final p = DownloadProgress(-5, 100);
      expect(p.fraction, 0);
    });
  });

  group('DownloadManager 常量', () {
    test('内存下载上限为 256MB', () {
      expect(DownloadManager.maxDownloadBytes, 256 * 1024 * 1024);
    });
  });
}
