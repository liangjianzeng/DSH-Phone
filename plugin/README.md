# 自研 DSH 插件维护说明

这个目录是**所有自研 DSH 插件的唯一源码存放处**。两台主机（GeekPro、DGX）上的
`node_modules` 里那些只是部署副本——以前 `web-search-localxng` / `web-search-searxng`
就只存在于主机安装目录，仓库里一份都没有，主机重装即丢。现在起以本目录为准。

## 目录里有什么

| 插件 | 版本 | 作用 | 主机上的部署位置 | 启用方式 |
| --- | --- | --- | --- | --- |
| `dsh-device-manager` | 0.1.5 | 安卓测试机（adb）发现 / 状态面板 / 调试消息注入；DSH Web 顶栏手机图标 + DSH-Phone 原生面板共用 | `<DSH_HOME>/profiles/web/node_modules/@local/dsh-device-manager` | `profiles/web/cordis.patch.yml` 追加 `install/device-manager.cordis-insert.yml` |
| `web-search-localxng` | 0.1.0 | 免 key 直连多引擎中文搜索（bing_cn / baidu / sogou / so360 / quark / chinaso），带熔断与窗口预算 | `<DSH_HOME>/profiles/node_modules/web-search-localxng` | GeekPro 用 `cordis.patch.yml` 的 insert 块；DGX 用 `profiles/web/package.json` 的 `dsh.profile.bundles` 列名 |
| `web-search-searxng` | 0.1.0 | 走自建 SearXNG 实例的搜索 provider（实例地址写死在 `lib/index.js`，换机器要改） | `<DSH_HOME>/profiles/node_modules/web-search-searxng` | 同上（DGX 走 `bundles`；GeekPro 那台 searxng 行指向官方包 `@deepseek-ai/dsh-web-search-searxng`） |

两类插件的部署层不一样：`@local/*` 装在 **web profile** 里，`web-search-*` 装在
**profiles 共享层**。启用有两种等效机制——插件自带的 `cordis.patch.yml` 会在被
`bundles` 列到时把行插进服务树；profile 级 `cordis.patch.yml` 的 `- insert:` 块则可以在
插入的同时覆盖 config（预算、超时等）。

其它相关文件：

- `install/device-manager.cordis-insert.yml` —— 设备管理插件的完整注册块（含全部 config）。改配置改这份并同步到主机，别只改主机那份。
- `install/search-providers.cordis-insert.yml` —— 搜索 provider 的注册块与默认引擎选择。
- `tools/pack.mjs` —— 打安装包。
- `dist/` —— 打出来的 `<name>-<version>.tar.gz` + `SHA256SUMS.txt`，跟 `apk/` 一样入库保存。
- `../docs/dsh-device-manager-plugin-plan.md`、`dsh-device-manager-selftest-report.md` —— 设备管理插件的设计与自测记录。

> **不要把主机上整份 `cordis.patch.yml` 拷进仓库**：里面 `- id: web-search-deepseek`
> 那行是明文 DeepSeek apiKey。要保存配置只摘需要的块，密钥走 DSH 凭证库
> （`refs.DEEPSEEK_API_KEY`）。

## 主机清单

| 主机 | 系统 | 地址 | 登录 | DSH 启动方式 | adb |
| --- | --- | --- | --- | --- | --- |
| Liang-GeekPro | Windows | Tailscale `100.100.140.75` | SSH 密码 | `dsh web --no-open`，`DSH_HOME=C:/Users/jianz/.dsh`，只监听 `127.0.0.1:3080` | `C:\Users\jianz\AppData\Local\Android\Sdk\platform-tools\adb.exe` |
| gx10-85f3 (DGX) | Linux aarch64 | Tailscale `100.81.83.59` | SSH key：`C:\Users\jianz\AppData\Local\NVIDIA Corporation\Sync\config\nvsync.key`，用户 `jianzengliang`（`~/.ssh/config` 里的 `sync-DgxSpark`） | `~/.npm-global/bin/dsh web --trusted-host 100.81.83.59:3080`，只监听 `127.0.0.1:3080` | `/usr/bin/adb`（1.0.41） |

两台都是只监听回环，DSH-Phone 通过自己的 SSH 隧道实例访问，所以插件装在哪台，
那台就是 adb 发现设备的主机。

