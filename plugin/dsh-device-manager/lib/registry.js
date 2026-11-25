/**
 * 设备注册表：把"通道"（adb transport）按物理设备身份（ro.serialno）合并成设备。
 *
 * 实测依据：本机 `adb devices -l` 会同时给出 `8b1e8747`（USB）与 `192.168.1.151:5555`
 * 两条 transport，而两者的 `ro.serialno` 都是 `8b1e8747` —— 同一台物理机。若不按 serial
 * 合并，面板就会出现"两台一模一样的机器"。
 */

const TRANSPORT_PRIORITY = {
  usb: 0,
  lan: 1,
  tailscale: 2,
  'remote-server': 3,
  emulator: 4,
};

const TRANSPORT_LABEL = {
  usb: 'USB',
  lan: 'WiFi 局域网',
  tailscale: 'Tailscale',
  'remote-server': '远程 adb server',
  emulator: '模拟器',
};

export function transportLabel(kind) {
  return TRANSPORT_LABEL[kind] ?? kind ?? '未知';
}

export function transportPriority(kind) {
  const value = TRANSPORT_PRIORITY[kind];
  return value === undefined ? 99 : value;
}

function transportKey(kind, endpoint, server) {
  return `${server ?? 'local'}|${kind}|${endpoint}`;
}

/**
 * 建立/复位一个注册表。
 * @param {{devices?: Record<string, object>}} initial
 */
export function createRegistry(initial = {}) {
  return { version: 1, devices: { ...(initial.devices ?? {}) } };
}

/**
 * 合并一次观测。
 * @param {object} registry 可变注册表
 * @param {Array} observed 观测到的 transport 列表
 *   `[{ serial, endpoint, kind, server?, state, attrs?, facts?, connected? }]`
 * @param {{now?: number, fullScan?: boolean, pruneAfter?: number}} options
 * @returns {{registry: object, merged: Array, created: string[], updated: string[], dropped: string[]}}
 */
