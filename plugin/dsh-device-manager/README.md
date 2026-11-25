# dsh-device-manager

DSH 顶栏「安卓测试机」入口：点会话右上角的手机图标 → 下拉面板，看**本主机**能连到的 Android 测试机，
勾选后把「去哪台设备调试、它现在什么状态、怎么连」注入消息框或排队投递到会话。

设计文档：`E:\DTXY\DSH-Phone\docs\dsh-device-manager-plugin-plan.md`

## 它做什么

| 能力 | 说明 |
| --- | --- |
| 扫描 | 由**主机进程**执行：`adb devices -l`（USB/已连接）、`adb mdns services`（无线调试）、`tailscale status --json`（peer 网段）、可选局域网 CIDR 扫段、远程 adb server |
| 归并 | 同一台手机的 USB + WiFi + tailnet 多条 transport 按 `ro.serialno` 合成一台设备，通道各自保留状态 |
| 状态 | 亮屏/息屏、锁屏/解锁（含通知栏焦点兜底）、常亮（`stay_on_while_plugged_in` 位掩码）、电量与供电方式、前台应用、分辨率/DPI、自动亮度 |
| 缓存 | 首次扫描后落本地 JSON（`~/.dsh/device-manager/registry.json`，派生缓存，删掉即可重来）；面板打开只刷状态，重扫才回主机全扫 |
| 注入 | 勾选单台/全部 → 三种模板生成消息 → `填入输入框`（`inputActions.setDraft`）或 `发送到会话`（Host 侧 `sessionController.prompt(mode:'queue')`） |
| 模型侧 | `adb_devices` 工具 + 系统提示词段（`exposeToModel`），让 agent 自己知道该去哪台机器验证 |

顶栏图标旁的数字角标 = 已知设备数，颜色随健康度变化（绿/黄/红）。

## 安装

```bash
# 目录已就绪，DSH 里执行（或让 agent 调 plugin_manager install_bundle）
dsh plugin install E:\DTXY\DSH-Phone\plugin\dsh-device-manager
dsh plugin enable device-manager
```

零运行时依赖（不 import `@deepseek-ai/*`），所以本地目录链接即可安装，不需要 npm 解析。

## 配置（`cordis.patch.yml` 里该行的 `config`）

```yaml
- insert:
    - id: device-manager
      name: '@local/dsh-device-manager'
      config:
        adbPath: auto            # auto = PATH → ANDROID_HOME → %LOCALAPPDATA%\Android\Sdk\platform-tools
        exposeToModel: true
        sources:
          usb: { enabled: true }
          lan:                   # 扫段默认关闭：必须显式写 CIDR 才扫
            enabled: false
            cidrs: [192.168.1.0/24]
            ports: [5555]
            ratePerSec: 200
            maxIps: 512
          tailscale: { enabled: true, ports: [5555] }
          emulator: { enabled: true }
          remoteAdbServers: []   # "host:5037"
        poll: { panelMs: 3000, backgroundMs: 30000, staleAfterMs: 120000, pruneAfter: 3 }
        inject: { mode: queue, template: default, allowSteer: true }
```

## 安全边界

- 局域网扫段默认关闭，且只接受显式 CIDR；有 `maxIps` / `ratePerSec` / `maxConcurrency` 上限。
- 不给模型暴露任意 `adb shell`；`adb_devices` 的 `action` 是闭集，P0 没有任何破坏性动作。
- 外部命令只在 DSH Host 进程里跑（不在 agent 沙箱），P0 不暴露 install/screenshot/logcat。
- HTTP 路由 `/adb-devices/*`：读接口（`list/status/doctor/history`）匿名可读，写接口要求已认证凭据。

## 自测

```bash
# 离线 + fixture 回放（fixture 由真机抓取）：151 项断言
node plugin/dsh-device-manager/tools/selftest.mjs

# 只跑离线用例
node plugin/dsh-device-manager/tools/selftest.mjs --offline

# 追加真机扫描（需要能在本机 spawn adb；DSH 沙箱内会被拒）
node plugin/dsh-device-manager/tools/selftest.mjs --live

# 重新抓取 fixture（PowerShell；执行策略受限时把脚本内容贴进 pwsh 直接跑）
powershell -File plugin/dsh-device-manager/tools/capture-fixtures.ps1
```

装好之后在会话里直接对 agent 说「自检一下设备管理」，它会调 `adb_devices(action:'doctor')`，
逐项回报 adb / adb devices / mDNS / Tailscale / 网段策略 / 缓存 / 会话投递是否可用。

## 与计划的偏差（P0 取舍）

| 计划 | 实际 | 原因 |
| --- | --- | --- |
| `storageDomain` + zod 存储 | 本地 JSON 文件（原子写 + 500ms 合并落盘） | 保持零运行时依赖，避免 npm 解析；缓存是派生数据，可整目录删除 |
| `defineTool` 包 | 直接传 `ToolDefinition` 平面对象给 `ctx.tools.register` | 同上；字段与 `@deepseek-ai/dsh-tools` 的 `ToolDefinition` 一致 |
| `@Remote` 服务 + 生成的 `<pkg>/remote` | 同域 HTTP 路由（+ `connection.rpc` 若可用） | 免 typert 代码生成；面板用 `fetch`，诊断可用 curl |
| DSH-Phone 顶栏入口 | 本轮只交付 Web bundle | 已拍板：原生侧下一轮 |
