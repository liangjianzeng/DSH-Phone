#!/usr/bin/env node
/**
 * 对照实验：证明「DSH Web 的登录 cookie 是**按端口**签发的」。
 *
 * 为什么要有这个文件：`LocalPortBinder` 的黏性端口阶梯（test/local_port_binder_test.dart
 * 的「黏性端口」组）钉的是"隧道别乱换本地端口"，而"为什么必须稳定"这件事的证据在**服务端**：
 *  1. cookie 名字 = `dsh-auth-<sha256(Host 头)>`，Host 头带着端口 → 名字随端口变；
 *  2. 浏览器发 cookie **不看端口**（同主机所有端口共享 jar）→ 换端口后请求照发旧 cookie，
 *     但服务端按新端口算名字，查不到 → 只能退回 URL 上的 `?token=` 重签；
 *  3. token 是 DSH **进程启动时**随机生成的（`PROCESS_LAUNCH_TOKENS`，不落盘、只在
 *     `dsh web` 启动时打印一次）→ 服务器重启过一次，App 里存的那份就永久对不上。
 * 三条凑齐 = 主文档 401「dsh web authentication required; reopen the URL printed by
 * dsh web.」，拿同一个废 token 重试一万次也不会变好，只有杀掉 App 进程把配置端口腾回来
 * （旧 cookie 重新对得上名字）才恢复 —— 就是用户报的"从后台回前台经常报鉴权未通过，
 * 只有杀掉进程重启才行"。
 *
 * 跑法（默认在本机 npm 全局安装里找 DSH；也可用第一个参数指定包目录）：
 *   node tool/dsh_cookie_port_scoping.mjs
 *   node tool/dsh_cookie_port_scoping.mjs /path/to/@deepseek-ai/dsh-host-authentication-token
 */
import { spawnSync } from 'node:child_process'

// DSH 的 auth 源码用了 TS 参数属性（`private readonly secret: Buffer`），Node 默认的
// strip-only 模式不认，必须带 --experimental-transform-types。没带就自己带flag重跑一次，
// 免得每个想看这个证据的人都要先踩一遍。
if (!process.execArgv.some((a) => a.includes('experimental-transform-types'))) {
  const rerun = spawnSync(
    process.execPath,
    ['--experimental-transform-types', ...process.argv.slice(1)],
    { stdio: 'inherit' },
  )
  process.exit(rerun.status ?? 1)
}

const { createHash } = await import('node:crypto')
const { existsSync, mkdtempSync, readFileSync, writeFileSync } = await import('node:fs')
const { tmpdir } = await import('node:os')
const { join } = await import('node:path')

const CANDIDATES = [
  process.argv[2],
  '/home/jianzengliang/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-host-authentication-token',
  'node_modules/@deepseek-ai/dsh-host-authentication-token',
].filter(Boolean)

const pkg = CANDIDATES.find((p) => existsSync(join(p, 'src/browser-auth.ts')))
if (pkg === undefined) {
  console.error('找不到 dsh-host-authentication-token/src/browser-auth.ts，'
    + '把 DSH 安装目录作为第一个参数传进来即可。');
  process.exit(1)
}

// src/browser-auth.ts 是 TS 且从三个 DSH 包导入；为了独立可跑，取源码后只替换掉
// **运行时**那两条导入（`import type` 会被 Node 的类型剥离直接扔掉）。
const dir = mkdtempSync(join(tmpdir(), 'dsh-cookie-repro-'))
const source = readFileSync(join(pkg, 'src/browser-auth.ts'), 'utf8')
  .replace("import { CONNECT_PATH } from '@deepseek-ai/dsh-client-connection'",
    "const CONNECT_PATH = '/connect';")
  .replace("import { credentialKey } from '@deepseek-ai/dsh-credentials'",
    "const credentialKey = (...parts) => parts.join('/');")
  .replaceAll("from './types.ts'", "from './types_stub.ts'")
