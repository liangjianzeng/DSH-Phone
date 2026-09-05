# APK 下载触发能力评估 + 高概率优化建议

> 结论先行：手机 App 侧链路在「产物 chips 存在且为 `<button>` + 带 `title`」时已经基本完备；
> 所谓「有时候能下载、有时候不能」几乎全部来自两个脆弱点——
> 1) App 与 DSH Web UI 的 chips DOM 强耦合（ chips 没渲染成 button、或没 title 就彻底失效）；
> 2) 对话里的「纯文本路径」目前完全不会被识别。
> 因此**提升下载概率是可行的**，且最高杠杆在「模型/提示词侧」（无需改 App 代码）。

---

## 一、当前 APK 下载完整链路（已逐行核对）

```
模型 write 工具写文件
  └─ DSH Web UI 渲染「产物 chips」：<button class="_fileMention_*" title="云端路径">  ← 关键假设
       │  用户点击 chip
       │        └─ JS 桥 artifactBridgeJs（webview_bridges.dart）
       │             ② button 分支：className 含 fileMention 或 title 带后缀 → 拦截
       │             发送 {type:'resource', path:'云端路径'}
       └─ Dart parseArtifactHit → typeOfPath 命中 .apk → ArtifactType.resource
            └─ _openArtifact → resource && _resourceDownloadEnabled
                 └─ _resolveHitPath：path 含 \ 或 / → 视为完整路径直接返回
                      └─ _openResourceDownload → DownloadManager.start(path)
                           └─ TunnelService.openRemoteFile → SFTP 流式下载（256MB 上限）
```

三条触发入口（JS 桥三段）：
- **① 链接型**（`<a href="...apk">`）：先 `findMentionPath` 反查 chips 路径，缺省回传 `dirs`。
- **② chip 按钮型**（`<button class="*_fileMention_*" title="路径">`）：直接取 title。
- **③ 代码块型**（`<pre>/<code>` 内单行且带后缀）：`findMentionPath` 查 chips；
  路径本身含分隔符则直接用文本；否则回传 `dirs` 由 App 拼接。

---

## 二、失败点 / 脆弱点（按影响排序）

| # | 脆弱点 | 现象 | 根因 |
|---|--------|------|------|
| F1 | **与 chips DOM 强耦合** | 时好时坏 | `findMentionPath`/`collectProducedDirs`/②分支**只认 `<button>` + `title`**。DSH 若把产物渲染成 `<a>/<span>/<div>` 或无 `title`，三段全部落空。 |
| F2 | **纯文本路径不识别** | 「模型返回的下载目录」点不动 | 段落(`<p>/<div>`)里的路径不在 pre/code/button/a 内，**无任何分支命中**。 |
| F3 | **链接型无 chips 时静默失败** | 点链接提示「不支持直接下载」 | ①分支 `findMentionPath` 返回空、`dirs` 也空 → `path` 空 → `_openResourceDownload` 报「不支持直接下载」。 |
| F4 | **Windows 路径 SFTP 适配** | 路径对但下载失败 | `_sftpPathCandidates` 产出 `[原样, 斜杠化, 前加/]` 三种形态，能否打开取决于远端 SFTP 是否支持盘符路径（环境依赖，App 侧难控）。 |
| F5 | **开关/隧道未就绪** | 点了无反应/灰屏 | `_resourceDownloadEnabled` 虽默认 `true`，但被关闭则不触发；隧道未连则 `openRemoteFile` 返回 null。 |
| F6 | **256MB / 8MB 上限** | 超大文件中止 | `maxDownloadBytes=256MB` 限下载、`maxRemoteReadBytes=8MB` 限查看；APK 通常无碍。 |

> 注：F1 就是「时好时坏」的主因——成败取决于 DSH Web UI 当次是否把产物渲染成
> 一个「带 title 的 button」，而这不在 App 可控范围内。

---

## 三、优化建议（按杠杆率从高到低）

### A. 模型/提示词侧（**不改 App 代码，杠杆最高**，建议写进系统提示）

**规则 1 —— 一律用 write 工具写「带真实后缀的绝对路径」**
- `write(file_path: 'E:\\Work\\xxx.apk', ...)`：路径以 `.apk` 结尾 → 命中 `resourceSuffixes`，
  且 DSH 会把它渲染成产物 chips（②分支可触发）。
- 避免：写到 `.txt`/无后缀再改名；或只在文字里提一句文件名。

**规则 2 —— 同时把完整路径放进「围栏代码块」（关键兜底）**
- 在回复里用 ``` 把路径单独成行写出，例如：
  ```
  已写入：
  ```
  E:\Work\xxx.apk
  ```
  ```
- 依据：JS 桥 ③分支会识别 `pre/code` 内「单行 + 带后缀 + 含分隔符」的文本，
  **即使没有 chips 也能直接当 resource 触发**（`mentionPath = 文本` → `isResource=true`）。
- 这是目前 App 已支持、但常被忽略的兜底路径。

**规则 3 —— 路径与 chips 文件名保持一致**
- ①/③分支的 `findMentionPath` 靠「文件名（末段）匹配 chips 的 title」。
- write 路径的末段名 = chips 显示名，才能反查到完整路径。

**规则 4 —— 下发前自检**
- 确认手机侧「资源下载」开关开启（默认开，勿误关）+ SSH 隧道已连到对应主机。
- 大 APK 注意 256MB 上限（一般无碍）。

> 一句话口诀：**要下发 APK，就用 write 写进带 `.apk` 的远端路径，并在代码块里再写一遍完整路径，
> 让 Web UI 渲染成产物按钮 / 让 App 从代码块识别。**

---

### B. App 侧代码改进（进一步抬高下限，缓解 F1/F2/F3）

> 这些改动可把「依赖 DSH 渲染对 chips」的脆弱前提变弱，显著提升成功率。

- **B1 放宽 chips 选择器（治 F1）**：`findMentionPath`/`collectProducedDirs`/②分支
  除 `<button>` 外，额外兼容 `<a>`/`<span>`/`[data-file-path]`/`[data-remote-path]` 等
  带 `title`/`data-*` 路径属性的元素；②分支把 `fileMention` 匹配改为「className 或任意
  `data-*` 含 fileMention 即可」。
- **B2 新增「纯文本路径」识别（治 F2）**：对 `<p>/<div>/<li>` 等正文元素，
  单击命中且含资源后缀、含分隔符时，按 resource 处理（复用③分支逻辑）。
- **B3 链接型兜底（治 F3）**：①分支查不到 chips 时，若 href 本身是
  `/api/files/…`、`/files/…` 或直链，直接以 URL 经隧道取内容下载，
  而非仅报「不支持直接下载」。
- **B4 路径不可达时给「手动输入/复制路径」入口**：`_openResourceDownload` 在 `path` 为空时，
  除提示外提供「手动填远端路径」入口，避免一次失败就断掉。
- **B5 环境适配（治 F4）**：`_sftpPathCandidates` 对 Windows 盘符路径补充
  `\\<host>\share\…`（SMB）或 PowerShell `Get-Content` 等候选形态，提升远端可打开率。

---

## 四、优先级建议

1. **立即**：把「A 规则 1~4」写进系统提示 / 模型指引（零成本、立竿见影）。
2. **其次**：App 侧做 **B1 + B2**（解耦 chips DOM + 识别纯文本路径），这是「时好时坏」的根本解。
3. **补充**：B3/B4（链接兜底 + 手动输入），进一步抬高下限。