export function observe(registry, observed, options = {}) {
  const now = options.now ?? Date.now();
  const fullScan = options.fullScan !== false;
  const pruneAfter = options.pruneAfter ?? 3;
  const created = [];
  const updated = [];
  const dropped = [];
  const mergedFrom = [];
  const seenIdentities = new Set();

  for (const item of observed ?? []) {
    const kind = item.kind ?? (/:5555|^\d+(\.\d+){3}:\d+$/.test(String(item.serial ?? '')) ? 'lan' : 'usb');
    const endpoint = item.endpoint ?? item.serial;
    if (!endpoint) continue;
    // 身份优先级：ro.serialno > 非 host:port 的 adb serial（模拟器）> 端点临时键。
    const shellSerial = item.facts?.shellSerial || null;
    const endpointIdentity = `tmp:${endpoint}`;
    const plainSerial = !/^\d+(\.\d+){3}:\d+$/.test(String(item.serial ?? '')) ? item.serial : null;
    let identity = shellSerial || (kind === 'emulator' ? item.serial : null) || plainSerial || endpointIdentity;
    let device = registry.devices[identity];
    const orphan = identity !== endpointIdentity ? registry.devices[endpointIdentity] : undefined;

    if (!device && orphan) {
      // 之前只按端点登记（当时拿不到 ro.serialno），现在确认了身份：整条搬到真实 serial 下。
      delete registry.devices[endpointIdentity];
      orphan.serial = identity;
      orphan.identitySource = shellSerial ? 'ro.serialno' : orphan.identitySource;
      registry.devices[identity] = orphan;
      device = orphan;
      mergedFrom.push({ from: endpointIdentity, to: identity });
    } else if (device && orphan && orphan !== device) {
      // 真身已在、临时记录多余：通道并过去，丢掉临时记录。
      for (const [orphanKey, transport] of Object.entries(orphan.transports ?? {})) {
        if (!device.transports[orphanKey]) device.transports[orphanKey] = transport;
      }
      delete registry.devices[endpointIdentity];
      dropped.push(endpointIdentity);
    }

    seenIdentities.add(identity);
    if (!device) {
      device = {
        serial: identity,
        identitySource: shellSerial ? 'ro.serialno' : 'fallback',
        model: item.facts?.model ?? item.attrs?.model ?? null,
        brand: item.facts?.brand ?? null,
        android: item.facts?.android ?? null,
        sdk: item.facts?.sdk ?? null,
        size: item.facts?.size ?? null,
        density: item.facts?.density ?? null,
        facts: null,
        factsAt: 0,
        transports: {},
        missingRounds: 0,
        firstSeenAt: now,
        lastSeenAt: now,
        group: null,
        notes: '',
      };
      registry.devices[identity] = device;
      created.push(identity);
    } else {
      updated.push(identity);
      if (shellSerial && device.identitySource !== 'ro.serialno') device.identitySource = 'ro.serialno';
    }

    for (const field of ['model', 'brand', 'android', 'sdk', 'size', 'density']) {
      if (item.facts?.[field]) device[field] = item.facts[field];
    }
    if (item.facts) {
      device.facts = item.facts;
      device.factsAt = now;
    }

    const key = transportKey(kind, endpoint, item.server);
    const previous = device.transports[key];
    device.transports[key] = {
      key,
      kind,
      endpoint,
      server: item.server ?? null,
      adbTarget: item.serial ?? endpoint,
      state: item.state ?? 'unknown',
      detail: item.detail ?? previous?.detail ?? null,
      connected: item.connected !== false,
      priority: transportPriority(kind),
      addedAt: previous?.addedAt ?? now,
      lastSeenAt: now,
      lastError: item.error ?? previous?.lastError ?? null,
    };
    if (previous?.state && previous.state !== device.transports[key].state) {
      device.transports[key].stateChangedAt = now;
    }
    device.lastSeenAt = now;
    device.missingRounds = 0;
  }

  if (fullScan) {
    for (const [identity, device] of Object.entries(registry.devices)) {
      if (seenIdentities.has(identity)) continue;
      device.missingRounds = (device.missingRounds ?? 0) + 1;
      for (const transport of Object.values(device.transports)) {
        if (device.missingRounds >= pruneAfter) {
          transport.state = 'absent';
        }
      }
      if (device.missingRounds >= pruneAfter + 2 && device.identitySource !== 'ro.serialno') {
        delete registry.devices[identity];
        dropped.push(identity);
      }
    }
  }

  return { registry, merged: [...seenIdentities], created, updated, dropped, mergedFrom };
}

/** 健康度：ok / degraded / error / unknown。 */
export function deviceHealth(device) {
  const transports = Object.values(device.transports ?? {});
  if (transports.length === 0) return 'unknown';
  if (transports.some((t) => /unauthorized/.test(t.state))) return 'error';
  if (transports.some((t) => t.state === 'device' && t.connected)) return 'ok';
  if (transports.some((t) => /offline|no permissions|bootloader|sideload/.test(t.state))) return 'error';
  if (transports.some((t) => t.state === 'absent')) return 'unknown';
  return 'degraded';
}

/** 取优先级最高且可用的通道。 */
export function bestTransport(device) {
  const list = Object.values(device.transports ?? {}).filter((t) => t.state !== 'absent');
  const pool = list.length > 0 ? list : Object.values(device.transports ?? {});
  return pool.slice().sort((a, b) => {
    const aLive = a.state === 'device' ? 0 : 1;
    const bLive = b.state === 'device' ? 0 : 1;
    if (aLive !== bLive) return aLive - bLive;
    if (a.priority !== b.priority) return a.priority - b.priority;
    return (b.lastSeenAt ?? 0) - (a.lastSeenAt ?? 0);
  })[0] ?? null;
}

