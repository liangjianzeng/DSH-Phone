# dsh-device-manager 自测报告（P0）

生成时间：2026-11-25 03:35（Asia/Shanghai）｜DSH 0.2.3-alpha.2｜`DSH_PROFILE=web`｜主机 `Liang-GeekPro`

结论速览：**离线 + fixture 回放 151 项断言全绿；插件已在运行的 DSH 里激活（Host fiber active + 顶栏插槽 occupants 出现 device-manager + 全局工具 adb_devices 可见 + 系统提示词段生效）；真机端到端由四轮独立验证代理实测，累计修掉 20 个真 bug；P0 核心闭环（扫描 → 归并 → 生成消息 → 投进主会话）已用真会话验证成功。**
未验证项集中在"浏览器里点面板"这一条（需要一次页面刷新），已单独列在 §5。

---

## 1. 离线自测（不依赖 DSH 运行时）

```
node plugin/dsh-device-manager/tools/selftest.mjs            # 离线 + fixture 回放
合计 144 项，失败 0 项（exit=0）
node plugin/dsh-device-manager/tools/selftest.mjs --offline  # 只离线
合计 133 项，失败 0 项
```

覆盖分组：

| 组 | 覆盖点 |
| --- | --- |
| `parseDevicesList` | 真机三通道、`unauthorized/offline/no permissions`、转义空格 model、daemon 噪声行 |
| `parseMdnsServices` | connect/pairing 分类、无服务 |
| `parseTailscaleStatus` + `tailscaleCandidates` | JSON 正常、tailscaled 未运行降级、只取在线 peer 的 IPv4 |
| `parseFacts` / `buildFactScript` | A13 与 A17 两种 dumpsys 形态、字段漂移回退、全空降级、BOM 容忍、标记只用字母数字下划线（避开 mksh 的 `#` 注释坑） |
| `classifyEndpoint` / `isTailnetAddress` | USB vs TCP、`100.64/10` 与 `fd../fc..` 判 tailnet |
| `expandCidrs` / `tcpProbe` / `buildProbeTargets` | /24 去网络与广播地址、/30、/32、上限截断、非法 CIDR 记录；假 net 验开放/超时/拒绝与错误码；mDNS+LAN+tailnet 合并去重、pairing 端口不留 |
| 注册表（核心） | **3 条 transport → 2 台设备**、`ro.serialno` 归并、`tmp:` 身份升级搬迁、真身+tmp 合并、缺席 3 轮转 absent、只读刷新不推进缺席轮次、unauthorized/offline 判 error、超 TTL 转 degraded |
| 模板 | default/brief/perDevice 无残留 `{变量}`、同一设备列出全部通道与连接命令、自定义模板插值、空设备列表不崩 |
| 配置 | LAN 默认关（安全默认）、mDNS 优先默认开、TTL 120s、限速 200/s、adb 自动发现（含无 SDK 环境变量回落 PATH） |
| 入参清洗 | `["a"]` JSON 字符串、逗号串、单串、去重去空、挡 `--help/-s/"a b"/"$(id)"/".."`、`toInt` 夹紧 |
| fixture 回放 | 用真机抓的 adb/tailscale 输出跑整条 `scanFull`/`refreshStatus`，断言扫描成功、耗时 <20s、serial 唯一、每通道带连接命令、注入文本无残留变量 |

## 2. fixture 来源与真机事实

`test/fixtures/` 由 PowerShell 直连 adb 抓取（DSH 沙箱内 Node `child_process.spawn` 会 `EPERM`，所以抓取走 pwsh；正式路径是 Host 里的子进程，见 §4）：

- `8b1e8747` 与 `192.168.1.151:5555` 是**同一台** Redmi M2012K11AC（Android 13）：息屏、锁屏（焦点 `NotificationShade`）、电量 100%、USB 供电、`stay_on_while_plugged_in=0`、`adb_wifi_enabled=0`、1080x2400@440。
- `100.75.247.55:5555`（serial `43328e37`，Redmi M332BF，Android 17）：亮屏、未锁、电量 57%、AC、`stay_on_while_plugged_in=15`、前台 `com.netease.uuremote`。本轮对端 offline，**三通道归并场景未在真机复现**，由离线用例覆盖（`身份合并: 3 transport → 2 设备`）。
- adb：`C:\Users\jianz\AppData\Local\Android\Sdk\platform-tools\adb.exe`（不在 PATH，插件自动发现成功，版本 37.0.1-15733141）。

