# DSH 测试机管理面板（adb Device Manager）方案

> 目标：在 DSH Web UI 顶部会话栏加一个设备管理图标，点开下拉面板，由**当前会话所在主机**扫描 USB / 局域网 / Tailscale 上可连通的 Android 测试机，展示连接方式与设备状态（在线、锁屏、常亮、电量…），并把"去哪台设备调试、什么状态、怎么连"一键注入到消息框。
>
> 状态：设计方案（未开工）。所有 DSH 机制均在**本机运行的 DSH 0.2.3-alpha.2（web profile）**上用 `cordis_inspect` 实测核对；adb 采集命令在本机三台真机上实测通过。

> **架构（2026-11-25 09:20 修正，以本条为准）**
>
> 主入口不在 DSH 网页里，而在 **DSH-Phone App 自己的原生顶栏**——与主机监控 / Unsloth / GitHub 同一套机制：
>
> | 层 | 落点 |
> |---|---|
> | 入口 | `_buildTopBar` 里的「测试机设备」图标（仅 DSH 模式显示，Zcode 模式无此路由）→ `showModalBottomSheet` 弹 [lib/device_panel.dart](../lib/device_panel.dart) |
> | 数据面 | 在 **WebView 页面上下文**里 `fetch('/adb-devices/*')`（[lib/webview_bridges.dart](../lib/webview_bridges.dart) 的 `adbBridgeJs`），结果经 `callHandler('onAdbResult')` 回传 Flutter。同源、同 cookie、同 SSH 隧道，实例切 3080/8787/8790 或随机借用端口都自动跟得上 |
> | 执行面 | **隧道对端那台机器上的 DSH 插件**（[plugin/dsh-device-manager](../plugin/dsh-device-manager)）：adb / mDNS / Tailscale 都在那台机器上执行（当前 = Liang-GeekPro，测试机插在这台） |
> | 注入 | 页面自带的 `__dshComposerBridge.insertText`，**只注入不发送**（发送留给用户，避免误触发回合） |
>
> 两条已否决的路线，别再走回头路：
>
> 1. **把扫描塞进 `zcode-phone-server`（8787）**——与本需求毫无关系，已完整回滚（`server.mjs` 零残留、`node --check` 通过、在跑的 8787 未受影响）。
> 2. **App 用 Flutter 侧 HttpClient 直连**——隧道映射的是 WebView 的 loopback 端口，DSH 的会话 cookie / token 只在 WebView 的 cookie jar 里；Flutter 自己发请求就得复制端口与鉴权，多实例 / 换端口立刻失效。
>
> 安全要点：`onAdbResult` handler 必须过 `_bridgeOriginOk` 校验。面板内容会被用户当事实勾选、再一键注入 DSH 输入框，WebView 里打开的第三方页面同样能 `callHandler('onAdbResult', …)`——不校验等于让它伪造设备清单、借用户的手把文本喂进 DSH（提示注入）。

---

## 0. 一页摘要

| 维度 | 结论 |
|---|---|
| 交付形态 | 一个 DSH **bundle**（Host 半区 + Client 半区），不是 DSH-Phone 的原生页面；DSH-Phone 侧是**联动增强**（P2） |
| 顶栏入口 | 注册到实测存在的插槽 `conversation.session.header.utilities`（会话级、右对齐工具区）；面板浮层走 `shell.overlay`（须 portal 到 body） |
| 扫描执行者 | **Host 插件**用 `ctx.subprocess.spawn` 执行 adb / tailscale；绝不让模型用沙箱 Bash 去扫段（实测：沙箱里 tailscale 命不中 tailscaled 命名管道） |
| 设备主键 | **`ro.serialno`**（实测：USB `8b1e8747` 与 `192.168.1.151:5555` 是同一台机器，按 adb serial 直接展示会出现"重复设备"） |
| 缓存 | Host 全局设备表用 `storageDomain`（KV）持久化；**会话级勾选**用 `sessionProjections`；面板打开高频刷新，关闭即停 |
| 消息注入 | `sessionController` 的 `@Remote('prompt')`，`mode: 'queue'`（排队不打断）/ `'steer'`（中途纠偏）；入队后可用 `updateQueue` 的 edit/remove/steer 再改 |
| 模型可见 | 注册 agent 工具 + `systemPrompt.section()`，让模型自己知道"现在有哪几台机器、什么状态"，而不是只能靠人贴消息 |
| 分级动作 | 只读（截图/电量/前台应用/logcat）→ 中风险（安装/启动/常亮/端口转发）→ 高危（卸载/清数据/root）走 `approval` 审批 |
| 里程碑 | P0 图标+扫描+列表+注入（可交付）；P1 动作集+模板+截图附件+logcat+agent 工具；P2 多主机/远程 adb server + DSH-Phone 原生顶栏 + 本机自报状态 |

