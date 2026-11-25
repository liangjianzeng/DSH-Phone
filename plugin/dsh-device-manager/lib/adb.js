/**
 * adb 命令行封装与输出解析。
 *
 * 本模块**不直接依赖 Node 的 child_process**：所有外部命令通过注入的 `run(argv, opts)`
 * 执行，这样同一套解析逻辑既能跑在 DSH Host 的 `ctx.subprocess.spawn` 里，也能在
 * `tools/selftest.mjs` 里用本地 child_process 直接自测。
 *
 * @typedef {(argv: string[], opts?: {timeoutMs?: number, env?: Record<string,string>})
 *   => Promise<{code: number | null, stdout: string, stderr: string, timedOut: boolean}>} Runner
 */

/** `adb devices -l` 的一行设备记录。 */
export function parseDevicesList(text) {
  const devices = [];
  const notes = [];
  for (const rawLine of String(text ?? '').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    if (/^list of devices attached/i.test(line)) continue;
    // daemon 启动提示、版本不匹配提示等都属于噪声，保留成 note 供诊断使用。
    if (/^\*/.test(line) || /daemon|adb server|error:|warning:/i.test(line)) {
      notes.push(line);
      continue;
    }
    // adb 用反斜杠转义字段里的空格（model:Motorola\ Edge_2），先占位再切分。
    const parts = line.replace(/\\ /g, '\u0000').split(/\s+/).map((token) => token.split('\u0000').join(' '));
    if (parts.length < 2) {
      notes.push(line);
      continue;
    }
    const [serial, stateWord] = parts;
    let state = stateWord;
    let detail = '';
    // "no permissions (user in plugdev group…)" 这类状态含空格，整段收进 detail。
    if (/^no$/i.test(stateWord) && /^permissions$/i.test(parts[2] ?? '')) {
      state = 'no permissions';
      const rest = line.slice(serial.length).trim();
      const paren = rest.indexOf('(');
      detail = paren >= 0 ? rest.slice(paren) : rest;
    }
    const attrs = {};
    for (const token of parts.slice(2)) {
      const idx = token.indexOf(':');
      if (idx > 0) attrs[token.slice(0, idx)] = token.slice(idx + 1);
    }
    devices.push({
      serial,
      state,
      detail: detail || undefined,
      product: attrs.product || undefined,
      model: attrs.model || undefined,
      deviceName: attrs.device || undefined,
      transportId: attrs.transport_id || undefined,
      attrs,
    });
  }
  return { devices, notes };
}

/** `adb mdns services` 输出 → 无线调试（Android 11+）候选端点。 */
export function parseMdnsServices(text) {
  const out = [];
  for (const rawLine of String(text ?? '').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || !/_adb-tls-(connect|pairing)\._tcp/.test(line)) continue;
    // 形如：  <instance>   _adb-tls-connect._tcp.   192.168.1.20   5555
    const fields = line.split(/\s+/);
    const port = Number(fields[fields.length - 1]);
    const address = fields[fields.length - 2];
    const pairing = /_adb-tls-pairing\._tcp/.test(line);
    if (!/^[0-9a-fA-F:.]+$/.test(address) || !Number.isFinite(port) || port <= 0) continue;
    out.push({ serviceType: pairing ? 'pairing' : 'connect', address, port, instance: fields[0] });
  }
  return out;
}

/** `tailscale status --json` → 可作为局域网候选的 peer IPv4。 */
export function parseTailscaleStatus(text) {
  try {
    const json = JSON.parse(text);
    const self = json?.Self?.IPv4Addresses ?? [];
    const peers = Object.values(json?.Peer ?? {})
      .map((peer) => ({
        name: peer?.HostName || peer?.DNSName || '',
        ips: peer?.TailscaleIPs ?? [],
        online: Boolean(peer?.Online),
        os: peer?.OS,
      }))
      .filter((peer) => (peer.ips ?? []).length > 0);
    return { ok: true, selfIps: self, peers };
  } catch (error) {
    // 常见原因：tailscaled 未运行 / 沙箱拒绝命名管道 / CLI 不在 PATH。保留原文首行便于诊断。
    const firstLine = String(text ?? '').trim().split(/\r?\n/)[0] ?? '';
    return {
      ok: false,
      error: `tailscale status 输出无法解析：${firstLine || String(error?.message ?? error)}`.slice(0, 300),
      selfIps: [],
      peers: [],
    };
  }
}

