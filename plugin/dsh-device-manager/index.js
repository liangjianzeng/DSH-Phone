/**
 * dsh-device-manager — DSH 测试机（adb）管理插件的 Host 半区。
 *
 * 职责：
 *  · 由**本主机**扫描 USB / 局域网 / Tailscale / 远程 adb server 上可连的 Android 设备；
 *  · 按 ro.serialno 把多条 transport 合并成一台物理设备，缓存到本地 JSON（派生缓存，可随时重扫）；
 *  · 给面板与 Agent 工具提供同一份快照；
 *  · 把"去哪台设备调试、什么状态、怎么连"渲染成消息，填入输入框或排队投递。
 *
 * 设计约束（见 docs/dsh-device-manager-plugin-plan.md）：
 *  · 零运行时依赖：不 import 任何 @deepseek-ai/* 包，全部服务用 ctx.get() 可选取用，
 *    这样 `install_bundle` 走本地目录链接、无需 npm 解析；
 *  · P0 只做「扫描 + 列表 + 注入」，动作集（安装/截图/logcat）留给 P1；
 *  · 外部命令在本机进程内执行（DSH Host 无沙箱限制），不暴露任意 shell 给模型。
 */

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import net from 'node:net';
import { join } from 'node:path';
import { homedir, hostname as osHostname } from 'node:os';

import { createScanner, normalizeConfig, discoverAdbPath } from './lib/scan.js';
import { createRegistry, observe, snapshot as snapshotRegistry, setAliases, resolveDeviceRefs, deviceNames } from './lib/registry.js';
import { composeMessage, BUILTIN_TEMPLATES } from './lib/templates.js';
import { renderModelPrompt } from './lib/prompt.js';
import { toSerialList, toRefList, toInt } from './lib/args.js';

export const name = 'device-manager';

/** 全部依赖都按需用 ctx.get() 取，缺失时功能降级而不是启动失败。 */
function service(ctx, key) {
  try {
    if (typeof ctx.get === 'function') {
      const found = ctx.get(key);
      if (found !== undefined) return found;
    }
  } catch { /* 忽略，退回属性访问 */ }
  try { return ctx[key]; } catch { return undefined; }
}

/** JSON 派生缓存（不是事实来源；删掉目录即可完全重来）。 */
class Store {
  constructor(dir, log) {
    this.dir = dir;
    this.file = join(dir, 'registry.json');
    this.log = log;
    this.timer = null;
    this.dirty = false;
  }

  load() {
    try {
      if (!existsSync(this.file)) {
        this.state = createRegistry();
        return this.state;
      }
      const raw = JSON.parse(readFileSync(this.file, 'utf8'));
      // 缓存是派生数据，可能被手改或被旧版本写坏。逐台修补形状：
      // 下游 registry/templates 直接读 device.transports[...]，缺了会抛，进而打断系统提示词组装。
      const devices = {};
      for (const [serial, device] of Object.entries(raw?.devices ?? {})) {
        if (!serial || !device || typeof device !== 'object') continue;
        const fixed = { ...device };
        if (!fixed.transports || typeof fixed.transports !== 'object' || Array.isArray(fixed.transports)) fixed.transports = {};
        if (!Array.isArray(fixed.transportKeys)) fixed.transportKeys = Object.keys(fixed.transports);
        if (typeof fixed.model !== 'string') fixed.model = fixed.model == null ? '' : String(fixed.model);
        // version 1 的缓存没有 aliases；下游（提示词渲染、面板）按数组读，缺了会抛。
        if (!Array.isArray(fixed.aliases)) fixed.aliases = fixed.aliases ? [String(fixed.aliases)] : [];
        devices[serial] = fixed;
      }
      this.state = createRegistry({ devices });
      return this.state;
    } catch (error) {
      this.log('读取缓存失败，按空缓存继续', String(error?.message ?? error));
      this.state = createRegistry();
      return this.state;
    }
  }

  touch() {
    this.dirty = true;
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.flush();
    }, 500);
    if (typeof this.timer.unref === 'function') this.timer.unref();
  }

  flush() {
    if (!this.dirty) return;
    this.dirty = false;
    try {
      mkdirSync(this.dir, { recursive: true });
      const tmp = `${this.file}.tmp`;
      writeFileSync(tmp, JSON.stringify(this.state, null, 2), 'utf8');
      renameSync(tmp, this.file);
    } catch (error) {
      this.log('写入缓存失败', String(error?.message ?? error));
    }
  }
}

/** 注入历史 + 扫描历史，环形缓冲，落盘便于第二天早上看"昨晚扫了什么"。 */
class History {
  constructor(limit = 50) {
    this.limit = limit;
    this.scans = [];
    this.injects = [];
  }

  push(kind, record) {
    this[kind] = [{ at: Date.now(), ...record }, ...this[kind]].slice(0, this.limit);
  }
}

/** 进程内 adb/tailscale 执行器（DSH Host 无沙箱限制）。 */
function makeRunner(log) {
  return (argv, { timeoutMs = 5000, env } = {}) => new Promise((resolve) => {
    const [command, ...args] = argv;
    let child;
    try {
      child = spawn(command, args, { windowsHide: true, env: env ? { ...process.env, ...env } : undefined });
    } catch (error) {
      resolve({ code: -1, stdout: '', stderr: String(error?.message ?? error), timedOut: false });
      return;
    }
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill(); } catch { /* 忽略 */ }
    }, timeoutMs);
    child.stdout?.on('data', (chunk) => { stdout += chunk; });
    child.stderr?.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => {
      clearTimeout(timer);
      log('子进程错误', `${argv.join(' ')} → ${String(error?.message ?? error)}`);
      resolve({ code: -1, stdout, stderr: String(error?.message ?? error), timedOut });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut });
    });
  });
}

const OUTPUT = {
  schema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      ok: { type: 'boolean', description: '本次调用是否成功。' },
      text: { type: 'string', description: '给人/模型看的正文。' },
      data: { type: 'object', description: '结构化结果（设备清单、扫描记录等）。' },
      error: { type: 'string', description: '失败原因（ok=false 时给出）。' },
    },
    required: ['ok', 'text'],
  },
  render(_args, value) {
    const text = typeof value?.text === 'string' ? value.text : JSON.stringify(value);
    return [{ type: 'text', text }];
  },
};

