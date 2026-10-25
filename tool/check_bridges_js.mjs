#!/usr/bin/env node
// 注入式 JS 桥的静态 + 行为校验（`node tool/check_bridges_js.mjs`，CI 已接入）。
//
// 为什么单独要这一道：桥脚本是**写在 Dart 字符串里的 JS**，`flutter analyze`
// 与 `flutter test` 都看不见字符串内部——少个括号、正则写错、分支不 send，
// 全部只在真机点击时才暴露（表现为"点了没反应"），排查成本极高。
//
// 两层校验：
//  1) 语法：每个 `...Js = r'''…'''` 块过一遍 `node --check` 等价的 vm 编译。
//  2) 行为：用最小假 DOM 跑成果点击分发，断言历史上真出过问题的判据
//     （`?token=` 后缀、file 分支带 dirs、fetch 失败带原因、含空格路径、
//      版本化 .so.N 归资源、composer 区放行）。
//
// 断言只描述**期望行为**，不依赖实现细节；改桥脚本时若语义变了会当场红。

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const srcPath = path.resolve('lib/webview_bridges.dart');
if (!fs.existsSync(srcPath)) {
  console.error('× 找不到 lib/webview_bridges.dart（请在仓库根目录运行）');
  process.exit(2);
}
const dart = fs.readFileSync(srcPath, 'utf8');

// ---- 1) 抽取并编译所有 JS 块 ------------------------------------------------
const blocks = [...dart.matchAll(/const String (\w+Js) = r'''([\s\S]*?)'''/g)];
if (blocks.length === 0) {
  console.error('× 没有抽到任何 JS 桥常量（正则与源码结构不符？）');
  process.exit(2);
}
for (const [, name, body] of blocks) {
  try {
    new vm.Script(body, { filename: `${name}.js` });
    console.log(`✓ 语法 ${name}（${body.length} 字节）`);
  } catch (e) {
    console.error(`× 语法 ${name} 解析失败：${e.message}`);
    process.exit(1);
  }
}

// ---- 2) 行为校验：最小假 DOM 跑分发 ---------------------------------------
const artifactJs = blocks.find(([, n]) => n === 'artifactBridgeJs')?.[2];
if (!artifactJs) {
  console.error('× 缺少 artifactBridgeJs');
  process.exit(2);
}

function el(attrs, tagName = 'SPAN', parent = null) {
  return {
    tagName,
    parentElement: parent,
    className: attrs._class || '',
    textContent: attrs._text || '',
    href: attrs.href ? 'http://127.0.0.1:3080' + attrs.href : undefined,
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    matches: (sel) => (attrs._matches || []).includes(sel),
    closest(sel) {
      let c = this;
      while (c) {
        if (c.matches && c.matches(sel)) return c;
        c = c.parentElement;
      }
      return null;
    },
  };
}

let sent = [];
let chips = [];
let clickHandler = null;
const handlers = {};
let fetchImpl = async () => ({
  ok: true,
  status: 200,
  headers: { get: () => null },
  text: async () => '',
});

const documentStub = {
  documentElement: {},
  readyState: 'complete',
  addEventListener: (type, fn) => {
    handlers[type] = fn;
    if (type === 'click') clickHandler = fn;
  },
  querySelectorAll: () => chips,
};
const windowStub = {
  flutter_inappwebview: {
    callHandler: (name, payload) => {
      if (name === 'onArtifactClick') sent.push(payload);
    },
  },
};
vm.runInContext(artifactJs, vm.createContext({
  window: windowStub,
  document: documentStub,
  setTimeout,
  clearTimeout,
  Promise,
  fetch: (u, o) => fetchImpl(u, o),
}));
if (!clickHandler) {
  console.error('× 桥脚本没有注册 click 监听（注入即失效）');
  process.exit(1);
}

async function click(target) {
  sent = [];
  clickHandler({ target, preventDefault() {}, stopPropagation() {} });
  await new Promise((r) => setTimeout(r, 30)); // 等 fetchArtifact 的 Promise 落地
  return sent;
}

// 长按：安卓 WebView 的 contextmenu 事件（App 下载保底入口）
async function longpress(target) {
  sent = [];
  handlers.contextmenu?.({ target, preventDefault() {}, stopPropagation() {} });
  await new Promise((r) => setTimeout(r, 30));
  return sent;
}

const cases = [];
const check = (name, ok, detail = '') => cases.push({ name, ok, detail });

