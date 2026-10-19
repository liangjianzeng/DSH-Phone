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

  group('ArtifactRules 带查询串/片段的后缀判定（回归：?token= 让二进制被当文本）', () {
    test('带 ?query 的资源仍判为 resource', () {
      expect(ArtifactRules.typeOfPath('/api/files/app.apk?token=abc'),
          ArtifactType.resource);
      expect(ArtifactRules.typeOfPath('E:\\Work\\x.zip#sha=1'),
          ArtifactType.resource);
    });

    test('结尾斜杠不影响后缀判定', () {
      expect(ArtifactRules.typeOfPath('/a/b/app.apk/'), ArtifactType.resource);
    });

    test('isFileUrl 对带查询串的 .md 生效', () {
      expect(ArtifactRules.isFileUrl('/api/files/x.md?token=1'), isTrue);
      expect(ArtifactRules.isFileUrl('/api/files/x.MD#frag'), isTrue);
      expect(ArtifactRules.isFileUrl('/chat/123'), isFalse);
    });

    test('新补的常见后缀可识别', () {
      expect(ArtifactRules.typeOfPath('run.log'), ArtifactType.file);
      expect(ArtifactRules.typeOfPath('App.tsx'), ArtifactType.file);
      expect(ArtifactRules.typeOfPath('lib.so.1'), ArtifactType.resource);
      expect(ArtifactRules.typeOfPath('pkg.deb'), ArtifactType.resource);
      expect(ArtifactRules.typeOfPath('pkg.jar'), ArtifactType.resource);
    });

    test('isImageSuffix 覆盖常见图片', () {
      expect(ArtifactRules.isImageSuffix('/a/b.png?token=x'), isTrue);
      expect(ArtifactRules.isImageSuffix('/a/b.md'), isFalse);
    });
  });

  group('parseArtifactHit 链接型成果', () {
    test('只有 url 的资源链接强制归 resource（二进制不进文本查看器）', () {
      final hit = parseArtifactHit({
        'type': 'file',
        'url': 'http://127.0.0.1:3080/api/files/app.apk?sign=zz',
      });
      expect(hit.type, ArtifactType.resource);
    });

    test('JS 侧 fetch 失败原因随 error 透出', () {
      final hit = parseArtifactHit({
        'type': 'file',
        'url': '/api/files/x.md',
        'content': '',
        'error': 'HTTP 401（登录态失效，需重新填写 Token）',
      });
      expect(hit.error, contains('401'));
    });
  });

}
