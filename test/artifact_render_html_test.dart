import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/artifact_render_html.dart';

void main() {
  group('ArtifactWebDocument.parseDelimited', () {
    test('逗号分隔 + 表头', () {
      final rows = ArtifactWebDocument.parseDelimited('a,b,c\n1,2,3\n');
      expect(rows, [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
    });

    test('引号包裹的字段内分隔符与换行不拆列', () {
      final rows = ArtifactWebDocument.parseDelimited('name,note\n"张三","a,b"\n"x","l1\nl2"\n');
      expect(rows.length, 3);
      expect(rows[1], ['张三', 'a,b']);
      expect(rows[2], ['x', 'l1\nl2']);
    });

    test('双写引号还原为单个引号', () {
      final rows = ArtifactWebDocument.parseDelimited('a\n"say ""hi"""\n');
      expect(rows[1].first, 'say "hi"');
    });

    test('CRLF 与末尾空行不产生垃圾行', () {
      final rows = ArtifactWebDocument.parseDelimited('a,b\r\n1,2\r\n\r\n');
      expect(rows.length, 2);
      expect(rows.last, ['1', '2']);
    });

    test('分号/制表符/竖线可自动识别', () {
      expect(ArtifactWebDocument.detectDelimiter('a;b;c'), ';');
      expect(ArtifactWebDocument.detectDelimiter('a\tb\tc'), 'Tab');
      expect(ArtifactWebDocument.detectDelimiter('a|b|c'), '|');
      expect(ArtifactWebDocument.detectDelimiter('a,b;c'), ',');
    });

    test('字段内含分隔符（引号内）不影响分隔符猜测', () {
      final rows = ArtifactWebDocument.parseDelimited('a,b\n"x,y",2\n');
      expect(rows[1], ['x,y', '2']);
    });
  });

  group('ArtifactWebDocument.prettyJson', () {
    test('紧凑 JSON 展开为缩进格式', () {
      expect(ArtifactWebDocument.prettyJson('{"a":1,"b":[1,2]}'),
          '{\n  "a": 1,\n  "b": [\n    1,\n    2\n  ]\n}');
    });

    test('坏 JSON 原样返回（不吞内容）', () {
      const broken = '{"a":1,,}';
      expect(ArtifactWebDocument.prettyJson(broken), broken);
    });
  });

  group('ArtifactWebDocument.document', () {
    test('代码内容做 HTML 转义（防成果内容注入标签）', () {
      final html = ArtifactWebDocument.document(
        kind: ArtifactRenderKind.code,
        content: '<script>alert(1)</script>',
        dark: false,
      );
      expect(html, isNot(contains('<script>alert(1)</script>')));
      expect(html, contains('&lt;script&gt;'));
    });

    test('深色模式切换生效', () {
      final dark = ArtifactWebDocument.document(
        kind: ArtifactRenderKind.markdown,
        content: '# t',
        dark: true,
      );
      expect(dark, contains('data-theme="dark"'));
      expect(dark, contains('color-scheme: dark'));
    });

    test('CSV 渲染出真表格（曾被 Markdown 挤成一段）', () {
      final html = ArtifactWebDocument.document(
        kind: ArtifactRenderKind.csv,
        content: 'a,b\n1,2\n',
        dark: false,
      );
      expect(html, contains('<table>'));
      expect(html, contains('<th>a</th>'));
      expect(html, contains('<td>2</td>'));
    });

    test('Markdown 表格扩展可用（gitHubWeb）', () {
      final html = ArtifactWebDocument.document(
        kind: ArtifactRenderKind.markdown,
        content: '| a | b |\n|---|---|\n| 1 | 2 |\n',
        dark: false,
      );
      expect(html, contains('<table>'));
      expect(html, contains('<td>1</td>'));
    });

    test('HTML 成果原样透传（保留脚本与样式）', () {
      final html = ArtifactWebDocument.document(
        kind: ArtifactRenderKind.html,
        content: '<div class="card">报表</div>',
        dark: false,
      );
      expect(html, contains('<div class="card">报表</div>'));
    });
  });
}
