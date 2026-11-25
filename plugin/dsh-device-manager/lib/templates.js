/**
 * 消息模板：把设备状态渲染成可直接粘进对话的调试提示。
 * 模板存在注册表域里（用户可自定义），内置三套；变量用 `{name}` 插值。
 */

export const BUILTIN_TEMPLATES = {
  default: {
    title: '默认（一条汇总）',
    mode: 'single',
    body: [
      '请在以下 {count} 台 Android 测试机上验证：{target}',
      '{deviceLines}',
      '主机：{hostName}｜adb：{adbVersion}｜采集时间：{generatedAtLocal}',
      '{channelAdvice}',
    ].join('\n'),
    perDeviceLine: [
      '{index}. {model}（Android {android}）· {serial}',
      '   通道：{allTransports}',
      '   状态：{screen} · {lock} · 电量 {battery}{charging} · {stayAwake}',
      '   {foreground}',
    ].join('\n'),
  },
  brief: {
    title: '简版（一行一台）',
    mode: 'single',
    body: ['调试目标：{target}', '{deviceLines}', '（主机 {hostName}，{generatedAtLocal}）'].join('\n'),
    perDeviceLine: '- {model}（Android {android}）· {serial} · {allTransportsBrief} · {screen}/{lock}/{battery}{charging}/{stayAwake}',
  },
  perDevice: {
    title: '每台一条',
    mode: 'perDevice',
    body: [
      '[设备] {model}（Android {android}）· {serial}',
      '通道：{allTransports}',
      '状态：{screen} · {lock} · 电量 {battery}{charging} · {stayAwake}',
      '{foreground}',
      '{channelAdvice}',
      '任务：{target}',
    ].join('\n'),
    perDeviceLine: null,
  },
};

function pad(value, fallback = '未知') {
  return value === null || value === undefined || value === '' ? fallback : String(value);
}

/** 单台设备可用作插值的扁平变量表。 */
export function deviceVars(device, { index = 1, fallbackTransport = null } = {}) {
  const best = device.transports?.find((t) => t.key === device.bestTransportKey) ?? device.transports?.[0] ?? {};
  const facts = device.facts ?? {};
  const screen = facts.screen === 'on' ? '亮屏' : facts.screen === 'off' ? '息屏' : '屏幕未知';
  const lock = facts.locked === true ? '锁屏' : facts.locked === false ? '已解锁' : '锁屏未知';
  const battery = facts.battery == null ? '电量未知' : `${facts.battery}%`;
  const charging = facts.battery == null ? '' : facts.powerSource ? `（${facts.powerSource}${facts.chargeStatus === 2 ? ' 充电中' : ''}）` : '';
  const stayAwake = facts.stayAwake ? `常亮${(facts.stayAwakeConditions ?? []).length ? `(${facts.stayAwakeConditions.join('/')})` : ''}` : '非常亮';
  const fg = facts.foreground;
  // 系统界面（通知栏/桌面）也要把 activity 说出来：只显示"无"会让人以为采集失败，
  // 而 inspect 里同一台机器印的是 NotificationShade，两处口径必须一致。
  const foreground = fg && !fg.systemUi
    ? `前台：${fg.package ?? fg.raw}${fg.activity ? `/${fg.activity}` : ''}`
    : `前台：无应用（${fg?.activity ?? '桌面/通知栏'}${fg?.systemUi ? '，系统界面' : ''}）`;
  const transports = device.transports ?? [];
  // 回落通道优先取**同一台设备**的次选通道（USB 掉了走 WiFi），再退到别的设备的通道。
  const fallback = transports.find((t) => t.key !== best?.key) ?? fallbackTransport ?? best;
  const hasFallback = Boolean(fallback && fallback.key !== best?.key);
  // 只有一条通道时不要印"回落到自己"这种废话指令；USB 的 connectCommand 本质是探活命令，说清楚。
  const channelAdvice = hasFallback
    ? `优先使用 \`${best.connectCommand}\`；该通道不可用时回落 \`${fallback.connectCommand}\`。`
    : (best?.kind === 'usb' || best?.kind === 'emulator')
      ? `只用这条通道：\`${best.connectCommand}\`（探活用；设备应已在 adb devices 里，不需要 adb connect）。`
      : `只用这条通道：\`${best.connectCommand}\`。`;
  const allTransports = transports.length
    ? transports.map((t) => `${pad(t.label ?? t.kind)} ${pad(t.endpoint)}（\`${pad(t.connectCommand)}\`）`).join(' + ')
    : '（无可用通道）';
  const allTransportsBrief = transports.length
    ? transports.map((t) => `${pad(t.label ?? t.kind)} ${pad(t.endpoint)}`).join(' + ')
    : '（无可用通道）';

  return {
    index,
    model: pad(device.model, '未知型号'),
    brand: pad(device.brand, ''),
    android: pad(device.android),
    serial: pad(device.serial),
    endpoint: pad(best.endpoint),
    transportLabel: pad(best.label ?? best.kind),
    transportKind: pad(best.kind),
    connectCommand: pad(best.connectCommand),
    preferredCmd: pad(best.connectCommand),
    fallbackCmd: pad(fallback?.connectCommand),
    channelAdvice,
    allTransports,
    allTransportsBrief,
    channelCount: transports.length,
    screen,
    lock,
    battery,
    charging,
    stayAwake,
    foreground,
    foregroundLine: `   ${foreground}`,
    size: pad(device.size, ''),
    density: pad(device.density, ''),
  };
}

