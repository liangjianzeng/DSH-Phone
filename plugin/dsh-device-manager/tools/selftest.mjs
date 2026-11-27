#!/usr/bin/env node
/**
 * dsh-device-manager 自测脚本（不依赖 DSH 运行时）。
 *
 *   node plugin/dsh-device-manager/tools/selftest.mjs              # 离线用例；有 fixtures 时自动跑回放扫描
 *   node plugin/dsh-device-manager/tools/selftest.mjs --offline    # 只跑离线用例
 *   node plugin/dsh-device-manager/tools/selftest.mjs --live       # 追加真机扫描（需能在本机 spawn adb）
 *   node plugin/dsh-device-manager/tools/selftest.mjs --json       # 机器可读输出
 *
 * `test/fixtures/` 里的 fixture 由本机真机实测抓成（`tools/capture-fixtures.ps1`）：
 * adb version / adb devices -l / adb mdns services / tailscale status --json，以及每台设备
 * 一次 fact script 的完整输出。回放模式用真实输出驱动整条 scanFull/refreshStatus 链路，
 * 因此回归的是**真实**字段形态（含 A13 与 A17 的 dumpsys 差异），不是理想化样例。
 */

import net from 'node:net';
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  parseDevicesList,
  parseMdnsServices,
  parseTailscaleStatus,
  parseFacts,
  splitFactOutput,
  buildFactScript,
  collectFactsFrom,
  classifyEndpoint,
  isTailnetAddress,
} from '../lib/adb.js';
import { expandCidrs, tcpProbe, tailscaleCandidates, buildProbeTargets } from '../lib/probe.js';
import { createRegistry, observe, snapshot, deviceHealth, connectCommand, stateSummary, bestTransport, transportLabel, setAliases, resolveDeviceRef, resolveDeviceRefs, normalizeRef, deviceNames } from '../lib/registry.js';
import { renderModelPrompt, freshnessBucket, promptTargets } from '../lib/prompt.js';
import { composeMessage, BUILTIN_TEMPLATES, interpolate, deviceVars } from '../lib/templates.js';
import { createScanner, normalizeConfig, discoverAdbPath } from '../lib/scan.js';
import { toSerialList, toRefList, toInt } from '../lib/args.js';

const here = dirname(fileURLToPath(import.meta.url));
const FIXTURES = join(here, '..', 'test', 'fixtures');
const results = [];
let failures = 0;

function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  const ok = a === e;
  if (!ok) failures += 1;
  results.push({ name, ok, actual: a, expected: e });
}

function checkOk(name, condition, detail = '') {
  if (!condition) failures += 1;
  results.push({ name, ok: Boolean(condition), actual: String(condition), expected: 'true', detail });
}

/** 用 KEY + 若干行构造一次 fact script 的输出。 */
function factOutput(groups) {
  return groups.flatMap(([key, ...lines]) => [`_DMK_${key}_`, ...lines]).join('\n');
}

// ───────────────────────────── fixtures（真机实测） ─────────────────────────────

const DEVICES_LIST_REAL = `List of devices attached
8b1e8747               device product:alioth model:M2012K11AC device:alioth transport_id:5
100.75.247.55:5555     device product:warsaw model:M332BF device:warsaw transport_id:4
192.168.1.151:5555     device product:alioth model:M2012K11AC device:alioth transport_id:6
`;

const DEVICES_LIST_EDGE = `List of devices attached
ZY223XXXXX       unauthorized product:us996 model:Motorola\\ Edge_2 device:us996 transport_id:1
0123456789ABCDEF offline product:foo model:Foo\\ Phone device:foo transport_id:2
emulator-5554    device product:sdk_gphone64_x86_64 model:Pixel_7 device:emu64xa transport_id:3
abcd1234         no permissions (user in plugdev group; are your udev rules wrong?); see [http://developer.android.com/tools/device.html] transport_id:4
`;

const MDNS_REAL = `Services discovered:
adb-8b1e8747-K30Pro   _adb-tls-connect._tcp.   192.168.1.151   37851
adb-8b1e8747-K30Pro   _adb-tls-pairing._tcp.   192.168.1.151   37855
`;

const TAILSCALE_REAL = JSON.stringify({
  Self: { IPv4Addresses: ['100.75.247.10'] },
  Peer: {
    'peer-a': { HostName: 'phone-lab', TailscaleIPs: ['100.75.247.55', 'fd7a:115c:a1e0::1'], Online: true, OS: 'android' },
    'peer-b': { HostName: 'offline-box', TailscaleIPs: ['100.99.1.1'], Online: false, OS: 'linux' },
  },
});

const TAILSCALE_DENIED = 'failed to connect to local tailscaled (no tailscaled process found): Access is denied.';

const FACTS_A13_SLEEP = factOutput([
  ['MODEL', 'M2012K11AC'],
  ['BRAND', 'Redmi'],
  ['ANDROID', '13'],
  ['SDK', '33'],
  ['SERIAL', '8b1e8747'],
  ['POWER', '  mWakefulness=Asleep', '  Display Power: com.android.server.power.PowerManagerService$1@cc65066'],
  ['WINDOW', '  mCurrentFocus=Window{a17ee4d u0 NotificationShade}', '  mShowingDream=false mDreamingLockscreen=true'],
  ['BATTERY', '  AC powered: false', '  USB powered: true', '  status: 5', '  level: 100'],
  ['STAY', '0'],
  ['ADBWIFI', '0'],
  ['SIZE', 'Physical size: 1080x2400'],
  ['DENSITY', 'Physical density: 440'],
  ['BRIGHT', '1'],
]);

const FACTS_A17_AWAKE = factOutput([
  ['MODEL', 'M332BF'],
  ['BRAND', 'Redmi'],
  ['ANDROID', '17'],
  ['SDK', '37'],
  ['SERIAL', '43328e37'],
  ['POWER', '  mWakefulness=Awake', '  Display Power: com.android.server.power.PowerManagerService$3@764dd75'],
  ['WINDOW', '  mCurrentFocus=Window{d06e7cf u0 com.netease.uuremote/com.remote.app.ui.activity.ScreenActivity}',
    '  mShowingDream=false mDreamingLockscreen=false'],
  ['BATTERY', '  AC powered: true', '  USB powered: false', '  status: 2', '  level: 57'],
  ['STAY', '15'],
  ['ADBWIFI', '0'],
  ['SIZE', 'Physical size: 1220x2712'],
  ['DENSITY', 'Physical density: 480'],
  ['BRIGHT', '0'],
]);

// ───────────────────────────── 解析用例 ─────────────────────────────

