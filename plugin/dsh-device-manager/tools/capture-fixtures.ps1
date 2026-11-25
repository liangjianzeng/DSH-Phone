# 抓取本机真机的 adb / tailscale 输出到 test/fixtures，供 selftest.mjs 回放。
# 用法：pwsh -File plugin/dsh-device-manager/tools/capture-fixtures.ps1
# 说明：DSH 沙箱里 Node 的 child_process.spawn 会被拒（EPERM），所以 fixture 由 PowerShell 直接跑 adb 抓取；
#       真机链路的最终验证走已安装插件的 Host 侧 ctx.subprocess。

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dir = Join-Path $PSScriptRoot '..\test\fixtures'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Write-NoBom($path, $text) {
  if ($null -eq $text) { $text = '' }
  [System.IO.File]::WriteAllText($path, [string]$text, [System.Text.UTF8Encoding]::new($false))
}

$adbCandidates = @(
  $env:DSH_DEVICE_MANAGER_ADB,
  "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
  "$env:ANDROID_HOME\platform-tools\adb.exe",
  'adb'
) | Where-Object { $_ -and (Test-Path $_ -ErrorAction SilentlyContinue) }
$adb = if ($adbCandidates.Count -gt 0) { $adbCandidates[0] } else { 'adb' }
$tailscale = if (Get-Command tailscale -ErrorAction SilentlyContinue) { 'tailscale' } else { "$env:ProgramFiles\Tailscale\tailscale.exe" }
"adb = $adb"

$lib = Join-Path $PSScriptRoot 'print-fact-script.mjs'
$script = node $lib
Write-NoBom (Join-Path $dir 'fact-script.txt') $script

function Capture($name, $exe, $arguments) {
  $output = & $exe @arguments 2>&1 | Out-String
  $code = $LASTEXITCODE
  Write-NoBom (Join-Path $dir $name) (($output).TrimEnd())
  "  {0,-26} exit={1} bytes={2}" -f $name, $code, ((Get-Item (Join-Path $dir $name)).Length)
  return $code
}

Capture 'adb-version.txt' $adb @('version') | Out-Null
Capture 'adb-devices.txt' $adb @('devices', '-l') | Out-Null
Capture 'adb-mdns-services.txt' $adb @('mdns', 'services') | Out-Null
Capture 'tailscale-status.json' $tailscale @('status', '--json') | Out-Null

$devices = (& $adb devices -l 2>$null | Select-String -Pattern '^\S+\s+device\b' | ForEach-Object { ($_ -split '\s+')[0] })
"devices: $($devices -join ', ')"
foreach ($target in $devices) {
  $safe = $target -replace '[^A-Za-z0-9]', '_'
  Capture "fact-$safe.txt" $adb @('-s', $target, 'shell', $script) | Out-Null
}

# 额外抓一份"设备不在"的负例，供离线断言（回放时用它验证错误路径不炸）。
Capture 'fact-missing.txt' $adb @('-s', 'no-such-device:5555', 'shell', $script) | Out-Null

"fixtures -> $dir"
