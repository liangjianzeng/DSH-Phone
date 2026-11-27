/**
 * 扫描编排：USB（adb devices）+ 局域网（TCP 探活 + adb connect）+ Tailscale（peer → 探活）
 * + mDNS（Android 11+ 无线调试）+ 远程 adb server，再把全部 transport 交给注册表按
 * ro.serialno 合并，最后一次性采集设备事实。
 *
 * 不依赖 DSH：外部命令走注入的 `run`，TCP 走注入的 `net`，因此同一份代码可在
 * DSH Host（ctx.subprocess）与 tools/selftest.mjs（child_process）里跑。
 */

import {
  parseDevicesList,
  parseMdnsServices,
  parseTailscaleStatus,
  collectFactsFrom,
  classifyEndpoint,
  isTailnetAddress,
} from './adb.js';
import { buildProbeTargets, tcpProbe } from './probe.js';
import { observe, snapshot, transportPriority } from './registry.js';

/** 简单并发池。 */
async function mapLimit(items, limit, worker) {
  const queue = items.map((item, index) => ({ item, index }));
  const results = new Array(items.length);
  const size = Math.max(1, Math.min(limit || 4, 16));
  const runners = Array.from({ length: size }, async () => {
    for (;;) {
      const next = queue.shift();
      if (!next) return;
      results[next.index] = await worker(next.item, next.index);
    }
  });
  await Promise.all(runners);
  return results;
}

export function normalizeConfig(raw = {}) {
  const sources = raw.sources ?? {};
  return {
    adbPath: typeof raw.adbPath === 'string' && raw.adbPath !== 'auto' ? raw.adbPath : null,
    dataDir: typeof raw.dataDir === 'string' && raw.dataDir ? raw.dataDir : null,
    exposeToModel: raw.exposeToModel !== false,
    tailscalePath: typeof raw.tailscalePath === 'string' && raw.tailscalePath !== 'auto' ? raw.tailscalePath : 'tailscale',
    server: { port: Number(raw.server?.port ?? 5037) },
    sources: {
      usb: { enabled: sources.usb?.enabled !== false },
      lan: {
        enabled: sources.lan?.enabled === true,
        cidrs: Array.isArray(sources.lan?.cidrs) ? sources.lan.cidrs : [],
        ports: Array.isArray(sources.lan?.ports) ? sources.lan.ports.map(Number) : [5555],
        useMdnsFirst: sources.lan?.useMdnsFirst !== false,
        ratePerSec: Number(sources.lan?.ratePerSec ?? 200),
        connectTimeoutMs: Number(sources.lan?.connectTimeoutMs ?? 250),
        maxConcurrency: Number(sources.lan?.maxConcurrency ?? 32),
        maxIps: Number(sources.lan?.maxIps ?? 512),
      },
      tailscale: {
        enabled: sources.tailscale?.enabled !== false,
        ports: Array.isArray(sources.tailscale?.ports) ? sources.tailscale.ports.map(Number) : [5555],
      },
      emulator: { enabled: sources.emulator?.enabled !== false },
      remoteAdbServers: Array.isArray(sources.remoteAdbServers) ? sources.remoteAdbServers : [],
    },
    collect: {
      concurrency: Number(raw.collect?.concurrency ?? 4),
      perCommandTimeoutMs: Number(raw.collect?.perCommandTimeoutMs ?? 3000),
      factTimeoutMs: Number(raw.collect?.factTimeoutMs ?? 5000),
      roundBudgetMs: Number(raw.collect?.roundBudgetMs ?? 20000),
    },
    poll: {
      enabled: raw.poll?.enabled !== false,
      // 面板 3 秒一刷会让整排按钮反复 disabled（用户反馈"界面每两三秒闪一下"）。
      // 默认降到 60 秒；客户端读服务端下发的这个值，不再硬编码。
      panelMs: Number(raw.poll?.panelMs ?? 60000),
      badgeMs: Number(raw.poll?.badgeMs ?? 30000),
      backgroundMs: Number(raw.poll?.backgroundMs ?? 30000),
      staleAfterMs: Number(raw.poll?.staleAfterMs ?? 120000),
      pruneAfter: Number(raw.poll?.pruneAfter ?? 3),
    },
    // 注入系统提示词的那一段。默认只放慢变事实（见 lib/prompt.js 文件头）。
    prompt: {
      includeVolatile: raw.prompt?.includeVolatile === true,
      maxRows: Number(raw.prompt?.maxRows ?? 12),
      showRules: raw.prompt?.showRules !== false,
    },
    inject: {
      mode: raw.inject?.mode === 'steer' ? 'steer' : 'queue',
      template: ['default', 'brief', 'perDevice'].includes(raw.inject?.template) ? raw.inject.template : 'default',
      allowSteer: raw.inject?.allowSteer !== false,
    },
    hostName: raw.hostName ?? null,
  };
}

