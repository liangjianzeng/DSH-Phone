/// WebView 注入的 JS 桥脚本常量。
///
/// DSH 页面每次导航都会重建 DOM，桥脚本须在页面加载完成后（onLoadStop）
/// 重新注入；注入与使用方式见 webview_screen.dart。
///
/// 这些字符串是注入到 WebView 的原生 JS 代码，改动前务必在真机/模拟器
/// 验证对应功能（成果点击 / 任务状态通知 / 图片直传）。
library;

/// 成果识别 JS 桥：页面内注入全局点击监听，把点击命中的成果
/// （代码块 / 文件型链接 / markdown 显式容器）通过
/// `flutter_inappwebview.callHandler('onArtifactClick', {...})` 回传 Flutter。
///
/// 代码块/markdown 内容由 JS 侧直接提取文本；文件型成果在页面内 `fetch`
/// （天然带隧道/鉴权上下文）后连同文本一起回传。
const String artifactBridgeJs = r'''
(function() {
  if (window.__dshArtifactBridge) return;
  window.__dshArtifactBridge = true;

  function closestUp(el, selectors) {
    var c = el;
    while (c && c !== document.documentElement) {
      for (var i = 0; i < selectors.length; i++) {
        if (c.matches && c.matches(selectors[i])) return c;
      }
      c = c.parentElement;
    }
    return null;
  }

  function send(payload) {
    try {
      window.flutter_inappwebview.callHandler('onArtifactClick', payload);
    } catch (e) {}
  }

  // 成果文本拉取：限制大小与超时，防止大文件打爆 WebView 内存 / 请求悬挂。
  // 依据 content-length 头提前拒绝超大文件；无该头时由 Dart 侧 _looksBinary 兜底。
  var MAX_ARTIFACT_FETCH = 8 * 1024 * 1024; // 8MB 上限
  function fetchArtifact(url) {
    return new Promise(function(resolve, reject) {
      var settled = false;
      var timer = setTimeout(function() {
        if (!settled) { settled = true; reject(new Error('fetch timeout')); }
      }, 30000);
      fetch(url).then(function(r) {
        var len = r.headers.get('content-length');
        if (len && parseInt(len, 10) > MAX_ARTIFACT_FETCH) {
          throw new Error('artifact too large');
        }
        return r.text();
      }).then(function(text) {
        if (settled) return;
        settled = true; clearTimeout(timer);
        resolve(text);
      }).catch(function(err) {
        if (settled) return;
        settled = true; clearTimeout(timer);
        reject(err);
      });
    });
  }

  // 在整个文档中查找 file-mention 按钮（"产物"chips，title 存完整路径），
  // 返回其 title（完整路径）。用于把对话里"文件名文本"（表格单元格/代码块）
  // 解析成产物路径：文件名是 DSH 产物时，chips 里必有对应按钮。
  // 取元素的远端路径候选：title / aria-label / data-* 路径属性。
  // 放宽对 chips 渲染形式的依赖：DSH 可能把产物渲染成 button/a/span 或带
  // data-file-path 等属性的元素，统一由这里取路径。
  function elementPath(el) {
    var t = el.getAttribute('title');
    if (t) return t;
    var a = el.getAttribute('aria-label');
    if (a) return a;
    var d = el.getAttribute('data-file-path') ||
            el.getAttribute('data-remote-path') ||
            el.getAttribute('data-path');
    if (d) return d;
    return '';
  }

  // 路径形似判断：含路径分隔符，或形如盘符/家目录，避开普通文本与 tooltip。
  function looksLikePath(p) {
    return /\\/.test(p) || p.indexOf('/') >= 0 ||
           /^[a-zA-Z]:\//.test(p) ||
           p === '~' || p.startsWith('~') || p.startsWith('.');
  }

  // 是否为产物 chip：className 含 fileMention，或带显式路径 data 属性。
  function isChipLike(el) {
    var cls = (el.className || '');
    if (typeof cls === 'string' && cls.indexOf('fileMention') >= 0) return true;
    return !!el.getAttribute('data-file-path') ||
           !!el.getAttribute('data-remote-path') ||
           !!el.getAttribute('data-path');
  }

  // 在整个文档中查找 file-mention chip（不限于 button，兼容 a/span/data-*），
  // 返回其完整路径（title/aria-label/data-*）。
  function findMentionPath(filename) {
    var els = document.querySelectorAll(
        'button, a, span, [data-file-path], [data-remote-path], [data-path]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var p = elementPath(el);
      if (!p) continue;
      var lastSep = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
      var base = lastSep >= 0 ? p.substring(lastSep + 1) : p;
      if (base === filename) return p;
    }
    return '';
  }

  // 收集页面上所有"产物"chips（title 含完整路径）的目录列表，去重。
  // 反查不到路径时（chips 被隐藏），用目录 + 文件名拼接候选路径。
  function collectProducedDirs() {
    var dirs = [];
    var els = document.querySelectorAll(
        'button, a, span, [data-file-path], [data-remote-path], [data-path]');
    for (var i = 0; i < els.length; i++) {
      var p = elementPath(els[i]);
      if (!p) continue;
      var at = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
      if (at > 0) {
        var dir = p.slice(0, at);
        if (dirs.indexOf(dir) < 0) dirs.push(dir);
      }
    }
    return dirs;
  }

  document.addEventListener('click', function(ev) {
    var t = ev.target;

    // 0) 放行 composer 输入/附件区域：附件删除按钮/预览图/发送按钮等
    //    点击归 DSH 处理，避免附件文件名（含 .png 等后缀）被误判为
    //    "资源型成果"而触发查看/下载流程（导致无法删除、误开下载页）。
    if (closestUp(t, ['[data-composer-card]'])) return;

    // 资源型后缀（apk/压缩包等二进制，走下载保存流程）
    var isResourceSuffix = /\.(apk|zip|tar|gz|tgz|rar|7z|xz|bin|exe|msi|dmg|iso|img|mp4|mp3|pdf|png|jpg|jpeg|gif|webp|svg|doc|docx|xls|xlsx|ppt|pptx|so|a|dll)(\?|#|$)/i;

    // 1) 文件型成果链接：优先判断，即使链接包裹在 pre/code 里。
    var a = closestUp(t, ['a']);
    if (a) {
      var href = a.getAttribute('href') || '';
      var isFile = /\/api\/files\/|\/files\/|\/api\/artifact\/|\/artifacts\/|\.(md|markdown|html|htm|txt|json|csv)(\?|#|$)/i.test(href);
      var isResource = isResourceSuffix.test(href);
      if (isFile || isResource) {
        ev.preventDefault();
        ev.stopPropagation();
        if (isResource) {
          // 资源型链接：先按文件名反查产物 chips 的完整路径（title），
          // 反查不到时回传文件名 + 页面产物目录，由 Dart 侧拼接定位；
          // 避免"链接型 APK 一律不支持下载"导致时好时坏。
          var base = href.split(/[\\/?#]+/).pop() || '';
          var mentionPath = findMentionPath(base);
          var dirs = collectProducedDirs();
          send({type: 'resource', url: a.href, language: '', content: '', path: mentionPath, dirs: dirs});
          return;
        }
        fetchArtifact(a.href).then(function(text){
          send({type: 'file', url: a.href, language: '', content: text});
        }).catch(function(err){
          send({type: 'file', url: a.href, language: '', content: ''});
        });
        return;
      }
    }

    // 2) 文件成果按钮：DSH 把文件成果渲染为
    //    <button class="_fileMention_*" title="云端路径">文件名</button>，
    //    云端路径在 title/aria-label 里，须先于代码块检测。
    //    资源类按钮同样以路径形式存在，这里放宽：路径带资源/可查看后缀即拦截。
    var mention = closestUp(t, ['button', 'a', 'span', '[data-file-path]', '[data-remote-path]', '[data-path]']);
    if (mention) {
      var cls = mention.className || '';
      var title = mention.getAttribute('title') || '';
      var label = mention.getAttribute('aria-label') || '';
      var filePath = elementPath(mention) || title || label || '';
      var isMention = cls.indexOf('fileMention') >= 0 ||
          /\.(md|markdown|html|htm|txt|json|csv|apk|zip|tar|gz|tgz|rar|7z|xz|bin|exe|msi|dmg|iso|img|mp4|mp3|pdf|png|jpg|jpeg|gif|webp|svg|doc|docx|xls|xlsx|ppt|pptx|so|a|dll)(\?|#|$)/i.test(filePath);
      if (isMention && filePath) {
        ev.preventDefault();
        ev.stopPropagation();
        // 资源型（apk 等二进制）：走下载保存流程；否则经 SSH 读取查看。
        var isResource = isResourceSuffix.test(filePath);
        send({type: isResource ? 'resource' : 'file', url: '', language: '', content: '', path: filePath});
        return;
      }
    }

    // 3) 代码块：命中 pre/code（非链接），提取文本与语言。
    //    若 code 内容只是单个文件名（如对话表格单元格/代码块里的文件名），
    //    且页面里有对应的"产物"chips（title 含完整路径），按文件/资源处理。
    var code = closestUp(t, ['pre', 'code']);
    if (code) {
      ev.preventDefault();
      ev.stopPropagation();
      var text = code.innerText || code.textContent || '';
      var trimmed = text.trim();
      var singleLine = trimmed.indexOf('\n') < 0 && trimmed.length > 0;
      var suffixRe = /\.(md|markdown|html|htm|txt|json|csv|apk|zip|tar|gz|tgz|rar|7z|xz|bin|exe|msi|dmg|iso|img|mp4|mp3|pdf|png|jpg|jpeg|gif|webp|svg|doc|docx|xls|xlsx|ppt|pptx|so|a|dll)$/i;
      if (singleLine && suffixRe.test(trimmed)) {
        // 先按文件名在整个文档的产物 chips 里反查完整路径；
        // 若文本自身已含路径分隔符（/ 或 \），则直接用文本作为路径。
        var mentionPath = findMentionPath(trimmed);
        if (!mentionPath && /[\\/]/.test(trimmed)) mentionPath = trimmed;
        if (mentionPath) {
          var isResource = isResourceSuffix.test(mentionPath);
          send({type: isResource ? 'resource' : 'file', url: '', language: '', content: '', path: mentionPath});
          return;
        }
        // 反查失败（该文件 chips 被隐藏）：回传文件名 + 可见产物目录，
        // 由 Dart 侧逐个拼接目录定位云端路径。
        var dirs = collectProducedDirs();
        if (dirs.length > 0) {
          var isResource = isResourceSuffix.test(trimmed);
          send({type: isResource ? 'resource' : 'file', url: '', language: '', content: '', path: trimmed, dirs: dirs});
          return;
        }
      }
      var lang = '';
      var m = (code.className || '').match(/language-([\w-]+)/);
      if (m) lang = m[1];
      send({type: 'code', url: '', language: lang, content: text});
      return;
    }

    // 4) 正文纯文本路径：命中 p/span/td/li 等正文容器，内容形似单个
    //    资源/文件路径（含路径分隔符，或为 chips 文件名）时，按资源/文件处理。
    //    这是"对话里模型写下的下载路径/目录"点击可下载的关键兜底（chips 未必存在）。
    var body = closestUp(t, ['p', 'span', 'td', 'li']);
    if (body && !isChipLike(body)) {
      var raw = (body.innerText || body.textContent || '').trim();
      var plainSingle = raw.indexOf('\n') < 0 && raw.indexOf('\r') < 0 && raw.length > 0;
      if (plainSingle) {
        var lastBack = raw.lastIndexOf('\\');
        var lastSlash = raw.lastIndexOf('/');
        var lastSep = Math.max(lastBack, lastSlash);
        var bodyBase = lastSep >= 0 ? raw.substring(lastSep + 1) : raw;
        var bodyMention = bodyBase ? findMentionPath(bodyBase) : '';
        var bodyPath = bodyMention || raw;
        var suffixes = ['.md', '.html', '.htm', '.txt', '.json', '.csv', '.apk', '.zip', '.tar', '.gz', '.tgz', '.rar', '.7z', '.xz', '.bin', '.exe', '.msi', '.dmg', '.iso', '.img', '.mp4', '.mp3', '.pdf', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.so', '.a', '.dll'];
        // 形似路径：含反斜杠、以 / 开头的绝对路径、~，或无空格且带已知后缀。
        var looksPath = raw.indexOf('\\') >= 0 || raw.indexOf('/') === 0 ||
            raw === '~' ||
            (raw.indexOf(' ') < 0 && suffixes.some(function(s) { return raw.toLowerCase().endsWith(s); }));
        if (looksPath) {
          ev.preventDefault();
          ev.stopPropagation();
          var isResource = isResourceSuffix.test(bodyPath);
          send({type: isResource ? 'resource' : 'file', url: '', language: '', content: '', path: bodyPath, dirs: collectProducedDirs()});
          return;
        }
      }
    }

    // 3) Markdown 成果：仅显式标记容器，避免误报
    var md = closestUp(t, ['[data-dsh-artifact]', '.dsh-markdown', '.artifact-markdown']);
    if (md) {
      ev.preventDefault();
      ev.stopPropagation();
      send({type: 'markdown', url: '', language: '', content: md.innerText || md.textContent || ''});
      return;
    }
  }, true);
})();
''';

