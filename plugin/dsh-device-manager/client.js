/**
 * dsh-device-manager — Client 半区（Web）。
 *
 * 在会话顶栏右侧工具区（`conversation.session.header.utilities`）注册一个手机图标，
 * 点开是浮在 document.body 上的设备面板：主机扫描到的设备、每台设备的连接通道 / 亮屏 /
 * 锁屏 / 常亮 / 电量 / 前台应用；勾选后可「填入输入框」（inputActions.setDraft）或
 * 「排队投递到会话」（Host 侧 sessionController.prompt(mode:'queue')）。
 *
 * 遵循 DSH 插件 UI 规范：
 *  · 只注册进既有插槽，不新建第二棵应用树、不改宿主 DOM；
 *  · 只用 `--dsw-alias-*` / `--dsw-specific-*` / `--dsw-elevation-*` 主题令牌，控件自绘
 *    （不 require 宿主 primitives 包）；
 *  · 浮层 portal 到 document.body，Escape 与外部点击关闭；
 *  · 文案走 Client locale 服务（zh / en 两套字典，namespace = deviceManager）。
 */
window.__ModuleLoader__.load({
  id: '@local/dsh-device-manager',
  factory(require) {
    const React = require('react');
    /**
     * createPortal 不在 `react` 上：官方客户端插件一律 `require("react-dom")` 取它。
     * 之前写成 React.createPortal，点开面板那一帧就抛 TypeError，异常把插槽组件整棵带走，
     * 表现为"图标点一下就消失了，什么也没弹出来"。
     * 这里逐个候选取，全部取不到就退回原地渲染（不 portal），绝不让面板连累顶栏图标。
     */
    let createPortal = null;
    for (const source of ['react-dom', 'react']) {
      try {
        const mod = require(source);
        const candidate = mod?.createPortal ?? mod?.default?.createPortal;
        if (typeof candidate === 'function') {
          createPortal = candidate.bind(mod?.default ?? mod);
          break;
        }
      } catch { /* 换下一个候选 */ }
    }
    if (!createPortal && typeof window !== 'undefined' && typeof window.ReactDOM?.createPortal === 'function') {
      createPortal = window.ReactDOM.createPortal.bind(window.ReactDOM);
    }
    const { createElement: h, useState, useEffect, useRef, useCallback, useMemo } = React;

    const NS = 'deviceManager';
    const PANEL_MS = 3000;
    const BADGE_MS = 20000;

    const DICTS = {
      zh: {
        'trigger.aria': '安卓测试机',
        'panel.title': '测试设备',
        'panel.host': '主机',
        'panel.adb': 'adb',
        'panel.lastScan': '上次扫描',
        'panel.never': '尚未扫描',
        'panel.scanning': '扫描中…',
        'panel.scan': '扫描可用设备',
        'panel.refresh': '只刷新状态',
        'panel.empty': '本会话还没有获取过设备。',
        'panel.emptyHint': '扫描在主机上执行：USB + 已配置网段 + Tailscale。',
        'panel.noDevice': '主机上还没有已知设备，点「扫描可用设备」试试。',
        'panel.devices': '台设备',
        'panel.channels': '条通道',
        'filter.all': '全部',
        'filter.usb': 'USB',
        'filter.lan': 'WiFi',
        'filter.tailscale': 'Tail',
        'filter.offline': '异常',
        'row.select': '选择该设备',
        'row.blockedError': '该设备当前不可用，不能勾选',
        'row.blockedUnknown': '还没有采集到该设备的状态，请先扫描',
        'row.copy': '复制连接命令',
        'row.copied': '已复制',
        'row.stale': '数据过期',
        'panel.crash': '设备面板渲染失败',
        'screen.on': '亮屏',
        'screen.off': '息屏',
        'screen.unknown': '屏 ?',
        'lock.locked': '锁屏',
        'lock.unlocked': '已解锁',
        'lock.unknown': '锁 ?',
        'battery.unknown': '电量 ?',
        'stay.on': '常亮',
        'stay.off': '非常亮',
        'footer.selectAll': '全选',
        'footer.selected': '已选 {count}',
        'footer.template': '模板',
        'template.default': '一条汇总',
        'template.brief': '一行一台',
        'template.perDevice': '每台一条',
        'footer.mode': '投递方式',
        'mode.queue': '排队发送',
        'mode.steer': '中途纠偏',
        'footer.target': '调试目标',
        'footer.targetPlaceholder': '例如：登录页重构',
        'footer.fill': '填入输入框',
        'footer.queue': '发送到会话',
        'footer.copy': '复制文本',
        'footer.doctor': '自检',
        'hint.notConnected': '未连上主机，面板只读。',
        'hint.error': '主机调用失败：{message}',
        'hint.noSelection': '先勾选至少一台设备。',
        'hint.filled': '已填入输入框，可直接编辑后发送。',
        'hint.queued': '已投递 {count} 条到本会话（{mode}）。',
        'hint.none': '没有可注入的设备，请先扫描。',
        'hint.noDraft': '当前输入框不可用，已改为复制到剪贴板。',
        'hint.copied': '已复制到剪贴板。',
        'hint.copiedAll': '没有勾选设备，已复制全部 {count} 台的调试文本。',
      },
      en: {
        'trigger.aria': 'Android test devices',
        'panel.title': 'Test devices',
        'panel.host': 'Host',
        'panel.adb': 'adb',
        'panel.lastScan': 'Last scan',
        'panel.never': 'not scanned yet',
        'panel.scanning': 'scanning…',
        'panel.scan': 'Scan devices',
        'panel.refresh': 'Refresh status',
        'panel.empty': 'No device has been fetched in this session yet.',
        'panel.emptyHint': 'Scanning runs on the host: USB + configured CIDRs + Tailscale.',
        'panel.noDevice': 'The host has no known devices yet — try Scan devices.',
        'panel.devices': 'devices',
        'panel.channels': 'channels',
        'filter.all': 'All',
        'filter.usb': 'USB',
        'filter.lan': 'WiFi',
        'filter.tailscale': 'Tail',
        'filter.offline': 'Issues',
        'row.select': 'Select device',
        'row.blockedError': 'This device is unavailable and cannot be selected',
        'row.blockedUnknown': 'No state collected for this device yet — scan first',
        'row.copy': 'Copy connect command',
        'row.copied': 'copied',
        'row.stale': 'stale',
        'panel.crash': 'Device panel failed to render',
        'screen.on': 'screen on',
        'screen.off': 'screen off',
        'screen.unknown': 'screen ?',
        'lock.locked': 'locked',
        'lock.unlocked': 'unlocked',
        'lock.unknown': 'lock ?',
        'battery.unknown': 'battery ?',
        'stay.on': 'stay awake',
        'stay.off': 'no stay-awake',
        'footer.selectAll': 'Select all',
        'footer.selected': '{count} selected',
        'footer.template': 'Template',
        'template.default': 'One summary',
        'template.brief': 'One line each',
        'template.perDevice': 'One per device',
        'footer.mode': 'Delivery',
        'mode.queue': 'Queue',
        'mode.steer': 'Steer',
        'footer.target': 'Debug target',
        'footer.targetPlaceholder': 'e.g. login page rework',
        'footer.fill': 'Fill composer',
        'footer.queue': 'Send to session',
        'footer.copy': 'Copy text',
        'footer.doctor': 'Self-check',
        'hint.notConnected': 'Host connection unavailable; panel is read-only.',
        'hint.error': 'Host call failed: {message}',
        'hint.noSelection': 'Select at least one device first.',
        'hint.filled': 'Inserted into the composer — edit and send.',
        'hint.queued': 'Delivered {count} message(s) to this session ({mode}).',
        'hint.none': 'No device to inject; scan first.',
        'hint.noDraft': 'Composer unavailable; copied to clipboard instead.',
        'hint.copied': 'Copied to clipboard.',
        'hint.copiedAll': 'Nothing selected — copied the debug text for all {count} devices.',
      },
    };

    const FILTERS = ['all', 'usb', 'lan', 'tailscale', 'offline'];
    const TONE = { ok: 'ok', degraded: 'warn', error: 'error', unknown: 'muted' };

    // 只用宿主已声明的主题令牌（--dsw-alias-* / --dsw-specific-* / --dsw-elevation-*），
    // 每个可能缺失的令牌都带兜底值，保证亮/暗两套主题都可读。
    //
    // 面板底色不能直接用 --dsw-specific-menu：那是带 alpha 的菜单色，宿主自己配
    // backdrop-filter 才敢浮在正文上。插件面板没有底衬，直接吃这个色会把聊天正文
    // 透出来压花 adb 列表（2026-11-25 真机）。做法是先用不透明的主题底色铺实底，
    // 再把菜单色作为渐变叠在上层——观感跟宿主菜单一致，但保证不透。
    const STYLE = `
.dm-root{position:relative;display:inline-flex}
.dm-trigger{position:relative;width:28px;height:28px;display:inline-flex;align-items:center;justify-content:center;
  border:none;border-radius:14px;background:transparent;color:var(--dsw-alias-label-secondary);cursor:pointer;padding:0}
.dm-trigger:hover{background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary)}
.dm-trigger:focus-visible{outline:2px solid var(--dsw-focus-ring-color,var(--dsw-alias-brand-primary));outline-offset:1px}
.dm-trigger[data-open="true"]{background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary)}
.dm-badge{position:absolute;right:-2px;bottom:-2px;min-width:13px;height:13px;padding:0 3px;border-radius:7px;
  font-size:9px;line-height:13px;text-align:center;background:var(--dsw-alias-state-success-primary);color:var(--dsw-alias-bg-base)}
.dm-badge[data-tone="warn"]{background:var(--dsw-alias-state-warn-primary)}
.dm-badge[data-tone="error"]{background:var(--dsw-alias-state-error-primary)}
.dm-panel{position:fixed;inset:auto;top:52px;right:16px;width:min(378px,calc(100vw - 24px));max-height:min(560px,72vh);display:flex;flex-direction:column;
  background-color:var(--dsw-alias-bg-base,#fff);
  background-image:linear-gradient(var(--dsw-specific-menu,var(--dsw-alias-bg-overlay)),var(--dsw-specific-menu,var(--dsw-alias-bg-overlay)));
  border:1px solid var(--dsw-alias-border-l1);border-radius:16px;
  box-shadow:var(--dsw-elevation-prominent,0 12px 32px rgba(0,0,0,.24));color:var(--dsw-alias-label-primary);font-size:13px;overflow:hidden;z-index:1000}
.dm-head{display:flex;flex-direction:column;gap:6px;padding:10px 12px 8px;border-bottom:1px solid var(--dsw-alias-border-l1)}
.dm-title{display:flex;align-items:center;justify-content:space-between;gap:8px;font-weight:600}
.dm-meta{display:flex;flex-wrap:wrap;gap:6px;color:var(--dsw-alias-label-secondary);font-size:11px}
.dm-chip{padding:1px 6px;border-radius:7px;background:var(--dsw-alias-bg-layer-2)}
.dm-actions{display:flex;gap:6px}
.dm-btn{border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-secondary);
  border-radius:8px;padding:3px 9px;font-size:12px;cursor:pointer;white-space:nowrap;flex:none}
.dm-btn:hover:not(:disabled){background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary)}
.dm-btn:focus-visible{outline:2px solid var(--dsw-focus-ring-color,var(--dsw-alias-brand-primary))}
.dm-btn:disabled{opacity:.5;cursor:default}
.dm-btn[data-primary="true"]{background:var(--dsw-alias-brand-primary);border-color:transparent;color:var(--dsw-alias-bg-base)}
.dm-filters{display:flex;gap:4px;padding:6px 12px;border-bottom:1px solid var(--dsw-alias-border-l1)}
.dm-filter{border:none;background:transparent;color:var(--dsw-alias-label-secondary);border-radius:7px;padding:3px 8px;font-size:12px;cursor:pointer;white-space:nowrap}
.dm-filter[data-active="true"]{background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary)}
.dm-list{flex:1;overflow:auto;padding:4px 6px}
.dm-device{display:flex;gap:8px;padding:8px;border-radius:10px}
.dm-device:hover{background:var(--dsw-alias-bg-layer-1)}
.dm-check{margin-top:3px;width:14px;height:14px;flex:none;accent-color:var(--dsw-alias-brand-primary);cursor:pointer}
.dm-main{flex:1;min-width:0;display:flex;flex-direction:column;gap:3px}
.dm-name{display:flex;align-items:center;gap:6px;font-weight:600}
.dm-dot{width:7px;height:7px;border-radius:50%;flex:none;background:var(--dsw-alias-state-idle-primary)}
.dm-dot[data-tone="ok"]{background:var(--dsw-alias-state-success-primary)}
.dm-dot[data-tone="warn"]{background:var(--dsw-alias-state-warn-primary)}
.dm-dot[data-tone="error"]{background:var(--dsw-alias-state-error-primary)}
.dm-sub{color:var(--dsw-alias-label-secondary);font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dm-tags{display:flex;flex-wrap:wrap;gap:4px}
.dm-tag{font-size:10px;padding:1px 5px;border-radius:6px;background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-secondary)}
.dm-tag[data-tone="ok"]{background:var(--dsw-alias-state-success-primary);color:var(--dsw-alias-bg-base)}
.dm-tag[data-tone="warn"]{background:var(--dsw-alias-state-warn-primary);color:var(--dsw-alias-bg-base)}
.dm-tag[data-tone="error"]{background:var(--dsw-alias-state-error-primary);color:var(--dsw-alias-bg-base)}
.dm-copy{border:none;background:transparent;color:var(--dsw-alias-brand-primary);font-size:11px;cursor:pointer;padding:0;align-self:flex-start}
.dm-empty{padding:22px 16px;display:flex;flex-direction:column;align-items:center;gap:10px;text-align:center;color:var(--dsw-alias-label-secondary)}
.dm-foot{display:flex;flex-direction:column;gap:8px;padding:8px 12px 10px;border-top:1px solid var(--dsw-alias-border-l1)}
.dm-line{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.dm-line[data-right="true"]{justify-content:flex-end}
/* 输入框独占一行：378px 的面板里塞下输入框 + 三个按钮必然错位换行（2026-11-25 真机
   「复制文本」被单独挤到第三行）。basis 100% 让它自己一行，按钮组整体换到下一行。 */
.dm-input{flex:1 1 100%;min-width:0;border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-1);
  color:var(--dsw-alias-label-primary);border-radius:8px;padding:4px 8px;font-size:12px}
.dm-input:focus-visible{outline:2px solid var(--dsw-focus-ring-color,var(--dsw-alias-brand-primary))}
.dm-select{border:1px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-secondary);
  border-radius:8px;padding:3px 6px;font-size:12px;white-space:nowrap;flex:none;max-width:100%}
.dm-hint{font-size:11px;color:var(--dsw-alias-label-secondary);min-height:14px;white-space:pre-wrap}
.dm-hint[data-tone="error"]{color:var(--dsw-alias-state-error-primary)}
.dm-hint[data-tone="ok"]{color:var(--dsw-alias-state-success-primary)}
.dm-count{font-size:11px;color:var(--dsw-alias-label-secondary);margin-left:auto;flex:none}
`;

    function Icon() {
      return h('svg', { width: 16, height: 16, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true },
        h('rect', { x: 3.25, y: 1.75, width: 9.5, height: 12.5, rx: 2.25, stroke: 'currentColor', strokeWidth: 1 }),
        h('path', { d: 'M6.6 11.9h2.8', stroke: 'currentColor', strokeWidth: 1, strokeLinecap: 'round' }),
        h('path', { d: 'M12.7 3.5c1.1.7 1.9 1.7 2.3 2.8', stroke: 'currentColor', strokeWidth: 1, strokeLinecap: 'round' }));
    }

    function makeTr(localeService, fallbackLocale) {
      const readDict = () => {
        let id = fallbackLocale ?? 'zh';
        try { id = localeService?.getLocale?.()?.active ?? id; } catch { /* 用兜底 */ }
        const base = String(id).toLowerCase().startsWith('zh') ? DICTS.zh : DICTS.en;
        return base;
      };
      return (key, vars) => {
        let text = readDict()[key] ?? DICTS.en[key] ?? key;
        if (vars) {
          for (const [name, value] of Object.entries(vars)) {
            text = text.split(`{${name}}`).join(String(value));
          }
        }
        return text;
      };
    }

    function factTags(device, tr) {
      const facts = device.facts ?? {};
      const tags = [{
        key: 'screen',
        text: tr(`screen.${facts.screen === 'on' || facts.screen === 'off' ? facts.screen : 'unknown'}`),
        tone: facts.screen === 'on' ? 'ok' : 'muted',
      }, {
        key: 'lock',
        text: facts.locked === true ? tr('lock.locked') : facts.locked === false ? tr('lock.unlocked') : tr('lock.unknown'),
        tone: facts.locked === true ? 'warn' : 'muted',
      }, {
        key: 'battery',
        text: facts.battery == null ? tr('battery.unknown') : `${facts.battery}%${facts.powerSource ? `·${facts.powerSource}` : ''}`,
        tone: facts.battery != null && facts.battery <= 15 ? 'warn' : 'muted',
      }, {
        key: 'stay',
        text: facts.stayAwake ? tr('stay.on') : tr('stay.off'),
        tone: facts.stayAwake ? 'ok' : 'muted',
      }];
      if (facts.foreground && !facts.foreground.systemUi && facts.foreground.package) {
        tags.push({ key: 'fg', text: facts.foreground.package, tone: 'muted' });
      }
      return tags;
    }

    function DeviceRow(props) {
      const { device, tr, checked, onToggle, onCopy, copied } = props;
      const command = device.transports?.[0]?.connectCommand;
      const blocked = device.health === 'error' || device.health === 'unknown';
      // 选不上的时候必须说清为什么（unauthorized / offline / 缓存过期），
      // 否则只剩一个灰点，用户只能猜。adb 的状态词保持原文，那是排查用的关键信息。
      const transportStates = (device.transports ?? [])
        .map((transport) => `${transport.label ?? transport.kind} ${transport.state ?? '?'}`).join('，');
      const blockedReason = blocked
        ? `${tr(device.health === 'error' ? 'row.blockedError' : 'row.blockedUnknown')}${transportStates ? `（${transportStates}）` : ''}`
        : undefined;
      return h('div', { className: 'dm-device', role: 'listitem' },
        h('input', {
          className: 'dm-check',
          type: 'checkbox',
          'aria-label': tr('row.select'),
          title: blockedReason,
          checked,
          disabled: blocked,
          onChange: () => onToggle(device.serial),
        }),
        h('div', { className: 'dm-main' },
          h('div', { className: 'dm-name' },
            h('span', { className: 'dm-dot', 'data-tone': TONE[device.health] ?? 'muted' }),
            h('span', {}, `${device.model}${device.android ? ` · Android ${device.android}` : ''}`),
            device.stale ? h('span', { className: 'dm-tag', 'data-tone': 'warn' }, tr('row.stale')) : null),
          h('div', { className: 'dm-sub' }, device.serial),
          h('div', { className: 'dm-tags' },
            (device.transports ?? []).map((transport) => h('span', {
              key: transport.key ?? transport.endpoint,
              className: 'dm-tag',
              'data-tone': transport.state === 'device' ? 'ok' : transport.state === 'unauthorized' ? 'error' : 'muted',
            }, `${transport.label ?? transport.kind} ${transport.endpoint}${transport.state === 'device' ? '' : ` · ${transport.state}`}`)),
            ...factTags(device, tr).map((tag) => h('span', { key: tag.key, className: 'dm-tag', 'data-tone': tag.tone }, tag.text))),
          command ? h('button', {
            className: 'dm-copy',
            type: 'button',
            onClick: () => onCopy(command),
          }, copied === command ? tr('row.copied') : tr('row.copy')) : null));
    }

    /**
     * 面板的错误边界：面板里任何一处渲染抛异常，都只让面板自己降级成一行错误，
     * 绝不能把顶栏图标一起带走（用户就再也点不开了）。
     */
    class PanelBoundary extends React.Component {
      constructor(props) {
        super(props);
        this.state = { error: null };
      }

      static getDerivedStateFromError(error) {
        return { error };
      }

      componentDidCatch(error) {
        try { console.error('[dsh-device-manager] 设备面板渲染失败', error); } catch { /* 宿主可能不吃 console */ }
      }

      render() {
        if (!this.state.error) return this.props.children;
        const tr = typeof this.props.tr === 'function' ? this.props.tr : (key) => key;
        const detail = String(this.state.error?.message ?? this.state.error ?? 'unknown');
        const text = tr('panel.crash');
        return h('div', { className: 'dm-panel', role: 'dialog', tabIndex: -1 },
          h('div', { className: 'dm-hint', 'data-tone': 'error' },
            `${text === 'panel.crash' ? '设备面板渲染失败' : text}：${detail}`),
          h('button', {
            type: 'button',
            className: 'dm-btn',
            onClick: () => this.setState({ error: null }),
          }, '重试 / Retry'));
      }
    }

    /** portal 可用就挂到 body，不可用就在原地渲染——两条路都不能抛异常。 */
    function renderPanel(node) {
      if (createPortal) {
        try { return createPortal(node, document.body); } catch { /* 退回原地渲染 */ }
      }
      return node;
    }

    function Panel(props) {
      const { call, tr, sessionId, inputActions, panelRef, onClose } = props;
      const [snapshot, setSnapshot] = useState(null);
      const [busy, setBusy] = useState('');
      const [hint, setHint] = useState(null);
      const [selected, setSelected] = useState(() => new Set());
      const [filter, setFilter] = useState('all');
      const [template, setTemplate] = useState('default');
      const [mode, setMode] = useState('queue');
      const [target, setTarget] = useState('');
      const [copied, setCopied] = useState('');
      // tr / inputActions 每次渲染都是新引用，放进 ref 里读，避免把它们写进 useCallback 依赖
      // 造成 useEffect 反复重建定时器（进而每次渲染都重跑首屏扫描）。
      const trRef = useRef(tr);
      trRef.current = tr;
      const actionsRef = useRef(inputActions);
      actionsRef.current = inputActions;
      const aliveRef = useRef(true);
      const autoScanned = useRef(false);
      const inFlight = useRef(false);
      useEffect(() => () => { aliveRef.current = false; }, []);

      const call2 = useCallback(async (action, payload) => {
        setBusy(action);
        inFlight.current = true;
        const result = await call(action, { ...payload, sessionId });
        inFlight.current = false;
        if (!aliveRef.current) return null;
        setBusy('');
        if (!result.ok) {
          setHint({ tone: 'error', text: trRef.current('hint.error', { message: result.error ?? 'unknown' }) });
          return null;
        }
        const envelope = result.value ?? {};
        // 统一信封：{ok, text, data}。data 里是各动作的载荷（快照 / 模板文本 / 投递回执），
        // 之前只取 data 会把 text 丢掉，导致"填入输入框"拿到空文本。
        const body = envelope.data ?? {};
        const merged = { ...body, text: envelope.text, ok: envelope.ok !== false };
        const snapshotData = body.snapshot ?? (body.devices || body.counts ? body : null);
        // 合并而不是整体替换：只读刷新回来的对象没有 lastScanAt/adbPath，
        // 整体替换会让面板半小时后显示"尚未扫描 / adb -"。
        if (snapshotData) setSnapshot((prev) => ({ ...(prev ?? {}), ...snapshotData }));
        return merged;
      }, [call, sessionId]);

      useEffect(() => {
        let cancelled = false;
        const first = async () => {
          const data = await call2('list', {});
          if (cancelled) return;
          // R2：还没有任何已知设备 → 首屏自动扫一次；每次打开只试一次，失败不循环重试。
          if (!autoScanned.current && !(data?.devices?.length > 0)) {
            autoScanned.current = true;
            await call2('scan', {});
          }
        };
        first();
        // 手动 scan 或上一轮 status 还在飞的时候跳过这一 tick：
        // 否则两轮请求交叠，busy 会被后回来的那一轮提前清空，面板显示也会跳。
        const timer = setInterval(() => { if (!cancelled && !inFlight.current) call2('status', {}); }, PANEL_MS);
        return () => { cancelled = true; clearInterval(timer); };
      }, [call2]);

      const devices = useMemo(() => {
        const all = snapshot?.devices ?? [];
        if (filter === 'all') return all;
        if (filter === 'offline') return all.filter((d) => d.health === 'error' || d.health === 'unknown');
        return all.filter((d) => (d.kinds ?? []).includes(filter));
      }, [snapshot, filter]);

      const selectable = devices.filter((d) => d.health === 'ok' || d.health === 'degraded');
      // 勾选跨筛选保留：勾完再切 filter，不能把看不见的设备悄悄从消息里丢掉
      const chosen = [...selected].filter((serial) => (snapshot?.devices ?? []).some((d) => d.serial === serial));

      const toggle = (serial) => setSelected((current) => {
        const next = new Set(current);
        if (next.has(serial)) next.delete(serial); else next.add(serial);
        return next;
      });

      const copy = async (text) => {
        try {
          await navigator.clipboard.writeText(text);
          setCopied(text);
          setTimeout(() => { if (aliveRef.current) setCopied(''); }, 1500);
          return true;
        } catch {
          return false;
        }
      };

      const compose = () => call2('compose', {
        serials: chosen.length ? chosen : undefined,
        template,
        target: target || undefined,
      });

      const fill = async () => {
        if (busy) return;
        if (!chosen.length) { setHint({ tone: 'error', text: tr('hint.noSelection') }); return; }
        const composed = await compose();
        if (!aliveRef.current) return;
        const text = composed?.text;
        if (!text) { setHint({ tone: 'error', text: tr('hint.none') }); return; }
        // 顺序很重要：setDraft 的契约是"整段替换草稿、并清掉引用芯片"，
        // 先用它会把用户已写的内容静默抹掉；先走追加语义的 insertText。
        const actions = actionsRef.current;
        if (typeof actions?.insertText === 'function' && typeof actions?.captureInsertion === 'function') {
          const inserted = actions.insertText(text, actions.captureInsertion());
          // insertText 返回 false 表示草稿已变/提交锁定，不能当成功报
          if (inserted !== false) {
            setHint({ tone: 'ok', text: tr('hint.filled') });
            onClose();
            return;
          }
        }
        if (typeof actions?.setDraft === 'function') {
          actions.setDraft(text);
          if (typeof actions.persistDraft === 'function') actions.persistDraft();
          setHint({ tone: 'ok', text: tr('hint.filled') });
          onClose();
          return;
        }
        if (await copy(text)) setHint({ tone: 'ok', text: tr('hint.noDraft') });
      };

      const send = async () => {
        if (busy) return;
        const serials = [...chosen];
        if (!serials.length) { setHint({ tone: 'error', text: tr('hint.noSelection') }); return; }
        const data = await call2('inject', { serials, template, target: target || undefined, mode });
        if (!aliveRef.current) return;
        // call2 已经把 Host 侧 ok:false 转成红色提示了，这里只报成功条数
        if (data) setHint({ tone: 'ok', text: tr('hint.queued', { count: data.receipts?.length ?? serials.length, mode: tr(`mode.${mode}`) }) });
      };

      const copyAll = async () => {
        const serials = [...chosen];
        const composed = await compose(serials);
        if (!aliveRef.current) return;
        if (!composed?.text) return;
        if (await copy(composed.text)) {
          setHint({
            tone: 'ok',
            // 没勾选时复制的是"全部可用设备"，必须说出来，不能让用户以为只复制了勾选项
            text: serials.length ? tr('hint.copied') : tr('hint.copiedAll', { count: snapshot?.devices?.length ?? 0 }),
          });
        }
      };

      useEffect(() => {
        const node = panelRef?.current;
        if (!node) return undefined;
        // 打开即聚焦：portal 到 body 末尾的面板否则要 Tab 完整页才能到达；
        // 卸载时把焦点还给触发按钮，不让键盘焦点掉在 body 上。
        const previous = document.activeElement;
        if (typeof node.focus === 'function') node.focus({ preventScroll: true });
        // 只处理落在面板内的 Escape，且不做 preventDefault：
        // 面板是非模态的，宿主自己的 Escape（关命令面板、收起输入框）必须照常工作。
        const onKeyDown = (event) => {
          if (event.key !== 'Escape' || event.defaultPrevented) return;
          if (!node.contains(event.target)) return;
          event.stopPropagation();
          onClose();
        };
        node.addEventListener('keydown', onKeyDown);
        return () => {
          node.removeEventListener('keydown', onKeyDown);
          if (previous && previous !== document.body && typeof previous.focus === 'function') previous.focus();
        };
      }, [onClose, panelRef]);

      const counts = snapshot?.counts ?? {};
      const lastScanAt = snapshot?.lastScanAt ?? 0;
      const timeText = lastScanAt
        ? new Date(lastScanAt).toLocaleTimeString(undefined, { hour12: false })
        : tr('panel.never');
      const busyAny = Boolean(busy);

      return h('div', {
        className: 'dm-panel',
        ref: panelRef ?? undefined,
        role: 'dialog',
        'aria-modal': false,
        'aria-label': tr('panel.title'),
        tabIndex: -1,
        onClick: (event) => event.stopPropagation(),
      },
        h('style', { dangerouslySetInnerHTML: { __html: STYLE } }),

        h('div', { className: 'dm-head' },
          h('div', { className: 'dm-title' },
            h('span', {}, tr('panel.title')),
            h('div', { className: 'dm-actions' },
              h('button', {
                className: 'dm-btn', type: 'button', 'data-primary': 'true', disabled: busyAny,
                onClick: () => call2('scan', {}),
              }, busy === 'scan' ? tr('panel.scanning') : tr('panel.scan')),
              h('button', {
                className: 'dm-btn', type: 'button', disabled: busyAny, onClick: () => call2('status', {}),
              }, tr('panel.refresh')),
              h('button', { className: 'dm-btn', type: 'button', disabled: busyAny, onClick: () => call2('doctor', {}) }, tr('footer.doctor')))),
          h('div', { className: 'dm-meta' },
            h('span', { className: 'dm-chip' }, `${tr('panel.host')} ${snapshot?.hostName ?? '-'}`),
            h('span', { className: 'dm-chip' }, `${tr('panel.adb')} ${snapshot?.adbPath ? String(snapshot.adbPath).split(/[\\/]/).pop() : '-'}`),
            h('span', { className: 'dm-chip' }, `${tr('panel.lastScan')} ${timeText}`),
            counts.total != null
              ? h('span', { className: 'dm-chip' }, `${counts.total} ${tr('panel.devices')} / ${counts.transports ?? 0} ${tr('panel.channels')}`)
              : null)),

        h('div', { className: 'dm-filters' },
          FILTERS.map((key) => h('button', {
            key,
            type: 'button',
            className: 'dm-filter',
            'data-active': filter === key ? 'true' : 'false',
            onClick: () => setFilter(key),
          }, tr(`filter.${key}`)))),

        devices.length === 0
          ? h('div', { className: 'dm-empty' },
              h('div', {}, tr(snapshot ? 'panel.noDevice' : 'panel.empty')),
              h('div', { className: 'dm-hint' }, tr('panel.emptyHint')),
              h('button', {
                className: 'dm-btn', type: 'button', 'data-primary': 'true', disabled: busyAny,
                onClick: () => call2('scan', {}),
              }, busy === 'scan' ? tr('panel.scanning') : tr('panel.scan')),
              snapshot ? null : h('div', { className: 'dm-hint', 'data-tone': 'error' }, tr('hint.notConnected')))
          : h('div', { className: 'dm-list', role: 'list' },
              devices.map((device) => h(DeviceRow, {
                key: device.serial,
                device,
                tr,
                checked: selected.has(device.serial),
                onToggle: toggle,
                onCopy: copy,
                copied,
              }))),

        h('div', { className: 'dm-foot' },
          h('div', { className: 'dm-line' },
            h('button', {
              className: 'dm-btn',
              type: 'button',
              onClick: () => setSelected((current) => {
                const next = new Set(current);
                const allOn = selectable.length > 0 && selectable.every((d) => next.has(d.serial));
                if (allOn) selectable.forEach((d) => next.delete(d.serial));
                else selectable.forEach((d) => next.add(d.serial));
                return next;
              }),
            }, tr('footer.selectAll')),
            h('select', {
              className: 'dm-select',
              'aria-label': tr('footer.template'),
              value: template,
              onChange: (event) => setTemplate(event.target.value),
            }, ['default', 'brief', 'perDevice'].map((key) => h('option', { key, value: key }, tr(`template.${key}`)))),
            h('select', {
              className: 'dm-select',
              'aria-label': tr('footer.mode'),
              value: mode,
              onChange: (event) => setMode(event.target.value),
            }, ['queue', 'steer'].map((key) => h('option', { key, value: key }, tr(`mode.${key}`)))),
            h('span', { className: 'dm-count' }, tr('footer.selected', { count: chosen.length }))),
          h('div', { className: 'dm-line' },
            h('input', {
              className: 'dm-input',
              type: 'text',
              'aria-label': tr('footer.target'),
              placeholder: tr('footer.targetPlaceholder'),
              value: target,
              onChange: (event) => setTarget(event.target.value),
              onKeyDown: (event) => { if (event.key === 'Enter' && !busy) { event.preventDefault(); send(); } },
            })),
          h('div', { className: 'dm-line', 'data-right': 'true' },
            h('button', {
              className: 'dm-btn', type: 'button', 'data-primary': 'true', disabled: busyAny, onClick: fill,
            }, tr('footer.fill')),
            h('button', { className: 'dm-btn', type: 'button', disabled: busyAny, onClick: send }, tr('footer.queue')),
            h('button', { className: 'dm-btn', type: 'button', disabled: busyAny, onClick: copyAll }, tr('footer.copy'))),
          hint ? h('div', { className: 'dm-hint', 'data-tone': hint.tone }, hint.text) : null));
    }

    function Trigger(props) {
      const { call, tr, sessionId, inputActions } = props;
      const [open, setOpen] = useState(false);
      const [counts, setCounts] = useState(null);
      const rootRef = useRef(null);
      const panelRef = useRef(null);

      useEffect(() => {
        let cancelled = false;
        const tick = async () => {
          const result = await call('list', { sessionId });
          if (cancelled || !result?.ok) return;
          const value = result.value ?? {};
          const data = value.data ?? value.value ?? value;
          if (data?.counts) setCounts(data.counts);
        };
        tick();
        const timer = setInterval(tick, BADGE_MS);
        return () => { cancelled = true; clearInterval(timer); };
      }, [call, sessionId]);

      useEffect(() => {
        if (!open) return undefined;
        const onPointerDown = (event) => {
          const target = event.target;
          if (!(target instanceof Node)) return;
          // 面板 portal 到 body，不在触发器的子树里：两处都要算「内部点击」，
          // 否则勾一下复选框就会把整个面板关掉。
          if (rootRef.current?.contains(target)) return;
          if (panelRef.current?.contains(target)) return;
          setOpen(false);
        };
        document.addEventListener('pointerdown', onPointerDown, true);
        return () => document.removeEventListener('pointerdown', onPointerDown, true);
      }, [open]);

      let badge = null;
      if (counts) {
        const total = counts.total ?? 0;
        if (counts.error > 0) badge = { text: String(total), tone: 'error' };
        else if (counts.degraded > 0) badge = { text: String(total), tone: 'warn' };
        else if (total > 0) badge = { text: String(total), tone: 'ok' };
      }

      return h('div', { className: 'dm-root', ref: rootRef },
        h('button', {
          type: 'button',
          className: 'dm-trigger',
          'aria-label': tr('trigger.aria'),
          'aria-expanded': open,
          'aria-haspopup': 'dialog',
          'data-open': open ? 'true' : 'false',
          onClick: (event) => { event.stopPropagation(); setOpen((value) => !value); },
        },
          h(Icon),
          badge ? h('span', { className: 'dm-badge', 'data-tone': badge.tone }, badge.text) : null),
        open
          ? renderPanel(h(PanelBoundary, { tr }, h(Panel, {
              call, tr, sessionId, inputActions, panelRef, onClose: () => setOpen(false),
            })))
          : null);
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        const setup = () => {
        const locale = ctx.get?.('locale') ?? ctx.locale;
        const slots = ctx.get?.('slots') ?? ctx.slots;
        if (!slots?.inject || !slots?.register) return;

        const disposers = [];
        try {
          if (locale?.register) {
            for (const [id, dict] of Object.entries(DICTS)) {
              disposers.push(locale.register(NS, id, dict));
            }
          }
        } catch { /* 字典重复注册时忽略，面板仍可用内置文案 */ }

        const bound = typeof locale?.bind === 'function' ? locale.bind(NS) : null;
        const tr = makeTr(locale, 'zh');
        const translate = (key, vars) => {
          // 先问宿主：这样宿主语言包（含我们 register 进去的字典、以及用户自己覆盖的词条）能生效；
          // 内置字典只作兜底。反过来写会让宿主语言包永远命中不到。
          if (bound) {
            try {
              const hostText = bound(key, vars);
              if (typeof hostText === 'string' && hostText !== key) return hostText;
            } catch { /* 宿主 bind 不可用时用内置字典 */ }
          }
          return tr(key, vars);
        };

        const READ_ONLY = new Set(['list', 'status', 'doctor', 'history']);

        const unwrap = (data) => {
          const inner = data?.ok === true ? data.value : data;
          // Host 把 perform() 的结果包在 value 里；内层 ok:false 同样是失败，
          // 并把内层写给用户看的 text 当作错误文案（比裸错误码可读）。
          if ((data && data.ok === false) || (inner && inner.ok === false)) {
            const detail = (inner && inner.text)
              ?? (data && (data.error?.message ?? data.error))
              ?? (inner && (inner.error?.message ?? inner.error))
              ?? 'rpc-failed';
            return { ok: false, error: String(detail) };
          }
          return { ok: true, value: inner };
        };

        const call = async (action, payload) => {
          const body = { action, ...payload };
          // 自证：把每一次尝试的确切结果攒起来。之前所有失败都被压成 'no-transport'，
          // 用户只能看到"主机调用失败：no-transport"，谁都定位不了；现在直接报出去。
          const trace = [];
          // 数据面地址可覆盖：页面可能被端口转发/代理（例如 127.0.0.1:3083）提供，
          // 而 adb 跑在另一个 DSH 实例（例如 127.0.0.1:3080），那条代理不认我们自定的路径。
          // 在浏览器控制台里执行一次即可：
          //   localStorage.setItem('deviceManager.baseUrl', 'http://127.0.0.1:3080/adb-devices')
          let base = '/adb-devices';
          let crossOrigin = false;
          try {
            const override = typeof localStorage !== 'undefined' && localStorage.getItem(`${NS}.baseUrl`);
            if (override) { base = override.replace(/\/+$/, ''); crossOrigin = !override.startsWith('/'); }
          } catch { /* 隐私模式下 localStorage 不可用，用同源默认 */ }
          try {
            if (typeof fetch === 'function') {
              const serials = Array.isArray(body.serials) ? body.serials.join(',') : body.serials;
              const query = {};
              for (const [key, value] of Object.entries({ ...body, serials })) {
                if (value !== undefined && value !== null && value !== '') query[key] = String(value);
              }
              const read = READ_ONLY.has(action);
              const url = read
                ? `${base}/${action}?${new URLSearchParams(query).toString()}`
                : `${base}/${action}`;
              trace.push(`${read ? 'GET' : 'POST'} ${url}`);
              const response = await fetch(url, read
                ? { method: 'GET', credentials: crossOrigin ? 'include' : 'same-origin', cache: 'no-store' }
                : {
                  method: 'POST',
                  credentials: crossOrigin ? 'include' : 'same-origin',
                  headers: { 'content-type': 'application/json' },
                  body: JSON.stringify(body),
                });
              trace.push(`→ ${response.status}${response.statusText ? ` ${response.statusText}` : ''}`);
              if (response.ok) return unwrap(await response.json());
              if (response.status !== 401 && response.status !== 404) {
                const head = (await response.text().catch(() => '')).slice(0, 160).replace(/\s+/g, ' ');
                return { ok: false, error: `HTTP ${response.status}${head ? ` ${head}` : ''}（${trace.join(' ')}）` };
              }
            } else {
              trace.push('fetch=不可用');
            }
          } catch (error) {
            trace.push(`抛出 ${error?.name ?? 'Error'}: ${String(error?.message ?? error).slice(0, 140)}`);
          }

          // 2) Typert remote 兜底（本部署若已暴露 deviceManager 门面则用它）。
          const remote = ctx.get?.('remote') ?? ctx.remote;
          const face = remote?.deviceManager ?? remote?.['device-manager'];
          if (face && typeof face.call === 'function') {
            try {
              return unwrap(await face.call(body));
            } catch (error) {
              trace.push(`remote 抛出 ${String(error?.message ?? error).slice(0, 80)}`);
            }
          } else {
            trace.push('remote 门面未声明');
          }
          const notFound = trace.some((line) => line.includes(' 404'));
          const hint = notFound
            ? `这个页面所在的地址（${typeof location === 'undefined' ? '?' : location.origin}）没有这条路由——多半它是由端口转发/代理提供的，只转了 SPA 与 /api。`
              + '两条路：① 直接打开跑 adb 的那个 DSH 实例地址再点图标；'
              + '② 在浏览器控制台执行 localStorage.setItem(\'deviceManager.baseUrl\', \'http://127.0.0.1:3080/adb-devices\') 后刷新（把端口换成你那个实例的）。'
            : '';
          return { ok: false, error: `${hint || '无可用通道 '}${trace.join(' ｜ ')}（页面 ${typeof location === 'undefined' ? '?' : location.origin}）` };
        };

        // translate 每次渲染都新建会让 Panel 的 useCallback/useEffect 反复重建轮询，
        // 这里按宿主 t 的引用缓存一个稳定包装（locale.bind 返回的函数引用是按命名空间稳定的）。
        let cachedHostT;
        let cachedWrapper;
        const stableTr = (hostT) => {
          if (cachedHostT === hostT && cachedWrapper) return cachedWrapper;
          cachedHostT = hostT;
          cachedWrapper = typeof hostT === 'function'
            ? (key, vars) => {
              try {
                const text = hostT(key, vars);
                if (typeof text === 'string' && text !== key && !text.startsWith(`${NS}.`)) return text;
              } catch { /* 退回内置字典 */ }
              return translate(key, vars);
            }
            : translate;
          return cachedWrapper;
        };

        const disposeInject = slots.inject('conversation.session.header.utilities', () => slots.register({
          name: 'conversation.session.header.utilities',
          id: 'device-manager',
          order: 6,
          label: () => translate('trigger.aria'),
          locale: NS,
        }, (props) => h(Trigger, {
          ...props,
          call,
          tr: stableTr(props.t),
        })));
        if (typeof disposeInject === 'function') disposers.push(disposeInject);

        return () => {
          for (const dispose of disposers) {
            try { dispose?.(); } catch { /* 忽略 */ }
          }
        };
        };

        if (typeof ctx.effect === 'function') ctx.effect(setup);
        else return setup();
      },
    };
  },
});
