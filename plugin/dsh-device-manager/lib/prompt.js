/**
 * 模型可见的设备清单（`systemPrompt.section()` 的那一段）。
 *
 * 为什么单独成文件、并且刻意"信息少"：
 *  · DSH 每次组装提示词都会把这段和已提交状态比对，**文本一变就往会话里追加一条 system 消息**
 *    （dsh-system-prompt 的 `systemUpdates()`）。旧版把电量/屏幕/前台应用也印进来，
 *    后台 30 秒刷一次 → 每步都在追加新版清单，会话里同时躺着好几版互相矛盾的设备表，
 *    模型回看历史就会引用过期的那版 —— 这正是"模型搞不清设备"的主因。
 *  · 所以这段只保留**慢变事实**：身份、别名、通道、可用性。
 *    易变事实（屏幕/锁屏/电量/前台）一律不印，让模型自己调 `adb_devices{action:"status"}` 现取。
 *  · 另一条硬要求：模型要能**照着执行**。旧版只印 endpoint 和序列号，没说是 `adb -s` 的哪一个参数，
 *    模型经常拿型号名（`2211133C`）去连网络设备，然后得出"设备掉线了"的错误结论。
 *
 * 纯函数，不碰 DSH 运行时，便于 tools/selftest.mjs 断言。
 */

const HEALTH_LABEL = {
  ok: '可用',
  degraded: '通道未连上（先 status/scan）',
  error: '不可用',
  unknown: '未知（先 scan）',
};

/** 时间桶：粒度必须粗到"大多数轮次文本不变"，否则这段自己就成了抖动源。 */
export function freshnessBucket(ageMs, staleAfterMs = 120000) {
  const age = Math.max(0, Number(ageMs) || 0);
  if (age <= 30_000) return '30 秒内';
  if (age <= staleAfterMs) return '2 分钟内';
  if (age <= 10 * 60_000) return '10 分钟内（偏旧）';
  return '超过 10 分钟，很可能已过期，先 action:"status" 或 action:"scan"';
}

export function healthLabel(health) {
  return HEALTH_LABEL[health] ?? health ?? '未知';
}

/** 该设备可直接当 `adb -s` 参数的目标，按优先级排好（首选 + 可回落，最多展示 3 个）。 */
export function promptTargets(device) {
  const transports = device?.transports ?? [];
  const bestKey = device?.bestTransportKey;
  const ordered = [...transports].sort((a, b) => (a.key === bestKey ? -1 : 0) - (b.key === bestKey ? -1 : 0) || (a.priority ?? 99) - (b.priority ?? 99));
  const seen = new Set();
  const list = [];
  for (const t of ordered) {
    const target = t.adbTarget || t.endpoint;
    if (!target || seen.has(target)) continue;
    seen.add(target);
    list.push({ target, label: t.label ?? t.kind ?? '通道' });
  }
  return { primary: list[0]?.target ?? null, all: list.map((entry) => entry.target), fallbacks: list.slice(1, 3), hidden: Math.max(0, list.length - 3) };
}

function cell(value) {
  return String(value ?? '')
    .replace(/\r?\n/g, ' ')
    .replace(/\|/g, '｜')
    .trim();
}

/**
 * 渲染注入系统提示词的段体。
 * @param {{devices: Array, hostName?: string, now?: number, staleAfterMs?: number,
 *          includeVolatile?: boolean, maxRows?: number, showRules?: boolean}} input
 *   devices 取 `snapshot()` 出来的行（含 transports/health/aliases）。
 *   includeVolatile=true 时才把屏幕/电量等易变列加回来（默认关，见文件头注释）。
 * @returns {string} 空串表示"没有可说的"，调用方据此让整段消失
 */