/// 任务状态桥 JS：监听 DSH 智能体任务的运行态并回传 Flutter。
///
/// 运行指示器：ChatView 的 TurnStatus 组件渲染
/// `<div role="status" aria-live="polite">Deep diving...</div>`（硬编码文案，
/// 不随语言切换）。用「role=status + aria-live=polite + 文本含哨兵词」组合
/// 精确定位，避开遍布全 UI 的其它 role="status" 元素。
///
/// 状态机：仅上报「运行 ↔ 结束」的切换；页面加载时若已在运行则直接上报
/// 运行态，否则只对齐基准不上报（避免每次导航误报"已完成"）。
const String taskBridgeJs = r'''
(function() {
  if (window.__dshTaskBridge) return;
  window.__dshTaskBridge = true;

  var SENTINEL = 'Deep diving';
  var state = null; // 上次上报的运行态；null = 尚未对齐
  var timer = null;

  function report(next) {
    try {
      window.flutter_inappwebview.callHandler('onTaskState', { state: next });
    } catch (e) {}
  }

  function scan() {
    var running = false;
    var nodes = document.querySelectorAll('[role="status"][aria-live="polite"]');
    for (var i = 0; i < nodes.length; i++) {
      if ((nodes[i].textContent || '').indexOf(SENTINEL) !== -1) {
        running = true;
        break;
      }
    }
    var next = running ? 'running' : 'settled';
    if (state === null) {
      // 首次对齐：已在运行则上报，否则只记基准（不误报已完成）
      state = next;
      if (running) report('running');
      return;
    }
    if (next !== state) {
      state = next;
      report(next);
    }
  }

  // 运行指示器随元素增删出现/消失：只监听 childList（子树增删），
  // 不做 characterData（流式输出高频文本变动），成本更低。
  var pending = false;
  function scheduleScan() {
    if (pending) return;
    pending = true;
    timer = setTimeout(function() { pending = false; scan(); }, 250);
  }
  new MutationObserver(function(mutations) {
    for (var i = 0; i < mutations.length; i++) {
      if (mutations[i].type === 'childList') { scheduleScan(); break; }
    }
  }).observe(document.documentElement, { childList: true, subtree: true });

  // 页面可能正运行中：立即对齐一次。
  scan();
})();
''';