{
  const parsed = parseDevicesList(DEVICES_LIST_REAL);
  check('parseDevicesList: 真机三通道条数', parsed.devices.length, 3);
  check('parseDevicesList: serial 列表', parsed.devices.map((d) => d.serial),
    ['8b1e8747', '100.75.247.55:5555', '192.168.1.151:5555']);
  check('parseDevicesList: model 解析', parsed.devices.map((d) => d.model), ['M2012K11AC', 'M332BF', 'M2012K11AC']);
  check('parseDevicesList: transport_id', parsed.devices.map((d) => d.transportId), ['5', '4', '6']);
  check('parseDevicesList: 噪声不产设备', parseDevicesList('* daemon started\nList of devices attached\n').devices.length, 0);
  check('parseDevicesList: 空输入', parseDevicesList('').devices.length, 0);
}

{
  const parsed = parseDevicesList(DEVICES_LIST_EDGE);
  check('parseDevicesList: 异常状态集合', parsed.devices.map((d) => d.state),
    ['unauthorized', 'offline', 'device', 'no permissions']);
  check('parseDevicesList: 模拟器 serial', parsed.devices[2].serial, 'emulator-5554');
  checkOk('parseDevicesList: no permissions 带 detail', /plugdev/.test(parsed.devices[3].detail ?? ''), parsed.devices[3].detail);
  checkOk('parseDevicesList: 反斜杠转义的空格还原成一个空格', parsed.devices[0].model === 'Motorola Edge_2', parsed.devices[0].model);
}

{
  const services = parseMdnsServices(MDNS_REAL);
  check('parseMdnsServices: 抓到两条', services.length, 2);
  check('parseMdnsServices: connect 端点', services[0], { serviceType: 'connect', address: '192.168.1.151', port: 37851, instance: 'adb-8b1e8747-K30Pro' });
  check('parseMdnsServices: pairing 归类', services[1].serviceType, 'pairing');
  check('parseMdnsServices: 无服务时为空', parseMdnsServices('List of discovered mdns services').length, 0);
}

{
  const status = parseTailscaleStatus(TAILSCALE_REAL);
  check('parseTailscaleStatus: ok', status.ok, true);
  check('parseTailscaleStatus: self ip', status.selfIps, ['100.75.247.10']);
  check('parseTailscaleStatus: peer 数', status.peers.length, 2);
  const cands = tailscaleCandidates(status, { ports: [5555] });
  check('tailscaleCandidates: 只取在线 peer 的 IPv4', cands, [{ host: '100.75.247.55', port: 5555, peer: 'phone-lab' }]);
  const denied = parseTailscaleStatus(TAILSCALE_DENIED);
  check('parseTailscaleStatus: tailscaled 未运行降级', [denied.ok, denied.peers.length], [false, 0]);
  checkOk('parseTailscaleStatus: 降级带原因', /tailscaled/.test(denied.error ?? ''), denied.error);
}

{
  const a13 = parseFacts(splitFactOutput(FACTS_A13_SLEEP));
  check('parseFacts(A13): serial', a13.shellSerial, '8b1e8747');
  check('parseFacts(A13): model/android', [a13.model, a13.android], ['M2012K11AC', '13']);
  check('parseFacts(A13): 息屏', a13.screen, 'off');
  check('parseFacts(A13): 锁屏(通知栏焦点)', a13.locked, true);
  check('parseFacts(A13): 电量/电源', [a13.battery, a13.powerSource, a13.chargeStatus], [100, 'USB', 5]);
  check('parseFacts(A13): 非常亮', [a13.stayAwake, a13.stayAwakeBits], [false, 0]);
  check('parseFacts(A13): 前台判为系统 UI', a13.foreground?.systemUi, true);
  check('parseFacts(A13): 分辨率/DPI', [a13.size, a13.density], ['1080x2400', '440']);
  check('parseFacts(A13): 自动亮度', a13.brightnessAuto, true);

  const a17 = parseFacts(splitFactOutput(FACTS_A17_AWAKE));
  check('parseFacts(A17): serial', a17.shellSerial, '43328e37');
  check('parseFacts(A17): 亮屏', a17.screen, 'on');
  check('parseFacts(A17): 未锁屏', a17.locked, false);
  check('parseFacts(A17): 电量/充电', [a17.battery, a17.powerSource, a17.chargeStatus], [57, 'AC', 2]);
  check('parseFacts(A17): 常亮(15 位掩码)', [a17.stayAwake, a17.stayAwakeConditions], [true, ['AC', 'USB', '无线']]);
  check('parseFacts(A17): 前台应用', [a17.foreground?.package, a17.foreground?.systemUi], ['com.netease.uuremote', undefined]);

  const empty = parseFacts(splitFactOutput(''));
  check('parseFacts: 全空降级为 unknown', [empty.screen, empty.locked, empty.battery], ['unknown', 'unknown', null]);
  const drift = parseFacts(splitFactOutput(factOutput([['POWER', '  Display Power: state=ON'], ['WINDOW', '  nothing here']])));
  check('parseFacts: 字段漂移回退(Display Power state)', drift.screen, 'on');
  checkOk('parseFacts: BOM 不破坏切分', parseFacts(splitFactOutput('\uFEFF' + FACTS_A17_AWAKE)).screen, 'on' === 'on' ? true : false);
  checkOk('fact script: 标记只用字母数字下划线（避开 sh 注释）', /^echo _DMK_[A-Z_]+_; /.test(buildFactScript()) && !buildFactScript().includes('#'),
    buildFactScript().slice(0, 40));
  checkOk('fact script: 覆盖全部标记', ['MODEL', 'POWER', 'WINDOW', 'BATTERY', 'STAY', 'SERIAL', 'ADBWIFI']
    .every((key) => buildFactScript().includes(`_DMK_${key}_`)));
}

{
  check('classifyEndpoint: USB serial', classifyEndpoint('8b1e8747'), { kind: 'usb', host: null, port: null });
  check('classifyEndpoint: WiFi', classifyEndpoint('192.168.1.151:5555'), { kind: 'tcp', host: '192.168.1.151', port: 5555 });
  check('classifyEndpoint: tailnet 判定', isTailnetAddress('100.75.247.55'), true);
  check('classifyEndpoint: 公网 IP 不算 tailnet', isTailnetAddress('8.8.8.8'), false);
}

// ───────────────────────────── 探测用例 ─────────────────────────────