/** adb 可执行文件自动发现（DSH 侧优先用 ctx.subprocess.resolveExecutable）。 */
export function discoverAdbPath({ fs, env, platform = process.platform }) {
  const candidates = [];
  if (env?.ANDROID_HOME) candidates.push(join(platform, env.ANDROID_HOME, 'platform-tools', exe(platform)));
  if (env?.ANDROID_SDK_ROOT) candidates.push(join(platform, env.ANDROID_SDK_ROOT, 'platform-tools', exe(platform)));
  if (env?.LOCALAPPDATA) candidates.push(join(platform, env.LOCALAPPDATA, 'Android', 'Sdk', 'platform-tools', exe(platform)));
  if (env?.HOME) candidates.push(join(platform, env.HOME, 'Library', 'Android', 'sdk', 'platform-tools', exe(platform)));
  candidates.push(join(platform, '/opt/android-sdk/platform-tools', exe(platform)));
  candidates.push('adb'); // PATH 兜底
  for (const candidate of candidates) {
    if (candidate === 'adb') continue;
    try { if (fs?.existsSync?.(candidate)) return { path: candidate, source: 'candidate' }; } catch { /* 忽略 */ }
  }
  return { path: 'adb', source: 'path' };
}

function exe(platform) { return platform === 'win32' ? 'adb.exe' : 'adb'; }
function join(platform, ...parts) { return platform === 'win32' ? parts.join('\\') : parts.join('/'); }

/**
 * @param {{run: import('./adb.js').Runner, net?: typeof import('node:net'), config?: object, log?: (msg: string, data?: unknown) => void, now?: () => number, hostname?: string, adbVersion?: string}} deps
 */