---

## 1. 需求梳理（你的原始诉求 → 拆成可实现条目）

| # | 你的描述 | 拆解为 |
|---|---|---|
| R1 | 顶部状态栏设备管理图标入口，点击下拉弹框 | header 插槽图标 + 徽标（在线数/异常数）+ 下拉面板（不是新页面、不占用会话区） |
| R2 | 当前会话没获取过设备 → 显示"扫描可用设备"按钮 | 会话投影 `adb.selection` 为空 ⇒ 首屏空态 + 单次扫描 CTA |
| R3 | 已扫描则列表缓存，后续只更新状态 | 主机侧设备表持久化（跨会话复用）；后续只做"状态刷新"，不重扫网段 |
| R4 | 刷新触发主机重新扫描 | 面板刷新 = 重扫（USB + 已配置网段 + tailnet），带进度流与耗时统计 |
| R5 | 由当前会话所在主机扫描自身 USB / 192 局域网 / Tailscale | 三类探测源 + 第四类**远程 adb server**（见 §4.5），并在面板头部标明主机身份 |
| R6 | 设备清单 + 状态 + 连接方式 + 屏幕常亮 + 是否锁屏 | §5 状态模型（实测命令与字段） |
| R7 | 选单条 / 全部设备，注入消息框 | 行复选框 + 全选；生成一条汇总消息或 N 条分条消息；`queue` / `steer` 两种投递 |
| R8 | 消息内容含"去什么设备调试、什么状态、怎么连" | 可配置消息模板（变量插值 + i18n），支持自定义模板 |

**我补充的建议（下文展开）**：设备身份合并、状态语义分层、扫描成本与去抖、分级动作与审批、截图转消息附件、logcat 落到终端标签页、模型上下文注入、会话级 vs 主机级状态隔离、失败诊断事件流、安全 allowlist、多主机、DSH-Phone 侧联动与"本机自报状态"。

---

## 2. 关键设计决策（含取舍）

### 2.1 为什么是 DSH bundle，而不是只做 DSH-Phone 原生页面
- 扫描必须发生在**设备所在的主机**（USB 插在开发机上、局域网 adb 在办公网、tailnet 对端），手机侧只能经隧道转发，拿不到 USB 总线。
- 消息注入、模型上下文、审批、工具注册都只有 Host 侧有权威入口。
- 做成 bundle 后，**DSH-Phone 的 WebView 里天然就有同一个面板**（零额外成本），原生顶栏入口只是"再加一个快捷方式"，见 §8。

### 2.2 扫描统一走 Host `subprocess`，不走 agent Bash（实测依据）
本机实测（Windows 10.0.26300，adb 1.0.41 / 37.0.1，`%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`）：

```
adb devices -l
8b1e8747               device product:alioth model:M2012K11AC device:alioth transport_id:5
100.75.247.55:5555     device product:warsaw  model:M332BF     device:warsaw    transport_id:4
192.168.1.151:5555     device product:alioth model:M2012K11AC device:alioth transport_id:6
```

- `adb` 在沙箱内可跑，但 **`tailscale status --json` 在沙箱内失败**：`failed to connect to local tailscaled ... Access is denied`（命名管道被沙箱策略拒绝）。
- `adb` 不在 PATH 上 → 必须可配置路径 + 自动发现（`%LOCALAPPDATA%\Android\Sdk\platform-tools`、`ANDROID_HOME`、`where adb`）。
- 结论：**所有探测由 Host 插件的 `ctx.subprocess.spawn({argv, cwd, stdio, graceMs, env})` + `resolveExecutable()` 完成**，agent 侧只暴露高层工具（`device_list` / `device_action`），避免模型自己拼命令、扫段、烧 token。

### 2.3 设备身份：按 `ro.serialno` 合并，transport 是数组（实测依据）
上表三台里，`8b1e8747`（USB）与 `192.168.1.151:5555`（WiFi）`ro.serialno` 都是 `8b1e8747` —— **同一台物理机，两条通道**。若不合并，用户会看到"两台一模一样的 K30 Pro"，并且不知道点哪条。

设计：
- `Device{ serial, model, android, transports[] }`，`Transport{ kind: usb|lan|tailnet|remote-server|emulator, endpoint, state, lastSeen, priority }`。
- 通道优先级 `usb > lan > tailnet > remote-server > emulator`；操作时取"最高优先级可用通道"，USB 掉了自动回落 WiFi，并在 UI 上说明当前用的是哪条。
- 展示：一行一台设备，右侧小徽章显示通道集合（`USB` `WiFi` `Tail`），而不是多行。