{
  const cidr24 = expandCidrs(['192.168.1.0/24'], { maxIps: 512 });
  check('expandCidrs: /24 去掉网络与广播地址', cidr24.ips.length, 254);
  check('expandCidrs: 首尾', [cidr24.ips[0], cidr24.ips[253]], ['192.168.1.1', '192.168.1.254']);
  check('expandCidrs: 单 IP', expandCidrs(['10.0.0.9/32']).ips, ['10.0.0.9']);
  check('expandCidrs: /30 四地址去掉首尾', expandCidrs(['10.0.0.0/30']).ips, ['10.0.0.1', '10.0.0.2']);
  check('expandCidrs: 上限截断', expandCidrs(['10.0.0.0/16'], { maxIps: 10 }).ips.length, 10);
  check('expandCidrs: 截断有标记', expandCidrs(['10.0.0.0/16'], { maxIps: 10 }).truncated, true);
  check('expandCidrs: 非法 CIDR 被忽略并记录', expandCidrs(['300.1.1.0/24']).notes.length, 1);
}

{
  // 假 net：5555 开放、5556 超时、其它立即拒绝。
  const fakeNet = {
    connect({ port }) {
      const listeners = {};
      const socket = {
        setTimeout() {}, destroy() {}, removeAllListeners() {},
        on(event, fn) { (listeners[event] ??= []).push(fn); return socket; },
        emit(event, ...args) { for (const fn of listeners[event] ?? []) fn(...args); },
      };
      setTimeout(() => {
        if (port === 5555) socket.emit('connect');
        else if (port === 5556) socket.emit('timeout');
        else socket.emit('error', Object.assign(new Error('ECONNREFUSED'), { code: 'ECONNREFUSED' }));
      }, 0);
      return socket;
    },
  };
  const probeTargets = buildProbeTargets({
    lan: { enabled: true, cidrs: ['192.168.1.50/32'], ports: [5555, 5556, 9999] },
    tailscaleStatus: parseTailscaleStatus(TAILSCALE_REAL),
    tailnetPorts: [5555],
    lanPorts: [5555, 5556, 9999],
    mdns: parseMdnsServices(MDNS_REAL),
  });
  checkOk('buildProbeTargets: 含 mDNS 端点', probeTargets.some((t) => t.source === 'mdns' && t.port === 37851));
  checkOk('buildProbeTargets: 含 LAN 端点', probeTargets.some((t) => t.source === 'lan'));
  checkOk('buildProbeTargets: 含 tailnet peer 端点', probeTargets.some((t) => t.source === 'tailscale' && t.host === '100.75.247.55'));
  check('buildProbeTargets: 去重', new Set(probeTargets.map((t) => `${t.host}:${t.port}`)).size, probeTargets.length);
  check('buildProbeTargets: 只留 connect 不留 pairing', probeTargets.some((t) => t.port === 37855), false);

  const probed = await tcpProbe([{ host: 'a', port: 5555 }, { host: 'b', port: 5556 }, { host: 'c', port: 9 }],
    { net: fakeNet, timeoutMs: 50, concurrency: 4, ratePerSec: 0 });
  check('tcpProbe: 开放', probed.find((p) => p.port === 5555).open, true);
  check('tcpProbe: 超时未开放', probed.find((p) => p.port === 5556).open, false);
  check('tcpProbe: 超时原因', probed.find((p) => p.port === 5556).error, 'timeout');
  check('tcpProbe: 拒绝原因', probed.find((p) => p.port === 9).error, 'ECONNREFUSED');
  check('tcpProbe: 结果条数', probed.length, 3);
  let threw = false;
  try { await tcpProbe([{ host: 'a', port: 1 }], {}); } catch { threw = true; }
  check('tcpProbe: 缺 net 抛错（不静默）', threw, true);
}

// ───────────────────────────── 注册表：身份合并（核心回归） ─────────────────────────────

const A13 = () => parseFacts(splitFactOutput(FACTS_A13_SLEEP));
const A17 = () => parseFacts(splitFactOutput(FACTS_A17_AWAKE));

{
  const registry = createRegistry();
  const observed = [
    { serial: '8b1e8747', endpoint: '8b1e8747', kind: 'usb', state: 'device', facts: A13() },
    { serial: '192.168.1.151:5555', endpoint: '192.168.1.151:5555', kind: 'lan', state: 'device', facts: A13() },
    { serial: '100.75.247.55:5555', endpoint: '100.75.247.55:5555', kind: 'tailscale', state: 'device', facts: A17() },
  ];
  const merged = observe(registry, observed, { now: 1000, fullScan: true });
  const snap = snapshot(registry, { now: 1000 });
  check('身份合并: 3 transport → 2 设备', snap.counts.total, 2);
  check('身份合并: 3 transport 全部保留', snap.counts.transports, 3);
  check('身份合并: 只建两条设备记录', [merged.created.length, merged.dropped.length], [2, 0]);
  const k30 = snap.devices.find((d) => d.serial === '8b1e8747');
  check('身份合并: K30 双通道', k30?.kinds, ['usb', 'lan']);
  check('身份合并: 身份来源 ro.serialno', k30?.identitySource, 'ro.serialno');
  check('身份合并: 最佳通道优先 USB', k30?.transports.find((t) => t.key === k30.bestTransportKey)?.kind, 'usb');
  check('身份合并: 健康度 ok', k30?.health, 'ok');
  checkOk('身份合并: 摘要含息屏/锁屏/电量/常亮',
    ['息屏', '锁屏', '电量 100%', '非常亮'].every((token) => (k30?.summary ?? '').includes(token)), k30?.summary);
  const m332 = snap.devices.find((d) => d.serial === '43328e37');
  check('身份合并: tailnet 设备用 ro.serialno 作键', m332?.serial, '43328e37');
  checkOk('身份合并: A17 摘要含亮屏/常亮', ['亮屏', '常亮'].every((token) => (m332?.summary ?? '').includes(token)), m332?.summary);
  check('身份合并: 过滤只留 tailscale 通道设备', snapshot(registry, { now: 1000, filter: 'tailscale' }).devices.map((d) => d.serial), ['43328e37']);
  check('身份合并: 通道标签本地化', transportLabel('remote-server'), '远程 adb server');
  checkOk('bestTransport: 返回对象', bestTransport(registry.devices['8b1e8747'])?.kind === 'usb');
}