**GeekPro 的坑**：`C:\nvm4w\nodejs` 那个 junction 指向已删除的 `nvm\v25.2.0`，
记录的启动命令会秒退。手动起要用
`C:\Users\jianz\.workbuddy\binaries\node\versions\22.22.2-6\node.exe`
跑 `...\@deepseek-ai\dsh\lib\bin.js web --no-open`，并设 `DSH_HOME=C:/Users/jianz/.dsh`、
`NODE_OPTIONS=""`。另外在 SSH 会话里起的进程会随会话一起死，要用
`Invoke-CimMethod -ClassName Win32_Process -MethodName Create` 脱管启动。

## 日常维护流程

1. **改源码**：只改 `plugin/<name>/` 下的文件。
2. **bump 版本号**：改 `package.json` 的 `version`。不改版本号就无法判断主机上跑的到底是哪一份——这是之前排查 404 时最费时间的地方。
3. **自检**：`node --check` 入口文件；设备管理插件还有 `tools/selftest.mjs`。
4. **打包**：`node plugin/tools/pack.mjs`（可跟目录名只打一个），产物进 `plugin/dist/`。
5. **部署到主机**（见下面命令），然后**重启 DSH 或在插件管理里把该插件关掉再打开**——
   宿主在插件激活时才组装服务端并打包 `client.js`，不重启的话磁盘上的新文件不会生效。
   重启会打断正在跑的会话，动手前先看主机上有没有活跃 turn。
6. **验证**：Web 面板看顶栏入口和列表；设备管理还可以直接
   `GET /adb-devices/list?action=list` 数设备条数。

### 部署：GeekPro（Windows）

```powershell
# 在 GeekPro 上执行（$DSH = 'C:\Users\jianz\.dsh'）
tar -xzf C:\Users\jianz\tmp\dsh-device-manager-0.1.5.tar.gz `
    -C $DSH\profiles\web\node_modules\@local
# 注册块：确认 profiles\web\cordis.patch.yml 里有 install\device-manager.cordis-insert.yml 那段
```

### 部署：DGX（Linux）

```bash
mkdir -p ~/.dsh/profiles/web/node_modules/@local
tar -xzf /tmp/dsh-device-manager-0.1.5.tar.gz -C ~/.dsh/profiles/web/node_modules/@local
grep -q dsh-device-manager ~/.dsh/profiles/web/cordis.patch.yml || {
  cp ~/.dsh/profiles/web/cordis.patch.yml ~/.dsh/profiles/web/cordis.patch.yml.bak-$(date +%Y%m%d-%H%M%S)-pre_dm
  printf '\n' >> ~/.dsh/profiles/web/cordis.patch.yml
  cat /tmp/device-manager.cordis-insert.yml >> ~/.dsh/profiles/web/cordis.patch.yml
}
node --check ~/.dsh/profiles/web/node_modules/@local/dsh-device-manager/index.js
```

搜索插件同理，只是目标目录换成 `~/.dsh/profiles/node_modules/<name>`，启用改在
`profiles/web/package.json` 的 `dsh.profile.bundles` 数组里加名字。

### 从主机抢救源码

主机上若出现过仓库没有的改动（直接在安装目录改过），拉回来覆盖 `plugin/<name>/`，
然后照常 bump 版本、打包：

```bash
ssh -i "<nvsync.key>" jianzengliang@100.81.83.59 \
  "tar czf - -C ~/.dsh/profiles/node_modules web-search-localxng" > web-search-localxng.tgz
```

## 已知的坑（都踩过，别再踩）

- **HTTP 404**：主机进程启动时间早于插件注册块，或路由压根没注册。注意 webServer 的
  鉴权门对**所有**未匹配路径都回 401，收到 401 不能证明路由存在。
- **POST 405**：`webServer.register` 用 `resource:` 注册的路由按设计只应答 GET/HEAD，
  其它方法在匹配之前就 405。要收 POST 必须注册 `handler:`。
- **响应发不出去**：`res.end()` 只吃 Buffer/Uint8Array，`await response.arrayBuffer()`
  拿到的是 ArrayBuffer，得 `Buffer.from(...)` 包一层。
- **面板恒显示 0 台设备**：`handle()` 返回的是 RPC 双层信封 `{ok, value:{ok, text, data}}`，
  HTTP 通道也带这层壳，客户端不剥就永远读不到数据。
- **设备重复显示**：某轮拿不到 `ro.serialno` 时会按 `tmp:<host:port>` 建身份，同一端点
  上一轮可能已挂在真实设备下——`lib/registry.js` 的 `ownerOfEndpoint()` 负责并回去。
- **改完不生效**：见上面第 5 步，插件激活时机问题，不是代码问题。