### 2.4 状态分层，避免"一个 offline 打天下"
| 层 | 取值 | 判定方式 |
|---|---|---|
| 传输层 transportState | `device` / `offline` / `unauthorized` / `no permissions` / `bootloader` / `sideload` / `absent` | `adb devices -l` 第二列 |
| 可达性 liveness | `ok` / `unreachable` / `timeout` | `adb -s X shell true`（TCP 命中还需 `net.connect` 探活） |
| 会话事实 facts | 亮屏/息屏、锁屏、常亮、电量、充电、前台应用… | §4.3 的 adb shell 采集 |
| 新鲜度 staleness | `fresh`(<TTL) / `stale` / `unknown` | 采集时间戳 + TTL |

UI 上四态语义色沿用 DSH-Phone 已有的约定（绿=正常 / 橙=抖动或降级 / 红=确定性失败 / 灰=未知），避免同一用户面对两套色义。

### 2.5 缓存与刷新策略（成本敏感）
- **主机级**：`storageDomain` 打开一个 `adb-devices` 域（`{devices, scanRuns, templates, lastScanAt}`）；跨会话共享 ⇒ 满足 R3。
- **会话级**：`sessionProjections` 存 `{selectedSerials[], injectedAt}` ⇒ 满足 R2「当前会话没获取过设备」的判定。
- 三档节流：面板**打开**时 `panelMs=3s` 刷新事实（不重扫网段）；面板**关闭**时 `backgroundMs=30s`（可关）；**空闲/无客户端**不跑；`重扫` 才是全量（USB + 网段 + tailnet），并用 `@Remote({mode:'stream'})` 推进度。
- 并发与串行化：同一 adb server 的调用要过**串行/限流池**（默认并发 4、单命令超时 3s、整轮上限 20s），否则会看到 `adb server offline` 抖动。
- 去抖：状态翻转需连续两次一致才改判（防 flapping），异常直接进诊断事件流。

### 2.6 消息注入的三条通道（按可靠性排序）
| 通道 | 机制 | 适用 | 状态 |
|---|---|---|---|
| A. 排队/纠偏投递 | `ctx.remote.session.prompt({requestId, sessionId, mode:'queue'\|'steer', content})` | 主路径：注入当前会话；agent 正在跑时不插队；`steer` 用于"中途纠偏到另一台设备" | 已核到 `@Remote('prompt')` 契约（`SessionPromptRequest`） |
| B. 队列二次编辑 | `updateQueue{itemId, action: edit\|remove\|steer}` | 入队后让用户改文案再发 | 契约已核 |
| C. 原生输入框填充 | DSH-Phone 的 `window.__dshComposerBridge.insertText(text)`（[webview_bridges.dart:625](</E:/DTXY/DSH-Phone/lib/webview_bridges.dart>)） | **填但不发**：只在 DSH-Phone 原生顶栏入口里可用 | 现有能力，实测在跑 |

> ⚠️ 明确的未验证点：Web Client 侧没有暴露"草稿"服务（`cordis_inspect` 客户端服务只有 `layout / locale / sessions / slots / theme / timer / uiWorkspace / workspaces`），而且规范禁止插件直接改宿主 DOM。所以"纯 Web 端把文字塞进输入框但不发送"在 P0 **不做**，改为 A（queue，语义等价、可撤销）。若体验不满足，再评估：在插件自己的浮层里维护草稿 + 一个"填入"按钮走 C 通道（仅 App 内）。

---

## 3. 架构与数据流

```
┌──────────────── DSH Web UI (Client 半区) ────────────────┐
│ conversation.session.header.utilities  → 图标 + 徽标     │
│   └─ click → shell.overlay(portal) 下拉面板              │
│        · 头部：主机名/adb server/上次扫描/⏳刷新          │
│        · 过滤：全部 | USB | WiFi | Tail | 离线           │
│        · 列表：状态点 型号+Android serial 通道 电量 亮/锁 │
│        · 行内：⋯ 动作菜单（截图/logcat/常亮/安装…）      │
│        · 底部：☑全选 | 注入选中(N) | 模板 | ⚙ 设置       │
│ conversation.input.left / input.dock → 常驻设备 chips    │
└───────────────┬───────────────────────▲──────────────────┘
       ctx.remote.adbDevices.*           │ projection / stream
┌───────────────▼───────────────────────┴──────────────────┐
│ Host bundle: dsh-device-manager                          │
│  ScanOrchestrator  ─ USB / LAN / Tailscale / RemoteAdb   │
│  StateCollector    ─ adb shell 事实采集（限流池）        │
│  DeviceRegistry    ─ serial 合并 + storageDomain 持久化  │
│  ActionRunner      ─ verbs + approval + 审计             │
│  AgentIntegration  ─ tools.register + systemPrompt.section│
│  WebRoute (可选)   ─ /api/devices 供 DSH-Phone / CLI 调用 │
└───────┬───────────────────────────┬──────────────────────┘
   ctx.subprocess.spawn        sessionProjections / sessionController
   (adb / tailscale / node:net)  └→ prompt(mode:'queue'|'steer')
```