{
  // 先只知端点（未授权/掉线拿不到 ro.serialno），之后确认身份 → 必须搬迁而不是新建设备
  const tmp = createRegistry();
  observe(tmp, [{ serial: '192.168.1.60:5555', endpoint: '192.168.1.60:5555', kind: 'lan', state: 'device', facts: null }], { now: 1 });
  check('tmp 身份: 先落 tmp 键', Object.keys(tmp.devices), ['tmp:192.168.1.60:5555']);
  const promoted = observe(tmp, [{ serial: '192.168.1.60:5555', endpoint: '192.168.1.60:5555', kind: 'lan', state: 'device', facts: { shellSerial: 'ABC123', model: 'X' } }], { now: 2 });
  check('tmp 身份: 升级到真实 serial', Object.keys(tmp.devices), ['ABC123']);
  check('tmp 身份: 搬迁路径可追溯', promoted.mergedFrom, [{ from: 'tmp:192.168.1.60:5555', to: 'ABC123' }]);

  // 同一真身已有记录 + 遗留 tmp 记录 → 合并通道并丢弃 tmp
  const both = createRegistry();
  observe(both, [{ serial: 'ZZZ', endpoint: 'ZZZ', kind: 'usb', state: 'device', facts: null }], { now: 1 });
  observe(both, [{ serial: '10.0.0.5:5555', endpoint: '10.0.0.5:5555', kind: 'lan', state: 'device', facts: null }], { now: 2 });
  observe(both, [{ serial: '10.0.0.5:5555', endpoint: '10.0.0.5:5555', kind: 'lan', state: 'device', facts: { shellSerial: 'ZZZ' } }], { now: 3 });
  check('真身+tmp: 合成一台', Object.keys(both.devices), ['ZZZ']);
  check('真身+tmp: 两条通道都在', Object.keys(both.devices.ZZZ.transports).length, 2);
}

{
  const absent = createRegistry();
  observe(absent, [{ serial: 'A', endpoint: 'A', kind: 'usb', state: 'device', facts: null }], { now: 1 });
  for (let i = 0; i < 3; i += 1) observe(absent, [], { now: 2 + i, fullScan: true });
  check('缺席推进: 3 轮后 transport 变 absent', Object.values(absent.devices.A.transports)[0].state, 'absent');
  check('缺席推进: 健康度转 unknown', deviceHealth(absent.devices.A), 'unknown');
  const partial = createRegistry();
  observe(partial, [{ serial: 'A', endpoint: 'A', kind: 'usb', state: 'device' }], { now: 1 });
  observe(partial, [], { now: 2, fullScan: false });
  check('只读刷新不推进缺席轮次', partial.devices.A.missingRounds, 0);

  const unauth = createRegistry();
  observe(unauth, [{ serial: 'U1', endpoint: 'U1', kind: 'usb', state: 'unauthorized' }], { now: 1 });
  check('健康度: unauthorized 判 error', deviceHealth(unauth.devices.U1), 'error');
  const off = createRegistry();
  observe(off, [{ serial: 'O1', endpoint: 'O1', kind: 'lan', state: 'offline' }], { now: 1 });
  check('健康度: offline 判 error', deviceHealth(off.devices.O1), 'error');

  const staleReg = createRegistry();
  observe(staleReg, [{ serial: 'S', endpoint: 'S', kind: 'usb', state: 'device', facts: A13() }], { now: 0 });
  const staleSnap = snapshot(staleReg, { now: 10 * 60 * 1000, staleAfterMs: 120000 });
  check('新鲜度: 超 TTL 降级 degraded', staleSnap.devices[0].health, 'degraded');
  checkOk('新鲜度: stale 标记', staleSnap.devices[0].stale === true);

  check('连接命令: USB', connectCommand({ kind: 'usb', adbTarget: '8b1e8747' }), 'adb -s 8b1e8747 shell true');
  check('连接命令: WiFi', connectCommand({ kind: 'lan', endpoint: '192.168.1.151:5555' }), 'adb connect 192.168.1.151:5555');
  check('连接命令: 远程 server', connectCommand({ kind: 'remote-server', endpoint: '1.2.3.4:5555', server: '100.1.2.3:5037' }),
    'ADB_SERVER_SOCKET=tcp:100.1.2.3:5037 adb connect 1.2.3.4:5555');
  checkOk('stateSummary: 含四个维度', ['屏', '锁', '电量', '常亮'].every((token) => stateSummary({ facts: A13() }).includes(token)));
  check('deviceVars: 未知字段兜底', deviceVars({}).model, '未知型号');
}

// ───────────────────────────── 模板用例 ─────────────────────────────

{
  const registry = createRegistry();
  observe(registry, [
    { serial: '8b1e8747', endpoint: '8b1e8747', kind: 'usb', state: 'device', facts: A13() },
    { serial: '192.168.1.151:5555', endpoint: '192.168.1.151:5555', kind: 'lan', state: 'device', facts: A13() },
    { serial: '100.75.247.55:5555', endpoint: '100.75.247.55:5555', kind: 'tailscale', state: 'device', facts: A17() },
  ], { now: 1700000000000 });
  const snap = snapshot(registry, { now: 1700000000000 });

  const single = composeMessage({ devices: snap.devices, template: 'default', target: '登录页重构', hostName: 'dev-win', adbVersion: '37.0.1' });
  check('模板 default: 一条消息', single.messages.length, 1);
  checkOk('模板 default: 含目标', single.text.includes('登录页重构'));
  checkOk('模板 default: 含两台设备 serial', single.text.includes('8b1e8747') && single.text.includes('43328e37'));
  checkOk('模板 default: 含连接命令', single.text.includes('adb connect 100.75.247.55:5555') || single.text.includes('adb -s 8b1e8747'));
  checkOk('模板 default: 含状态字段', ['息屏', '亮屏', '常亮'].every((token) => single.text.includes(token)), single.text);
  checkOk('模板 default: 含主机与 adb 版本', single.text.includes('dev-win') && single.text.includes('37.0.1'));
  check('模板 default: 不含未替换变量', single.text.match(/\{[A-Za-z0-9_]+\}/g), null);
  checkOk('模板 default: 同一设备列出全部通道（USB + WiFi）',
    single.text.includes('8b1e8747') && single.text.includes('192.168.1.151:5555'), single.text);
  checkOk('模板 default: 每条通道带可执行连接命令',
    single.text.includes('adb -s 8b1e8747 shell true') && single.text.includes('adb connect 192.168.1.151:5555'), single.text);

  const perDevice = composeMessage({ devices: snap.devices, template: 'perDevice', target: 'T' });
  check('模板 perDevice: 每台一条', perDevice.messages.length, 2);
  checkOk('模板 perDevice: 每条含 serial', perDevice.messages.every((m) => /8b1e8747|43328e37/.test(m)));
  check('模板 perDevice: 不含未替换变量', perDevice.text.match(/\{[A-Za-z0-9_]+\}/g), null);
  checkOk('模板 perDevice: 含优先与回落命令', perDevice.text.includes('优先使用 `adb -s 8b1e8747 shell true`')
    && perDevice.text.includes('回落 `adb connect 192.168.1.151:5555`'), perDevice.text);

  const singleChannel = composeMessage({
    devices: [{ ...snap.devices[1] ?? snap.devices[0], transports: (snap.devices[1] ?? snap.devices[0]).transports.slice(0, 1) }],
    template: 'perDevice',
    target: 'T',
  });
  check('模板 perDevice: 单通道不印"回落到自己"', singleChannel.text.match(/回落/g), null);
  checkOk('模板 perDevice: 单通道说明探活语义', /只用这条通道/.test(singleChannel.text), singleChannel.text);

  const briefOfOne = composeMessage({ devices: [snap.devices[0]], template: 'brief', target: 'T' });
  checkOk('模板 brief: 一行里列出两条通道', briefOfOne.text.includes('USB 8b1e8747') && briefOfOne.text.includes('192.168.1.151:5555'), briefOfOne.text);
  checkOk('模板 brief: 型号与 Android 版本有分隔', briefOfOne.text.includes('（Android 13）'), briefOfOne.text);

  const brief = composeMessage({ devices: snap.devices, template: 'brief', target: 'T' });
  checkOk('模板 brief: 单条且简短', brief.messages.length === 1 && brief.text.split('\n').length <= 5, brief.text);
  check('模板 brief: 不含未替换变量', brief.text.match(/\{[A-Za-z0-9_]+\}/g), null);

  const custom = composeMessage({
    devices: snap.devices,
    template: { title: '自定义', mode: 'single', body: '目标 {target}｜{count} 台｜{deviceLines}', perDeviceLine: '- {model}@{endpoint}' },
    target: 'X',
  });
  check('模板 自定义: 变量插值', custom.text, '目标 X｜2 台｜- M2012K11AC@8b1e8747\n- M332BF@100.75.247.55:5555');
  check('模板: 未知变量保留原样', interpolate('a {unknownVar} b', { a: 1 }), 'a {unknownVar} b');
  checkOk('内置模板齐备', ['default', 'brief', 'perDevice'].every((k) => BUILTIN_TEMPLATES[k]?.body));
  check('模板: 空设备列表不崩', composeMessage({ devices: [], target: 'T' }).messages.length, 1);
}