export function createScanner(deps) {
  const { run, net, log = () => {} } = deps;
  const config = normalizeConfig(deps.config ?? {});
  const now = deps.now ?? (() => Date.now());
  const base = config.adbPath ? [config.adbPath] : [deps.adbPath ?? 'adb'];

  const call = async (argv, { timeoutMs = 4000, env } = {}) => {
    const started = now();
    const result = await run([...base, ...argv], { timeoutMs, env });
    return { ...result, ms: now() - started };
  };

  async function adbVersion() {
    const result = await call(['version'], { timeoutMs: 4000 });
    const text = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
    const version = /Version\s+(\S+)/.exec(text)?.[1] ?? null;
    return { ok: result.code === 0, version, raw: text.trim().split(/\r?\n/)[0] ?? '', error: result.code === 0 ? null : 'adb 不可用' };
  }

  /** 一次 `adb devices -l`（可指向远程 adb server）。 */
  async function listTransports({ server = null } = {}) {
    const env = server ? { ADB_SERVER_SOCKET: `tcp:${server}` } : undefined;
    const result = await call(['devices', '-l'], { timeoutMs: 6000, env });
    const { devices, notes } = parseDevicesList(result.stdout ?? '');
    return { ok: result.code === 0, devices, notes, error: result.code === 0 ? null : (result.stderr || '').trim().split('\n')[0] };
  }

  async function mdnsServices() {
    if (!config.sources.lan.useMdnsFirst) return { available: false, services: [], note: '已关闭 mDNS' };
    const result = await call(['mdns', 'services'], { timeoutMs: 3500 });
    const services = parseMdnsServices(result.stdout ?? '');
    const failed = result.code !== 0 || /error:/i.test(result.stderr ?? '');
    return { available: !failed, services, note: failed ? (result.stderr || 'mdns 不可用').trim().split('\n')[0] : null };
  }

  async function tailscaleStatus() {
    if (!config.sources.tailscale.enabled) return { ok: false, skipped: true, peers: [], selfIps: [], error: '已关闭' };
    const result = await run([config.tailscalePath, 'status', '--json'], { timeoutMs: 4000 });
    if (result.code !== 0) {
      return { ok: false, peers: [], selfIps: [], error: (result.stderr || result.stdout || 'tailscale 不可用').trim().split('\n')[0] };
    }
    return parseTailscaleStatus(result.stdout);
  }

  async function connectTarget(host, port, { server = null } = {}) {
    const env = server ? { ADB_SERVER_SOCKET: `tcp:${server}` } : undefined;
    const result = await call(['connect', `${host}:${port}`], { timeoutMs: 3500, env });
    const text = `${result.stdout ?? ''} ${result.stderr ?? ''}`.trim();
    const ok = /connected to|already connected/i.test(text) && !/failed|unable|cannot/i.test(text);
    return { ok, text };
  }

  async function collectAll(targets) {
    return mapLimit(targets, config.collect.concurrency, async (target) => {
      const collected = await collectFactsFrom(run, base, target.adbTarget ?? target.serial, {
        timeoutMs: config.collect.factTimeoutMs,
      });
      return { ...target, ...collected };
    });
  }

  /**
   * 全量扫描：重扫三类来源。返回 ScanRun 记录 + 观测列表。
   * @param {{registry: object, signal?: AbortSignal}} state
   */
  async function scanFull(state) {
    const startedAt = now();
    const run_ = {
      id: `scan-${startedAt}`,
      at: startedAt,
      trigger: 'manual',
      sources: {},
      found: 0,
      merged: 0,
      created: [],
      dropped: [],
      errors: [],
      notes: [],
      durationMs: 0,
    };
    const observed = [];

    const version = await adbVersion();
    if (!version.ok) {
      run_.errors.push({ source: 'adb', message: version.error });
      run_.durationMs = now() - startedAt;
      return { ok: false, registry: state.registry, run: run_, observed, version };
    }

    // 1) USB + 已连接的 TCP transport
    const local = await listTransports();
    run_.sources.usb = { ok: local.ok, count: local.devices.length, notes: local.notes };
    if (!local.ok) run_.errors.push({ source: 'usb', message: local.error ?? 'adb devices 失败' });
    for (const device of local.devices) observed.push(toObserved(device, { server: null }));

    // 2) 远程 adb server（其它机器挂的设备）
    for (const server of config.sources.remoteAdbServers) {
      const remote = await listTransports({ server });
      run_.sources[`remote:${server}`] = { ok: remote.ok, count: remote.devices.length };
      for (const device of remote.devices) observed.push(toObserved(device, { server }));
    }

    // 3) mDNS（优先，无副作用）+ 局域网 CIDR + Tailscale 探活
    const mdns = await mdnsServices();
    run_.sources.mdns = { ok: mdns.available, count: mdns.services.length, note: mdns.note };
    const tailnet = await tailscaleStatus();
    run_.sources.tailscale = { ok: tailnet.ok, peers: tailnet.peers?.length ?? 0, error: tailnet.error ?? null, skipped: Boolean(tailnet.skipped) };
    run_.sources.lan = { enabled: config.sources.lan.enabled, cidrs: config.sources.lan.cidrs };

    const targets = buildProbeTargets({
      lan: config.sources.lan,
      tailscaleStatus: tailnet,
      tailnetPorts: config.sources.tailscale.ports,
      lanPorts: config.sources.lan.ports,
      mdns: mdns.services,
    });
    const probeTargets = targets.filter((target) => !observed.some((d) => d.endpoint === `${target.host}:${target.port}`));
    run_.sources.probe = { candidates: probeTargets.length };

    if (probeTargets.length > 0 && net) {
      const targetIndex = new Map(probeTargets.map((t) => [`${t.host}:${t.port}`, t]));
      const probed = await tcpProbe(probeTargets.map((t) => ({ host: t.host, port: t.port })), {
        net,
        timeoutMs: config.sources.lan.connectTimeoutMs,
        concurrency: config.sources.lan.maxConcurrency,
        ratePerSec: config.sources.lan.ratePerSec,
        signal: state.signal,
      });
      const open = probed.filter((p) => p.open).map((p) => ({ ...p, ...(targetIndex.get(`${p.host}:${p.port}`) ?? {}) }));
      run_.sources.probe.open = open.length;
      for (const hit of open) {
        const connected = await connectTarget(hit.host, hit.port);
        if (!connected.ok) {
          run_.errors.push({ source: hit.source ?? 'lan', endpoint: `${hit.host}:${hit.port}`, message: connected.text });
          continue;
        }
        observed.push({
          serial: `${hit.host}:${hit.port}`,
          endpoint: `${hit.host}:${hit.port}`,
          kind: (hit.source === 'tailscale' || isTailnetAddress(hit.host)) ? 'tailscale' : 'lan',
          state: 'device',
          connected: true,
          source: hit.source,
        });
      }
      // 新连接的设备需要再读一次 adb 列表补 product/model。
      const after = await listTransports();
      const known = new Set(observed.map((o) => o.serial));
      for (const device of after.devices) {
        if (known.has(device.serial)) continue;
        observed.push(toObserved(device, { server: null }));
      }
    } else if (probeTargets.length > 0 && !net) {
      run_.notes.push('未注入 net 模块，跳过 TCP 探活');
    }

    // 4) 来源开关过滤 + 采集事实（一次 shell 往返/台）
    const enabledKinds = new Set(['lan', 'tailscale', 'remote-server']);
    if (config.sources.usb.enabled) enabledKinds.add('usb');
    if (config.sources.emulator.enabled) enabledKinds.add('emulator');
    const candidates = observed.filter((item) => enabledKinds.has(item.kind ?? 'usb'));
    if (candidates.length !== observed.length) {
      run_.notes.push(`来源开关剔除了 ${observed.length - candidates.length} 条关闭通道`);
    }
    const withFacts = await collectAll(candidates);
    for (const item of withFacts) {
      if (!item.ok) {
        run_.errors.push({ source: item.kind ?? 'unknown', endpoint: item.endpoint, message: item.error });
      }
    }

    const merged = observe(state.registry, withFacts, {
      now: now(),
      fullScan: true,
      pruneAfter: config.poll.pruneAfter,
    });
    run_.found = withFacts.length;
    run_.merged = merged.merged.length;
    run_.created = merged.created;
    run_.dropped = merged.dropped;
    run_.durationMs = now() - startedAt;
    log('scanFull 完成', { found: run_.found, merged: run_.merged, durationMs: run_.durationMs });
    return { ok: true, registry: state.registry, run: run_, observed: withFacts, version };
  }

  /** 只刷新状态（不重扫网段、不 adb connect）：满足"缓存后只更新状态"。 */
  async function refreshStatus(state, { serials = null } = {}) {
    const startedAt = now();
    const registry = state.registry;
    const targets = [];
    for (const device of Object.values(registry.devices ?? {})) {
      if (serials && !serials.includes(device.serial)) continue;
      for (const transport of Object.values(device.transports ?? {})) {
        if (transport.state === 'absent' || transport.connected === false) continue;
        targets.push({ ...transport, adbTarget: transport.adbTarget ?? transport.endpoint, device });
      }
    }
    const version = await adbVersion();
    const local = version.ok ? await listTransports() : { ok: false, devices: [], notes: [], error: version.error };
    const liveBySerial = new Map(local.devices.map((d) => [d.serial, d]));

    const updated = [];
    for (const target of targets) {
      const live = liveBySerial.get(target.adbTarget);
      updated.push({
        serial: target.adbTarget,
        endpoint: target.endpoint,
        kind: target.kind,
        server: target.server,
        state: live?.state ?? (live ? live.state : 'offline'),
        attrs: live?.attrs,
        connected: Boolean(live),
      });
    }
    const withFacts = await collectAll(updated);
    const merged = observe(registry, withFacts, { now: now(), fullScan: false });
    return {
      ok: true,
      registry,
      durationMs: now() - startedAt,
      probed: withFacts.length,
      merged: merged.merged.length,
      adbVersion: version.version,
      error: local.error ?? null,
    };
  }

  /** 单台设备的即时详情（供工具与面板展开使用）。 */
  async function inspect(registry, serial) {
    const device = registry.devices?.[serial];
    if (!device) return { ok: false, error: `未知设备 ${serial}` };
    const transport = bestTransportLocal(device);
    if (!transport) return { ok: false, error: '该设备没有可用通道' };
    const collected = await collectFactsFrom(run, base, transport.adbTarget ?? transport.endpoint, {
      timeoutMs: config.collect.factTimeoutMs,
    });
    if (!collected.ok) return { ok: false, error: collected.error };
    observe(registry, [{ serial: transport.adbTarget ?? transport.endpoint, endpoint: transport.endpoint, kind: transport.kind, state: 'device', facts: collected.facts }], { now: now(), fullScan: false });
    return { ok: true, facts: collected.facts };
  }

  function bestTransportLocal(device) {
    return Object.values(device.transports ?? {})
      .filter((t) => t.state !== 'absent')
      .sort((a, b) => (a.state === 'device' ? 0 : 1) - (b.state === 'device' ? 0 : 1) || transportPriority(a.kind) - transportPriority(b.kind))[0] ?? null;
  }

  return {
    config,
    adbVersion,
    listTransports,
    mdnsServices,
    tailscaleStatus,
    scanFull,
    refreshStatus,
    inspect,
    snapshot: (registry, options) => snapshot(registry, { ...options, now: now(), staleAfterMs: config.poll.staleAfterMs }),
    classify: classifyEndpoint,
  };
}

/** 把 `adb devices -l` 的一行转成注册表观测项。 */
function toObserved(device, { server }) {
  const { kind: tcpKind, host } = classifyEndpoint(device.serial);
  const kind = tcpKind === 'tcp'
    ? (isTailnetAddress(host) ? 'tailscale' : 'lan')
    : /^emulator-\d+$/.test(device.serial) ? 'emulator' : 'usb';
  return {
    serial: device.serial,
    endpoint: device.serial,
    kind,
    server,
    state: device.state,
    detail: device.detail,
    attrs: { model: device.model, product: device.product, device: device.deviceName },
    connected: device.state === 'device',
  };
}
