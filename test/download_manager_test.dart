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

  group('DownloadManager 任务键与文件名', () {
    test('同一文件的不同分隔符形态归一到同一键（防同文件双份任务）', () {
      expect(DownloadManager.taskKeyOf(r'E:\a\b.apk'),
          DownloadManager.taskKeyOf('E:/a/b.apk'));
      expect(DownloadManager.taskKeyOf('/a//b/c.md'), '/a/b/c.md');
      expect(DownloadManager.taskKeyOf('/a/b/'), '/a/b');
    });

    test('键不折叠大小写（Linux 上大小写敏感）', () {
      expect(DownloadManager.taskKeyOf('/a/Readme.md'),
          isNot(DownloadManager.taskKeyOf('/a/readme.md')));
    });

    test('basename 去掉 ?query 与 #fragment（防 SAF 生成非法文件名）', () {
      expect(DownloadManager.basename('/api/files/app.apk?sign=abc'),
          'app.apk');
      expect(DownloadManager.basename(r'E:\x\报告.md#f'), '报告.md');
      expect(DownloadManager.basename('plain.txt'), 'plain.txt');
    });

    test('并发闸门常量存在且留有余量（远端 MaxSessions 通常 10）', () {
      expect(DownloadManager.maxConcurrentDownloads, greaterThan(0));
      expect(DownloadManager.maxConcurrentDownloads, lessThanOrEqualTo(3));
    });
  });

}