/** 极简 `{var}` 插值：未知变量保留原样，便于发现模板写错。 */
export function interpolate(text, vars) {
  return String(text ?? '').replace(/\{([A-Za-z0-9_]+)\}/g, (match, name) =>
    Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : match);
}

/**
 * 组装注入消息。
 * @param {{devices: Array, template?: object|string, target?: string, hostName?: string, adbVersion?: string, generatedAt?: number, locale?: string}} input
 * @returns {{messages: string[], text: string, templateTitle: string}}
 */
export function composeMessage(input) {
  const {
    devices = [],
    template = 'default',
    target = '本次改动',
    hostName = '本机',
    adbVersion = '未知',
    generatedAt = Date.now(),
  } = input;

  const spec = typeof template === 'string'
    ? (BUILTIN_TEMPLATES[template] ?? BUILTIN_TEMPLATES.default)
    : { ...BUILTIN_TEMPLATES.default, ...template };

  const generatedAtLocal = new Date(generatedAt).toLocaleString('zh-CN', { hour12: false });
  const first = devices[0] ? deviceVars(devices[0], { index: 1, fallbackTransport: devices[1]?.transports?.[0] }) : {};
  const head = {
    count: devices.length,
    target,
    hostName,
    adbVersion,
    generatedAtLocal,
    preferredCmd: first.preferredCmd ?? 'adb devices',
    fallbackCmd: first.fallbackCmd ?? first.preferredCmd ?? 'adb devices',
    // 多台设备时不要只按第一台给"优先/回落"指令，那会让人以为整套都用同一条通道。
    channelAdvice: devices.length > 1
      ? '每台设备按上面"通道"里列出的顺序使用（反引号里就是可直接执行的命令）。'
      : (first.channelAdvice ?? '先用 `adb devices` 确认设备在线。'),
  };

  const perDevice = devices.map((device, i) => interpolate(spec.perDeviceLine ?? '- {model} {serial}',
    deviceVars(device, { index: i + 1, fallbackTransport: devices[(i + 1) % Math.max(1, devices.length)]?.transports?.[0] })));

  if (spec.mode === 'perDevice') {
    const messages = devices.map((device, i) => {
      const vars = { ...head, ...deviceVars(device, { index: i + 1, fallbackTransport: devices[(i + 1) % Math.max(1, devices.length)]?.transports?.[0] }) };
      return interpolate(spec.body, vars);
    });
    return { messages, text: messages.join('\n\n'), templateTitle: spec.title ?? '每台一条' };
  }

  const text = interpolate(spec.body, { ...head, deviceLines: perDevice.join('\n') });
  return { messages: [text], text, templateTitle: spec.title ?? '默认' };
}