/// 图片直传桥（方案 A）：把 Flutter 侧选好的图片注入 DSH 消息输入窗口。
///
/// DSH Web UI 的图片附件只支持"拖拽 drop"（document 级 drop 事件 →
/// `onAddImages(files)`），没有 `input[type=file]`。本桥：
/// 1. 隐藏 file input 作为程序化接收文件的中转站（`input.files` 可赋值）；
/// 2. Flutter 注入 base64 → 构造 `File` → 塞进中转 input → 派发 change；
/// 3. 桥监听 change 拿到 `File` → 构造合成 drop 事件（`defineProperty`
///    覆盖只读 dataTransfer）→ dispatch 到 document，DSH 附件槽收到图。
const String photoBridgeJs = r'''
(function() {
  // 隐藏 file input：仅用于原生选择器路径；base64 注入直接走 deliverDrop。
  // 按 id 去重，避免页面导航/DOM 重建后重复创建。
  var input = document.getElementById('__dshPhotoInput');
  if (!input) {
    input = document.createElement('input');
    input.id = '__dshPhotoInput';
    input.type = 'file';
    input.accept = 'image/png,image/jpeg,image/webp,image/gif';
    input.style.display = 'none';
    document.body.appendChild(input);
    input.addEventListener('change', function() {
      var file = input.files && input.files[0];
      if (!file) return;
      input.value = '';
      deliverDrop(file);
    });
  }

  function deliverDrop(file) {
    var dt = new DataTransfer();
    dt.items.add(file);
    var ev = new DragEvent('drop', { bubbles: true, cancelable: true });
    try {
      Object.defineProperty(ev, 'dataTransfer', { value: dt });
    } catch (e) {
      return { ok: false, error: String(e) };
    }
    document.dispatchEvent(ev);
    return { ok: true };
  }

  // 每次注入都重置桥对象：页面导航/DOM 重建后确保 __dshPhotoBridge 始终可用，
  // 不再用布尔哨兵提前 return 导致重建后漏建 input。
  window.__dshPhotoBridge = {
    // Flutter 注入：base64 → 图片文件 → drop 给 DSH 附件槽
    pickImage: function(base64, name, mime) {
      try {
        var bin = atob(base64);
        var bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        var file = new File([bytes], name || 'image.jpg', { type: mime || 'image/jpeg' });
        // input.files 为只读属性，程序化赋值被静默忽略，
        // 无法经 change 事件送达，故直接用已有 File 调用 deliverDrop drop 进附件槽。
        return deliverDrop(file);
      } catch (e) {
        return { ok: false, error: String(e) };
      }
    }
  };
})();
''';