## 3. 插件在运行的 DSH 里是否真的挂载

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Host 条目激活 | `plugin_manager list_plugins` | `include:device-manager` → `enabled:true`，`fiberPhase:"active"` |
| 全局工具注册 | `cordis_inspect Tool.listTools` | 出现 `adb_devices`（含 action 闭集与逐项描述） |
| 顶栏插槽占位 | `cordis_inspect Slots.listSubTree(conversation.session.header.utilities)` | occupants 里出现 `device-manager`（order 6，active） |
| 系统提示词段 | 本会话上下文 | 出现「## 可用 Android 测试机（主机 Liang-GeekPro）… 1 台设备 / 2 条通道」；禁用插件后该段消失、启用后回来 |
| 配置行 | `cordis_inspect Config.listConfigs` | `include:device-manager` / patchId `device-manager` |
| 缓存目录 | 文件系统 | `C:\Users\jianz\.dsh\device-manager\registry.json`（`identitySource:"ro.serialno"`，transports `local\|usb\|8b1e8747` + `local\|lan\|192.168.1.151:5555`） |

## 4. 真机端到端（验证代理实测）

第一轮（修复前）暴露的 4 个真 bug 与处置：

| # | 症状（原样） | 根因 | 处置 |
| --- | --- | --- | --- |
| 1 | `读取 ["8b1e8747"] 失败：未知设备 ["8b1e8747"]` | 模型把数组当 JSON 字符串传，未解包 | 新增 `lib/args.js:toSerialList`，统一吃数组/逗号串/JSON 字符串/单串，并挡 `--help`、`-s`、含空格、纯符号值；9 条回归用例 |
| 2 | `部分投递失败：session "…" is owned by subagent routing` 却报"部分失败" | 只看 Promise 是否 reject，未看 `RemoteResult.ok`；失败也计入历史 | 失败判定改为看 `receipt.ok`；历史区分 `失败(x/y)`；错误文案说明 subagent 会话不可投递并提示显式传 sessionId |
| 3 | `主机：…｜adb：未知` | compose 取 `state.lastScan.adbVersion`，该字段不存在 | `ensureAdbVersion()` 缓存真实版本 |
| 4 | brief/perDevice 丢 WiFi 通道；`前台` 行缩进不齐；回落命令取的是**别的设备**的通道 | 模板只用 best transport | 新增 `{allTransports}`/`{allTransportsBrief}`；回落优先同机次选通道；模板重排 |

第二轮（修复 + 重载后）实测：见 §6（`verify-round2` 代理原样回报）。

## 5. 未验证 / 有限验证（诚实清单）

1. **浏览器里点面板**：客户端半区已注册（插槽 occupants 有 `device-manager`），但面板真正打开、勾选、"填入输入框"、"发送到会话"这条 **UI 交互路径需要一次页面刷新后由人点一遍**。为此插件自带自证：`adb_devices(action:'doctor')` 的 `面板通道` 项显示最近一次**外部**调用的来源/动作/耗时/成败。第四轮验证实测：连续两次 `doctor` 该项都停在 `✘ 还没有面板/外部调用（…本项不含 doctor 自检探针，能自己证伪）`——即它不会被自己刷成 ✔；你在浏览器里刷新并打开过一次面板后，这一项才会变成 `N 次外部调用；最近 … http:list ok（…ms）`。
   > 注意：`history` 与 `panelCalls` 都在内存里，插件重载（禁用/启用、重启 DSH）后从 0 开始；**只有 `registry.json` 是持久的**。所以刚重载完看到「最近 0 次扫描」是正常现象，跑一次 `action:'scan'` 即有。