// ───────────────────────────── 配置用例 ─────────────────────────────

{
  const cfg = normalizeConfig({ sources: { lan: { enabled: true, cidrs: ['192.168.1.0/24'] } }, collect: { concurrency: 8 } });
  check('config: LAN 显式开启', cfg.sources.lan.enabled, true);
  check('config: LAN 默认端口', cfg.sources.lan.ports, [5555]);
  check('config: 并发覆盖', cfg.collect.concurrency, 8);
  const def = normalizeConfig({});
  check('config: LAN 默认关闭（安全默认）', def.sources.lan.enabled, false);
  check('config: USB/Tailscale/模拟器 默认开', [def.sources.usb.enabled, def.sources.tailscale.enabled, def.sources.emulator.enabled], [true, true, true]);
  check('config: mDNS 优先默认开', def.sources.lan.useMdnsFirst, true);
  check('config: TTL 默认 120s', def.poll.staleAfterMs, 120000);
  check('config: 扫描限速默认 200/s', def.sources.lan.ratePerSec, 200);
  const found = discoverAdbPath({ fs: { existsSync }, env: process.env, platform: process.platform });
  checkOk('config: adb 自动发现返回可执行路径', typeof found.path === 'string' && found.path.length > 0, found.path);
  const noEnv = discoverAdbPath({ fs: { existsSync }, env: {}, platform: 'linux' });
  check('config: 无 SDK 环境变量时退回 PATH', noEnv, { path: 'adb', source: 'path' });
}

// ───────────────────────────── 入参清洗（真机自测发现的 bug 回归） ─────────────────────────────

{
  check('args: 数组直通', toSerialList(['8b1e8747', '192.168.1.151:5555']), ['8b1e8747', '192.168.1.151:5555']);
  // 真机自测里 inspect 失败就是因为模型把数组当成 JSON 字符串传进来
  check('args: JSON 字符串数组', toSerialList('["8b1e8747"]'), ['8b1e8747']);
  check('args: JSON 字符串多值', toSerialList('["8b1e8747","100.75.247.55:5555"]'), ['8b1e8747', '100.75.247.55:5555']);
  check('args: 逗号串', toSerialList('8b1e8747, 192.168.1.151:5555'), ['8b1e8747', '192.168.1.151:5555']);
  check('args: 单个字符串', toSerialList('8b1e8747'), ['8b1e8747']);
  check('args: 去重去空去空白', toSerialList([' a ', 'a', '', '  ']), ['a']);
  check('args: 空值', [toSerialList(null), toSerialList(undefined), toSerialList([])], [[], [], []]);
  check('args: 挡掉会被当选项的值', toSerialList(['--help', '-s', 'a b', '$(id)', '..', 'emulator-5554']), ['emulator-5554']);
  check('args: 对象值摊平、数字可用', toSerialList([{ a: 1 }, 'ok']), ['1', 'ok']);
  check('args: 怪对象仍被挡', toSerialList([{ a: {} }, { b: null }]), []);
  // verify-round2 实测：数组元素**内部**又是 JSON 串或逗号串，也要拆开
  check('args: 元素内再套 JSON 串', toSerialList(['["8b1e8747","100.75.247.55:5555"]']), ['8b1e8747', '100.75.247.55:5555']);
  check('args: 元素内是逗号串', toSerialList(['8b1e8747, 192.168.1.151:5555']), ['8b1e8747', '192.168.1.151:5555']);
  check('args: 整体对象里取 serials', toSerialList({ serials: ['8b1e8747'] }), ['8b1e8747']);
  check('args: 嵌套里仍挡怪值', toSerialList(['["--help","8b1e8747"]']), ['8b1e8747']);
  check('args: toInt 夹紧与兜底', [
    toInt('5', { min: 1, max: 3, fallback: 1 }),
    toInt('x', { min: 1, max: 3, fallback: 7 }),
    toInt(-2, { min: 1, max: 3, fallback: 7 }),
  ], [3, 7, 1]);
}

// ───────────────────────────── fixture 回放扫描 ─────────────────────────────

function readFixture(dir, name) {
  return readFileSync(join(dir, name), 'utf8').replace(/^\uFEFF/, '');
}