/// 消息输入框文本注入桥：把文本（如上传后的远程文件路径）写入 DSH 消息输入框。
///
/// DSH 消息输入框可能是原生 textarea/input，也可能是 contenteditable 富文本
/// 编辑器（ProseMirror/TipTap 类）。本桥多策略探测：
/// 1. 可见的 textarea / input[type=text]：直接赋值 + 派发 input/change；
/// 2. contenteditable：focus + `execCommand('insertText')`（保留编辑器内部
///    结构与 undo 栈，框架监听 input 事件同步模型）；
/// 3. 兜底：直接追加 textContent + 派发 input。
/// 返回 `{ok, error}` 供 Flutter 侧提示。
const String composerBridgeJs = r'''
(function() {
  function findComposer() {
    // 策略 1：可见的 textarea / 文本类 input
    var inputs = document.querySelectorAll(
        'textarea, input[type="text"], input[type="search"], input[type="url"], input[type="email"]');
    for (var i = 0; i < inputs.length; i++) {
      var el = inputs[i];
      if (el.offsetParent !== null) return el;
    }
    // 策略 2：contenteditable 富文本编辑器（含 contenteditable="plaintext-only"）
    var editors = document.querySelectorAll('[contenteditable], [contenteditable="true"], [contenteditable="plaintext-only"]');
    for (var j = 0; j < editors.length; j++) {
      var ed = editors[j];
      if (ed.offsetParent !== null) return ed;
    }
    return null;
  }

  function insertInto(el, text) {
    try { el.focus(); } catch (e) {}
    var tag = el.tagName ? el.tagName.toUpperCase() : '';

    if (tag === 'TEXTAREA' || tag === 'INPUT') {
      var start = el.selectionStart;
      var end = el.selectionEnd;
      var value = el.value || '';
      el.value = value.substring(0, start) + text + value.substring(end);
      // 光标移到插入文本末尾，便于用户继续补充指令
      var pos = start + text.length;
      try {
        el.setSelectionRange(pos, pos);
      } catch (e) {}
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return { ok: true };
    }

    // contenteditable：execCommand 插入（保留编辑器状态与 undo）
    var done = false;
    try {
      done = document.execCommand('insertText', false, text);
    } catch (e) { done = false; }
    if (done) {
      el.dispatchEvent(new Event('input', { bubbles: true }));
      return { ok: true };
    }

    // 兜底：直接追加文本
    el.textContent = (el.textContent || '') + text;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    return { ok: true };
  }

  // 每次注入都重置桥对象（页面导航/DOM 重建后保持可用）
  window.__dshComposerBridge = {
    insertText: function(text) {
      try {
        var el = findComposer();
        if (!el) return { ok: false, error: '未找到消息输入框' };
        return insertInto(el, String(text));
      } catch (e) {
        return { ok: false, error: String(e) };
      }
    }
  };
})();
''';