/// 成果 → 一份可直接交给系统 WebView（InAppWebView `loadData`）渲染的 HTML 文档。
///
/// 为什么要从原生渲染迁走：`flutter_widget_from_html_core` 是**不执行脚本、
/// 不支持外链 CSS/flex/grid** 的纯 Widget 渲染器，DSH 生成的 HTML 报告
/// （带样式表格、卡片、图表脚本）落到它手里就退化成裸文本；`flutter_markdown`
/// 也没有 `imageBuilder`/`onTapLink`，相对路径图片因缺少 `baseUrl` 与登录态
/// 一律加载失败。交给系统 Chromium 渲染，CSS/字体/表格/图片/mermaid 一次全部
/// 解决，且 `baseUrl` 指向隧道 origin 后可直接复用 WebView 的同源与登录态。
///
/// 原生渲染并没有删掉：代码块与"轻量快速模式"仍走原生（见查看器），
/// 因为原生渲染没有 WebView 的首屏开销、也更适合超长代码。
library;

import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

/// 文档种类：决定用哪条转换路径。
enum ArtifactRenderKind { html, markdown, code, csv, json }

/// 成果 HTML 文档构造器。
class ArtifactWebDocument {
  const ArtifactWebDocument._();

  /// 构造完整 HTML 文档。
  ///
  /// [content] 是原始文本（未转义）；[dark] 跟随 App 主题，避免深色模式下
  /// 白底刺眼；[language] 仅对 [ArtifactRenderKind.code] 有意义（给
  /// 代码高亮库做语言标注）。
  static String document({
    required ArtifactRenderKind kind,
    required String content,
    required bool dark,
    String? title,
    String language = '',
  }) {
    final body = _bodyFor(kind, content, language);
    return '''
<!DOCTYPE html>
<html lang="zh-CN"${dark ? ' data-theme="dark"' : ''}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${_escape(title ?? '')}</title>
<style>
${_css(dark)}
</style>
</head>
<body>
<main id="dsh-artifact">
$body
</main>
<script>
/* 链接一律不离开查看器：交给原生处理（复制 + 提示），
   否则点一个外链就把整个预览页替换掉，用户回不来。 */
document.addEventListener('click', function (e) {
  var a = e.target && e.target.closest ? e.target.closest('a') : null;
  if (!a || !a.href) return;
  e.preventDefault();
  try {
    window.flutter_inappwebview.callHandler('onViewerLink', a.href);
  } catch (_) {
    /* 原生未注册 handler 时静默忽略，别把预览页搞崩 */
  }
}, true);
</script>
</body>
</html>
''';
  }

  static String _bodyFor(ArtifactRenderKind kind, String content, String language) {
    switch (kind) {
      case ArtifactRenderKind.html:
        // 原样交给 Chromium：DSH 的 HTML 报告本身就带样式与脚本。
        return content;
      case ArtifactRenderKind.markdown:
        return md.markdownToHtml(
          content,
          extensionSet: md.ExtensionSet.gitHubWeb,
          inlineSyntaxes: [],
        );
      case ArtifactRenderKind.code:
        final cls = language.trim().isEmpty ? '' : ' class="language-${_escape(language)}"';
        return '<pre$cls><code>${_escape(content)}</code></pre>';
      case ArtifactRenderKind.json:
        return '<pre><code>${_escape(prettyJson(content))}</code></pre>';
      case ArtifactRenderKind.csv:
        return _csvTable(content);
    }
  }

  /// JSON 美化：解析失败就原样展示（坏 JSON 也是常见的成果形态）。
  static String prettyJson(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return content;
    try {
      final decoded = jsonDecode(trimmed);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return content;
    }
  }