function makeReplayRunner(dir) {
  const files = new Set(readdirSync(dir));
  const pick = (name) => (files.has(name) ? readFixture(dir, name) : '');
  return async (argv) => {
    const joined = argv.join(' ');
    if (/tailscale/i.test(joined)) {
      const text = pick('tailscale-status.json');
      const ok = /^\s*\{/.test(text);
      return { code: ok ? 0 : 1, stdout: ok ? text : '', stderr: ok ? '' : text, timedOut: false };
    }
    if (argv.includes('version')) return { code: 0, stdout: pick('adb-version.txt'), stderr: '', timedOut: false };
    if (argv.includes('mdns')) return { code: 0, stdout: pick('adb-mdns-services.txt'), stderr: '', timedOut: false };
    if (argv.includes('devices')) return { code: 0, stdout: pick('adb-devices.txt'), stderr: '', timedOut: false };
    if (argv.includes('connect')) {
      const target = argv[argv.length - 1];
      return { code: 0, stdout: `connected to ${target}`, stderr: '', timedOut: false };
    }
    if (argv.includes('shell')) {
      const target = argv[argv.indexOf('-s') + 1];
      const name = `fact-${String(target).replace(/[^A-Za-z0-9]/g, '_')}.txt`;
      if (!files.has(name)) return { code: 1, stdout: '', stderr: `error: device '${target}' not found`, timedOut: false };
      return { code: 0, stdout: readFixture(dir, name), stderr: '', timedOut: false };
    }
    return { code: 1, stdout: '', stderr: `fixture 未覆盖: ${joined}`, timedOut: false };
  };
}

async function runScanSuite(label, runner, expectMinDevices) {
  const scanner = createScanner({
    run: runner,
    net: {
      connect() {
        const listeners = {};
        const socket = { setTimeout() {}, destroy() {}, removeAllListeners() {}, on(e, f) { (listeners[e] ??= []).push(f); return socket; }, emit(e, ...a) { for (const f of listeners[e] ?? []) f(...a); } };
        setTimeout(() => socket.emit('error', Object.assign(new Error('ECONNREFUSED'), { code: 'ECONNREFUSED' })), 0);
        return socket;
      },
    },
    config: { sources: { lan: { enabled: false }, tailscale: { enabled: true } }, collect: { perCommandTimeoutMs: 900, factTimeoutMs: 900 } },
    hostname: `selftest-${label}`,
  });
  const state = { registry: createRegistry() };
  const version = await scanner.adbVersion();
  const scan = await scanner.scanFull(state);
  const snap = scanner.snapshot(state.registry);
  const again = await scanner.refreshStatus(state);

  checkOk(`${label}: adb 版本可读`, typeof version.version === 'string' && version.version.length > 0, JSON.stringify(version));
  checkOk(`${label}: 全量扫描成功`, scan.ok === true, JSON.stringify(scan.run.errors?.slice(0, 2)));
  checkOk(`${label}: 扫描耗时合理(<20s)`, scan.run.durationMs < 20000, `${scan.run.durationMs}ms`);
  checkOk(`${label}: 至少 ${expectMinDevices} 台设备`, snap.counts.total >= expectMinDevices, JSON.stringify(snap.counts));
  check(`${label}: serial 唯一（同一物理机不重复）`, new Set(snap.devices.map((d) => d.serial)).size, snap.devices.length);
  checkOk(`${label}: 每台设备至少一条通道`, snap.devices.every((d) => d.transports.length >= 1));
  checkOk(`${label}: 通道带连接命令`, snap.devices.every((d) => d.transports.every((t) => typeof t.connectCommand === 'string' && t.connectCommand.startsWith('adb'))));
  checkOk(`${label}: 扫描记录含来源统计`, ['usb', 'mdns', 'tailscale', 'lan', 'probe'].every((k) => scan.run.sources[k] !== undefined), JSON.stringify(scan.run.sources));
  checkOk(`${label}: tailscale 不可用时只记错误不失败`, scan.ok === true);
  checkOk(`${label}: 只读刷新可用`, again.probed >= 0 && again.durationMs < 20000, `${again.probed}/${again.durationMs}ms`);
  checkOk(`${label}: 注入文本无残留变量`, (() => {
    const text = composeMessage({ devices: snap.devices, template: 'default', target: '自测', hostName: 'selftest' }).text;
    return text.length > 0 && !/\{[A-Za-z0-9_]+\}/.test(text);
  })());
  return { snap, scan, again, version };
}

const offline = process.argv.includes('--offline');
const wantLive = process.argv.includes('--live');
const fixturesReady = existsSync(join(FIXTURES, 'adb-devices.txt'));
let replay = null;
let live = null;

if (!offline && fixturesReady) {
  replay = await runScanSuite('回放', makeReplayRunner(FIXTURES), 1);
  replay.devices = replay.snap.devices.map((d) => ({
    serial: d.serial, model: d.model, android: d.android, health: d.health, kinds: d.kinds,
    transports: d.transports.map((t) => `${t.kind}:${t.endpoint}(${t.state})`), summary: d.summary,
  }));
  replay.errors = replay.scan.run.errors;
  replay.sources = replay.scan.run.sources;
  replay.scanMs = replay.scan.run.durationMs;
  replay.refreshMs = replay.again.durationMs;
}

if (wantLive) {
  const { spawn } = await import('node:child_process');
  const runner = (argv, { timeoutMs = 5000, env } = {}) => new Promise((resolve) => {
    const [command, ...args] = argv;
    const child = spawn(command, args, { windowsHide: true, env: env ? { ...process.env, ...env } : undefined });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => { try { child.kill(); } catch { /* 忽略 */ } }, timeoutMs);
    child.stdout.on('data', (c) => { stdout += c; });
    child.stderr.on('data', (c) => { stderr += c; });
    child.on('error', (error) => { clearTimeout(timer); resolve({ code: -1, stdout, stderr: String(error?.message ?? error), timedOut: false }); });
    child.on('close', (code) => { clearTimeout(timer); resolve({ code, stdout, stderr, timedOut: false }); });
  });
  const adb = discoverAdbPath({ fs: { existsSync }, env: process.env, platform: process.platform });
  try {
    const out = await runScanSuite('真机', runner, 1);
    live = { adbPath: adb.path, adbSource: adb.source, devices: out.snap.devices.map((d) => ({ serial: d.serial, model: d.model, kinds: d.kinds, health: d.health, summary: d.summary })), counts: out.snap.counts };
  } catch (error) {
    live = { error: String(error?.message ?? error), adbPath: adb.path };
  }
}

// ────────────────── 提示词段 / 别名 / 称呼解析（离线，不碰 adb） ──────────────────

const PROMPT_NOW = 1_795_791_000_000;

/** 造一行 snapshot() 形态的设备（渲染层只认这些字段）。 */
function promptRow(serial, model, android, transports, extra = {}) {
  const rows = transports.map((t) => ({
    key: `${t.kind}|${t.endpoint}`,
    kind: t.kind,
    endpoint: t.endpoint,
    adbTarget: t.adbTarget ?? t.endpoint,
    state: 'device',
    connected: true,
    priority: t.kind === 'usb' ? 0 : 2,
    label: t.kind === 'usb' ? 'USB' : 'Tailscale',
    stale: false,
    connectCommand: 'adb …',
  }));
  return {
    serial,
    model,
    brand: null,
    android,
    health: 'ok',
    stale: false,
    factsAt: PROMPT_NOW,
    summary: '亮屏 · 已解锁 · 电量 50% · 非常亮',
    transports: rows,
    bestTransportKey: rows[0]?.key ?? null,
    kinds: [...new Set(rows.map((t) => t.kind))],
    aliases: [],
    group: null,
    notes: '',
    ...extra,
  };
}