**插槽选型（全部来自 `Slots.listSubTree` 实测目录）**
- `conversation.session.header.utilities`（list，scope=session，注册项 `id/order/label`）→ 图标本体，右对齐工具区，符合"顶部状态栏图标入口"。
- 备选：`conversation.header.leading`（root 作用域，无会话也在）、`conversation.session.header.corner`（最右角，但 single，会与宿主抢位）。
- 浮层：`shell.overlay`（frame-wide，"above every column"）+ portal；`conversation.input.*` 系列的注释都明确要求 fixed overlay 必须 portal。
- 常驻提示：`conversation.input.left`（小 chips：`☑ 2 台 · Redmi K30 Pro`），点它复用同一个面板。
- 想要"看板模式"时：`layout.openRightbar(...)` + 右栏插槽，把面板钉成右侧栏（P1 可选）。

---

## 4. 探测与采集设计

### 4.1 USB 源
`adb devices -l` → 解析 `serial state product model device transport_id`；补 `getprop` 事实。
异常态处理：`unauthorized` → 文案"请在手机上点允许 USB 调试"，行内"重试"；`offline` → 先 `adb reconnect offline`（限 1 次）再判失败；`no permissions`(Linux) → 提示 udev 规则。

### 4.2 局域网源（默认关，配置 CIDR 白名单才扫）
1. 候选生成：`config.sources.lan.cidrs`（如 `192.168.1.0/24`）+ `ports`（默认 `[5555]`，可选 `5556`）。
2. TCP 探活：`node:net` connect，超时 250ms，并发 32，整段限速（默认 ≤200 conn/s），命中才 `adb connect ip:port`。
3. 收敛：`adb connect` 成功后取 `ro.serialno` 并入注册表；失败连接立即销毁，不重试超过 2 次。
4. mDNS 加成（Android 11+ 无线调试）：`adb mdns check` 可用时用 `adb mdns services` 直接拿 `_adb-tls-connect._tcp` 列表，比扫段快且无副作用 —— 作为**首选**，扫段作兜底。

### 4.3 Tailscale 源
`tailscale status --json`（**必须在 Host 侧跑**，见 §2.2）取 peer IPv4 → 同样走 TCP 探活 + `adb connect`；或配置 tailnet CIDR（`100.64.0.0/10`）做定向扫描。面板头部显示 `tailnet: <本机 tailnet IP> / 未就绪`。

### 4.4 事实采集（本机三台真机实测）
```
adb -s <t> shell getprop ro.serialno / ro.product.model / ro.build.version.release
adb -s <t> shell dumpsys power   | grep mWakefulness      → Awake / Asleep
adb -s <t> shell dumpsys window  | grep mDreamingLockscreen|mCurrentFocus
adb -s <t> shell dumpsys battery | grep level|AC powered|USB powered|status
adb -s <t> shell settings get global stay_on_while_plugged_in  → 常亮
adb -s <t> shell settings get global adb_wifi_enabled          → 无线调试（Android 11+）
adb -s <t> shell wm size / wm density                          → 分辨率/DPI
```
实测样例（同一命令、三种通道）：

| serial | 通道 | model/Android | 亮屏 | 锁屏 | 前台应用 | 电量 | 常亮 |
|---|---|---|---|---|---|---|---|
| `8b1e8747` | USB | M2012K11AC / 13 | Asleep | `mDreamingLockscreen=true` | `NotificationShade` | 100%（USB 供电，status 5） | `0` |
| `8b1e8747` | `192.168.1.151:5555` | M2012K11AC / 13 | Asleep | true | `NotificationShade` | 100% | `0` |
| `43328e37` | `100.75.247.55:5555` | M332BF / **17** | **Awake** | false | `com.netease.uuremote/…ScreenActivity` | 57%（AC，status 2 充电中） | **15** |