const PARAMETERS = {
  action: {
    type: 'string',
    required: true,
    enum: ['list', 'scan', 'status', 'inspect', 'compose', 'inject', 'name', 'prompt', 'doctor', 'history'],
    description: 'list=读缓存快照；scan=主机重扫（USB/网段/Tailscale）；status=只刷新已知设备的**即时**状态（屏幕/锁屏/电量/前台，答"该在哪台验证"之前先调它）；inspect=单台设备即时详情；compose=按模板生成调试消息文本；inject=把调试消息投递到会话；name=给用户起的外号建立别名（如把某台叫"小米13"）；prompt=回读当前注入系统提示词的设备清单原文；doctor=自检（adb/tailscale/缓存/工具链）；history=最近扫描与投递记录。',
  },
  serials: {
    type: 'array',
    items: { type: 'string' },
    description: '设备称呼数组，可直接写序列号、型号、adb 目标（IP:5555），或用户起的别名（如"小米13"）——插件会归一化后匹配。inspect 取第一个；compose/inject/name 指定目标设备；省略＝全部健康设备。写错时错误信息会列出候选设备，照候选改名，别猜。',
  },
  names: {
    type: 'array',
    items: { type: 'string' },
    description: '仅 name 用：这台设备的别名表（**整表替换**，空数组＝清空）。首个为主名，最多 6 个、单个 ≤40 字符；会用于匹配用户口中的机器名。',
  },
  sessionId: { type: 'string', description: 'inject 的目标会话 id；省略时使用调用工具所在会话。' },
  target: { type: 'string', description: 'compose/inject 的调试目标文字，例如"登录页重构"。省略时使用会话标题或"本次改动"。' },
  template: { type: 'string', enum: ['default', 'brief', 'perDevice'], description: '消息模板；default=一条汇总（默认），brief=一行一台，perDevice=每台一条。' },
  mode: { type: 'string', enum: ['queue', 'steer'], description: 'inject 投递方式：queue=排队不打断当前回合（默认）；steer=中途纠偏。' },
  filter: { type: 'string', enum: ['all', 'usb', 'lan', 'tailscale', 'remote-server', 'emulator', 'offline'], description: 'list 的过滤条件，默认 all。' },
  limit: { type: 'number', description: 'history 返回条数，默认 10，最多 50。' },
};

/**
 * @param {any} ctx Cordis 上下文
 * @param {Record<string, any>} [rawConfig] cordis.patch.yml 里该行的 config
 */