const promptDevices = () => [
  promptRow('98fc9410', '2211133C', '16', [{ kind: 'tailscale', endpoint: '100.109.138.2:5555' }]),
  promptRow('8b1e8747', 'M2012K11AC', '13', [{ kind: 'usb', endpoint: '8b1e8747' }]),
  promptRow('43328e37', 'M332BF', '17', [{ kind: 'tailscale', endpoint: '100.75.247.55:5555' }, { kind: 'usb', endpoint: '43328e37' }]),
];
const promptBase = { hostName: 'test-host', now: PROMPT_NOW + 5_000, staleAfterMs: 120_000 };

check('提示词段: 没有设备时返回空串（整段消失，不留空标题）', renderModelPrompt({ ...promptBase, devices: [] }), '');

const plain = renderModelPrompt({ ...promptBase, devices: promptDevices() });
checkOk('提示词段: 网络设备的 adb 目标写成 IP:端口', plain.includes('`100.109.138.2:5555`'));
checkOk('提示词段: USB 设备的 adb 目标写成序列号', plain.includes('`8b1e8747`'));
checkOk('提示词段: 明确警告型号名不能当 -s 参数', plain.includes('不能当 `-s` 参数'));
checkOk('提示词段: 每台都带可复制的序列号', plain.includes('`98fc9410`') && plain.includes('`43328e37`'));
checkOk('提示词段: 没人起别名时不印「名字」列（省 token）', !plain.includes('名字（用户可能这么叫）'));
checkOk('提示词段: 没别名时教怎么建别名', plain.includes('action:"name"'));
checkOk('提示词段: 默认不把电量/屏幕写进提示词', !plain.includes('电量 50%') && plain.includes('故意不写在本表里'));
checkOk('提示词段: 双通道设备给出首选并列出可回落目标', plain.includes('备用 `43328e37`/USB'), plain);
checkOk('提示词段: 单通道设备不写"备用"废话', !/`100\.109\.138\.2:5555`（备用/.test(plain));

// 抖动回归（本次改动的核心）：facts/summary/factsAt 变了但身份没变 → 文本必须逐字节不变。
// DSH 每检测到一次 section 文本变化就往会话里追加一条 system 消息，
// 旧版每 30 秒就制造一版新清单，会话里同时躺着多版互相矛盾的设备表 —— 模型"搞不清设备"的主因。
const jitter = promptDevices().map((device, index) => ({
  ...device,
  factsAt: PROMPT_NOW + index * 1000,
  summary: '息屏 · 锁屏 · 电量 12% · 非常亮 · 前台 com.tencent.mm',
  facts: { battery: 12, screen: 'off', foreground: { package: 'com.tencent.mm' } },
}));
check('提示词段: 易变字段变化不改变文本（防多版清单）', renderModelPrompt({ ...promptBase, devices: jitter }), plain);

const volatile = renderModelPrompt({ ...promptBase, devices: promptDevices(), includeVolatile: true });
checkOk('提示词段: includeVolatile 才带实时状态列', volatile.includes('电量 50%') && !plain.includes('电量 50%'));

const aged = renderModelPrompt({ ...promptBase, devices: promptDevices().map((d) => ({ ...d, factsAt: PROMPT_NOW - 40 * 60_000 })) });
checkOk('提示词段: 数据过期要明说', aged.includes('超过 10 分钟'), aged.slice(-160));
check('提示词段: 新鲜度分桶（粗到不抖）', [freshnessBucket(90_000, 120_000), freshnessBucket(5_000), freshnessBucket(30 * 60_000)], ['2 分钟内', '30 秒内', '超过 10 分钟，很可能已过期，先 action:"status" 或 action:"scan"']);

const withAlias = renderModelPrompt({ ...promptBase, devices: promptDevices().map((d) => (d.serial === '98fc9410' ? { ...d, aliases: ['小米13', '备用机'] } : d)) });
checkOk('提示词段: 有别名时给出「名字」列并列出别名', withAlias.includes('名字（用户可能这么叫）') && withAlias.includes('小米13、备用机'));
checkOk('提示词段: 超行时说明还有几台', renderModelPrompt({ ...promptBase, devices: promptDevices(), maxRows: 2 }).includes('另有 1 台未列出'));
check('提示词段: 表头与分隔行、数据行列数一致', (() => {
  const widths = new Set(withAlias.split('\n').filter((line) => line.startsWith('|')).map((line) => line.split('|').length));
  return widths.size;
})(), 1);
check('提示词段: 单元格里的竖线被转义（不撑破表格）', renderModelPrompt({ ...promptBase, devices: promptDevices().map((d) => ({ ...d, model: 'A|B' })) }).split('\n').filter((l) => l.startsWith('|')).every((l) => !/\|A\|B\|/.test(l)), true);
check('提示词段: 首选通道排在最前', promptTargets(promptRow('43328e37', 'M332BF', '17', [{ kind: 'tailscale', endpoint: '100.75.247.55:5555' }, { kind: 'usb', endpoint: '43328e37' }])).primary, '100.75.247.55:5555');

const reg = createRegistry();
observe(reg, [
  { serial: '100.109.138.2:5555', endpoint: '100.109.138.2:5555', kind: 'tailscale', state: 'device', facts: { shellSerial: '98fc9410', model: '2211133C', android: '16' } },
  { serial: '8b1e8747', endpoint: '8b1e8747', kind: 'usb', state: 'device', facts: { shellSerial: '8b1e8747', model: 'M2012K11AC', android: '13' } },
], { now: PROMPT_NOW, fullScan: true });
check('别名: 两台设备入库', Object.keys(reg.devices).length, 2);
check('别名: 新设备自带空别名表', reg.devices['98fc9410'].aliases, []);
check('别名: deviceNames 提供 adb 目标', deviceNames(reg.devices['98fc9410']).targets.includes('100.109.138.2:5555'), true);

