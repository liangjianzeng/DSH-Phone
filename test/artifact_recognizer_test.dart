import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/artifact_recognizer.dart';

void main() {
  group('ArtifactRules.typeOfPath', () {
    test('资源后缀归为 resource', () {
      expect(ArtifactRules.typeOfPath('/a/b/app.apk'), ArtifactType.resource);
      expect(ArtifactRules.typeOfPath('archive.zip'), ArtifactType.resource);
      expect(ArtifactRules.typeOfPath('image.PNG'), ArtifactType.resource);
    });

    test('可查看文本后缀归为 file', () {
      expect(ArtifactRules.typeOfPath('note.md'), ArtifactType.file);
      expect(ArtifactRules.typeOfPath('script.py'), ArtifactType.file);
      expect(ArtifactRules.typeOfPath('config.yaml'), ArtifactType.file);
    });

    test('无明确后缀默认按可查看文本处理', () {
      expect(ArtifactRules.typeOfPath('README'), ArtifactType.file);
    });

    test('大小写不敏感', () {
      expect(ArtifactRules.typeOfPath('APP.APK'), ArtifactType.resource);
      expect(ArtifactRules.typeOfPath('Note.MD'), ArtifactType.file);
    });
  });

  group('ArtifactRules.isFileUrl', () {
    test('命中文件前缀', () {
      expect(ArtifactRules.isFileUrl('/api/files/abc'), isTrue);
      expect(ArtifactRules.isFileUrl('/files/abc'), isTrue);
    });

    test('命中文件后缀', () {
      expect(ArtifactRules.isFileUrl('/download/readme.md'), isTrue);
      expect(ArtifactRules.isFileUrl('/data/note.html'), isTrue);
    });

    test('普通页面 URL 不是文件', () {
      expect(ArtifactRules.isFileUrl('/'), isFalse);
      expect(ArtifactRules.isFileUrl('/conversation/1'), isFalse);
    });
  });

  group('ArtifactRules.isCodeTarget', () {
    test('PRE 与 CODE 命中', () {
      expect(ArtifactRules.isCodeTarget('PRE'), isTrue);
      expect(ArtifactRules.isCodeTarget('CODE'), isTrue);
    });

    test('其他标签不命中', () {
      expect(ArtifactRules.isCodeTarget('DIV'), isFalse);
      expect(ArtifactRules.isCodeTarget('A'), isFalse);
    });
  });

  group('parseArtifactHit', () {
    test('解析完整字段', () {
      final hit = parseArtifactHit({
        'type': 'markdown',
        'url': '/files/doc.md',
        'language': '',
        'content': '# 标题',
        'path': '/root/doc.md',
      });
      expect(hit.type, ArtifactType.markdown);
      expect(hit.url, '/files/doc.md');
      expect(hit.content, '# 标题');
      expect(hit.path, '/root/doc.md');
    });

    test('未知类型降级为 none', () {
      final hit = parseArtifactHit({'type': 'weird'});
      expect(hit.isNone, isTrue);
    });

    test('缺失字段降级为空值', () {
      final hit = parseArtifactHit({});
      expect(hit.isNone, isTrue);
      expect(hit.url, isEmpty);
      expect(hit.content, isEmpty);
      expect(hit.path, isEmpty);
    });

    test('文件型带资源后缀强制归为资源', () {
      final hit = parseArtifactHit({
        'type': 'file',
        'url': '/api/files/app.apk',
        'path': '/root/app.apk',
      });
      expect(hit.type, ArtifactType.resource);
    });

    test('文件型带文本后缀保持 file', () {
      final hit = parseArtifactHit({
        'type': 'file',
        'url': '/api/files/note.md',
        'path': '/root/note.md',
      });
      expect(hit.type, ArtifactType.file);
    });

    test('dirs 只保留非空字符串', () {
      final hit = parseArtifactHit({
        'type': 'code',
        'dirs': <Object?>['/root', '', 42, '/var'],
      });
      expect(hit.dirs, ['/root', '/var']);
    });

    test('类型大小写不敏感', () {
      final hit = parseArtifactHit({'type': 'RESOURCE'});
      expect(hit.type, ArtifactType.resource);
    });
  });
}