要点：
- `stay_on_while_plugged_in=15` ⇒ "插着电常亮"，正是你要的"屏幕是否常亮"；UI 直接显示 `常亮·充电`。
- 锁屏判定用 `mDreamingLockscreen` + `mCurrentFocus` 组合（焦点是 `NotificationShade`/`Keyguard` 视为锁屏），不要单看亮屏。
- Android 17 的 dumpsys 字段有漂移风险 ⇒ 采集器写成**带回退链的解析器**（`mWakefulness` → `Display Power: state=ON` → `powerinfo` → `unknown`），`unknown` 显示灰点而非红点。
- 整轮 3 台设备 ≈ 12 次 `adb shell`，实测 2s 内；面板 3s 节流刷新完全够。

### 4.5 远程 adb server（让"别人机器上的设备"也进来）
其它机器 `adb -a -P 5037 fork-server server --reply-ok`（或 `ADB_SERVER_SOCKET=tcp:<host>:5037`），本插件配置 `remoteAdbServers: ["100.75.247.60:5037"]` 即可把它挂的 USB 设备纳管。走 tailnet，不走公网。

### 4.6 扫描运行记录
每次扫描写 `ScanRun{id, at, trigger, hosts, sources, found, merged, dropped[], errors[], durationMs}`；面板底部"诊断"展开成事件流（复用你在 DSH-Phone 里"连接诊断（事件流）"的交互范式：环形缓冲、时间线、分类着色）。

---

## 5. 数据模型（`storageDomain` 域声明草案）

```js
// 域：adb-devices（version 1，compatibleVersions: [1]）
{
  global: { lastScanAt, scanSeq, adbServerInfo, tailnet },   // zod 校验 + initial
  tables: {
    devices:   { key: serial,   value: { model, android, density, size, group,
                                         transports: [{kind, endpoint, priority, addedAt, lastSeen, state}],
                                         facts: { wake, locked, stayAwake, battery, charging,
                                                  foreground, adbWifiEnabled },
                                         collectedAt, notes } },
    scanRuns:  { key: runId,    value: { at, trigger, sources, found, merged, errors, durationMs } },
    templates: { key: name,     value: { title, body, locale } },
  }
}
// 会话投影：adb.selection = { selected: [serial], injectedAt, lastSummary }（会话级，随 log 走 fork/resume）
```

> 遵循 DSH 规范：**不新增 `session/event` 类型**，会话级状态走 `sessionProjections`；需要给客户端算好的值用 projection 的 `wire.view`，客户端不自己折叠事件。

---

## 6. UI / UX 细节

```
┌─ 顶部会话栏 ────────────────────────────────────────────────┐
│  会话标题…                          📱³  ⌠ 其它工具  ⚙  ✕  │   ← 图标 + 在线数徽标
└─────────────────────────────────────────────────────────────┘
                          ▼ 点击（浮层 portal 到 body）
┌───────────────────────────────────────────────┐
│ 主机 dev-win · adb 37.0.1 · tailnet 100.x │ ⏳ │
│ 上次扫描 12s 前 · 3 台设备 / 4 通道      [重扫]│
│ [全部] [USB] [WiFi] [Tail] [离线]     🔍搜索   │
├───────────────────────────────────────────────┤
│ ☐ ● Redmi K30 Pro  A13  8b1e8747              │
│      USB + WiFi(192.168.1.151)  息屏·锁屏     │
│      100% ⚡USB  非常亮   [⋯]                  │
│ ☐ ● Xiaomi (M332BF) A17  43328e37             │
│      Tail(100.75.247.55:5555)  亮屏·解锁       │
│      57% ⚡AC  常亮·充电  前台 UU远程   [⋯]     │
│ ☐ ⚠ 未授权设备  USB  请在手机上点"允许" [重试] │
├───────────────────────────────────────────────┤
│ ☑ 全选   模板[默认 ▾]              [注入 2 台 ▸]│
│ 诊断 · 设置 · 关闭                        Esc  │
└───────────────────────────────────────────────┘
```

- **空态（R2）**：本会话投影为空 → 中间一个大按钮「扫描可用设备」+ 一行提示（扫描在主机 X 上执行，范围：USB + 192.168.1.0/24 + tailnet）。
- **徽标语义**：数字=可用设备数；橙点=有降级（stale/offline/unauthorized）；扫描中=呼吸动画。禁用纯红（避免"全屏报警"观感，沿用你 App 里"非阻塞提示"的取向）。
- **注入按钮**：主按钮 `注入 2 台 ▸` 是 split-button：默认按当前模板一条汇总消息（`queue`）；下拉里给「每台一条」「中途纠偏(steer)」「复制到剪贴板」「复制 adb 连接命令」。
- **键盘**：`Esc` 关闭、`↑↓` 移动、`Space` 勾选、`Enter` 注入、`R` 重扫；焦点管理照宿主 Modal 的行为抄（Escape + focus trap），符合"插件 UI 是宿主 UI 的一部分"。
- **主题/文案**：只用 `--dsw-alias-*` 令牌，控件自绘（规范要求，不能 require 宿主 primitives）；文案走 client locale 服务，中英双语。
- **常驻 chip**（P1）：注入后在 `conversation.input.left` 挂 `📱 Redmi K30 Pro · USB · 息屏`，一眼知道当前对话目标机，点击重开面板。