export function apply(ctx, rawConfig) {
  const config = normalizeConfig(rawConfig ?? {});
  const log = (message, detail) => {
    const logger = service(ctx, 'logger') ?? ctx.logger;
    const line = `[device-manager] ${message}${detail === undefined ? '' : `：${typeof detail === 'string' ? detail : JSON.stringify(detail)}`}`;
    try { logger?.info?.(line); } catch { /* 无 logger 时静默 */ }
  };

  const dataDir = config.dataDir
    ?? join(process.env.DSH_PROFILE_DIR ?? join(homedir(), '.dsh'), 'device-manager');
  const store = new Store(dataDir, log);
  const loadedRegistry = store.load();
  const history = new History();
  /** 面板通道自证：最近 25 次经 HTTP/RPC 进来的调用，用于回答"面板到底连上没有"。 */
  const panelCalls = [];
  const recordPanelCall = (entry) => {
    panelCalls.unshift(entry);
    if (panelCalls.length > 25) panelCalls.pop();
  };
  const adb = config.adbPath ? { path: config.adbPath, source: 'config' } : discoverAdbPath({ fs: { existsSync }, env: process.env });
  const hostName = config.hostName ?? osHostname() ?? '本机';
  const runner = makeRunner(log);

  const scanner = createScanner({
    run: runner,
    net,
    adbPath: adb.path,
    config: { ...rawConfig, hostName },
    log,
  });

  const state = { registry: loadedRegistry, scanning: null, lastScanAt: 0, lastScan: null, adbSource: adb.source, adbVersion: null };
  const registration = { route: 'pending', tool: 'pending', prompt: 'skipped', errors: [] };
  const sessions = new Map(); // sessionId → { selected: [], injectedAt, lastSummary }

  const sessionOf = (sessionId) => {
    if (!sessionId) return null;
    let entry = sessions.get(sessionId);
    if (!entry) {
      entry = { selected: [], injectedAt: 0, lastSummary: '' };
      sessions.set(sessionId, entry);
    }
    return entry;
  };

  const pickDevices = (serials, filter = 'all') => {
    const snap = scanner.snapshot(state.registry, { filter });
    if (!Array.isArray(serials) || serials.length === 0) {
      return snap.devices.filter((device) => device.health === 'ok' || device.health === 'degraded');
    }
    const wanted = new Set(serials);
    return snap.devices.filter((device) => wanted.has(device.serial) || serials.some((s) => s === device.serial || (device.transports ?? []).some((t) => t.endpoint === s)));
  };

  /** adb 版本只探测一次，供 compose / doctor 复用（避免每次调用都 spawn 一次 adb）。 */
  async function ensureAdbVersion() {
    if (state.adbVersion) return state.adbVersion;
    const version = await scanner.adbVersion();
    if (version?.ok && version.version) {
      state.adbVersion = version.version;
      return state.adbVersion;
    }
    return null;
  }

  // 整轮扫描的看门狗：单条命令有自己的 timeout，但探段/串行的 adb 调用叠起来仍可能卡死。
  const SCAN_TIMEOUT_MS = Math.max(10_000, Number(config.poll?.scanTimeoutMs ?? 60_000));

  /** 缓存里已知的设备序列号（错误提示里给模型当"可选值"用）。 */
  const knownSerials = () => Object.keys(state.registry?.devices ?? {});

  /** 错误提示里的"已知设备"要带上别名，否则模型不知道用户口中的名字对应哪台。 */
  const knownNamesHint = () => {
    const list = Object.values(state.registry?.devices ?? {}).slice(0, 12).map((device) => {
      const names = deviceNames(device);
      const alias = names.aliases.length ? `｜别名 ${names.aliases.join('、')}` : '';
      return `${names.serial}（${names.model ?? '未知型号'}${alias}）`;
    });
    return list.join('、') || '无';
  };

  /** 称呼没解析出来时，把候选摆出来：模型会照着候选改名重试，而不是回"没有这台设备"。 */
  const describeUnresolved = (unresolved) => unresolved.map((item) => {
    const candidates = (item.candidates ?? []).map((c) => {
      const alias = c.aliases?.length ? `，别名：${c.aliases.join('、')}` : '';
      const target = c.targets?.length ? `，adb 目标：${c.targets[0]}` : '';
      return `${c.serial}（${c.model ?? '未知型号'}${alias}${target}）`;
    }).join('；') || '（注册表里还没有设备，先 action:"scan"）';
    return `没有设备匹配「${item.ref}」（${item.reason}）。候选：${candidates}`;
  }).join('\n');

  /**
   * 会话 id 的地面真相有两种形态：主会话在 workspace 注册表里是 `session-<uuid>`，
   * subagent 会话是裸 `<uuid>`。只按一种查表会得到 "not found"，所以两种都备着。
   */
  const sessionIdCandidates = (value) => {
    const id = String(value ?? '').trim();
    if (!id) return [];
    const bare = id.replace(/^session-/, '');
    return [...new Set([id, `session-${bare}`, bare])];
  };

  /** 统一的动作入口：RPC 与 Agent 工具共用，保证行为一致。 */
  async function perform(action, rawArgs = {}, context = {}) {
    const args = { ...rawArgs };
    if (args.serials !== undefined) {
      const raw = args.serials;
      const hadInput = Array.isArray(raw) ? raw.length > 0 : String(raw ?? '').trim().length > 0;
      // 先按「称呼」收（序列号 / 型号 / IP:5555 / 别名都行），再解析成真实序列号：
      // 下游 scanner 只认 device.serial，把「小米13」原样传下去会静默变成"没匹配到设备"。
      const refs = toRefList(raw);
      // 给了 serials 却全被过滤掉 → 绝不能退化成"对全部设备动手"。
      if (hadInput && refs.length === 0) {
        return {
          ok: false,
          error: 'no-valid-serial',
          text: `serials 全部非法：${JSON.stringify(raw)}。可写 adb 序列号、host:port、型号或别名（用户起的名字）。已知设备：${knownNamesHint()}`,
        };
      }
      if (refs.length > 0) {
        const resolved = resolveDeviceRefs(state.registry, refs);
        if (!resolved.ok) {
          return { ok: false, error: 'unknown-device', text: describeUnresolved(resolved.unresolved), data: { unresolved: resolved.unresolved, known: knownSerials() } };
        }
        args.serials = resolved.devices.map((device) => device.serial);
      } else {
        args.serials = [];
      }
    }
    switch (action) {
      case 'list': {
        const snap = scanner.snapshot(state.registry, { filter: args.filter ?? 'all' });
        return {
          ok: true,
          text: describeSnapshot(snap),
          data: {
            ...snap,
            lastScanAt: state.lastScanAt,
            hostName,
            adbPath: adb.path,
            scanning: Boolean(state.scanning),
            // 面板把轮询节奏交给服务端统一下发（客户端不再硬编码 3 秒），顺带省掉一次配置往返。
            poll: { panelMs: config.poll.panelMs, badgeMs: config.poll.badgeMs },
          },
        };
      }
      case 'prompt': {
        // 自证入口：模型/用户想确认"到底往系统提示词里塞了什么"时调这个，
        // 不用去猜注册表与渲染的差别；也是 doctor 之外唯一的提示词回归面。
        const snap = scanner.snapshot(state.registry, { filter: 'all' });
        const text = renderModelPrompt({
          devices: snap.devices,
          hostName,
          now: Date.now(),
          staleAfterMs: config.poll.staleAfterMs,
          includeVolatile: config.prompt.includeVolatile,
          maxRows: config.prompt.maxRows,
          showRules: config.prompt.showRules,
        });
        return {
          ok: true,
          text: text || '当前没有可注入的设备（注册表为空）。先 action:"scan"。',
          data: { injected: Boolean(config.exposeToModel), includeVolatile: config.prompt.includeVolatile, registration: registration.prompt, counts: snap.counts },
        };
      }
      case 'name': {
        // 用户口中的"小米13"必须落到设备上，否则模型永远对不上号。
        // 必须显式点名设备：省略 serials 时 pickDevices 会回落到"全部健康设备"，
        // 那等于把同一个别名一次性盖到所有机器上，越权且没法撤销。
        if (!Array.isArray(args.serials) || args.serials.length === 0) {
          return { ok: false, error: 'no-serial', text: `name 必须显式指定设备（serials 写序列号、型号、adb 目标或别名）。已知设备：${knownNamesHint()}` };
        }
        const targets = pickDevices(args.serials, 'all');
        if (targets.length === 0) {
          return { ok: false, error: 'no-device', text: `name 需要指定设备。已知设备：${knownNamesHint()}` };
        }
        if (!Array.isArray(args.names) && args.names === undefined) {
          return { ok: false, error: 'no-names', text: 'name 需要 names（别名数组，整表替换；空数组＝清空）。例如 names:["小米13","备用机"]。' };
        }
        const results = [];
        for (const row of targets) {
          const outcome = setAliases(state.registry, row.serial, args.names);
          if (!outcome.ok) {
            const conflict = outcome.conflict
              ? `「${outcome.conflict.alias}」已经是设备 ${outcome.conflict.owner}${outcome.conflict.ownerModel ? `（${outcome.conflict.ownerModel}）` : ''} 的名字，换个称呼。`
              : (outcome.rejected?.length ? `被拒：${outcome.rejected.map((r) => `${r.name}（${r.reason}）`).join('、')}` : outcome.error);
            results.push({ serial: row.serial, ok: false, error: outcome.error, detail: conflict });
            continue;
          }
          results.push({ serial: row.serial, ok: true, aliases: outcome.aliases, rejected: outcome.rejected ?? [] });
        }
        store.state = state.registry;
        store.touch();
        const failed = results.filter((r) => !r.ok);
        return {
          ok: failed.length === 0,
          error: failed.length ? failed[0].error : undefined,
          text: results.map((r) => (r.ok
            ? `${r.serial} 别名已设为 ${r.aliases.length ? r.aliases.join('、') : '（清空）'}${r.rejected?.length ? `；被拒：${r.rejected.map((x) => `${x.name}（${x.reason}）`).join('、')}` : ''}`
            : `${r.serial} 设置失败：${r.detail}`)).join('\n'),
          data: { results, next: '下一次系统提示词更新后，模型就能用这些名字对上机器。' },
        };
      }
      case 'scan': {
        if (state.scanning) return { ok: true, text: '主机正在扫描中，请稍候。', data: { scanning: true } };
        // 整轮看门狗：一条卡死的 adb 不能把面板永久钉在"正在扫描中"。
        const started = Date.now();
        const current = (async () => {
          const timeout = new Promise((resolve) => {
            const timer = setTimeout(() => resolve({
              ok: false,
              timeout: true,
              run: { at: Date.now(), durationMs: SCAN_TIMEOUT_MS, created: [], merged: 0, errors: [{ stage: 'scan', message: `整轮扫描超过 ${SCAN_TIMEOUT_MS}ms 未返回（可能有 adb 进程卡住）` }] },
            }), SCAN_TIMEOUT_MS);
            timer.unref?.();
          });
          const scanResult = await Promise.race([scanner.scanFull(state), timeout]);
          const result = { ...scanResult, run: { ...(scanResult.run ?? {}), at: scanResult.run?.at ?? started } };
          state.lastScan = result.run;
          state.lastScanAt = result.run.at;
          history.push('scans', { ...result.run, ok: result.ok });
          store.state = state.registry;
          store.touch();
          return result;
        })();
        state.scanning = current;
        let result;
        try {
          result = await current;
        } finally {
          // 只解锁自己这一轮：并发进来的第二轮不能把新 scanning 清成 null。
          if (state.scanning === current) state.scanning = null;
        }
        const snap = scanner.snapshot(state.registry, { filter: args.filter ?? 'all' });
        const firstTime = snap.counts.total === result.run.created.length && result.run.created.length > 0;
        const sources = Object.entries(result.run.sources ?? {}).map(([key, value]) => {
          if (key === 'lan') return `lan=${value?.enabled ? (value.cidrs ?? []).join('|') : 'off'}`;
          if (key === 'probe') return `probe=${value?.candidates ?? 0}`;
          if (key === 'tailscale') return value?.ok ? `tailscale=${value.peers}peer` : `tailscale=不可用(${String(value?.error ?? '').slice(0, 40)})`;
          return `${key}=${value?.count ?? value?.services ?? 0}`;
        }).join(' ');
        return {
          ok: result.ok,
          text: [
            `${result.ok ? '扫描完成' : '扫描失败'}：${snap.counts.total} 台设备 / ${snap.counts.transports} 条通道，用时 ${result.run.durationMs}ms。`,
            `观测 ${result.run.found ?? '?'} 条 transport → 新建 ${result.run.created?.length ?? 0} 台 / 合并 ${Number(result.run.merged) || 0} 条。`,
            `来源：${sources}`,
            result.ok ? '' : `错误：${(result.run.errors ?? []).map((e) => `${e.source ?? e.stage ?? ''} ${e.message}`).join('；')}`,
          ].filter(Boolean).join('\n'),
          data: { snapshot: snap, run: result.run, firstTime, hostName, adbPath: adb.path, adbVersion: state.adbVersion ?? null, lastScanAt: state.lastScanAt },
        };
      }
      case 'status': {
        const targetSerials = args.serials?.length ? args.serials : null;
        const result = await scanner.refreshStatus(state, { serials: targetSerials });
        store.state = state.registry;
        store.touch();
        const snap = scanner.snapshot(state.registry, { filter: args.filter ?? 'all' });
        return {
          ok: true,
          text: `${describeSnapshot(snap)}\n（只读刷新：探测 ${result.probed} 条通道，用时 ${result.durationMs}ms）`,
          data: {
            ...snap,
            probed: result.probed,
            durationMs: result.durationMs,
            hostName,
            // 3 秒一次的只读刷新也要带上这些，否则面板开半小时后"上次扫描"和 adb 路径会被刷成空。
            lastScanAt: state.lastScanAt,
            adbPath: adb.path,
            adbVersion: state.adbVersion,
            scanning: Boolean(state.scanning),
          },
        };
      }
      case 'inspect': {
        const serial = args.serials?.[0];
        if (!serial) {
          return { ok: false, error: 'no-serial', text: 'inspect 需要指定一个设备序列号（serials 里放一个，例如 ["8b1e8747"]）。' };
        }
        if (!state.registry.devices?.[serial]) {
          const known = Object.keys(state.registry.devices ?? {}).join(', ') || '（缓存为空）';
          return { ok: false, error: 'unknown-device', text: `缓存里没有 ${serial}。已知设备：${known}。先用 action:'scan' 重扫。` };
        }
        const result = await scanner.inspect(state.registry, serial);
        if (!result.ok) return { ok: false, error: result.error, text: `读取 ${serial} 失败：${result.error}` };
        store.state = state.registry;
        store.touch();
        const facts = result.facts ?? {};
        return {
          ok: true,
          text: [
            `${serial} 即时状态：`,
            `  屏幕：${facts.screen === 'on' ? '亮屏' : facts.screen === 'off' ? '息屏' : '未知'}｜锁屏：${facts.locked === true ? '是' : facts.locked === false ? '否' : '未知'}`,
            `  电量：${facts.battery ?? '?'}%（${facts.powerSource ?? '未知'}，status ${facts.chargeStatus ?? '?'}）`,
            `  常亮：${facts.stayAwake ? `是（${(facts.stayAwakeConditions ?? []).join('/') || '开'}）` : '否'}｜adbWifi：${facts.adbWifiEnabled ? 'on' : 'off'}`,
            `  前台：${facts.foreground && !facts.foreground.systemUi
              ? `${facts.foreground.package ?? facts.foreground.raw}${facts.foreground.activity ? `/${facts.foreground.activity}` : ''}`
              : `无应用（${facts.foreground?.activity ?? '桌面/通知栏'}${facts.foreground?.systemUi ? '，系统界面' : ''}）`}`,
            `  分辨率：${facts.size ?? '?'} @${facts.density ?? '?'}dpi｜自动亮度：${facts.brightnessAuto ? '开' : '关'}`,
          ].join('\n'),
          data: { serial, facts },
        };
      }
      case 'compose': {
        const devices = pickDevices(args.serials, args.filter);
        if (devices.length === 0) return { ok: false, error: 'no-device', text: '没有可注入的设备，请先扫描。' };
        const composed = composeMessage({
          devices,
          template: args.template ?? config.inject.template,
          target: args.target ?? context.title ?? '本次改动',
          hostName,
          adbVersion: (await ensureAdbVersion()) ?? '未知',
          generatedAt: Date.now(),
        });
        const entry = sessionOf(context.sessionId);
        if (entry) {
          entry.selected = devices.map((device) => device.serial);
          entry.lastSummary = composed.text;
        }
        return { ok: true, text: composed.text, data: { messages: composed.messages, templateTitle: composed.templateTitle, serials: devices.map((d) => d.serial) } };
      }
      case 'inject': {
        const devices = pickDevices(args.serials, args.filter);
        if (devices.length === 0) return { ok: false, error: 'no-device', text: '没有可注入的设备，请先扫描。' };
        const composed = composeMessage({
          devices,
          template: args.template ?? config.inject.template,
          target: args.target ?? context.title ?? '本次改动',
          hostName,
          adbVersion: (await ensureAdbVersion()) ?? '未知',
          generatedAt: Date.now(),
        });
        const sessionId = args.sessionId ?? context.sessionId;
        if (!sessionId) return { ok: false, error: 'no-session', text: '缺少目标会话 id（工具在子会话里调用时请显式传 sessionId）。' };
        const sessionController = service(ctx, 'sessionController');
        if (!sessionController?.prompt) {
          return { ok: false, error: 'no-session-controller', text: '本部署未提供会话投递服务，请改用面板的"填入输入框"。' };
        }
        const mode = args.mode ?? config.inject.mode;
        const messages = composed.messages.length > 0 ? composed.messages : [composed.text];
        const candidates = sessionIdCandidates(sessionId);
        const receipts = [];
        // 会话 id 有两种真实形态：主会话在注册表里带 `session-` 前缀，subagent 会话是裸 uuid。
        // 只按一种形态查表会让 agent 收到 "session ... not found" 并误判投递功能坏了，
        // 所以逐个候选试；"not found" 才换下一个，其它错误（subagent routing / busy）换 id 无意义。
        let resolvedSessionId = candidates[0];
        for (const text of messages) {
          const requestId = `dm-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
          let receipt = null;
          let failure = null;
          for (const candidate of candidates) {
            try {
              const attempt = await sessionController.prompt(
                { requestId, sessionId: candidate, mode: mode === 'steer' ? 'steer' : 'queue', content: [{ type: 'text', text }] },
                AbortSignal.timeout(15000),
              );
              if (attempt && attempt.ok === false && /not found/i.test(String(attempt.error?.message ?? attempt.error ?? ''))) {
                failure = String(attempt.error?.message ?? attempt.error);
                continue;
              }
              receipt = attempt;
              resolvedSessionId = candidate;
              break;
            } catch (error) {
              const message = String(error?.message ?? error);
              failure = message;
              if (/not found/i.test(message)) continue;
              resolvedSessionId = candidate;
              break;
            }
          }
          if (receipt && receipt.ok !== false) {
            receipts.push({ requestId, sessionId: resolvedSessionId, ok: true, receipt });
          } else {
            receipts.push({
              requestId,
              sessionId: resolvedSessionId,
              ok: false,
              error: String(receipt?.error?.message ?? receipt?.error ?? failure ?? 'rejected by host'),
            });
          }
        }
        const failed = receipts.filter((r) => !r.ok);
        const ok = failed.length === 0;
        const entry = sessionOf(resolvedSessionId);
        if (entry) {
          entry.selected = devices.map((device) => device.serial);
          entry.injectedAt = Date.now();
          entry.lastSummary = composed.text;
        }
        history.push('injects', {
          sessionId: resolvedSessionId,
          mode,
          serials: devices.map((d) => d.serial),
          ok,
          count: receipts.length,
          failed: failed.length,
          errors: failed.map((r) => r.error).slice(0, 3),
        });
        const lines = [];
        if (ok) {
          lines.push(`已向会话 ${resolvedSessionId} 投递 ${receipts.length} 条设备调试消息（${mode}）。`);
          lines.push(`投递的正文首行：${messages[0].split('\n')[0]}`);
        } else {
          lines.push(`投递失败 ${failed.length}/${receipts.length} 条：${failed.map((r) => r.error).join('；')}`);
          if (failed.some((r) => /owned by subagent routing/i.test(r.error))) {
            lines.push('原因：该会话被 subagent routing 独占，Host 不允许从外部往里 prompt。请让主会话的 agent 调用，或让面板用"填入输入框"。');
          }
          if (failed.some((r) => /not found/i.test(r.error))) {
            lines.push(`原因：Host 会话表里没有 ${candidates.join(' / ')}（两种形态都试过）。请从面板发起，或显式传注册表里的会话 id。`);
          }
          if (!args.sessionId) {
            lines.push('提示：这次用的是调用方所在会话；显式传 sessionId 可投到别的会话。');
          }
        }
        return {
          ok,
          text: lines.join('\n'),
          data: { sessionId: resolvedSessionId, mode, receipts, serials: devices.map((device) => device.serial) },
        };
      }
      case 'history': {
        const limit = toInt(args.limit, { min: 1, max: 50, fallback: 10 });
        const scans = history.scans.slice(0, limit);
        const injects = history.injects.slice(0, limit);
        const lines = [];
        lines.push(`最近 ${scans.length} 次扫描：`);
        for (const scan of scans) {
          const stamp = new Date(scan.at).toLocaleTimeString('zh-CN', { hour12: false });
          const created = scan.created?.length ?? 0;
          const merged = Number(scan.merged) || 0;
          lines.push(`  ${stamp} ${scan.ok ? 'ok' : '失败'} 新建 ${created} 台 / 合并 ${merged} 条 · ${scan.durationMs ?? '?'}ms${scan.errors?.length ? ` · ${scan.errors.length} 个错误：${String(scan.errors[0]?.message ?? scan.errors[0])}` : ''}`);
        }
        lines.push(`最近 ${injects.length} 次投递：`);
        for (const record of injects) {
          const stamp = new Date(record.at).toLocaleTimeString('zh-CN', { hour12: false });
          // 注册表里的会话 id 带 `session-` 前缀，短显示要剥掉，否则一屏全是 "session-"
          const shortSession = String(record.sessionId ?? '?').replace(/^session-/, '').slice(0, 8);
          lines.push(`  ${stamp} ${record.ok ? 'ok' : `失败(${record.failed ?? 0}/${record.count})`} → ${shortSession} · ${record.mode} · ${(record.serials ?? []).join('+')}${record.errors?.length ? ` · ${record.errors[0]}` : ''}`);
        }
        return {
          ok: true,
          text: lines.join('\n') || '（还没有扫描或投递记录）',
          data: { scans, injects, dataDir },
        };
      }
      case 'doctor':
      default: {
        // 不经 HTTP 直接跑一遍路由本体，把"URL 解析 + JSON 编解码 + perform"这一段纳入自检。
        let routeCheck = null;
        try {
          const response = await routeResource(new Request('http://localhost/adb-devices/list?action=list'), { source: 'internal' });
          const body = await response.json();
          routeCheck = { status: response.status, ok: response.status === 200 && body?.ok === true && body?.value?.ok === true };
        } catch (error) {
          routeCheck = { status: 0, ok: false, error: String(error?.message ?? error) };
        }
        const version = await scanner.adbVersion();
        if (version?.ok && version.version) state.adbVersion = version.version;
        const local = version.ok ? await scanner.listTransports() : { ok: false, devices: [], notes: [], error: version.error };
        const mdns = await scanner.mdnsServices();
        const tailnet = await scanner.tailscaleStatus();
        const checks = [
          { name: 'adb', ok: version.ok, detail: `${adb.path}（来源 ${adb.source}）${version.version ? ` 版本 ${version.version}` : ''}` },
          { name: 'adb devices', ok: local.ok, detail: local.ok ? `${local.devices.length} 条通道` : (local.error ?? '失败') },
          { name: 'mDNS', ok: mdns.available, detail: mdns.available ? `${mdns.services.length} 个无线调试服务` : (mdns.note ?? '不可用') },
          { name: 'tailscale', ok: tailnet.ok, detail: tailnet.ok ? `${tailnet.peers?.length ?? 0} 个 peer` : (tailnet.error ?? tailnet.skipped ? '已关闭' : '不可用') },
          { name: '局域网扫描', ok: true, detail: config.sources.lan.enabled ? `已开：${config.sources.lan.cidrs.join(', ') || '未配 CIDR'}` : '默认关闭（需显式配 CIDR）' },
          { name: '路由注册', ok: registration.route === 'ok', detail: registration.route === 'ok' ? '/adb-devices/* 已注册（App 面板与 /api 通道的命脉）' : `${registration.route}${registration.errors.length ? ` ｜ ${registration.errors.join('；')}` : ' ｜ 未注册，面板会 404'}` },
          // 之前写的是 `!== 'failed'`，而失败值是带后缀的长串（'failed（…）'），精确比较永远不成立
          // → 真失败也画绿勾。现在 registration.tool 只取 'ok'/'pending'/'failed'，失败详情在 errors。
          { name: '工具注册', ok: registration.tool === 'ok', detail: registration.tool === 'ok' ? 'adb_devices 已注册（模型可调）' : registration.tool === 'pending' ? '等待宿主 tools 服务…（到货自动补注册）' : `${registration.tool}${registration.errors.length ? ` ｜ ${registration.errors.join('；')}` : ' ｜ adb_devices 不可用，模型没法查设备'}` },
          { name: '缓存', ok: true, detail: `${dataDir}（${Object.keys(state.registry.devices ?? {}).length} 台设备，上次扫描 ${state.lastScanAt ? new Date(state.lastScanAt).toLocaleTimeString('zh-CN', { hour12: false }) : '从未'}）` },
          {
            name: '会话投递服务',
            ok: Boolean(service(ctx, 'sessionController')?.prompt),
            detail: service(ctx, 'sessionController')?.prompt
              ? 'sessionController.prompt 已注入（真正能否投递取决于目标会话：subagent 会话会被拒，需显式传可写会话的 sessionId）'
              : '未注入 sessionController',
          },
        ];
        checks.push({
          name: 'HTTP 路由本体',
          ok: routeCheck?.ok === true,
          detail: routeCheck?.ok ? `直接调用 resource：HTTP ${routeCheck.status}，list 返回 ok` : `直接调用失败：${routeCheck?.error ?? JSON.stringify(routeCheck)}`,
        });
        checks.push({
          name: '面板通道',
          ok: panelCalls.length > 0,
          detail: panelCalls.length
            ? `${panelCalls.length} 次外部调用；最近 ${new Date(panelCalls[0].at).toLocaleTimeString('zh-CN', { hour12: false })} ${panelCalls[0].source ?? 'http'}:${panelCalls[0].action} ${panelCalls[0].ok ? 'ok' : `失败：${panelCalls[0].error ?? ''}`}（${panelCalls[0].ms}ms）`
            : '还没有面板/外部调用（浏览器没打开过面板；本项不含 doctor 自检探针，能自己证伪）',
        });
        const tolerated = new Set(['mDNS', 'tailscale', '局域网扫描', '面板通道']);
        const allOk = checks.every((c) => c.ok || tolerated.has(c.name));
        return {
          ok: allOk,
          text: checks.map((c) => `${c.ok ? '✔' : '✘'} ${c.name}：${c.detail}`).join('\n'),
          data: { checks, config, hostName, dataDir },
        };
      }
    }
  }

  function describeSnapshot(snap) {
    if (snap.counts.total === 0) return '主机上还没有已知设备，请执行扫描。';
    const cap = Math.max(1, Number(config.list?.maxRows ?? 20));
    const rows = snap.devices.slice(0, cap);
    const lines = rows.map((device, index) => {
      // 把「adb -s 该填什么」直接印出来：模型抄这一串就行，不用自己猜序列号还是 IP。
      const transports = device.transports
        .map((t) => `${t.label} ${t.endpoint}[${t.state}]（adb -s ${t.adbTarget || t.endpoint}）`)
        .join(' + ');
      const alias = (device.aliases ?? []).length ? ` 「${device.aliases.join('、')}」` : '';
      return `${index + 1}. ${device.model}${alias}（Android ${device.android ?? '?'}）serial ${device.serial}｜${transports}｜${device.summary}`;
    });
    const tail = snap.devices.length > rows.length
      ? `（还有 ${snap.devices.length - rows.length} 台未列出，请用 filter 收窄或指定 serials）`
      : '';
    return `主机 ${hostName}：${snap.counts.total} 台设备 / ${snap.counts.transports} 条通道\n${lines.join('\n')}${tail ? `\n${tail}` : ''}`;
  }

  // ── Agent 工具 ────────────────────────────────────────────────────────────
  const registerTool = (from = ctx) => {
    const tools = service(from, 'tools');
    if (!tools?.register) return false;
    if (registration.tool === 'ok') return true; // 已注册过（幂等：立即 + inject 回调可能先后到达）
    try {
      const dispose = tools.register({
        name: 'adb_devices',
        description: '管理本主机上的 Android 测试机（adb）。要回答"该在哪台设备上验证 / 这台现在什么状态"，先调本工具取实时状态（action:"status" 或 "inspect"），不要凭系统提示词里的设备清单猜屏幕与电量。定位设备用 adb -s <目标>，目标从 list/status 输出里原样取（网络设备是 IP:5555，USB 是序列号，型号名不能当 `-s` 参数）。serials 支持序列号、型号、adb 目标或用户起的别名（如"小米13"）；别名用 action:"name" 建立，之后模型和用户都能用同一个名字对上机器。',
        parameters: PARAMETERS,
        output: OUTPUT,
        async execute(args, exec) {
          const sessionId = exec?.agent?.id ?? args.sessionId ?? null;
          const title = exec?.agent?.session?.title ?? undefined;
          try {
            return await perform(String(args.action ?? 'doctor'), args, { sessionId, title });
          } catch (error) {
            const message = String(error?.message ?? error);
            log('工具执行失败', `${args.action} → ${message}`);
            return { ok: false, error: message, text: `设备管理调用失败：${message}` };
          }
        },
        isConcurrencySafe: (args) => args?.action === 'list' || args?.action === 'history',
      });
      ctx.effect?.(() => dispose);
      registration.tool = 'ok';
      log('adb_devices 工具已注册');
      return true;
    } catch (error) {
      // 注册抛了就别再重试（重试只会重复抛），但要如实记账——doctor 靠这个值亮红。
      registration.tool = 'failed';
      registration.errors.push(`注册工具异常：${String(error?.message ?? error)}`);
      log('注册工具失败', String(error?.message ?? error));
      return true;
    }
  };
  if (!registerTool(ctx)) {
    // 冷启动竞态（2026-11-28 重启实测：apply() 跑在 tools 服务起来之前，旧代码等服务到了
    // 也只记账不补注册，doctor 报「工具注册 failed」却画绿勾，模型整整没有 adb_devices 可调）。
    // 与路由 / 提示词段同款三段式：先 ctx.inject 让加载器等依赖，再轮询兜底；服务一到**真正补注册**。
    if (typeof ctx.inject === 'function') {
      ctx.inject(['tools'], (inner) => {
        if (!registerTool(inner ?? ctx) && registration.tool === 'pending') {
          registration.tool = 'failed';
          registration.errors.push('ctx.inject 回调里仍取不到 tools 服务，adb_devices 工具不可用');
        }
      });
    } else {
      waitForService('tools').then((found) => {
        if (found?.register) registerTool(ctx);
        if (registration.tool === 'pending') {
          registration.tool = 'failed';
          registration.errors.push('宿主 tools 服务在 6s 内未就绪，adb_devices 工具不可用');
        }
      });
    }
  }

  // ── 面板数据面：同域 HTTP 路由（读匿名、写需凭据）+ connection.rpc（若可用）──
  const normalizePayload = (payload) => {
    const next = { ...(payload ?? {}) };
    if (typeof next.limit === 'string') next.limit = Number(next.limit);
    for (const key of Object.keys(next)) if (next[key] === '' || next[key] === 'undefined') delete next[key];
    return next;
  };

  const handle = async (endpoint, payload, options = {}) => {
    const action = String(payload?.action ?? endpoint ?? 'list');
    const started = Date.now();
    // doctor 的自检探针也走这条函数，但它不是"面板真的连上过"的证据，
    // 记进去会让"面板通道"这一项永远显示已连通 —— 自检要能自己证伪。
    const record = options.source !== 'internal';
    try {
      const value = await perform(action, normalizePayload(payload), { sessionId: payload?.sessionId, title: payload?.title });
      if (record) recordPanelCall({ at: started, action, source: options.source ?? 'http', ok: value?.ok !== false, ms: Date.now() - started });
      // 内层 ok 透传到外层：面板据此把红色错误条显示出来（错误文案取 value.text）。
      return { ok: value?.ok !== false, value };
    } catch (error) {
      const message = String(error?.message ?? error);
      if (record) recordPanelCall({ at: started, action, source: options.source ?? 'http', ok: false, ms: Date.now() - started, error: message });
      log('RPC 调用失败', `${action} → ${message}`);
      return { ok: false, error: { code: 'device-manager/internal', message, details: {} } };
    }
  };

  const connection = service(ctx, 'connection');
  if (connection?.rpc?.handle) {
    try {
      const dispose = connection.rpc.handle('/adb-devices', async (endpoint, payload, signal, peer) => {
        void signal; void peer;
        return handle(endpoint, payload, { source: 'rpc' });
      });
      ctx.effect?.(() => async () => { try { await dispose?.(); } catch { /* 忽略 */ } });
      // 别把 registration.tool 抢改成 'ok'：这是面板的可选 RPC 快通道，不是 agent 工具；
      // 之前这一句会把「工具其实没注册上」的失败盖成 ok，doctor 就失去了报警能力。
    } catch (error) {
      log('注册 RPC 通道失败', String(error?.message ?? error));
    }
  }

  const READ_ONLY = new Set(['list', 'status', 'doctor', 'history', 'prompt']);

  /**
   * 跨 loopback 源放行：页面可能由端口转发/代理（如 127.0.0.1:3083）提供，
   * 而真正跑 adb 的是另一个 DSH 实例（127.0.0.1:3080）。
   * 只放行 loopback 源，且必须带凭据；公网源一律不给 CORS 头。
   */
  const corsHeaders = (request) => {
    const origin = typeof request?.headers?.get === 'function' ? request.headers.get('origin') : '';
    if (!origin) return {};
    let parsed;
    try { parsed = new URL(origin); } catch { return {}; }
    const host = parsed.hostname;
    const loopback = host === '127.0.0.1' || host === 'localhost' || host === '[::1]' || host === '::1';
    if (!loopback || !/^https?:$/.test(parsed.protocol)) return {};
    return {
      'access-control-allow-origin': origin,
      'access-control-allow-credentials': 'true',
      'access-control-allow-headers': 'content-type',
      'access-control-allow-methods': 'GET,POST,OPTIONS',
      vary: 'Origin',
    };
  };

  /** 路由处理本体：也供 doctor 直接调用，不经 HTTP 就能自测这一段（含 URL 解析与 JSON 编解码）。 */
  const routeResource = async (request, options = {}) => {
    const cors = corsHeaders(request);
    if (String(request?.method ?? 'GET').toUpperCase() === 'OPTIONS') {
      return new Response(null, { status: 204, headers: cors });
    }
    const url = new URL(request.url, 'http://localhost');
    const fromPath = url.pathname.split('/').filter(Boolean).slice(1).pop();
    let action = url.searchParams.get('action') || fromPath || 'list';
    let payload = { action };
    if (request.method === 'POST') {
      try {
        payload = { ...JSON.parse((await request.text()) || '{}'), action: payload.action };
        action = payload.action;
      } catch { /* 保留默认 payload */ }
    }
    const result = await handle(action, payload, options);
    return new Response(JSON.stringify(result), {
      status: 200,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        ...cors,
      },
    });
  };

  /**
   * auth 与 resource 必须用**同一个** action 解析口径，否则会出现
   * `GET /adb-devices/scan`：auth 只看 query 判成匿名、resource 却按路径执行写操作。
   */
  const resolveAction = (url) => {
    try {
      const fromQuery = url?.searchParams?.get('action');
      if (fromQuery) return fromQuery;
    } catch { /* 落到路径判定 */ }
    const fromPath = String(url?.pathname ?? '').split('/').filter(Boolean).slice(1).pop();
    return fromPath || 'list';
  };

  /** 把各种 url 形态（URL / 字符串）统一成 URL，供 resolveAction 使用。 */
  const toUrl = (raw) => {
    if (raw instanceof URL) return raw;
    try { return new URL(String(raw ?? ''), 'http://localhost'); } catch { return null; }
  };

  /** 从 URL 或字符串里取 action（WebAuthRequest.url 声明是 URL，但传字符串也要能判）。 */
  const actionOfRequest = (request) => resolveAction(toUrl(request?.url));

  /**
   * 冷启动时宿主各服务不保证同批可用（webServer 常常比插件激活晚到），
   * 只 ctx.get 一次会**静默**丢掉路由注册：表现为 /adb-devices/* 全线 404，而插件条目
   * 显示 active、工具也在、面板图标也在——排查者完全看不到原因（2026-11-25 08:43 冷启动
   * 复现，App 侧「扫描总是 404」就是这个）。所以：等它，且把结果记进 registration，
   * 让 doctor 和面板能如实说"路由没注册上"。
   *
   * 轮询等待宿主服务出现；超时返回 undefined，调用方自己记账。
   * 必须是**函数声明**而不是 const 箭头：工具注册段在文件更靠前的位置就要用它，
   * const 会撞 TDZ（ReferenceError: Cannot access 'waitForService' before
   * initialization），而那是运行时错误，`node --check` 查不出来——冷启动实测抓到过。
   */
  function waitForService(key, { attempts = 60, delayMs = 100 } = {}) {
    return new Promise((resolve) => {
      let tried = 0;
      const tick = () => {
        const found = service(ctx, key);
        if (found) return resolve(found);
        if (tried++ >= attempts) return resolve(undefined);
        setTimeout(tick, delayMs);
      };
      tick();
    });
  }

  let routeRegistered = false;
  function markRouteFailed(reason) {
    if (routeRegistered) return;
    registration.route = 'failed';
    registration.errors.push(`${reason}（/adb-devices/* 未注册，App 面板会 404）`);
    log('HTTP 路由未注册', reason);
  }
  /**
   * HTTP 入口本体。宿主 webServer 的 `resource` 路由按设计只应答 GET/HEAD，
   * 其它方法在匹配之前就回 405（Allow: GET, HEAD），POST /adb-devices/scan 因此全废
   * （2026-11-25 实测：面板点扫描 → HTTP 405）。要收 POST 只能注册 `handler`，
   * 自己把 node 的 req/res 适配成 Fetch 的 Request/Response，业务逻辑仍留在 routeResource。
   */
  const routeHandler = async (req, res) => {
    const method = String(req?.method ?? 'GET').toUpperCase();
    let body;
    if (method !== 'GET' && method !== 'HEAD') {
      const chunks = [];
      for await (const part of req) chunks.push(part);
      body = Buffer.concat(chunks);
    }
    const headers = new Headers();
    for (const [key, value] of Object.entries(req?.headers ?? {})) {
      if (value === undefined) continue;
      for (const one of Array.isArray(value) ? value : [value]) headers.append(key, one);
    }
    const request = new Request(new URL(String(req?.url ?? '/'), 'http://localhost'), {
      method,
      headers,
      body: body === undefined ? undefined : body,
    });
    const response = await routeResource(request);
    // arrayBuffer() 是 ArrayBuffer，node 的 res.end 只吃 Buffer/Uint8Array，
    // 直接传会 ERR_INVALID_ARG_TYPE 并把连接打断（表现为 GET 也拿不到响应）。
    const payload = method === 'HEAD' ? null : Buffer.from(await response.arrayBuffer());
    const flat = {};
    response.headers.forEach((value, key) => {
      flat[key] = value;
    });
    res.writeHead(response.status, flat);
    res.end(payload);
  };

  const registerHttpRoute = (from = ctx) => {
    if (routeRegistered) return true;
    const webServer = service(from, 'webServer');
    if (!webServer?.register) return false;
    try {
      const dispose = webServer.register({
        kind: 'prefix',
        path: '/adb-devices',
        // 只有闭集只读动作的 GET 允许匿名；其它（含任何写动作、任何 POST）必须带凭据。
        // 解析不出动作也一律 required——宁可多要凭据，不可放行写操作。
        auth: (request) => {
          const method = String(request?.method ?? 'GET').toUpperCase();
          // 预检不带凭据、也不执行任何业务逻辑，必须放行，否则跨 loopback 源的 POST 全废。
          if (method === 'OPTIONS') return 'anonymous';
          const action = actionOfRequest(request);
          return method === 'GET' && READ_ONLY.has(action) ? 'anonymous' : 'required';
        },
        handler: routeHandler,
      });
      ctx.effect?.(() => dispose);
      routeRegistered = true;
      registration.route = 'ok';
      log('HTTP 路由已注册 /adb-devices/*');
      return true;
    } catch (error) {
      registration.route = 'failed';
      registration.errors.push(`HTTP 路由注册异常：${String(error?.message ?? error)}`);
      log('注册 HTTP 路由失败', String(error?.message ?? error));
      return true; // 已尝试过，不再重试（重试只会重复抛）
    }
  };
  if (!registerHttpRoute(ctx)) {
    // 官方机制（practices.md：可选服务放 inject / ctx.inject，缺服务的 profile 里整段
    // 不激活而不是抛）：webServer 由 web 侧稍晚提供，冷启动时 ctx.get 是快照查询，
    // 自己轮询 ctx.get 等不到——必须走 ctx.inject 让加载器等依赖。
    if (typeof ctx.inject === 'function') {
      ctx.inject(['webServer'], (inner) => {
        if (!registerHttpRoute(inner ?? ctx)) markRouteFailed('ctx.inject 回调里仍取不到 webServer');
      });
    } else {
      waitForService('webServer').then((found) => {
        if (found?.register) registerHttpRoute(ctx);
        if (!routeRegistered) markRouteFailed('宿主 webServer 服务在 6s 内未就绪（ctx.inject 也不可用）');
      });
    }
  }

  // ── 会话上下文：让模型自己知道有哪些设备（可关） ───────────────────────────
  const registerPromptSection = (from = ctx) => {
    const systemPrompt = service(from, 'systemPrompt');
    if (!systemPrompt?.section) return false;
    try {
      const dispose = systemPrompt.section({
        name: 'device-manager',
        order: 60,
        // 设备 notes / 型号是外部可控文本；DSH 会把 section 里的 {{name}} 当插值变量解析，
        // 未注册的名字直接抛错，从而**打断所有会话的系统提示词组装**（不是只影响本插件）。
        // 这段本来就自排版，关掉插值是唯一的正确取值。
        interpolate: false,
        text: () => {
          // 这一段被拼进**每个会话**的系统提示词：这里抛异常会让整条 prompt 组装失败，
          // 影响面远大于设备面板本身，所以宁可吞掉返回空段。
          try {
            const snap = scanner.snapshot(state.registry, { filter: 'all' });
            return renderModelPrompt({
              devices: snap.devices,
              hostName,
              now: Date.now(),
              staleAfterMs: config.poll.staleAfterMs,
              includeVolatile: config.prompt.includeVolatile,
              maxRows: config.prompt.maxRows,
              showRules: config.prompt.showRules,
            });
          } catch (error) {
            log('系统提示词段生成失败', String(error?.message ?? error));
            return '';
          }
        },
      });
      ctx.effect?.(() => dispose);
      registration.prompt = 'ok';
      return true;
    } catch (error) {
      registration.prompt = 'failed';
      registration.errors.push(`系统提示词段注册异常：${String(error?.message ?? error)}`);
      log('注册系统提示词段失败', String(error?.message ?? error));
      return true;
    }
  };
  if (config.exposeToModel && !registerPromptSection(ctx)) {
    if (typeof ctx.inject === 'function') {
      ctx.inject(['systemPrompt'], (inner) => {
        if (!registerPromptSection(inner ?? ctx) && registration.prompt === 'pending') {
          registration.prompt = 'failed';
          registration.errors.push('ctx.inject 回调里仍取不到 systemPrompt，模型看不到设备清单');
        }
      });
    } else {
      waitForService('systemPrompt').then((found) => {
        if (found?.section) registerPromptSection(ctx);
        if (registration.prompt === 'pending') {
          registration.prompt = 'failed';
          registration.errors.push('宿主 systemPrompt 服务在 6s 内未就绪，模型看不到设备清单');
        }
      });
    }
  }

  // ── 后台低频刷新（仅在允许时） ────────────────────────────────────────────
  if (config.poll.enabled && config.poll.backgroundMs > 0) {
    const timer = setInterval(() => {
      scanner.refreshStatus(state, {}).then(() => {
        store.state = state.registry;
        store.touch();
      }, (error) => log('后台刷新失败', String(error?.message ?? error)));
    }, Math.max(5000, config.poll.backgroundMs));
    if (typeof timer.unref === 'function') timer.unref();
    ctx.effect?.(() => () => clearInterval(timer));
  }

  // 启动即做一次轻量刷新（不扫网段），让面板首屏就有东西；它不等于全量扫描，
  // 因此不能改写 lastScanAt，否则原生面板会误以为已经扫过并隐藏扫描入口。
  scanner.refreshStatus(state, {}).then((result) => {
    log('首屏状态刷新完成', `${result.probed} 条通道 / ${result.durationMs}ms`);
    store.state = state.registry;
    store.touch();
  }, (error) => log('首屏状态刷新失败', String(error?.message ?? error)));

  ctx.effect?.(() => () => {
    store.flush();
  });

  log('插件已激活', `adb=${adb.path} 主机=${hostName} 缓存=${dataDir}`);
  return () => { store.flush(); };
}

/** 供 RPC/工具与自测共用：导出纯函数面，方便脱离 DSH 单测。 */
export const __testables = { composeMessage, BUILTIN_TEMPLATES, createRegistry, observe, snapshotRegistry };