/**
 * 一次性采集一台设备的全部事实：把多条 shell 命令合成**一次** `adb shell`，
 * 用标记切分输出，避免每台设备十几次往返。
 *
 * 标记只用字母数字与下划线（`_DMK_KEY_`）：Android 的 /system/bin/sh（mksh）里
 * 以 `#` 开头的词会开启注释，用 `#@KEY@` 会让整行被吃掉（实测踩过的坑）。
 *
 * 字段名会随 Android 版本漂移（实测 A13 与 A17 不完全一致），因此每个事实都带
 * 回退链，解析不出来一律 `unknown`，不判成失败。
 */
export function buildFactScript() {
  const marks = [
    ['MODEL', 'getprop ro.product.model'],
    ['BRAND', 'getprop ro.product.brand'],
    ['ANDROID', 'getprop ro.build.version.release'],
    ['SDK', 'getprop ro.build.version.sdk'],
    ['SERIAL', 'getprop ro.serialno'],
    ['POWER', 'dumpsys power'],
    ['WINDOW', 'dumpsys window'],
    ['BATTERY', 'dumpsys battery'],
    ['STAY', 'settings get global stay_on_while_plugged_in'],
    ['ADBWIFI', 'settings get global adb_wifi_enabled'],
    ['SIZE', 'wm size'],
    ['DENSITY', 'wm density'],
    ['BRIGHT', 'settings get system screen_brightness_mode'],
  ];
  return marks.map(([key, cmd]) => `echo _DMK_${key}_; ${cmd} 2>/dev/null`).join('; ');
}

/** 把一次 shell 输出按标记切成段。 */
export function splitFactOutput(text) {
  const sections = {};
  let current = 'PRELUDE';
  sections[current] = '';
  for (const line of String(text ?? '').replace(/^\uFEFF/, '').split(/\r?\n/)) {
    const match = /^_DMK_([A-Z_]+)_$/.exec(line.trim());
    if (match) {
      current = match[1];
      if (sections[current] === undefined) sections[current] = '';
      continue;
    }
    sections[current] = (sections[current] ?? '') + line + '\n';
  }
  return sections;
}

const FOREGROUND_IGNORE = new Set([
  'com.android.systemui',
  'com.android.settings',
  'android',
]);