export function renderModelPrompt(input = {}) {
  const {
    devices = [],
    hostName = '本机',
    now = Date.now(),
    staleAfterMs = 120000,
    includeVolatile = false,
    maxRows = 12,
    showRules = true,
  } = input;

  if (!Array.isArray(devices) || devices.length === 0) return '';

  const cap = Math.max(1, Number(maxRows) || 12);
  const rows = devices.slice(0, cap);
  const usable = devices.filter((d) => d.health === 'ok').length;
  // 没有任何别名时干脆不要「名字」列：那一列只会把型号重复印一遍，白烧 token。
  const named = devices.some((device) => (device.aliases ?? []).length > 0);

  const header = [];
  if (named) header.push('名字（用户可能这么叫）');
  header.push('序列号（`adb -s` 可直接用）', 'adb 目标（`adb -s` 首选）', '型号', 'Android', '通道');
  if (includeVolatile) header.push('状态（截至采集时刻）');
  header.push('可用性');

  const lines = rows.map((device) => {
    const targets = promptTargets(device);
    const channels = (device.transports ?? [])
      .map((t) => `${t.label ?? t.kind}${t.stale ? '·数据偏旧' : ''}`)
      .join(' + ') || '无';
    const targetText = targets.primary
      ? `\`${targets.primary}\`${targets.fallbacks.length
        ? `（备用 ${targets.fallbacks.map((t) => `\`${t.target}\`/${t.label}`).join('、')}${targets.hidden ? `；另有 ${targets.hidden} 条通道` : ''}）`
        : ''}`
      : '（无可连通道）';
    const row = [];
    if (named) row.push(cell((device.aliases ?? []).join('、') || '（未命名）'));
    row.push(
      `\`${cell(device.serial)}\``,
      targetText,
      cell(device.model ?? '未知型号'),
      cell(device.android ?? '?'),
      cell(channels),
    );
    if (includeVolatile) row.push(cell(device.summary ?? ''));
    row.push(cell(healthLabel(device.health)));
    return `| ${row.join(' | ')} |`;
  });

  const newest = rows.reduce((max, device) => Math.max(max, Number(device.factsAt) || 0), 0);
  const ageText = freshnessBucket(newest ? now - newest : Number.POSITIVE_INFINITY, staleAfterMs);

  const out = [];
  out.push(`## Android 测试机（本主机 ${hostName} 上的 adb 设备）`);
  out.push(`共 ${devices.length} 台，${usable} 台当前可用。`);
  out.push('定位设备只用一种写法：`adb -s <目标> shell …`，`<目标>` 从下表「adb 目标」列**原样照抄**。');
  out.push('注意：网络（WiFi/Tailscale/远程）设备的目标是 `IP:端口`，USB 与模拟器的才是序列号；**型号名（如 `2211133C`）不能当 `-s` 参数**。');
  out.push('');
  out.push(`| ${header.join(' | ')} |`);
  out.push(`|${header.map(() => '---').join('|')}|`);
  out.push(...lines);
  if (devices.length > rows.length) out.push(`（另有 ${devices.length - rows.length} 台未列出，用 adb_devices{action:"list",filter:"…"} 查看）`);
  out.push('');

  if (showRules) {
    out.push('规则：');
    if (named) {
      out.push('1. 用户口中的机器名先查「名字」列（那是用户自己起的别名，如"小米13"）；查不到就 `adb_devices{action:"list"}` 看全量再决定，**不要直接回答"没有这台设备"**。');
    } else {
      out.push('1. 这些设备还没有别名，用户口语叫法（如"小米13"）可能对应不上型号代号。拿不准就先 `adb_devices{action:"list"}` 对照，与用户确认后用它建立映射：`adb_devices{action:"name",serials:["…"],names:["小米13"]}`，之后就能直接用这个名字。');
    }
    out.push('2. 只在「可用性＝可用」的机器上做验证；不可用的先 `adb_devices{action:"status",serials:["…"]}`，仍失败用 `action:"scan"` 重扫。');
    out.push('3. 要做界面交互、截图、输入，必须先确认亮屏且已解锁，再动手；屏幕状态不在本表内，现取：`adb_devices{action:"status"}`，单台细节 `action:"inspect"`。');
    out.push('4. 屏幕/锁屏/电量/前台应用**故意不写在本表里**（它们每分钟都在变，写进来会让会话里同时存在多版矛盾清单）。不要用记忆里的状态下结论，每次现取。');
    out.push('5. 多台都要验证时，逐台跑同一组命令，并在结论里用**序列号**点名结果，别说"第一台/第二台"。');
    out.push('6. 命令报 `device not found` / `offline` 时，先怀疑 `-s` 参数抄错了（十有八九用了型号名），再走 status/scan。');
    out.push('');
  }
  out.push(`清单采集时间：${ageText}。要看这段原文：adb_devices{action:"prompt"}。`);
  return out.join('\n');
}