/** 一条通道的连接命令（供注入消息与"复制连接命令"使用）。 */
export function connectCommand(transport) {
  if (!transport) return '';
  if (transport.kind === 'usb' || transport.kind === 'emulator') return `adb -s ${transport.adbTarget} shell true`;
  const host = String(transport.endpoint).split(':')[0];
  const port = String(transport.endpoint).split(':')[1] ?? '5555';
  const prefix = transport.server ? `ADB_SERVER_SOCKET=tcp:${transport.server} adb` : 'adb';
  return `${prefix} connect ${host}:${port}`;
}

/** 状态摘要短语，用于注入消息与列表行。 */
export function stateSummary(device) {
  const facts = device.facts ?? {};
  const screen = facts.screen === 'on' ? '亮屏' : facts.screen === 'off' ? '息屏' : '屏幕未知';
  const lock = facts.locked === true ? '锁屏' : facts.locked === false ? '已解锁' : '锁屏未知';
  const battery = facts.battery == null ? '电量未知' : `电量 ${facts.battery}%${facts.powerSource ? `·${facts.powerSource}` : ''}`;
  const stay = facts.stayAwake ? `常亮(${(facts.stayAwakeConditions ?? []).join('/') || '已开'})` : '非常亮';
  const foreground = facts.foreground && !facts.foreground.systemUi
    ? `前台 ${facts.foreground.package ?? facts.foreground.raw}`
    : null;
  const parts = [screen, lock, battery, stay];
  if (foreground) parts.push(foreground);
  return parts.join(' · ');
}

/**
 * 面板/工具用的快照。
 * @returns {{devices: Array, generatedAt: number, counts: object}}
 */
export function snapshot(registry, { now = Date.now(), staleAfterMs = 120000, filter = 'all' } = {}) {
  const rows = Object.values(registry.devices ?? {}).map((device) => {
    const transports = Object.values(device.transports ?? {}).slice().sort((a, b) => a.priority - b.priority);
    const best = bestTransport(device);
    const stale = now - (device.factsAt ?? 0) > staleAfterMs;
    const health = stale && deviceHealth(device) === 'ok' ? 'degraded' : deviceHealth(device);
    return {
      serial: device.serial,
      model: device.model ?? '未知型号',
      brand: device.brand ?? null,
      android: device.android ?? null,
      sdk: device.sdk ?? null,
      size: device.size ?? null,
      density: device.density ?? null,
      group: device.group ?? null,
      notes: device.notes ?? '',
      identitySource: device.identitySource,
      health,
      stale,
      facts: device.facts,
      factsAt: device.factsAt ?? 0,
      transports: transports.map((t) => ({
        ...t,
        label: transportLabel(t.kind),
        connectCommand: connectCommand(t),
        stale: now - (t.lastSeenAt ?? 0) > staleAfterMs,
      })),
      bestTransportKey: best?.key ?? null,
      kinds: [...new Set(transports.map((t) => t.kind))],
      summary: stateSummary(device),
      missingRounds: device.missingRounds ?? 0,
    };
  });

  const filtered = rows.filter((row) => {
    if (filter === 'all') return true;
    if (filter === 'offline') return row.health === 'error' || row.health === 'unknown';
    return row.kinds.includes(filter);
  });

  filtered.sort((a, b) => {
    const rank = { ok: 0, degraded: 1, error: 2, unknown: 3 };
    if (rank[a.health] !== rank[b.health]) return rank[a.health] - rank[b.health];
    return String(a.model).localeCompare(String(b.model));
  });

  return {
    generatedAt: now,
    devices: filtered,
    counts: {
      total: rows.length,
      ok: rows.filter((r) => r.health === 'ok').length,
      degraded: rows.filter((r) => r.health === 'degraded').length,
      error: rows.filter((r) => r.health === 'error').length,
      unknown: rows.filter((r) => r.health === 'unknown').length,
      transports: rows.reduce((sum, r) => sum + r.transports.length, 0),
    },
  };
}