/** 由采集段解析出结构化事实。 */
export function parseFacts(sections) {
  const power = sections.POWER ?? '';
  const window = sections.WINDOW ?? '';
  const battery = sections.BATTERY ?? '';

  // —— 亮屏/息屏：mWakefulness → Display Power state → powerinfo ——
  let screen = 'unknown';
  const wake = /mWakefulness=([A-Za-z]+)/.exec(power)?.[1];
  if (wake) screen = /awake/i.test(wake) ? 'on' : /asleep|dozing/i.test(wake) ? 'off' : 'unknown';
  if (screen === 'unknown') {
    const dp = /Display Power:\s*state=([A-Za-z]+)/i.exec(power)?.[1];
    if (dp) screen = /^on$/i.test(dp) ? 'on' : /^off$/i.test(dp) ? 'off' : 'unknown';
  }
  if (screen === 'unknown' && /mPowerState=ON|SCREEN_STATE_ON/i.test(power)) screen = 'on';
  if (screen === 'unknown' && /mPowerState=OFF|SCREEN_STATE_OFF/i.test(power)) screen = 'off';

  // —— 前台窗口/应用 ——
  const focusRaw =
    /mCurrentFocus=Window\{([^ ]+)\s+u\d+\s+([^}\s]+)/.exec(window)?.[2] ??
    /mCurrentFocus=Window\{[^}]*?\s([^\s}]+\/[^\s}]+)/.exec(window)?.[1] ??
    null;
  let foreground = null;
  if (focusRaw) {
    const [pkg = '', activity = ''] = focusRaw.includes('/') ? focusRaw.split('/') : ['', focusRaw];
    foreground = { package: pkg || null, activity: activity || null, raw: focusRaw };
  }
  const shadeish = /NotificationShade|Keyguard|mDreamingLockscreen=true|Toast/;
  if (foreground && (FOREGROUND_IGNORE.has(foreground.package ?? '') || shadeish.test(foreground.raw ?? ''))) {
    foreground.systemUi = true;
  }

  // —— 锁屏：焦点在锁屏/通知栏 或 mDreamingLockscreen=true ——
  let locked = 'unknown';
  const dreaming = /mDreamingLockscreen=(true|false)/.exec(window)?.[1];
  const showingLs = /mShowingLockscreen=(true|false)/.exec(window)?.[1];
  if (/mCurrentFocus=Window\{[^}]*(Keyguard|NotificationShade)/.test(window)) locked = true;
  else if (showingLs !== undefined) locked = showingLs === 'true';
  else if (dreaming !== undefined) locked = dreaming === 'true';
  if (locked === 'unknown' && screen === 'off') locked = 'unknown';

  // —— 电量与充电 ——
  const level = Number(/level:\s*(\d+)/.exec(battery)?.[1]);
  const status = Number(/status:\s*(\d+)/.exec(battery)?.[1]);
  const ac = /AC powered:\s*true/.test(battery);
  const usb = /USB powered:\s*true/.test(battery);
  const wireless = /Wireless powered:\s*true/.test(battery);
  const powerSource = ac ? 'AC' : wireless ? 'wireless' : usb ? 'USB' : null;

  // —— 常亮：stay_on_while_plugged_in 位掩码（1=AC 2=USB 4=wireless，7/15 常见于开发者打开"充电时不休眠"）——
  const stayRaw = (sections.STAY ?? '').trim();
  const stayBits = Number(/^-?\d+$/.test(stayRaw) ? stayRaw : '0');
  const stayConditions = Number.isFinite(stayBits) && stayBits > 0
    ? [stayBits & 1 ? 'AC' : null, stayBits & 2 ? 'USB' : null, stayBits & 4 ? '无线' : null].filter(Boolean)
    : [];

  const adbWifi = (sections.ADBWIFI ?? '').trim();
  const size = /Physical size:\s*(\d+x\d+)/.exec(sections.SIZE ?? '')?.[1] ?? null;
  const density = /Physical density:\s*(\d+)/.exec(sections.DENSITY ?? '')?.[1] ?? null;

  return {
    model: (sections.MODEL ?? '').trim() || null,
    brand: (sections.BRAND ?? '').trim() || null,
    android: (sections.ANDROID ?? '').trim() || null,
    sdk: Number((sections.SDK ?? '').trim()) || null,
    shellSerial: (sections.SERIAL ?? '').trim() || null,
    screen,
    locked,
    foreground,
    battery: Number.isFinite(level) ? level : null,
    chargeStatus: Number.isFinite(status) ? status : null,
    powerSource,
    stayAwake: stayBits > 0,
    stayAwakeBits: Number.isFinite(stayBits) ? stayBits : 0,
    stayAwakeConditions: stayConditions,
    adbWifiEnabled: /^(0|1|null)$/.test(adbWifi) ? adbWifi === '1' : null,
    size,
    density,
    brightnessAuto: /^1$/.test((sections.BRIGHT ?? '').trim()) ? true : /^0$/.test((sections.BRIGHT ?? '').trim()) ? false : null,
  };
}

/**
 * 解析 `adb -s <t> shell <buildFactScript()>` 的结果。
 * 失败（设备掉线、unauthorized）时返回 `ok: false` 并带上首行错误，供上层降级为 unknown。
 */
export function collectFactsFrom(run, base, target, { timeoutMs = 4000 } = {}) {
  const argv = [...base, '-s', target, 'shell', buildFactScript()];
  return run(argv, { timeoutMs }).then((result) => {
    const out = String(result.stdout ?? '');
    if (!out.trim()) {
      const message = String(result.stderr ?? '').trim().split(/\r?\n/)[0] || `shell 退出码 ${result.code}`;
      return { ok: false, error: message, timedOut: Boolean(result.timedOut), facts: null };
    }
    return { ok: true, error: null, timedOut: Boolean(result.timedOut), facts: parseFacts(splitFactOutput(out)) };
  });
}

/** 判断 transport 端点是否为 IP:port（WiFi / tailnet 无线 adb）。 */
export function classifyEndpoint(serial) {
  const match = /^(\d{1,3}(?:\.\d{1,3}){3}|\[[0-9a-fA-F:]+\]|[^:]+):(\d+)$/.exec(String(serial ?? ''));
  if (!match) return { kind: 'usb', host: null, port: null };
  return { kind: 'tcp', host: match[1].replace(/^\[|\]$/g, ''), port: Number(match[2]) };
}

/** tailnet 段（CGNAT 100.64.0.0/10）用于区分 "WiFi 局域网" 与 "Tailscale"。 */
export function isTailnetAddress(host) {
  if (!host) return false;
  if (/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(host)) return true;
  return /^[0-9a-fA-F:]+$/.test(host) && /^f[cd]/i.test(host);
}
