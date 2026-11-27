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
 * 找出已经把该端点登记为自己通道的真实设备（非 tmp:）。
 * 一轮探测拿不到 ro.serialno 时（离线/unauthorized），观测只能落到 tmp:端点 身份；
 * 而同一 host:port 很可能在上一轮已经挂在真实设备下了——不并回去，面板就会
 * 同时列出"真身"和"tmp:端点"两行重复设备。
 */
function ownerOfEndpoint(registry, endpoint) {
  const host = String(endpoint).split(':')[0];
  for (const [identity, device] of Object.entries(registry.devices ?? {})) {
    if (identity.startsWith('tmp:')) continue;
    for (const transport of Object.values(device.transports ?? {})) {
      const ep = String(transport.endpoint ?? '');
      if (ep === String(endpoint) || (host && ep.split(':')[0] === host)) return identity;
    }
  }
  return null;
}

/**
 * 建立/复位一个注册表。
 * version 2：设备多了 `aliases`（用户起的口语名字，如「小米13」）。老缓存没有该字段，
 * Store.load() 与 snapshot() 都按空表兜底，不做原地迁移——缓存是派生数据，重扫即可。
 * @param {{devices?: Record<string, object>}} initial
 */
export function createRegistry(initial = {}) {
  return { version: 2, devices: { ...(initial.devices ?? {}) } };
}

/** 别名条数与长度上限：面板手输，给个不会被灌爆提示词的上限。 */
export const ALIAS_MAX = 6;
export const ALIAS_MAX_LENGTH = 40;

/**
 * 把"设备称呼"拉平成可比较的形式：模型和用户会写 `小米 13`、`小米-13`、`MI 13`、`#13`。
 * 只做**比较用**的归一化，展示一律用原文。
 */
