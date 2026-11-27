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
    // React.memo 让内容没变的设备行整行跳过重渲染。老版本宿主没有 memo 就退化成原组件，
    // 只是少一层优化，不会白屏。
    const memo = typeof React.memo === 'function' ? React.memo : (component) => component;

    const NS = 'deviceManager';
    /**
     * 轮询间隔优先取服务端下发的 `data.poll.panelMs / badgeMs`（Host 侧统一下发，
     * 避免前后端各写一份节奏），这两个常量只是**读不到时的兜底**。
     *
     * 之前是 3000 / 20000 且写死：3 秒一次的后台刷新走的是会 setBusy 的 call2，
     * 而面板里所有按钮都 `disabled: busyAny`，于是每 3 秒全部按钮被禁用再恢复一遍
     * ——用户抱怨的「每 3 秒闪一下」就是这个。现在后台刷新走 silent（不碰 busy），
     * 间隔也回到 60s / 30s 的量级。
     */
    const PANEL_MS = 60000;
    const BADGE_MS = 30000;
    const MIN_PANEL_MS = 5000;
    const MIN_BADGE_MS = 10000;
    // 别名的硬限制：与 Host 侧 `name` 动作的校验保持一致（超出的部分客户端先夹掉并提示）。
    const ALIAS_MAX = 6;
    const ALIAS_MAX_LEN = 40;
    const NO_DEVICES = [];
    const ALIAS_SEPARATOR = /[,，、;；\n]/;

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
        'row.rename': '命名',
        'row.rename.aria': '为 {model} 设置别名',
        'alias.placeholder': '小米13、备用机',
        'alias.aria': '{model} 的别名，用逗号或顿号分隔，Enter 保存，Esc 取消',
        'alias.help': '逗号分隔，最多 6 个',
        'alias.saved': '名称已更新。',
        'alias.tooMany': '最多 {max} 个别名，已保留前 {max} 个。',
        'alias.tooLong': '单个别名最长 {max} 个字符，已截断。',
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
        'row.rename': 'Name',
        'row.rename.aria': 'Set aliases for {model}',
        'alias.placeholder': 'Xiaomi 13, backup',
        'alias.aria': 'Aliases for {model}, separated by commas. Enter to save, Esc to cancel',
        'alias.help': 'Comma separated, up to {max}',
        'alias.saved': 'Name updated.',
        'alias.tooMany': 'Up to {max} aliases — kept the first {max}.',
        'alias.tooLong': 'Each alias is limited to {max} characters — truncated.',
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
/* ── 别名（自定义设备名）────────────────────────────────────────────────
   用户嘴里说的是「小米13」，ro.product.model 给的是 2211133C 这种代号，两者对不上。
   有别名时主名比型号更醒目、型号退成灰色副标题，其余别名做成小的次要标签。
   只用 --dsw-alias-* 令牌 + 兜底，不写死颜色，亮/暗两套主题都得可读。 */
.dm-name{flex-wrap:wrap}
.dm-alias-name{font-weight:700;color:var(--dsw-alias-label-primary);max-width:180px;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dm-model{font-weight:400;color:var(--dsw-alias-label-secondary);font-size:12px;
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dm-alias-tag{font-size:10px;font-weight:400;padding:1px 5px;border-radius:6px;
  background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-secondary);
  max-width:110px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dm-rename{margin-left:auto;flex:none;border:none;background:transparent;
  color:var(--dsw-alias-label-secondary);font-size:11px;line-height:1.3;padding:1px 5px;
  border-radius:6px;cursor:pointer}
.dm-rename:hover{background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary)}
.dm-rename:focus-visible{outline:2px solid var(--dsw-focus-ring-color,var(--dsw-alias-brand-primary));outline-offset:1px}
.dm-alias-edit{display:flex;align-items:center;gap:6px;margin-top:2px}
.dm-alias-input{flex:1 1 auto;min-width:0;border:1px solid var(--dsw-alias-border-l2);
  background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);
  border-radius:8px;padding:3px 7px;font-size:12px}