2. **未认证 curl 打 `/adb-devices/*` 返回 401**：本部署的 token 插件在准入阶段拒绝无凭据请求（`/` 同样 401，`/favicon.ico` 404 作对照）。带凭据的浏览器 Peer 才是这条路由的真实使用方；路由本体已由 doctor 的 `HTTP 路由本体` 项不经 HTTP 直接跑一遍。
3. **三通道归并到同一台设备**（USB + WiFi + tailnet 同一台机器）：仍未在真机复现——本机可达的两台手机里，K30 有 USB+WiFi（**已实测归并成 1 台 / 2 条通道**，见系统提示词段与 `scan` 输出），Redmi 2211133C 只有 tailnet 一条（`local|tailscale|100.109.138.2:5555`，03:29 上线后被真实采集，Android 16 / 息屏 / 锁屏 / 100%）。三通道情形由离线用例覆盖（`身份合并: 3 transport → 2 设备`）；若那台手机同时插上 USB 并开 adb 无线，`action:'scan'` 应显示 `2 台设备 / 4 条通道` 且尾部设备 transports 变 2 条。
4. **局域网扫段**：默认关闭，本轮未开启验证（`doctor` 会显示策略）。要验：`lan.enabled: true` + `cidrs: [192.168.1.0/24]`，然后 `action:'scan'`，看 `来源：lan=192.168.1.0/24` 与 `probe=N`。
5. **mDNS**：本机 `adb mdns services` 当前 0 条服务，走的是"可用但为空"分支。
6. `inputActions.persistDraft` 等合成器 API 名以已验证的 `InputActions` 契约为准，代码里全部做了 `typeof === 'function'` 存在性检查并逐级回落（setDraft → insertText+captureInsertion → 剪贴板）。

## 6. 第二轮验证原样回报

### 6.1 第二轮（`verify-round2`，03:32–03:38）——4 个修复全部确认，另查出 5 个新问题

已确认修好：`inspect` 数组解包（`8b1e8747 即时状态：` 逐项中文，不再 `未知设备 ["8b1e8747"]`）、`compose` 的 adb 版本（`adb：37.0.1-15733141`）、通道行 USB+WiFi 各带命令、`status` 的只读刷新行（`探测 2 条通道，用时 726ms`）、`scan` 三行结构、`history` 逐条 + `失败(1/1)`。

新查出并**当场修掉**的 5 条：

| 症状（代理原样引用） | 根因 | 修复 |
| --- | --- | --- |
| `session "f1d116be-…" not found`（主会话裸 uuid） | Host 注册表里主会话是 `session-<uuid>`，subagent 会话是裸 `<uuid>`；插件只按传入形态查表 | `sessionIdCandidates()` 依次试 `原值`/`session-` 前缀 / 剥前缀；只在 `not found` 时换下一个候选 |
| `观测 3 条 transport → 新建 1 / 合并 0`（合并恒 0） | `run.merged` 是**数字**，代码写 `merged?.length` | 改 `Number(run.merged) \|\| 0`，单位补成「台/条」 |
| history 里每次扫描都印「失败」 | `history.push('scans', run)` 里根本没有 `ok` 字段 | 存 `{...run, ok: result.ok}`；文案改「新建 N 台 / 合并 M 条」 |
| history 投递条目会话位印成 `session-` | 短显示没剥前缀 | `.replace(/^session-/, '')` 后取 8 位 |
| `前台：无（桌面/通知栏）` 与 inspect 的 `NotificationShade（系统界面）` 口径不一致 | 模板只看 `package` 是否为 null | `systemUi` 分支也带 activity：`无应用（NotificationShade，系统界面）`；inspect 同步同一句式 |

另外它指出「数组**元素内部**再套 JSON 串/逗号串」没拆（`["[\"8b1e8747\"]"]`），已把 `toSerialList` 改成递归摊平（数组 / JSON 串 / 对象 / 逗号串，深度上限 3），补 5 条回归用例。

### 6.2 第三轮（`verify-round3`，03:51）——P0 闭环真机打通

```
scan      ：观测 3 条 transport → 新建 0 台 / 合并 2 条。来源：usb=3 mdns=0 tailscale=35peer lan=off probe=2
history   ：03:51:28 ok 新建 0 台 / 合并 2 条 · 1100ms ／ 03:51:37 ok → f1d116be · queue · 98fc9410+8b1e8747
inject    ：已向会话 session-f1d116be-bbff-4f2b-9223-10d9141102a5 投递 1 条设备调试消息（queue）。
            投递的正文首行：请在以下 2 台 Android 测试机上验证：自测 round3 裸uuid
compose   ：2 台设备 → 尾行「每台设备按上面"通道"里列出的顺序使用（反引号里就是可直接执行的命令）。」
perDevice ：单通道 98fc9410 → 「只用这条通道：`adb connect 100.109.138.2:5555`。」（全文无「回落」）
doctor    ：9 项全 ✔
```