(async () => {
  // 资源型链接：带 ?token= 也必须认出 apk 并走下载，同时带上 dirs
  chips = [el({ title: '/root/out/report.md' }), el({ title: '/root/out/app.apk' })];
  let p = (await click(el({ href: '/api/files/app.apk?token=abc', _matches: ['a'] }, 'A')))[0];
  check('资源链接（带 ?token=）归 resource', p?.type === 'resource', JSON.stringify(p));
  check('资源链接带 dirs（文件名反查的救机）',
    Array.isArray(p?.dirs) && p.dirs.includes('/root/out'), JSON.stringify(p?.dirs));

  // 文本链接：成功时 content 到位、error 为空；**file 分支也要带 dirs**
  fetchImpl = async () => ({
    ok: true, status: 200, headers: { get: () => null }, text: async () => '# 标题',
  });
  p = (await click(el({ href: '/api/files/note.md?token=abc', _matches: ['a'] }, 'A')))[0];
  check('文本链接（带 ?token=）归 file', p?.type === 'file', JSON.stringify(p));
  check('file 分支内容送达', p?.content === '# 标题', JSON.stringify(p));
  check('file 分支成功时 error 为空', p?.error === '', JSON.stringify(p?.error));
  check('file 分支也带 dirs（旧实现只有 resource 带）',
    Array.isArray(p?.dirs) && p.dirs.length > 0, JSON.stringify(p?.dirs));

  // fetch 失败：必须把原因带回来（401 = 会话过期，是最高频的一类）
  fetchImpl = async () => ({
    ok: false, status: 401, headers: { get: () => null }, text: async () => '',
  });
  p = (await click(el({ href: '/api/files/note.md', _matches: ['a'] }, 'A')))[0];
  check('HTTP 401 回传原因（不再只发空串）',
    p?.content === '' && /401/.test(p?.error || ''), JSON.stringify(p));

  fetchImpl = async () => { throw new Error('Failed to fetch'); };
  p = (await click(el({ href: '/api/files/note.md', _matches: ['a'] }, 'A')))[0];
  check('fetch 异常原因回传', /Failed to fetch/.test(p?.error || ''), JSON.stringify(p));

  // 含空格的 Windows 路径（旧判据要求整串不含空格 → 完全点不动）
  chips = [];
  p = (await click(el({ _text: 'C:\\Program Files\\x\\报告.md', _matches: ['code'] }, 'CODE')))[0];
  check('含空格路径可点', p?.type === 'file' && /报告\.md$/.test(p?.path || ''),
    JSON.stringify(p));

  // 反向：普通句子里的 A/B 不能被当路径
  p = (await click(el({ _text: '这个 A/B 测试 结果', _matches: ['code'] }, 'CODE')))[0];
  check('普通句子不误判为路径', p === undefined || !p?.path, JSON.stringify(p));

  // 版本化动态库必须归资源（与 Dart 侧 ArtifactRules.typeOfPath 一致）
  chips = [el({ title: '/usr/lib/libfoo.so.1', _class: '_fileMention_1' })];
  p = (await click(el({ title: '/usr/lib/libfoo.so.1', _class: '_fileMention_1', _matches: ['button'] }, 'BUTTON')))[0];
  check('libfoo.so.1 归 resource（不进文本查看器）',
    p?.type === 'resource', JSON.stringify(p));

  // PDF/office 放行（2026-10）：DSH Web 自带 pdf.js 预览（office 服务端转 PDF），
  // 真实成果控件交回 Web 处理、App 不截走；代码块裸文件名/外部链接 Web
  // 没人接管，仍走 App 下载。
  chips = [];
  let none = await click(el({ title: '/root/out/报告.pdf', _class: '_fileMention_1', _matches: ['button'] }, 'BUTTON'));
  check('成果 chips 的 PDF 放行给 Web 预览（不截走）', none.length === 0, JSON.stringify(none));
  none = await click(el({ href: '/api/files/报表.xlsx?token=abc', _matches: ['a'] }, 'A'));
  check('成果链接的 office 放行给 Web 预览（不截走）', none.length === 0, JSON.stringify(none));
  p = (await click(el({ _text: '/root/out/报告.pdf', _matches: ['code'] }, 'CODE')))[0];
  check('代码块裸 PDF 文件名仍归 resource（Web 不处理代码块）',
    p?.type === 'resource', JSON.stringify(p));
  p = (await click(el({ href: '/dl/报告.pdf', _matches: ['a'] }, 'A')))[0];
  check('外部 PDF 链接仍归 resource（非 DSH 成果控件）',
    p?.type === 'resource', JSON.stringify(p));

  // 长按（contextmenu）= App 下载保底：PDF/office 放行给 Web 预览后，
  // App 侧下载入口不能丢。
  chips = [];
  p = (await longpress(el({ title: '/root/out/报告.pdf', _class: '_fileMention_1', _matches: ['button'] }, 'BUTTON')))[0];
  check('长按成果 chips 的 PDF 走 App 下载',
    p?.type === 'resource' && /报告\.pdf$/.test(p?.path || ''), JSON.stringify(p));
  p = (await longpress(el({ href: '/api/files/报表.xlsx?token=abc', _matches: ['a'] }, 'A')))[0];
  check('长按成果链接的 office 走 App 下载',
    p?.type === 'resource' && /报表\.xlsx$/.test((p?.url || '').split(/[?#]/)[0]), JSON.stringify(p));
  const noneMd = await longpress(el({ title: '/root/out/note.md', _class: '_fileMention_1', _matches: ['button'] }, 'BUTTON'));
  check('长按文本 chips 不触发下载（非放行类型）', noneMd.length === 0, JSON.stringify(noneMd));

  // composer 附件区放行：不能拦截附件删除按钮
  chips = [el({ title: '/tmp/up.png' })];
  const card = el({ _matches: ['[data-composer-card]'] }, 'DIV');
  const got = await click(el({ title: '/tmp/up.png' }, 'IMG', card));
  check('composer 附件区放行', got.length === 0, JSON.stringify(got));

  let failed = 0;
  console.log('');
  for (const c of cases) {
    console.log(`${c.ok ? '✓' : '×'} ${c.name}${c.ok ? '' : '  →  ' + c.detail}`);
    if (!c.ok) failed++;
  }
  if (failed) {
    console.error(`\n× ${failed}/${cases.length} 项行为校验失败`);
    process.exit(1);
  }
  console.log(`\n✓ JS 桥校验全部通过（${cases.length} 项行为 + ${blocks.length} 个脚本语法）`);
})();