.dm-alias-input:focus-visible{outline:2px solid var(--dsw-focus-ring-color,var(--dsw-alias-brand-primary))}
.dm-alias-help{flex:none;font-size:10px;color:var(--dsw-alias-label-secondary);white-space:nowrap}
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

    /** 服务端下发的间隔可能是 undefined / 字符串 / 0 / 负数，一律夹到合法区间，兜底用上默认值。 */
    function clampMs(value, fallback, min) {
      const num = Number(value);
      if (!Number.isFinite(num) || num <= 0) return fallback;
      return Math.max(min, Math.round(num));
    }

    /** document 可能不存在（SSR / 测试环境），取不到就当作可见，别让面板抛异常。 */
    function isPageHidden() {
      try {
        return typeof document !== 'undefined' && document.hidden === true;
      } catch {
        return false;
      }
    }

    /** 快照里的 aliases 可能是 undefined / null / 非数组 / 数组里混了非字符串，全部容错。 */
    function readAliases(value) {
      if (!Array.isArray(value)) return [];
      const out = [];
      const seen = new Set();
      for (const item of value) {
        let text = '';
        try {
          text = String(item ?? '').trim();
        } catch {
          continue;
        }
        if (!text || seen.has(text)) continue;
        seen.add(text);
        out.push(text);
      }
      return out;
    }

    /**
     * 输入框里的一行文本 → 规范化的别名整表。
     * 逗号 / 顿号 / 分号都当分隔符；trim、去空、去重（保留首次顺序）；
     * 单个超长截断、数量超限截断，把「截断过」回报给调用方去提示用户——
     * 直接整条拒绝会让人搞不清为什么保存不了。
     */
    function parseAliasesInput(text) {
      const parts = String(text ?? '').split(ALIAS_SEPARATOR);
      const names = [];
      const seen = new Set();
      let truncated = false;
      let overflow = false;
      for (const part of parts) {
        let value = part.trim().replace(/\s+/g, ' ');
        if (!value) continue;
        const chars = Array.from(value);
        if (chars.length > ALIAS_MAX_LEN) {
          value = chars.slice(0, ALIAS_MAX_LEN).join('');
          truncated = true;
        }
        if (seen.has(value)) continue;
        seen.add(value);
        if (names.length >= ALIAS_MAX) {
          overflow = true;
          continue;
        }
        names.push(value);
      }
      return { names, truncated, overflow };
    }

    /**
     * 设备行的「渲染指纹」。后台静默刷新每次都带回全新的对象，只要上屏的东西没变，
     * 就该让 React 跳过整行重渲染——这就是「每 3 秒闪一下」的另一半。
     *
     * 只收真正会渲染到行上的字段：facts 里不上屏的易变东西（factsAt、raw 文本、
     * 各种时间戳）一律不进指纹。但电量/亮屏/锁屏/常亮/前台**确实**渲染成标签，
     * 所以这几个必须进指纹（任务书里让排除 facts，照做会让后台刷新再也看不到状态变化，
     * 这里按「渲染字段」的口径取子集，只取 factTags 读的那几个）。
     */
    function deviceRenderKey(device) {
      if (!device || typeof device !== 'object') return '';
      const transports = Array.isArray(device.transports) ? device.transports : [];
      const transportText = transports
        .map((t) => `${t?.key ?? ''}|${t?.endpoint ?? ''}|${t?.state ?? ''}|${t?.label ?? t?.kind ?? ''}|${t?.connectCommand ?? ''}`)
        .join(',');
      const facts = (device.facts && typeof device.facts === 'object') ? device.facts : {};
      const foreground = (facts.foreground && typeof facts.foreground === 'object') ? facts.foreground : {};
      return [
        device.serial ?? '',
        device.model ?? '',
        device.android ?? '',
        device.health ?? '',
        device.stale ? '1' : '0',
        device.summary ?? '',
        readAliases(device.aliases).join('\u0001'),
        transportText,
        facts.screen ?? '',
        String(facts.locked),
        String(facts.battery),
        facts.powerSource ?? '',
        facts.stayAwake ? '1' : '0',
        foreground.systemUi ? '1' : '0',
        foreground.package ?? '',
      ].join('\u0000');
    }

    /** 内容比较：逐项同指纹就复用旧数组引用，让 memo 化的 DeviceRow 整列跳过渲染。 */
    function sameDevices(prev, next) {
      if (prev === next) return true;
      if (!Array.isArray(prev) || !Array.isArray(next)) return false;
      if (prev.length !== next.length) return false;
      for (let i = 0; i < prev.length; i += 1) {
        if (prev[i] === next[i]) continue;
        if (deviceRenderKey(prev[i]) !== deviceRenderKey(next[i])) return false;
      }
      return true;
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

    /**
     * 一行设备。memo 化 + 父层的内容比较指纹配合，后台静默刷新时内容没变就不重渲染。
     * 别名（自定义设备名）的编辑态放在行内：点「命名」只重渲染这一行，
     * 也不会把编辑状态提到 Panel 里让整列跟着刷。
     */
    const DeviceRow = memo(function DeviceRow(props) {
      const { device, tr, checked, onToggle, onCopy, copied, onRename, onHint } = props;
      const command = device.transports?.[0]?.connectCommand;
      const blocked = device.health === 'error' || device.health === 'unknown';
      // 选不上的时候必须说清为什么（unauthorized / offline / 缓存过期），
      // 否则只剩一个灰点，用户只能猜。adb 的状态词保持原文，那是排查用的关键信息。
      const transportStates = (device.transports ?? [])
        .map((transport) => `${transport.label ?? transport.kind} ${transport.state ?? '?'}`).join('，');
      const blockedReason = blocked
        ? `${tr(device.health === 'error' ? 'row.blockedError' : 'row.blockedUnknown')}${transportStates ? `（${transportStates}）` : ''}`
        : undefined;
      const aliases = readAliases(device.aliases);
      const primary = aliases[0];
      const rest = aliases.slice(1);
      const modelText = `${device.model ?? ''}${device.android ? ` · Android ${device.android}` : ''}`;
      const label = primary ?? device.serial ?? device.model ?? '';

      const [editing, setEditing] = useState(false);
      const [draft, setDraft] = useState('');
      const inputRef = useRef(null);
      const editRef = useRef(null);
      // Escape 会让 input 失焦并触发 onBlur；用一个标记掐掉那次「提交」，
      // 否则「取消」会悄悄变成「保存」。
      const skipBlur = useRef(false);
      const submittingRef = useRef(false);
      const aliveRef = useRef(true);
      useEffect(() => () => { aliveRef.current = false; }, []);

      // 进入编辑态把焦点送进输入框（键盘用户点完不用再去够鼠标）。
      useEffect(() => {
        if (!editing) return;
        try { inputRef.current?.focus?.(); } catch { /* 拿不到焦点不影响编辑 */ }
      }, [editing]);

      const openEdit = () => {
        skipBlur.current = false;
        setDraft(readAliases(device.aliases).join('、'));
        setEditing(true);
      };

      const closeEdit = (restoreFocus) => {
        setEditing(false);
        setDraft('');
        if (!restoreFocus) return;
        try { editRef.current?.focus?.(); } catch { /* 按钮可能已经不在了 */ }
      };

      const commit = async () => {
        if (submittingRef.current) return;
        const parsed = parseAliasesInput(draft);
        // 先收编辑态再发请求：请求在飞的时候这一行应该已经是「新名字」的样子，
        // 而不是一个卡住的输入框。失败由 hint 报出来，下次刷新回到服务端权威值。
        closeEdit(true);
        if (parsed.truncated) onHint({ tone: 'error', text: tr('alias.tooLong', { max: ALIAS_MAX_LEN }) });
        if (parsed.overflow) onHint({ tone: 'error', text: tr('alias.tooMany', { max: ALIAS_MAX }) });
        submittingRef.current = true;
        let ok = false;
        try {
          ok = (await onRename(device.serial, parsed.names)) === true;
        } catch {
          ok = false;
        }
        submittingRef.current = false;
        if (!aliveRef.current) return;
        if (ok && !parsed.truncated && !parsed.overflow) onHint({ tone: 'ok', text: tr('alias.saved') });
      };

      const onInputKeyDown = (event) => {
        if (event.key === 'Escape') {
          // 只拦住本面板自己的 Escape 处理（Panel 的监听挂在 panel 节点上冒泡），
          // 不 preventDefault：宿主的 Escape 语义（关命令面板、收起输入框）不受影响。
          event.stopPropagation();
          skipBlur.current = true;
          closeEdit(true);
          return;
        }
        if (event.key === 'Enter') {
          event.preventDefault();
          commit();
        }
      };

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
            // 有别名 → 「主名 + 灰色型号」；没别名 → 完全保持原样，老数据不降级。
            primary ? h('span', { className: 'dm-alias-name', title: label }, primary) : null,
            h('span', { className: primary ? 'dm-model' : undefined }, modelText),
            device.stale ? h('span', { className: 'dm-tag', 'data-tone': 'warn' }, tr('row.stale')) : null,
            rest.map((alias, index) => h('span', {
              key: `${index}:${alias}`, className: 'dm-alias-tag', title: alias,
            }, alias)),
            h('button', {
              ref: editRef,
              className: 'dm-rename',
              type: 'button',
              'aria-label': tr('row.rename.aria', { model: label }),
              title: tr('row.rename'),
              'aria-expanded': editing,
              onClick: openEdit,
            }, tr('row.rename'))),
          editing
            ? h('div', { className: 'dm-alias-edit' },
                h('input', {
                  ref: inputRef,
                  className: 'dm-alias-input',
                  type: 'text',
                  'aria-label': tr('alias.aria', { model: device.model ?? device.serial ?? '' }),
                  placeholder: tr('alias.placeholder'),
                  value: draft,
                  onChange: (event) => setDraft(event.target.value),
                  onKeyDown: onInputKeyDown,
                  onBlur: () => {
                    if (skipBlur.current) { skipBlur.current = false; return; }
                    commit();
                  },
                }),
                h('span', { className: 'dm-alias-help' }, tr('alias.help', { max: ALIAS_MAX })))
            : null,
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
    });

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
      const { call, tr, sessionId, inputActions, panelRef, onClose, onPollConfig } = props;
      // 轮询间隔由 Host 下发（data.poll.panelMs），Trigger 拿到后传进来；没到就用兜底值。
      const intervalMs = clampMs(props.panelMs, PANEL_MS, MIN_PANEL_MS);
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
      // 同理：onPollConfig 只在收到响应时读一次，不进 call2 的依赖，保持 call2 引用稳定，
      // 否则首屏 list + 自动扫描会被反复重跑。
      const onPollRef = useRef(onPollConfig);
      onPollRef.current = onPollConfig;
      const aliveRef = useRef(true);
      const autoScanned = useRef(false);
      const inFlight = useRef(false);
      // 内容没变时复用的 devices 数组引用（见 stableDevices）。
      const devicesRef = useRef(null);
      useEffect(() => () => { aliveRef.current = false; }, []);

      /**
       * @param {object} [options] `{ silent: true }` = 后台定时器驱动的刷新：
       *   **不碰 busy**。busy 会让面板里所有按钮 disabled 再恢复，3 秒一次就是用户看到的
       *   「每 3 秒闪一下」。静默刷新仍然要去重（inFlight）、仍然要判存活、失败仍然要报 hint。
       */
      const call2 = useCallback(async (action, payload, options) => {
        const silent = options?.silent === true;
        if (!silent) setBusy(action);
        inFlight.current = true;
        const result = await call(action, { ...payload, sessionId });
        inFlight.current = false;
        if (!aliveRef.current) return null;
        if (!silent) setBusy('');
        if (!result.ok) {
          setHint({ tone: 'error', text: trRef.current('hint.error', { message: result.error ?? 'unknown' }) });
          return null;
        }
        const envelope = result.value ?? {};
        // 统一信封：{ok, text, data}。data 里是各动作的载荷（快照 / 模板文本 / 投递回执），
        // 之前只取 data 会把 text 丢掉，导致"填入输入框"拿到空文本。
        const body = envelope.data ?? {};
        // 服务端下发的轮询节奏：{ panelMs, badgeMs }。Host 同事没加之前这里是 undefined，
        // 传下去会被 clampMs 兜底，行为等价于用常量。
        try { onPollRef.current?.(body?.poll); } catch { /* 节奏拿不到就用兜底常量 */ }
        const merged = { ...body, text: envelope.text, ok: envelope.ok !== false };
        const snapshotData = body.snapshot ?? (body.devices || body.counts ? body : null);
        // 合并而不是整体替换：只读刷新回来的对象没有 lastScanAt/adbPath，
        // 整体替换会让面板半小时后显示"尚未扫描 / adb -"。
        if (snapshotData) setSnapshot((prev) => ({ ...(prev ?? {}), ...snapshotData }));
        return merged;
      }, [call, sessionId]);

      // 首屏：读一次快照，还没有任何已知设备就自动扫一次。
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
        return () => { cancelled = true; };
      }, [call2]);

      // 后台刷新：间隔跟着服务端下发值走；页面不可见时不发请求（省 adb 调用，也避免
      // 切回标签页时看到一屏正在闪的按钮），重新可见立刻补一次静默刷新。
      useEffect(() => {
        let cancelled = false;
        const tick = () => {
          if (cancelled || inFlight.current) return;
          if (isPageHidden()) return;
          call2('status', {}, { silent: true });
        };
        const timer = setInterval(tick, intervalMs);
        const onVisibility = () => {
          if (cancelled || isPageHidden() || inFlight.current) return;
          call2('status', {}, { silent: true });
        };
        let hasDocument = false;
        try {
          hasDocument = typeof document !== 'undefined' && typeof document.addEventListener === 'function';
          if (hasDocument) document.addEventListener('visibilitychange', onVisibility);
        } catch { hasDocument = false; }
        return () => {
          cancelled = true;
          clearInterval(timer);
          if (hasDocument) {
            try { document.removeEventListener('visibilitychange', onVisibility); } catch { /* 忽略 */ }
          }
        };
      }, [intervalMs, call2]);

      /**
       * 静默刷新每次回来都是全新的 devices 数组，逐项内容相同也照样让整列重渲染——
       * 「闪」的另一半就在这。内容一致时返回旧引用，配合 memo 化的 DeviceRow
       * 让 React 整列跳过渲染。
       */
      const stableDevices = useMemo(() => {
        const next = Array.isArray(snapshot?.devices) ? snapshot.devices : NO_DEVICES;
        const prev = devicesRef.current;
        if (prev && sameDevices(prev, next)) return prev;
        devicesRef.current = next;
        return next;
      }, [snapshot]);

      const devices = useMemo(() => {
        if (filter === 'all') return stableDevices;
        if (filter === 'offline') return stableDevices.filter((d) => d?.health === 'error' || d?.health === 'unknown');
        return stableDevices.filter((d) => (d?.kinds ?? []).includes(filter));
      }, [stableDevices, filter]);

      const selectable = devices.filter((d) => d?.health === 'ok' || d?.health === 'degraded');
      // 勾选跨筛选保留：勾完再切 filter，不能把看不见的设备悄悄从消息里丢掉
      const chosen = [...selected].filter((serial) => (snapshot?.devices ?? []).some((d) => d?.serial === serial));

      // toggle / copy 必须是稳定引用，否则 memo 化的 DeviceRow 每轮都白 memo。
      const toggle = useCallback((serial) => setSelected((current) => {
        const next = new Set(current);
        if (next.has(serial)) next.delete(serial); else next.add(serial);
        return next;
      }), []);

      const copy = useCallback(async (text) => {
        try {
          await navigator.clipboard.writeText(text);
          setCopied(text);
          setTimeout(() => { if (aliveRef.current) setCopied(''); }, 1500);
          return true;
        } catch {
          return false;
        }
      }, []);

      /**
       * 改别名。`names` 是**整表替换**（空数组＝清空），走 Host 的 `name` 动作：
       *   call('name', { serials: [serial], names: [...], sessionId }) → {ok, text, data:{results:[{serial, ok, aliases}]}}
       * 成功后只本地更新这一台设备的 aliases（优先用 Host 回写的权威 results[].aliases，
       * 它已经过 NFKC 归一与跨设备查重；拿不到才回退到本地整表），不整块刷新：
       * 用户改完立刻看到新名字，也不会把列表的滚动位置刷掉。
       */
      const rename = useCallback(async (serial, names) => {
        if (!serial) return false;
        const wanted = Array.isArray(names) ? names : [];
        const result = await call2('name', { serials: [serial], names: wanted });
        if (!aliveRef.current || !result || result.ok === false) return false;
        // Host 是别名合法性的唯一权威（长度 / 数量 / 标点 / 撞名都在它那儿判）。
        const echoed = (Array.isArray(result.results) ? result.results : [])
          .find((row) => row?.serial === serial && row?.ok !== false);
        const finalAliases = readAliases(echoed?.aliases ?? wanted);
        setSnapshot((prev) => {
          if (!prev || !Array.isArray(prev.devices)) return prev;
          const next = prev.devices.map((device) => (
            device && device.serial === serial ? { ...device, aliases: finalAliases } : device
          ));
          devicesRef.current = next;
          return { ...prev, devices: next };
        });
        return true;
      }, [call2]);

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
              devices.map((device, index) => h(DeviceRow, {
                key: device?.serial ?? `row-${index}`,
                device: device ?? {},
                tr,
                checked: device ? selected.has(device.serial) : false,
                onToggle: toggle,
                onCopy: copy,
                onRename: rename,
                onHint: setHint,
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
      // Host 下发的轮询节奏 { panelMs, badgeMs }；没下发就用文件顶部的兜底常量。
      // 放在 Trigger 这一层：徽标轮询和面板轮询共用同一份节奏，也共用同一次 list 响应。
      const [poll, setPoll] = useState(null);
      const rootRef = useRef(null);
      const panelRef = useRef(null);

      const applyPoll = useCallback((next) => {
        if (!next || typeof next !== 'object') return;
        const panelMs = clampMs(next.panelMs, PANEL_MS, MIN_PANEL_MS);
        const badgeMs = clampMs(next.badgeMs, BADGE_MS, MIN_BADGE_MS);
        // 值没变就返回旧对象：否则每次静默刷新都会让 Trigger 重渲染一遍，
        // 面板里的焦点／滚动跟着受影响。
        setPoll((prev) => (prev && prev.panelMs === panelMs && prev.badgeMs === badgeMs ? prev : { panelMs, badgeMs }));
      }, []);

      const panelMs = poll?.panelMs;
      const badgeMs = clampMs(poll?.badgeMs, BADGE_MS, MIN_BADGE_MS);

      useEffect(() => {
        let cancelled = false;
        const tick = async () => {
          // 页面在后台标签页里就别打 adb 了，切回来会补一次。
          if (isPageHidden()) return;
          const result = await call('list', { sessionId });
          if (cancelled || !result?.ok) return;
          const value = result.value ?? {};
          const data = value.data ?? value.value ?? value;
          if (data?.poll) applyPoll(data.poll);
          if (data?.counts) {
            const next = data.counts;
            setCounts((prev) => {
              const same = prev
                && ['total', 'ok', 'degraded', 'error', 'unknown', 'transports']
                  .every((key) => prev[key] === next[key]);
              return same ? prev : next;
            });
          }
        };
        tick();
        const timer = setInterval(tick, badgeMs);
        const onVisibility = () => { if (!isPageHidden()) tick(); };
        let hasDocument = false;
        try {
          hasDocument = typeof document !== 'undefined' && typeof document.addEventListener === 'function';
          if (hasDocument) document.addEventListener('visibilitychange', onVisibility);
        } catch { hasDocument = false; }
        return () => {
          cancelled = true;
          clearInterval(timer);
          if (hasDocument) {
            try { document.removeEventListener('visibilitychange', onVisibility); } catch { /* 忽略 */ }
          }
        };
      }, [call, sessionId, badgeMs, applyPoll]);

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

      // 必须是稳定引用：Panel 的「打开即聚焦 / Escape」effect 把它列进了依赖，
      // 每次渲染都新建会让那个 effect 每轮重跑（焦点被抢回去、监听反复拆装）。
      const closePanel = useCallback(() => setOpen(false), []);

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
              call, tr, sessionId, inputActions, panelRef, onClose: closePanel, panelMs, onPollConfig: applyPoll,
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
          // Host 有两种包法：HTTP 是 `{ok, value:{ok, text, data}}`（外层 ok 由 handle() 按
          // 内层 ok 同步），RPC 门面可能直接给 `{ok, text, data}`。先把 value 拆开再看失败，
          // 否则外层 ok:false 时内层那句写给人看的 text 会被丢掉——别名被拒（撞名 / 超数量 /
          // 非法名）就只能看到干巴巴的 'rpc-failed'。
          const inner = (data && typeof data.value === 'object' && data.value !== null) ? data.value : data;
          if ((data && data.ok === false) || (inner && inner.ok === false)) {
            const detail = (inner && (inner.text ?? inner.error?.message ?? inner.error))
              ?? (data && (data.text ?? data.error?.message ?? data.error))
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