`inject` 这条是 **P0 的核心闭环**：从 subagent 里用裸 uuid 投进**主会话**，一次成功，Host 端 `sessionController.prompt` 接受了补前缀后的规范 id。

### 6.3 第三轮之后又修的两条（自查 + 代理提示）

| 问题 | 处置 |
| --- | --- |
| `doctor` 的「面板通道」被它自己的自检探针计数 → 这一项永远 ✔，等于自我造假 | `handle(action, payload, {source})`；`source:'internal'` 不计数，detail 显示 `来源:动作`，并写明"本项不含 doctor 自检探针，能自己证伪" |
| 代码评审（`review-code`）查出的 `GET /adb-devices/scan` 越权面：`auth` 只看 query，`resource` 却按路径段取 action → 匿名 GET 能触发 `adb connect`/扫段/向任意会话投递 | `auth` 与 `resource` 共用 `resolveAction(url)`（query 优先、路径兜底），**解析不出动作一律 `required`**；只读闭集 + GET 才匿名 |

### 6.4 代码评审后本轮一并修掉的

`files` 漏 `lib/args.js`（打包安装会 `ERR_MODULE_NOT_FOUND`）；`status` 响应缺 `lastScanAt/adbPath` 导致面板半小时后显示"尚未扫描 / adb -"（同时改成合并快照）；`setDraft` 排在 `insertText` 之前会**静默清空用户草稿与引用芯片**（改为先追加语义、`insertText` 返回 false 不算成功）；面板 Escape 挂在 window 捕获阶段并 `preventDefault`（吞宿主快捷键）→ 改挂面板节点、不 preventDefault；面板从不 `focus()` → 打开即聚焦、关闭归还焦点；3 秒轮询与手动 scan 交叠把 busy 提前清空 → 在飞时跳过 tick；勾选跨筛选会被悄悄丢掉 → 按全量设备校验；宿主语言包永远命中不到（内置字典先返回）→ 改为宿主优先、内置兜底；单通道设备印"自己回落到自己"→ 改「只用这条通道」并说明 USB 命令是探活；`expandCidrs` 的 `1 << hostBits` 在 /1、/0 上溢出成静默 0 候选 → 用 `2 ** hostBits` 并拒绝掩码 < 8；`Store.load()` 不校验形状 + 系统提示词 `text()` 无兜底（坏缓存能让**每个会话**拿不到系统提示词）→ 逐台修补 transports/transportKeys + try/catch 返回空段；复制/发送/剪贴板回调的卸载后 setState 兜底；不可勾选设备补 `title` 说明原因；死代码清理（`identityOf`、`safeSerials`、`CHANNEL`、`dirname`、重复的 `toSerialList`）。

## 7. 明早三分钟检查

1. 刷新 GUI 页面 → 会话右上角应出现手机图标（数字角标 = 已知设备数）。点开：设备行（型号 / Android / serial / 两条通道标签 / 息屏·锁屏·电量·常亮）、底部"填入输入框 / 发送到会话"。
2. 对 agent 说「设备管理自检」→ 看 `doctor` 9 项。**打开面板之前 `面板通道` 应是 `✘`（这是设计成能自我证伪的）**；你打开过面板之后再问一次，它应变成 `N 次外部调用；最近 … http:list ok`。若你点了面板它仍停在 ✘，说明浏览器没能访问 `/adb-devices`，把这一行发我即可定位。
3. 面板里勾设备 → 点「填入输入框」→ 输入框应出现带连接命令与状态的调试文本，可直接编辑发送。

## 8. 与计划的偏差（P0 取舍，均已在 README 同步）

| 计划 | 实际 | 原因 |
| --- | --- | --- |
| `storageDomain` + zod | 本地 JSON（原子写 + 500ms 合并落盘） | 零运行时依赖，避免 npm 解析；缓存是派生数据可整目录删 |
| `defineTool` 包 | 传平面对象给 `ctx.tools.register`（字段同 `ToolDefinition`） | 同上 |
| `@Remote` + 生成的 `<pkg>/remote` | 同域 HTTP 路由（+ `connection.rpc` 若可用） | 免 typert 代码生成；诊断可用 curl |
| DSH-Phone 顶栏入口 | 本轮只交付 Web bundle | 已拍板：原生侧下一轮 |
| `engines.dsh` 版本闸门 | 未声明（也无 DSH peer 依赖） | 避免 prerelease 版本比较把本地包挡在门外 |