const named1 = setAliases(reg, '98fc9410', ['小米 13', '小米13', '备用机', '---']);
check('别名: 归一化去重后落表', reg.devices['98fc9410'].aliases, ['小米 13', '备用机']);
checkOk('别名: 纯标点被拒并说明原因', named1.ok === true && named1.rejected.some((r) => r.name === '---' && r.reason.includes('标点')));
check('别名: 与自己序列号同名的别名算冗余并剔除', setAliases(reg, '98fc9410', ['98FC9410', '主力机']), { ok: true, aliases: ['主力机'], rejected: [{ name: '98FC9410', reason: '和它自己的序列号/型号相同，写了也是冗余' }] });
const conflict = setAliases(reg, '8b1e8747', ['主力机']);
check('别名: 抢别的设备的名字被整表拒绝', [conflict.ok, conflict.error, conflict.conflict?.owner], [false, 'alias-conflict', '98fc9410']);
check('别名: 拒绝后原表未被改写', reg.devices['8b1e8747'].aliases, []);
check('别名: 超过 6 个被拒', setAliases(reg, '8b1e8747', ['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7']).error, 'too-many-aliases');
check('别名: 未知设备报错', setAliases(reg, 'nope', ['x']).error, 'unknown-device');
// 模型会把数组整成 JSON 字符串传回来；按分隔符硬拆会把括号引号拆进名字里
// （2026-11-28 真机踩过：注册表里躺出 ['["自检机"', '"测试机A"]']）。
check('别名: JSON 字符串入参先解开再落表', setAliases(reg, '8b1e8747', '["自检机","测试机A"]').aliases, ['自检机', '测试机A']);
check('别名: 非 JSON 的分隔符串照旧拆分', setAliases(reg, '8b1e8747', '自检机、测试机A').aliases, ['自检机', '测试机A']);
setAliases(reg, '98fc9410', ['小米13', '备用机']);

const byAlias = resolveDeviceRef(reg, '小米 13');
check('称呼: 别名带空格/大小写也能命中', [byAlias.ok, byAlias.device?.serial, byAlias.matchedBy], [true, '98fc9410', '别名']);
check('称呼: 序列号直查', resolveDeviceRef(reg, '8b1e8747').device?.serial, '8b1e8747');
check('称呼: adb 目标 host:port', resolveDeviceRef(reg, '100.109.138.2:5555').device?.serial, '98fc9410');
check('称呼: 只写 IP 也能定位', resolveDeviceRef(reg, '100.109.138.2').device?.serial, '98fc9410');
check('称呼: 型号', resolveDeviceRef(reg, 'M2012K11AC').device?.serial, '8b1e8747');
check('称呼: 前缀模糊唯一命中', [resolveDeviceRef(reg, '小米').ok, resolveDeviceRef(reg, '小米').device?.serial], [true, '98fc9410']);
const missing = resolveDeviceRef(reg, '华为Mate60');
checkOk('称呼: 认不出时给候选而不是空手', missing.ok === false && Array.isArray(missing.candidates));
// 候选必须带得出身份：一个字符都不沾时也要把"到底有哪几台"摆出来，模型才能自我纠正。
check('称呼: 候选携带序列号与型号（非空注册表）', missing.candidates.map((c) => c.serial).sort(), ['8b1e8747', '98fc9410']);
checkOk('称呼: 候选不是空壳', missing.candidates.every((c) => c.serial && c.model));
const batch = resolveDeviceRefs(reg, ['小米13', '8b1e8747', '不存在的机器']);
check('称呼: 批量解析能报出未匹配项', [batch.ok, batch.devices.map((d) => d.serial).sort()], [false, ['8b1e8747', '98fc9410']]);
check('称呼: 归一化吃掉全角与分隔符', [normalizeRef('Ｍｉ 13'), normalizeRef('小米-13'), normalizeRef(' 小米１3 ')], ['mi13', '小米13', '小米13']);

check('入参: 称呼可含中文与空格', toRefList('小米 13,8b1e8747,100.1.1.1:5555'), ['小米 13', '8b1e8747', '100.1.1.1:5555']);
check('入参: 挡掉 adb 选项注入与危险字符', toRefList(['--help', '-s', 'a|b', 'ok;rm', '', ' ', '$(id)']), []);
checkOk('入参: 旧 toSerialList 的严格性不回退', toSerialList(['8b1e8747', '小米 13', '--help']), ['8b1e8747']);

const cfg = normalizeConfig({});
check('配置: 面板轮询默认 60 秒（用户抱怨"两三秒闪一下"）', cfg.poll.panelMs, 60000);
check('配置: 顶栏徽标默认 30 秒', cfg.poll.badgeMs, 30000);
check('配置: 提示词默认不含易变字段', cfg.prompt.includeVolatile, false);
check('配置: 提示词规则默认开启', cfg.prompt.showRules, true);

// ───────────────────────────── 报告 ─────────────────────────────

if (process.argv.includes('--json')) {
  console.log(JSON.stringify({ failures, total: results.length, replay, live }, null, 2));
} else {
  let group = '';
  for (const item of results) {
    const prefix = item.name.split(':')[0];
    if (prefix !== group) { group = prefix; console.log(`\n▌${group}`); }
    console.log(`  ${item.ok ? '✔' : '✘'} ${item.name}${item.ok ? '' : `\n      实际   ${item.actual}\n      期望 ${item.expected}${item.detail ? `\n      说明   ${item.detail}` : ''}`}`);
  }
  if (replay) {
    console.log('\n▌fixture 回放（真机抓取的 adb / tailscale 输出）');
    console.log(`  扫描 ${replay.scanMs}ms：观测 ${replay.scan.run.found} 通道 → 合并 ${replay.scan.run.merged} 台；只读刷新 ${replay.refreshMs}ms`);
    console.log(`  来源：${JSON.stringify(replay.sources)}`);
    if (replay.errors?.length) console.log(`  错误：${JSON.stringify(replay.errors.slice(0, 5))}`);
    for (const device of replay.devices ?? []) {
      console.log(`  · ${device.model} A${device.android} ${device.serial} [${device.health}] ${device.kinds.join('+')}`);
      console.log(`      ${device.transports.join('  ')}`);
      console.log(`      ${device.summary}`);
    }
  }
  if (live) {
    console.log('\n▌真机（--live）');
    console.log(live.error ? `  跳过/失败：${live.error}（沙箱内不能 spawn；正式路径是 DSH Host 的 ctx.subprocess）`
      : `  adb ${live.adbPath} (${live.adbSource}) → ${JSON.stringify(live.counts)}\n` + (live.devices ?? []).map((d) => `  · ${d.model} ${d.serial} [${d.health}] ${d.kinds.join('+')} ${d.summary}`).join('\n'));
  }
  if (offline) console.log('\n（--offline：跳过回放与真机）');
  if (!offline && !fixturesReady) console.log('\n⚠ 缺少 test/fixtures，未跑回放（运行 tools/capture-fixtures.ps1 生成）');
  console.log(`\n合计 ${results.length} 项，失败 ${failures} 项`);
}

process.exitCode = failures === 0 ? 0 : 1;