---

## 7. 消息模板（R7/R8）

内置 3 套，变量插值，可在设置里改并存为自定义（存 `templates` 表）：

```
默认（单条汇总）
  请在以下 {count} 台 Android 测试机上验证 {target}：
  1. {model}（Android {android}）· {serial}
     连接：{transportLabel} {endpoint}   `adb -s {serial} {firstCmd}`
     状态：{screen} · {lock} · 电量 {battery}%{charging} · {stayAwake}
     前台：{foreground}
  优先使用 {preferredTransport}；掉线时自动回落 {fallbackTransport}。

每台一条（分条，适合多人/多任务分工）
  [设备] {model} {android} · {serial} · {transportLabel} · {screen}/{lock}/{battery}%
  任务：{target}
```

变量表：`{model} {android} {serial} {transportLabel} {endpoint} {screen} {lock} {battery} {charging} {stayAwake} {foreground} {density} {size} {firstCmd} {preferredTransport} {fallbackTransport} {hostName} {target} {count}`。`{target}` 由注入前的一次性输入框填（默认取会话标题）。

---

## 8. Agent / 模型侧集成（我额外建议的"更优解"）

| 能力 | 机制（已核） | 价值 |
|---|---|---|
| 设备清单工具 | `ctx.tools.register({name:'device_list'})` | 模型自己会看设备，不用再问"我USB上还有几台" |
| 状态刷新工具 | `device_refresh(scope:'status'\|'full')` | 让 agent 在跑 UI 自动化前自证目标机在线 |
| 分级动作 | `device_action({serial, verb, args})` + `ctx.tools.guard()` / `approval.request` | 高危动作必须人在环 |
| 上下文注入 | `ctx.systemPrompt.section()`：只写"可用设备 + 状态摘要 + 选择规则" | 避免每条消息手贴设备信息 |
| 截图进对话 | `adb exec-out screencap -p` → `ctx.attachments.saveImages()` → 作为附件入消息 | "设备现在长这样"直接进上下文，比文字描述强 |
| logcat | `ctx.remote.terminal.create(...)` 打开 `adb -s X logcat -v time` 侧栏终端 | 调试闭环，不打扰对话 |
| 端口转发 | `adb forward tcp:9222 localabstract:webview_devtools_remote_<pid>` 等 verbs | Flutter/WebView 调试一键到位 |
| 设备状态卡片（可选） | `actionCards.register(kind)` + `@Remote act(verb)` | 消息里出现可点设备卡：`[刷新] [切 USB] [注入]` |

> 审计：所有 action 走工具执行路径，天然留在会话日志里（"会话日志是唯一事实来源"），事后可复盘"谁在什么时候往哪台机器装了哪个包"。

---

## 9. 与 DSH-Phone 客户端的联动（P2，非阻塞主路径）

1. **原生顶栏入口**：顶栏新增 📱 图标（与现有连接状态、模式切换并列），点开半屏抽屉，直接调插件在 Host 注册的 `/api/devices`（走已有 SSH 隧道，鉴权链与 DSH token 一致），列表用 Flutter 原生渲染 —— 小屏上比 Web popover 好点，且 WebView 里的 Web 面板继续保留。
2. **填而不发**：抽屉里点"注入"→ 现有 `window.__dshComposerBridge.insertText(text)`（不自动发送，与语音输入一致的交互语义）。
3. **本机自报状态（很值的补充）**：跑 DSH-Phone 的那台手机，本身常常就是测试机，但它不一定在 adb 列表里（没插线、没开无线调试）。让 App 通过隧道自报 `{battery, screenOn, tailnetIp, carrier, appVersion, buildModel}` 到插件，插件把它作为 `selfReported` 通道并入注册表 —— 于是"设备什么状态"这类 adb 拿不到/拿不全的信息有了权威来源，也顺手解决了"这台是不是我现在手里这台"的困惑。
4. **一键镜像（可选）**：设备行 `[⋯] → 镜像` 提示 scrcpy 命令或复制 `adb shell screenrecord`，不在 App 内自建视频流（成本高、收益边界不清）。

