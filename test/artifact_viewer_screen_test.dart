import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/artifact_recognizer.dart';
import 'package:dsh_phone/artifact_viewer_screen.dart';
import 'package:dsh_phone/tunnel_service.dart' show
    RemoteFailureKind, RemoteReadException;

/// 查看器的**布局**回归测试。
///
/// 为什么是 widget test 而不是纯单元测试：这一层真出过两次线上问题都是
/// "布局约束错"——原生 CSV 只给横向滚动导致表格纵向溢出成黄黑花屏、
/// 代码块缺横向滚动导致长行被折行。这类只有把 Widget 真泵出来才炸得出来。
///
/// 全部用 `webRenderer: false` 钉住原生渲染：WebView 分支需要平台实现，
/// 在单测环境里不是被测对象（其正确性由 tool/check_bridges_js.mjs 与真机覆盖）。
Widget _wrap(Widget child) => MaterialApp(
      home: child,
      debugShowCheckedModeBanner: false,
    );

void main() {
  group('ArtifactViewerScreen 顶栏（真机截图：图标把标题挤成"文…"）', () {
    testWidgets('长文件名仍出现在标题里，栏上图标不超过 4 个', (tester) async {
      const name = '季度业务分析报告-2026年第三季度-终版复核.md';
      await tester.pumpWidget(_wrap(const ArtifactViewerScreen(
        type: ArtifactType.markdown,
        url: '',
        language: '',
        content: '# 正文',
        fileName: name,
        webRenderer: false,
      )));
      await tester.pumpAndSettle();
      // 标题用文件名而不是"Markdown 成果"这种四千字标签，且必须渲染出来
      expect(find.text(name), findsOneWidget);
      // 栏上只留 另存为/复制/分享 + ⋯，其余进菜单（挤不掉标题的关键）
      expect(tester.widgetList<IconButton>(find.byType(IconButton)).length,
          lessThanOrEqualTo(4));
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('失败卡片显示试过的云端路径并可复制、可网页兜底', (tester) async {
      await tester.pumpWidget(_wrap(ArtifactViewerScreen(
        type: ArtifactType.file,
        url: 'http://127.0.0.1:3080/api/files/outputs/report.md',
        language: '',
        content: '',
        fileName: 'report.md',
        path: '/root/outputs/report.md',
        webRenderer: false,
        loader: () async => throw const RemoteReadException('云端文件不存在',
            kind: RemoteFailureKind.notFound),
      )));
      await tester.pumpAndSettle();
      // 没有 adb 的现场，"到底试了哪条路径"必须看得见
      expect(find.textContaining('/root/outputs/report.md'), findsOneWidget);
      expect(find.textContaining('文件可能已被清理或改名'), findsOneWidget,
          reason: '要给出分类建议，而不是一句红云');
      expect(find.text('复制文件名与路径'), findsWidgets);
      expect(find.text('用网页方式打开'), findsOneWidget);
    });
  });

  group('ArtifactViewerScreen 原生渲染布局', () {
    testWidgets('CSV 表格纵向可滚：多行不得 RenderFlex 溢出', (tester) async {
      final rows = ['名称,数量,备注'] +
          List.generate(200, (i) => '条目$i,$i,说明文本 $i');
      await tester.pumpWidget(_wrap(const ArtifactViewerScreen(
        type: ArtifactType.file,
        url: '',
        language: '',
        content: '',
        fileName: '清单.csv',
        webRenderer: false,
      )));
      // 内容经 loader 注入，避免测里造 loader 之外的分支
      await tester.pumpWidget(_wrap(ArtifactViewerScreen(
        type: ArtifactType.file,
        url: '',
        language: '',
        content: rows.join('\n'),
        fileName: '清单.csv',
        webRenderer: false,
      )));
      await tester.pumpAndSettle();

      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('条目199'), findsOneWidget);
      // 行数说明必须说真话（原生模式有显示上限）
      expect(find.textContaining('共 200 行'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('代码：行号 + 横向滚动 + 可选中，长行不折行不溢出',
        (tester) async {
      final code = List.generate(
          600, (i) => 'const value$i = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";')
          .join('\n');
      await tester.pumpWidget(_wrap(ArtifactViewerScreen(
        type: ArtifactType.code,
        url: '',
        language: 'dart',
        content: code,
        fileName: 'sample.dart',
        webRenderer: false,
      )));
      await tester.pumpAndSettle();

      // 行号存在（此前完全没有行号）
      expect(find.text('1'), findsWidgets);
      expect(find.text('600'), findsOneWidget);
      // 横向 + 纵向两层滚动都在（此前只有纵向 → 长行被折行毁掉缩进）
      final scrollers = tester.widgetList<SingleChildScrollView>(
          find.byType(SingleChildScrollView, skipOffstage: false));
      expect(
          scrollers.where((s) => s.scrollDirection == Axis.horizontal),
          isNotEmpty,
          reason: '代码必须能横向滚动');
      expect(find.byType(SelectionArea), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Markdown 可选中且链接可点（此前整页不可选中）',
        (tester) async {
      await tester.pumpWidget(_wrap(const ArtifactViewerScreen(
        type: ArtifactType.markdown,
        url: 'http://127.0.0.1:3080/api/files/x.md',
        language: '',
        content: '# 标题\n\n[详情](https://example.com/a)\n\n正文内容',
        fileName: 'note.md',
        webRenderer: false,
      )));
      await tester.pumpAndSettle();
      expect(find.text('标题'), findsWidgets);
      expect(find.byType(SelectableText), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('HTML 片段（<div …>）按 HTML 渲染，不被 Markdown 吐标签',
        (tester) async {
      await tester.pumpWidget(_wrap(const ArtifactViewerScreen(
        type: ArtifactType.file,
        url: '',
        language: '',
        content: '<div class="card"><h2>报表卡片</h2></div>',
        fileName: 'report.html',
        webRenderer: false,
      )));
      await tester.pumpAndSettle();
      // HtmlWidget 走 RichText 渲染，不产生 Text 控件 → 只能遍历 RichText 断言。
      bool richContains(String needle) => tester
          .widgetList<RichText>(find.byType(RichText, skipOffstage: false))
          .any((r) => r.text.toPlainText().contains(needle));
      expect(richContains('<div'), isFalse, reason: '标签不应被当字面文本吐出');
      expect(richContains('报表卡片'), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('ArtifactViewerScreen 加载态', () {
    testWidgets('0 字节文件显示"空文件"而不是"读取失败"', (tester) async {
      await tester.pumpWidget(_wrap(ArtifactViewerScreen(
        type: ArtifactType.file,
        url: '',
        language: '',
        content: '',
        fileName: 'empty.md',
        webRenderer: false,
        loader: () async => '',
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('空的（0 字节）'), findsOneWidget);
      expect(find.textContaining('读取失败'), findsNothing);
      expect(find.text('重新读取'), findsOneWidget);
    });

    testWidgets('读取失败显示原因，点重试成功后渲染内容', (tester) async {
      var attempts = 0;
      await tester.pumpWidget(_wrap(ArtifactViewerScreen(
        type: ArtifactType.file,
        url: '',
        language: '',
        content: '',
        fileName: 'note.md',
        webRenderer: false,
        loader: () async {
          attempts++;
          if (attempts == 1) {
            throw const RemoteReadException('云端文件不存在',
                kind: RemoteFailureKind.notFound);
          }
          return '# 重试后的内容';
        },
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('云端文件不存在'), findsOneWidget);
      expect(find.text('重试'), findsWidgets);

      await tester.tap(find.text('重试').first);
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.textContaining('重试后的内容'), findsOneWidget);
    });

    testWidgets('loader 同步抛异常也进错误态（不能永久转圈）', (tester) async {
      await tester.pumpWidget(_wrap(ArtifactViewerScreen(
        type: ArtifactType.file,
        url: '',
        language: '',
        content: '',
        fileName: 'boom.md',
        webRenderer: false,
        // 同步 throw（不是返回 rejected Future）：旧写法 loader().then()
        // 会绕过 catchError，界面永远停在加载圈。
        loader: () => throw StateError('boom'),
      )));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // 标题同名（boom.md）也会命中，所以只要求"至少出现一次原因"。
      expect(find.textContaining('boom'), findsWidgets);
    });

    testWidgets('initialError 直接进错误界面（JS 侧 fetch 失败的原因不再被吞）',
        (tester) async {
      await tester.pumpWidget(_wrap(const ArtifactViewerScreen(
        type: ArtifactType.file,
        url: 'http://127.0.0.1:3080/api/files/x.md',
        language: '',
        content: '',
        fileName: 'x.md',
        webRenderer: false,
        initialError: 'HTTP 401（登录态失效，需重新填写 Token）',
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('401'), findsOneWidget);
      expect(find.textContaining('无内容可查看'), findsNothing);
    });
  });
}