export function normalizeRef(value) {
  return String(value ?? '')
    .normalize('NFKC')
    .toLowerCase()
    // 全角标点/括号、下划线、连字符、斜杠、间隔号统统当成分隔符
    .replace(/[\s_\-/\\|·・．。，、,;:;（）()\[\]{}「」【】#*'`"~^]+/g, '')
    .trim();
}

/** 单条别名的清洗；返回 null 表示不可用。 */
function cleanAlias(raw) {
  const text = String(raw ?? '').normalize('NFKC').replace(/\s+/g, ' ').trim();
  if (!text) return null;
  if ([...text].length > ALIAS_MAX_LENGTH) return null;
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(text)) return null;
  // 只有标点/数字的东西没法当名字用（`---`、`1`），会让所有设备互相撞上。
  if (!/[\p{L}\p{N}]/u.test(text)) return null;
  return text;
}

/** 设备参与"称呼"匹配的全部名义值（不含 facts 里的易变字段）。 */
export function deviceNames(device) {
  const aliases = Array.isArray(device?.aliases) ? device.aliases : [];
  const targets = Object.values(device?.transports ?? {}).flatMap((t) => {
    const list = [t?.adbTarget, t?.endpoint];
    const host = String(t?.endpoint ?? '').split(':')[0];
    return [...list, host];
  });
  return {
    serial: device?.serial ?? null,
    aliases: aliases.filter((a) => typeof a === 'string' && a),
    model: device?.model ?? null,
    brand: device?.brand ?? null,
    targets: targets.filter(Boolean),
  };
}

/**
 * 设置某台设备的别名（整表替换）。
 * 名字是**用户手输的口语称呼**，所以必须查重：如果它已经指向另一台设备，
 * 模型就会把"小米13"解析到错的机器上——这比没有别名更糟，所以直接拒绝。
 * @returns {{ok: boolean, error?: string, aliases?: string[], rejected?: Array<{name: string, reason: string}>}}
 */
export function setAliases(registry, serial, names) {
  const device = registry?.devices?.[serial];
  if (!device) return { ok: false, error: `unknown-device`, rejected: [] };

  // names 可能被模型整成 JSON 字符串（'["自检机","测试机A"]'）：先试着按 JSON 解开，
  // 解不开再按分隔符拆——否则方括号和引号会被当成名字的一部分写进注册表，
  // 提示词里就会躺着 ['["自检机"', '"测试机A"]'] 这种脏别名（2026-11-28 实测踩过）。
  let raw = names;
  if (!Array.isArray(raw)) {
    const text = String(raw ?? '').trim();
    let parsed = null;
    if (/^\[.*\]$/s.test(text)) {
      try { parsed = JSON.parse(text); } catch { /* 不是 JSON，走分隔符拆分 */ }
    }
    raw = Array.isArray(parsed) ? parsed : text.split(/[,，、;；]/);
  }
  const aliases = [];
  const rejected = [];
  const seen = new Set();
  for (const item of raw ?? []) {
    const text = cleanAlias(item);
    if (!text) {
      const original = String(item ?? '').trim();
      if (original) rejected.push({ name: original, reason: '为空、超长（>' + ALIAS_MAX_LENGTH + ' 字符）或只含标点' });
      continue;
    }
    const key = normalizeRef(text);
    if (!key) {
      rejected.push({ name: text, reason: '归一化后为空' });
      continue;
    }
    if (seen.has(key)) continue;
    seen.add(key);
    aliases.push(text);
  }
  if (aliases.length > ALIAS_MAX) {
    return { ok: false, error: `too-many-aliases`, rejected: [...rejected, { name: aliases.slice(ALIAS_MAX).join('、'), reason: `最多 ${ALIAS_MAX} 个别名` }] };
  }

  // 跨设备查重：别名不能抢走别人已有的称呼。
  for (const [identity, other] of Object.entries(registry.devices ?? {})) {
    if (identity === serial) continue;
    const names2 = deviceNames(other);
    const owned = [...names2.aliases, names2.serial, names2.model, ...names2.targets]
      .map(normalizeRef)
      .filter(Boolean);
    const clash = aliases.find((alias) => owned.includes(normalizeRef(alias)));
    if (clash) {
      return {
        ok: false,
        error: `alias-conflict`,
        rejected,
        conflict: { alias: clash, owner: identity, ownerModel: other.model ?? null },
      };
    }
  }
  // 跟自己 serial/型号 撞名的别名纯属冗余，丢掉，不占提示词的位置。
  const own = new Set([normalizeRef(device.serial), normalizeRef(device.model), normalizeRef(device.brand)].filter(Boolean));
  const kept = aliases.filter((alias) => !own.has(normalizeRef(alias)));
  for (const dropped of aliases.filter((alias) => own.has(normalizeRef(alias)))) {
    rejected.push({ name: dropped, reason: '和它自己的序列号/型号相同，写了也是冗余' });
  }
  device.aliases = kept;
  return { ok: true, aliases: kept, rejected };
}

/**
 * 把一个称呼解析成设备。命中顺序：序列号 → 别名 → adb 目标/端点 → 型号 → 唯一包含匹配。
 * 失败时给出候选（含别名），让模型能从错误信息里自己学会该怎么叫。
 * @returns {{ok: true, device: object, matchedBy: string} | {ok: false, ref: string, reason: string, candidates: Array<{serial: string, model: string|null, aliases: string[]}>}}
 */
export function resolveDeviceRef(registry, ref) {
  const key = normalizeRef(ref);
  const fail = (reason) => ({ ok: false, ref: String(ref ?? ''), reason, candidates: suggestDevices(registry, ref) });
  if (!key) return fail('称呼为空');

  const devices = Object.values(registry?.devices ?? {});
  const matchStage = (matchedBy, valuesOf) => {
    const hits = devices.filter((device) => valuesOf(device).some((value) => normalizeRef(value) === key));
    if (hits.length === 1) return { hit: { ok: true, device: hits[0], matchedBy } };
    if (hits.length > 1) return { hit: { ok: false, ref: String(ref ?? ''), reason: `${matchedBy}「${ref}」撞上 ${hits.length} 台设备`, candidates: hits.map(candidatesOf) } };
    return null;
  };
  const stages = [
    ['序列号', (device) => [device.serial]],
    ['别名', (device) => deviceNames(device).aliases],
    ['adb 目标', (device) => deviceNames(device).targets],
    ['型号', (device) => [device.model, `${device.brand ?? ''} ${device.model ?? ''}`]],
  ];
  for (const [matchedBy, valuesOf] of stages) {
    const stage = matchStage(matchedBy, valuesOf);
    if (stage) return stage.hit;
  }

  // 兜底：唯一包含匹配（用户会打「小米13」而型号是 `M2012K11AC`，别名才是要害）。
  const contains = devices.filter((device) => {
    const names = deviceNames(device);
    return [...names.aliases, names.model, names.brand, names.serial]
      .filter(Boolean)
      .some((value) => {
        const target = normalizeRef(value);
        return target.length >= 2 && (target.includes(key) || key.includes(target));
      });
  });
  if (contains.length === 1) return { ok: true, device: contains[0], matchedBy: 'fuzzy' };
  if (contains.length > 1) return { ok: false, ref: String(ref ?? ''), reason: `同时匹配 ${contains.length} 台，需要更准确的名字`, candidates: contains.slice(0, 5).map(candidatesOf) };
  return fail('没有设备叫这个名');
}

function candidatesOf(device) {
  const names = deviceNames(device);
  return { serial: names.serial, model: names.model, aliases: names.aliases, targets: names.targets };
}

/** 给错误信息用的"你可能想说"：按字符重合度挑最多 5 台；一个都没沾上就全量列出来。 */
export function suggestDevices(registry, ref, limit = 5) {
  const key = normalizeRef(ref);
  const all = Object.values(registry?.devices ?? {});
  const scored = all.map((device) => {
    const names = deviceNames(device);
    const pool = [...names.aliases, names.model, names.brand, names.serial].filter(Boolean).map(normalizeRef);
    const best = pool.reduce((max, value) => {
      const shared = [...key].filter((ch) => value.includes(ch)).length;
      return Math.max(max, key.length ? shared / Math.max(key.length, value.length) : 0);
    }, 0);
    return { device, best };
  }).filter((entry) => entry.best > 0).sort((a, b) => b.best - a.best).slice(0, limit);
  // 一点字符都不沾也要给候选：模型拿到"注册表里到底有哪几台"才能自我纠正，
  // 只回"没有这台设备"它就会直接放弃。
  const pool = scored.length > 0 ? scored.map((entry) => entry.device) : all.slice(0, limit);
  return pool.map((device) => candidatesOf(device));
}

/** 批量解析：把模型传来的 serials（可能是序列号/型号/别名/adb 目标混着写）换成设备。 */
export function resolveDeviceRefs(registry, refs) {
  const devices = [];
  const unresolved = [];
  const seen = new Set();
  for (const ref of refs ?? []) {
    const result = resolveDeviceRef(registry, ref);
    if (!result.ok) {
      unresolved.push({ ref: result.ref, reason: result.reason, candidates: result.candidates });
      continue;
    }
    if (!seen.has(result.device.serial)) {
      seen.add(result.device.serial);
      devices.push(result.device);
    }
  }
  return { ok: unresolved.length === 0, devices, unresolved };
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
    if (identity === endpointIdentity) {
      const owner = ownerOfEndpoint(registry, endpoint);
      if (owner) identity = owner;
    }
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
        aliases: [],
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
      aliases: Array.isArray(device.aliases) ? device.aliases.filter((a) => typeof a === 'string' && a) : [],
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