---

## 10. 配置样例（用户可在 `cordis.patch.yml` 里改）

```yaml
- insert:
    - id: device-manager
      name: '@local/dsh-device-manager'
      config:
        adbPath: auto                    # 或绝对路径；auto = PATH → ANDROID_HOME → %LOCALAPPDATA%\Android\Sdk\platform-tools
        server: { autoStart: true, port: 5037 }
        sources:
          usb:       { enabled: true }
          lan:       { enabled: false, cidrs: ['192.168.1.0/24'], ports: [5555], useMdnsFirst: true,
                       rateLimitPerSec: 200, connectTimeoutMs: 250, maxConcurrency: 32 }
          tailscale: { enabled: true, useStatusJson: true, cidrs: [] }
          remoteAdbServers: []           # ["100.75.247.60:5037"]
          emulator:  { enabled: true }
        poll: { panelMs: 3000, backgroundMs: 30000, staleAfterMs: 120000, enabled: true }
        collect: { concurrency: 4, perCommandTimeoutMs: 3000, roundBudgetMs: 20000 }
        inject: { mode: queue, template: default, perDevice: false, allowSteer: true }
        actions:
          requireApproval: ['install','uninstall','clear','reboot','root','remount','tcpip']
          disabled: []
        ui: { surface: 'header', showComposerChip: true }
```

---

## 11. 安全与权限（不可省略）

1. **网段白名单**：LAN 扫描默认关闭，必须显式 CIDR；单次扫描 IP 上限（默认 512）与速率上限，防止误扫办公网/生产网。
2. **adb over TCP**：Android ≤10 的 5555 无鉴权，tailnet 之外的网络禁止 `tcpip`；面板对"无鉴权通道"标橙。
3. **高危动词**：`install/uninstall/clear/reboot/root/remount/tcpip` 走 `approval.request`，默认人在环；`fastboot`/`factory reset`/`pm disable` 系统组件**不实现**。
4. **只暴露动词，不暴露 shell**：不提供 `adb shell <任意字符串>` 的工具；确有需要的调试走"在终端里自己敲"，让责任回到人。
5. **多用户/远程访问**：DSH 支持多客户端访问，设备操作要过 `connection`/principal 权限；非 owner 会话默认只读。
6. **审计**：所有动词落到工具调用记录 + `ActionRun` 表（谁、何时、哪台、哪个 verb、参数、结果）。

---

## 12. 里程碑与验收

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **P0**（可用） | bundle 骨架；Host：adb 解析 + serial 合并 + `storageDomain` 缓存 + 状态采集（亮屏/锁屏/常亮/电量/前台）+ Remote 方法；Client：header 图标 + 下拉面板 + 空态扫描 + 刷新 + 勾选 + `queue` 注入 | 本机复现：3 条 transport → **2 台设备 + 1 台未授权演示**；面板头部显示主机身份与 adb 版本；注入后消息出现在队列且可 edit/remove；断开 USB 后 6s 内状态转灰/橙 |
| **P1**（好用） | 动作集（wake/screenshot/stay-awake/anim-off/forward/install/logcat）+ approval；模板编辑；截图入附件；composer chip；agent 工具 + systemPrompt section；设置页；诊断事件流；键盘导航 | 高危 verb 触发审批卡片；截图直接出现在对话；模型能主动回答"我该在哪台机器上验证" |
| **P2**（扩展） | 远程 adb server；多主机/多 DSH 实例视图；DSH-Phone 原生顶栏抽屉 + `__dshComposerBridge`；App 本机自报状态；scrcpy 引导；设备分组与环境预设 | 手机在没开 adb 的情况下也能以"本机"身份出现在列表；DSH-Phone 顶栏一键唤出面板 |

**已拍板（2026-11-24）**：P0 只做「扫描 + 列表 + 注入」，动作集（截图/常亮/安装/logcat）一律推到 P1；注入默认且唯一使用 `queue`（`steer` 与"每台一条"留在下拉里，不进 P0 验收）；局域网扫描源**默认关闭**，只有配置里显式写 CIDR 才扫；本轮**只交付 Web bundle**，DSH-Phone 原生顶栏抽屉与"本机自报状态"另开一轮。因此 P0 的 `config.actions` 整节只解析不执行，`/api/devices` 路由可延后。