  /// CSV → 带表头的真表格。
  ///
  /// 以前 csv 被丢给 MarkdownBody，而 Markdown 需要 `|` 才算表格 → 整个文件
  /// 被挤成一段，等于完全不可读。
  static String _csvTable(String content) {
    final rows = parseDelimited(content);
    if (rows.isEmpty) return '<p class="empty">（没有可解析的表格内容）</p>';
    final delimiter = detectDelimiter(content);
    final header = rows.first;
    final maxCols = rows.fold<int>(
        0, (m, r) => r.length > m ? r.length : m);
    final sb = StringBuffer();
    sb.write('<div class="table-wrap"><table>');
    sb.write('<thead><tr>');
    for (var c = 0; c < maxCols; c++) {
      sb.write('<th>${_escape(c < header.length ? header[c] : '')}</th>');
    }
    sb.write('</tr></thead><tbody>');
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      sb.write('<tr>');
      for (var c = 0; c < maxCols; c++) {
        sb.write('<td>${_escape(c < row.length ? row[c] : '')}</td>');
      }
      sb.write('</tr>');
    }
    sb.write('</tbody></table></div>');
    sb.write('<p class="meta">共 ${rows.length - 1} 行 · '
        '$maxCols 列 · 分隔符「${_escape(delimiter)}」</p>');
    return sb.toString();
  }

  /// 猜分隔符：取首行里出现最多的候选（`, ; \t |`）。
  static String detectDelimiter(String content) {
    final firstLine = content.split(RegExp(r'\r?\n')).firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '',
        );
    String best = ',';
    var bestCount = -1;
    for (final cand in [',', ';', '\t', '|']) {
      // 不用 RegExp.escape：CI 矩阵还跑 Flutter 3.27 / Dart 3.6，那个版本没有
      // 这个 API（本地 3.7 能过、CI 直接红），手写转义更省事。
      final escaped =
          cand.replaceAllMapped(RegExp(r'[.*+?^${}()|\[\]\\]'), (m) => '\\${m[0]}');
      final count = RegExp(escaped).allMatches(firstLine).length;
      if (count > bestCount) {
        bestCount = count;
        best = cand == '\t' ? 'Tab' : cand;
      }
    }
    return best;
  }

  /// 解析分隔符文本（支持双引号包裹、`""` 转义、字段内换行、CRLF）。
  ///
  /// 不引第三方 csv 包：这个规模的手写解析器更好控（也避免又一份依赖），
  /// 关键是把"引号里含分隔符/换行"这一类真实成果里最常见的形态处理对。
  static List<List<String>> parseDelimited(String input) {
    final delim = switch (detectDelimiter(input)) {
      'Tab' => '\t',
      '|' => '|',
      ';' => ';',
      _ => ',',
    };
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var i = 0;
    void endField() {
      row.add(field.toString());
      field.clear();
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    while (i < input.length) {
      final ch = input[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < input.length && input[i + 1] == '"') {
            field.write('"');
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        field.write(ch);
        i++;
        continue;
      }
      if (ch == '"' && field.isEmpty) {
        inQuotes = true;
        i++;
        continue;
      }
      if (ch == delim) {
        endField();
        i++;
        continue;
      }
      if (ch == '\r') {
        i++;
        continue;
      }
      if (ch == '\n') {
        endRow();
        i++;
        continue;
      }
      field.write(ch);
      i++;
    }
    if (field.isNotEmpty || row.isNotEmpty) endRow();
    // 丢掉尾部整行为空的行（文件末尾换行很常见）
    while (rows.isNotEmpty &&
        rows.last.length == 1 &&
        rows.last.first.trim().isEmpty) {
      rows.removeLast();
    }
    return rows;
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// 样式：移动端优先，表格横向可滚、图片不溢出、代码不折行。
  static String _css(bool dark) {
    final fg = dark ? '#e6e6e6' : '#1f2328';
    final bg = dark ? '#14171a' : '#ffffff';
    final muted = dark ? '#9aa4ae' : '#656d76';
    final border = dark ? '#30363d' : '#d0d7de';
    final codeBg = dark ? '#0d1117' : '#f6f8fa';
    final thBg = dark ? '#1b2128' : '#f0f3f6';
    return '''
:root { color-scheme: ${dark ? 'dark' : 'light'}; }
* { box-sizing: border-box; }
html, body { margin:0; padding:0; background:$bg; color:$fg; }
body {
  font: 15px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
        "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  -webkit-text-size-adjust: 100%;
  word-wrap: break-word;
}
main#dsh-artifact { padding: 14px 14px calc(28px + env(safe-area-inset-bottom)); max-width: 900px; margin: 0 auto; }
h1,h2,h3,h4 { line-height:1.35; margin:1.2em 0 .55em; font-weight:600; }
h1 { font-size:1.5em; border-bottom:1px solid $border; padding-bottom:.25em; }
h2 { font-size:1.28em; border-bottom:1px solid $border; padding-bottom:.2em; }
h3 { font-size:1.12em; }
p { margin:.65em 0; }
a { color:${dark ? '#6cb6ff' : '#0969da'}; text-decoration:none; }
img { max-width:100%; height:auto; border-radius:6px; }
hr { border:none; border-top:1px solid $border; margin:1.4em 0; }
blockquote { margin:.8em 0; padding:.2em .9em; border-left:3px solid $border; color:$muted; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
       font-size:.9em; background:$codeBg; padding:.12em .35em; border-radius:4px; }
pre { background:$codeBg; border:1px solid $border; border-radius:8px;
      padding:12px; overflow-x:auto; -webkit-overflow-scrolling:touch; }
pre code { background:none; padding:0; font-size:13px; line-height:1.6;
           white-space:pre; word-break:normal; display:block; }
table { border-collapse:collapse; width:auto; font-size:14px; }
th, td { border:1px solid $border; padding:6px 10px; text-align:left; vertical-align:top; }
th { background:$thBg; position:sticky; top:0; z-index:1; white-space:nowrap; }
tr:nth-child(even) td { background:${dark ? 'rgba(255,255,255,.02)' : 'rgba(0,0,0,.015)'}; }
.table-wrap { overflow-x:auto; -webkit-overflow-scrolling:touch; border:1px solid $border;
              border-radius:8px; }
.table-wrap table { border:none; }
.table-wrap th, .table-wrap td { border-left:none; border-top:none; }
ul,ol { padding-left:1.5em; }
.meta { color:$muted; font-size:12px; margin:.6em 0 0; }
.empty { color:$muted; }
''';
  }
}