writeFileSync(join(dir, 'browser-auth.ts'), source)
writeFileSync(join(dir, 'types_stub.ts'), 'export {}\n')

const { BrowserAuth } = await import(
  `file://${join(dir, 'browser-auth.ts')}`)

const store = new Map()
const credentials = {
  async modifyRecord(key, fn) {
    const current = store.get(key)
    const next = await fn(current)
    if (next === undefined) return current
    store.set(key, next)
    return next
  },
}

class FakeRes {
  constructor() { this.statusCode = 0; this.headers = {}; this.body = '' }
  writeHead(code, headers = {}) { this.statusCode = code; Object.assign(this.headers, headers) }
  end(body = '') { this.body = body }
}

const req = ({ host, query = '', cookie, method = 'GET' }) => {
  const headers = { host }
  if (cookie !== undefined) headers.cookie = cookie
  return { method, url: `/${query}`, headers }
}

const auth = await BrowserAuth.create({}, credentials, 30)
const launchToken = new URL(auth.authenticatedUrl('http://dsh.invalid/'))
  .searchParams.get('token')

const cookieName = (authority) =>
  'dsh-auth-' + createHash('sha256').update(authority).digest('base64')
    .replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '')

const STALE = 'stale-token-from-previous-dsh-process'

// [1] 首次连上：隧道在配置端口，带 token 走鉴权链 → 303 + Set-Cookie
const mint = new FakeRes()
auth.authorizeIndex(req({ host: '127.0.0.1:3080', query: `?token=${launchToken}` }), mint)
const jar = String(mint.headers['set-cookie']).split(';')[0]
console.log('[1] 配置端口 + 有效 token        →', mint.statusCode, '| Set-Cookie:', jar.slice(0, 58), '…')
console.log('    cookie 名 == sha256("127.0.0.1:3080") ?',
  String(mint.headers['set-cookie']).startsWith(cookieName('127.0.0.1:3080')))
console.log('    cookie 名 == sha256("127.0.0.1:3123") ?',
  String(mint.headers['set-cookie']).startsWith(cookieName('127.0.0.1:3123')),
  '← 名字随端口变，而浏览器发 cookie 不看端口')

// [2] 端口没变、token 已过期：cookie 兜住 → 303（这就是"杀进程重启就好了"）
const same = new FakeRes()
auth.authorizeIndex(req({ host: '127.0.0.1:3080', query: `?token=${STALE}`, cookie: jar }), same)
console.log('[2] 端口没变 + token 过期        →', same.statusCode,
  same.statusCode === 303 ? '（cookie 兜住，正常打开）' : same.body.trim())

// [3] 回前台隧道重建后借了别的端口（3080→3123）：同名 cookie 查不到 → 401
const moved = new FakeRes()
auth.authorizeIndex(req({ host: '127.0.0.1:3123', query: `?token=${STALE}`, cookie: jar }), moved)
console.log('[3] 端口变了 + token 过期        →', moved.statusCode,
  moved.statusCode === 401 ? `「${moved.body.trim()}」  ← 用户截图上的那一句` : '')

// [4] 端口变了但 token 有效 → 服务端为新端口重新签发 cookie
const movedOk = new FakeRes()
auth.authorizeIndex(req({ host: '127.0.0.1:3123', query: `?token=${launchToken}` }), movedOk)
console.log('[4] 端口变了 + token 有效        →', movedOk.statusCode, '（重新签发 cookie）')

// [5] 对照：端口没变、没有 cookie、token 过期 → 同样 401（两个条件缺一不可）
const noCookie = new FakeRes()
auth.authorizeIndex(req({ host: '127.0.0.1:3080', query: `?token=${STALE}` }), noCookie)
console.log('[5] 端口没变 + 无 cookie + token 过期 →', noCookie.statusCode)

console.log('\n结论：本地端口必须稳定（见 LocalPortBinder 的黏性端口阶梯），'
  + '端口一漂就等于把用户登出一次。')