> **落地状态（2026-11-25 03:50）**：P0 已实现并装进正在运行的 DSH（`@local/dsh-device-manager`，`include:device-manager` 激活、全局工具 `adb_devices`、顶栏插槽 `device-manager`、系统提示词段全部实测在线）。离线 + fixture 回放 **151 项断言全绿**；真机端到端由三轮独立验证代理实测，修掉 12 个真 bug（数组入参、投递回执、sessionId 前缀、`merged` 数字当数组、auth/resource 口径不一致可越权触发写操作、`setDraft` 抹用户草稿、compose 丢 text、模板丢通道、系统提示词无兜底…）。代码见 [plugin/dsh-device-manager/](../plugin/dsh-device-manager/)，证据见 [自测报告](./dsh-device-manager-selftest-report.md)。与计划的 8 处偏差（JSON 存储代替 `storageDomain`、平面 ToolDefinition、同域 HTTP 路由代替 typert `@Remote`、`files`/安装方式等）集中在报告 §8 与本目录 [README](../plugin/dsh-device-manager/README.md)。

**测试矩阵（回归用）**：通道 {USB, LAN 5555, tailnet 5555, remote-server, emulator} × 状态 {device, unauthorized, offline, absent} × 事实 {亮/息, 锁/解锁, 常亮/非常亮, 充电/掉电, 前台有/无} × 边界（adb 不在 PATH、adb server 被占、设备中途拔线、dumpsys 字段漂移、面板开在两个标签页）。

---

## 13. 风险与未验证项（开工前需逐条确认）

| 项 | 现状 | 处置 |
|---|---|---|
| Web 端"填入输入框但不发送" | 客户端无草稿服务，禁止改宿主 DOM | P0 用 `prompt(mode:'queue')` + `updateQueue`；App 内用 C 通道 |
| 自定义插件 Remote 方法暴露给 Client 的确切写法（`@Remote` + typert 注册） | 机制存在（多个官方服务如此），具体装饰器与 typert 贡献待复核 | 构建时用 `cordis_inspect` 现场核对，必要时改走 `webServer.register` HTTP 路由 |
| `conversation.session.header.utilities` 注册项能拿到的 props（是否含 sessionId） | 插槽与注册签名已实测，props 未取 | 注册后用 `Slots.listSubTree(root)` 复查；拿不到就从 slot 外层 context 取当前会话 |
| Android 17 dumpsys 字段漂移 | 实测已有 A17 设备，字段与 A13 不完全一致 | 解析器带回退链，判不出显示 `unknown`（灰），不显示失败 |
| 沙箱限制 | tailscale 命名管道被拒（实测） | 探测只在 Host 侧；agent 工具仅高层调用 |
| adb 单 server 争用（用户自己也开 Android Studio） | 已知风险 | 只连现有 server，不 kill-server；异常时提示而非强杀 |
| 端口扫描误伤 | 已知风险 | 默认关闭 + CIDR 白名单 + 限速 + IP 上限 |

---

## 14. 需要你拍板的 5 件事

1. **P0 是否只做"扫描 + 列表 + 注入"**（动作集留 P1）？还是首批就要截图/常亮/安装？
2. **注入语义**：`queue`（排队不打断当前 turn，推荐）/ `steer`（正在跑时中途纠偏）/ 二者都要但默认前者？
3. **局域网扫描**默认范围：只 `192.168.1.0/24`？还是包含你另一段办公网？是否允许开启（默认关）？
4. **多主机**：你现在是"一台开发机 + 云主机"两路实例，还是更多？需不需要 P0 就把主机身份/远程 adb server 做进去？
5. **DSH-Phone 原生顶栏入口**是否纳入本次范围（P2），还是先只交付 Web 插件、App 侧另开一轮？

---

### 附：本方案的事实来源
- 运行环境：DSH `0.2.3-alpha.2`（`DSH_PROFILE=web`，`DSH_INSTALL_DIR=…\@deepseek-ai\dsh`）；`cordis_inspect` 实测的 Slot 目录、Host/Client 服务契约（`sessionController.prompt/updateQueue`、`subprocess.spawn`、`storageDomain.open`、`tools.register`、`systemPrompt.section`、`attachments.saveImages`、`terminalController.create`、`actionCards.register`）。
- 真机实测：本机 adb 1.0.41 / 37.0.1，设备 `8b1e8747`(USB)、`192.168.1.151:5555`(同 serial)、`100.75.247.55:5555`(serial `43328e37`, Android 17)；采集字段与取值见 §4.4。
- DSH-Phone 现有能力：`window.__dshComposerBridge.insertText/send`（[lib/webview_bridges.dart](</E:/DTXY/DSH-Phone/lib/webview_bridges.dart>)、调用点 [lib/webview_screen.dart](</E:/DTXY/DSH-Phone/lib/webview_screen.dart>)）。
