# ============================================================
# C盘瘦身助手 v1.2 —— 扫描 / 数据迁移 / 卸载 / 安全清理 / 报告
# 用法：双击同目录的 C_Disk_Slim_Helper_v1.2.bat
# 设计原则：只读扫描默认安全；任何迁移/卸载/删除都需要人工确认。
# v1.2 重点：保留 v1.1 安全修订；识别已迁移 Junction 并禁止重复迁移；修复退出菜单。
# ============================================================
[CmdletBinding()]
param([switch]$ReportOnly)

$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "C盘瘦身助手 v1.2"

function GB($b) { if ($null -eq $b) { return 0 }; [math]::Round($b / 1GB, 1) }
function MB($b) { if ($null -eq $b) { return 0 }; [math]::Round($b / 1MB, 1) }
function Log($m) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  Write-Host $m
  Add-Content -LiteralPath "C:\Users\Public\c_lean_log.txt" -Value $line -Encoding UTF8
}
function Get-DirStats($p) {
  if (-not (Test-Path -LiteralPath $p)) { return [PSCustomObject]@{ Bytes = 0; Files = 0 } }
  $m = Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
  $sum = if ($null -eq $m.Sum) { 0 } else { [int64]$m.Sum }
  [PSCustomObject]@{ Bytes = $sum; Files = [int64]$m.Count }
}
function Is-ReparsePoint($p) {
  if (-not (Test-Path -LiteralPath $p)) { return $false }
  $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return $false }
  return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}
function Get-LinkTarget($p) {
  if (-not (Is-ReparsePoint $p)) { return $null }
  $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return $null }
  $target = $item.Target
  if ($target -is [System.Array]) { $target = $target | Select-Object -First 1 }
  if ([string]::IsNullOrWhiteSpace([string]$target)) { return $null }
  return [string]$target
}
function Get-LinkType($p) {
  if (-not (Is-ReparsePoint $p)) { return $null }
  $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  if ($null -eq $item) { return $null }
  if ([string]::IsNullOrWhiteSpace([string]$item.LinkType)) { return "ReparsePoint" }
  return [string]$item.LinkType
}
function Remove-JunctionOnly($p) {
  if (-not (Is-ReparsePoint $p)) { throw "目标不是链接，拒绝删除：$p" }
  & cmd.exe /d /c "rmdir `"$p`"" | Out-Null
  if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $p)) { throw "无法移除链接：$p" }
}

$script:Targets = @(
  @{N="钉钉数据"; S="$env:APPDATA\DingTalk"; D="D:\Software\AppData\Roaming\DingTalk"},
  @{N="钉钉缓存Local"; S="$env:LOCALAPPDATA\DingTalk_133"; D="D:\Software\AppData\Local\DingTalk_133"},
  @{N="剪映数据"; S="$env:LOCALAPPDATA\JianyingPro"; D="D:\Software\AppData\Local\JianyingPro"},
  @{N="WPS数据"; S="$env:APPDATA\kingsoft"; D="D:\Software\AppData\Roaming\kingsoft"},
  @{N="腾讯系(微信/企微/腾讯会议)"; S="$env:APPDATA\Tencent"; D="D:\Software\AppData\Roaming\Tencent"},
  @{N="TRAE数据"; S="$env:APPDATA\TRAE SOLO CN"; D="D:\Software\AppData\Roaming\TRAE SOLO CN"}
)

# ---------- 1. 扫描 ----------
function Show-Disk {
  Write-Host "`n===== 磁盘空间 =====" -ForegroundColor Cyan
  Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $pct = if ($_.Size -gt 0) { [math]::Round($_.FreeSpace / $_.Size * 100) } else { 0 }
    Write-Host ("  {0}  总 {1} GB / 剩余 {2} GB ({3}%)" -f $_.DeviceID, (GB $_.Size), (GB $_.FreeSpace), $pct)
  }
}
function Show-TopDirs {
  Write-Host "`n===== C盘主要占用（只读扫描）=====" -ForegroundColor Cyan
  Write-Host "  注：Users 与 AppData 是包含关系，数值不可直接相加。" -ForegroundColor DarkGray
  Write-Host "  注：若目录是 Junction/软链接，递归统计可能包含 D 盘目标数据，不等于物理占用 C 盘。" -ForegroundColor DarkGray
  $items = @(
    [PSCustomObject]@{ N="用户目录 Users"; P=$env:USERPROFILE; S=(Get-DirStats $env:USERPROFILE).Bytes },
    [PSCustomObject]@{ N="AppData(Roaming)"; P=$env:APPDATA; S=(Get-DirStats $env:APPDATA).Bytes },
    [PSCustomObject]@{ N="AppData(Local)"; P=$env:LOCALAPPDATA; S=(Get-DirStats $env:LOCALAPPDATA).Bytes },
    [PSCustomObject]@{ N="Program Files"; P="C:\Program Files"; S=(Get-DirStats "C:\Program Files").Bytes },
    [PSCustomObject]@{ N="Program Files(x86)"; P="C:\Program Files (x86)"; S=(Get-DirStats "C:\Program Files (x86)").Bytes },
    [PSCustomObject]@{ N="ProgramData"; P="C:\ProgramData"; S=(Get-DirStats "C:\ProgramData").Bytes },
    [PSCustomObject]@{ N="Windows"; P="C:\Windows"; S=(Get-DirStats "C:\Windows").Bytes }
  )
  $items | Sort-Object S -Descending | ForEach-Object {
    Write-Host ("  {0,-22} {1,7} MB   {2}" -f $_.N, (MB $_.S), $_.P)
  }

  Write-Host "`n===== AppData 中占空间较大的一级目录（只读）=====" -ForegroundColor Cyan
  $big = @()
  foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA)) {
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $s = (Get-DirStats $_.FullName).Bytes
      if ($s -gt 300MB) {
        $note = ""
        if (Is-ReparsePoint $_.FullName) {
          $target = Get-LinkTarget $_.FullName
          $note = if ($target) { " [已迁移 -> $target]" } else { " [链接目录]" }
        }
        $big += [PSCustomObject]@{ N=$_.Name; MB=(MB $s); P=$_.FullName; Note=$note }
      }
    }
  }
  $big | Sort-Object MB -Descending | Select-Object -First 15 | ForEach-Object {
    Write-Host ("  {0,-30} {1,7} MB   {2}{3}" -f $_.N, $_.MB, $_.P, $_.Note)
  }
}

# ---------- 2. 数据迁移（事务化 + 备份保留） ----------
function Move-SoftwareData {
  param($Name, $Src, $DstRoot)

  if (-not (Test-Path -LiteralPath $Src)) {
    Write-Host ("  [跳过] {0}：源目录不存在 {1}" -f $Name, $Src) -ForegroundColor DarkGray
    return
  }
  if (Is-ReparsePoint $Src) {
    $actualTarget = Get-LinkTarget $Src
    $linkType = Get-LinkType $Src
    if ($actualTarget) {
      Write-Host ("  [跳过] 已迁移：{0} ({1}) -> {2}" -f $Src, $linkType, $actualTarget) -ForegroundColor Yellow
    } else {
      Write-Host ("  [跳过] 源目录已经是链接（{0}），禁止重复迁移：{1}" -f $linkType, $Src) -ForegroundColor Yellow
    }
    return
  }
  if (-not (Test-Path -LiteralPath "D:\")) {
    Write-Host "  [错误] 未检测到 D: 盘，已中止。" -ForegroundColor Red
    return
  }

  $backup = "$Src.old"
  if (Test-Path -LiteralPath $backup) {
    Write-Host "  [错误] 已存在备份目录：$backup" -ForegroundColor Red
    Write-Host "  为避免覆盖旧备份，本次不继续。请先用菜单 [6] 处理迁移备份。"
    return
  }

  if (Test-Path -LiteralPath $DstRoot) {
    $existing = @(Get-ChildItem -LiteralPath $DstRoot -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
      Write-Host "  [错误] 目标目录非空：$DstRoot" -ForegroundColor Red
      Write-Host "  为避免把旧数据与新数据混合，本次不继续。"
      return
    }
  }

  $srcStats = Get-DirStats $Src
  Write-Host ("`n===== 迁移: {0}（{1} MB / {2} 个文件）=====" -f $Name, (MB $srcStats.Bytes), $srcStats.Files) -ForegroundColor Yellow
  Write-Host "  源:   $Src"
  Write-Host "  目标: $DstRoot"
  Write-Host "  请先彻底退出对应软件。流程：复制 -> 校验 -> 原目录改名为 .old -> 建立 Junction。"
  Write-Host "  成功后 .old 会暂时保留在 C 盘，确认软件正常后再用菜单 [6] 删除。" -ForegroundColor Yellow
  $ok = Read-Host "  确认迁移? (y=是 n=跳过)"
  if ($ok -ne "y") { Write-Host "  已跳过"; return }

  try {
    New-Item -ItemType Directory -Path $DstRoot -Force -ErrorAction Stop | Out-Null
    Write-Host "  正在复制..." -NoNewline
    & robocopy.exe $Src $DstRoot /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NP /NJH /NJS /MT:8 | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { throw "robocopy 失败，退出码 $rc" }

    $dstStats = Get-DirStats $DstRoot
    $diff = [math]::Abs($srcStats.Bytes - $dstStats.Bytes)
    Write-Host (" 完成。源={0}MB/{1}文件，目标={2}MB/{3}文件" -f (MB $srcStats.Bytes), $srcStats.Files, (MB $dstStats.Bytes), $dstStats.Files)
    if ($diff -gt 3MB -or $srcStats.Files -ne $dstStats.Files) {
      throw "复制校验未通过（大小差异 >3MB 或文件数不同），原目录尚未改动"
    }

    Move-Item -LiteralPath $Src -Destination $backup -ErrorAction Stop
    try {
      New-Item -ItemType Junction -Path $Src -Target $DstRoot -ErrorAction Stop | Out-Null
      if (-not (Is-ReparsePoint $Src)) { throw "Junction 验证失败" }
    } catch {
      if (Test-Path -LiteralPath $Src) {
        if (Is-ReparsePoint $Src) { Remove-JunctionOnly $Src }
      }
      if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $Src)) {
        Move-Item -LiteralPath $backup -Destination $Src -ErrorAction Stop
      }
      throw "建立链接失败，已自动回滚原目录。$($_.Exception.Message)"
    }

    Write-Host "  [成功] 已建立 Junction，程序仍使用原路径，实际数据位于 D 盘。" -ForegroundColor Green
    Write-Host "  [重要] C 盘的 .old 备份尚未删除，所以此刻不会释放这部分空间。" -ForegroundColor Yellow
    Write-Host "  请先打开软件验证，确认正常后再使用菜单 [6] 完成收尾。"
    Log "迁移完成(待收尾): $Name ($Src -> $DstRoot), backup=$backup"
  } catch {
    Write-Host ("  [中止] {0}" -f $_.Exception.Message) -ForegroundColor Red
    Log "迁移失败: $Name - $($_.Exception.Message)"
  }
}

function Invoke-MigrateMenu {
  Write-Host "`n===== 软件数据迁移到 D 盘 =====" -ForegroundColor Cyan
  Write-Host "  已是 Junction/软链接的项目会标记为 [已迁移]，并禁止重复迁移。" -ForegroundColor DarkGray
  for ($i=0; $i -lt $script:Targets.Count; $i++) {
    $t = $script:Targets[$i]
    if (-not (Test-Path -LiteralPath $t.S)) {
      Write-Host ("  [{0}] {1}  (无数据)" -f $i, $t.N) -ForegroundColor DarkGray
      continue
    }
    if (Is-ReparsePoint $t.S) {
      $actualTarget = Get-LinkTarget $t.S
      $linkType = Get-LinkType $t.S
      if ($actualTarget) {
        Write-Host ("  [{0}] {1}  [已迁移:{2}] -> {3}" -f $i, $t.N, $linkType, $actualTarget) -ForegroundColor Green
      } else {
        Write-Host ("  [{0}] {1}  [已链接:{2}]" -f $i, $t.N, $linkType) -ForegroundColor Green
      }
      continue
    }
    $sz = MB (Get-DirStats $t.S).Bytes
    Write-Host ("  [{0}] {1}  {2} MB" -f $i, $t.N, $sz)
  }
  Write-Host "  [a] 全部依次处理（已迁移项自动跳过）    [q] 返回"
  $sel = Read-Host "  选择序号(可逗号分隔, 如 0,2)"
  if ($sel -eq "q") { return }
  if ($sel -eq "a") {
    foreach ($t in $script:Targets) {
      if (Is-ReparsePoint $t.S) {
        $actualTarget = Get-LinkTarget $t.S
        Write-Host ("  [跳过] {0} 已迁移{1}" -f $t.N, $(if ($actualTarget) { " -> $actualTarget" } else { "" })) -ForegroundColor DarkGray
        continue
      }
      Move-SoftwareData $t.N $t.S $t.D
    }
    return
  }
  foreach ($i in ($sel -split "," | ForEach-Object { $_.Trim() })) {
    if ($i -match "^\d+$" -and [int]$i -lt $script:Targets.Count) {
      $t = $script:Targets[[int]$i]
      if (Is-ReparsePoint $t.S) {
        $actualTarget = Get-LinkTarget $t.S
        Write-Host ("  [禁止重复迁移] {0} 已迁移{1}" -f $t.N, $(if ($actualTarget) { " -> $actualTarget" } else { "" })) -ForegroundColor Yellow
        continue
      }
      Move-SoftwareData $t.N $t.S $t.D
    }
  }
}

# ---------- 3. 卸载软件 ----------
function Parse-UninstallCommand($cmd) {
  $c = [Environment]::ExpandEnvironmentVariables([string]$cmd).Trim()
  if ($c -match '^"([^"]+)"\s*(.*)$') { return [PSCustomObject]@{ Exe=$Matches[1]; Args=$Matches[2] } }
  if ($c -match '^(.*?\.exe)\s*(.*)$') { return [PSCustomObject]@{ Exe=$Matches[1]; Args=$Matches[2] } }
  return [PSCustomObject]@{ Exe=$c; Args="" }
}
function Invoke-UninstallMenu {
  Write-Host "`n===== 卸载软件（系统卸载列表）=====" -ForegroundColor Cyan
  Write-Host "  加载中..."
  $apps = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*","HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.UninstallString -and $_.DisplayName -notmatch "Microsoft|Windows|Visual C\+\+|\.NET|Update for|Security Update|NVIDIA|AMD|Realtek|HP |OEM|DirectX" } |
    Select-Object DisplayName, DisplayVersion, UninstallString | Sort-Object DisplayName
  if (-not $apps) { Write-Host "  未找到可卸载的第三方软件"; return }

  for ($i=0; $i -lt $apps.Count -and $i -lt 60; $i++) { Write-Host ("  [{0}] {1}" -f $i, $apps[$i].DisplayName) }
  Write-Host "  [q] 返回"
  $sel = Read-Host "  选择序号卸载"
  if ($sel -eq "q") { return }
  if ($sel -notmatch "^\d+$") { Write-Host "  无效序号"; return }
  $idx = [int]$sel
  if ($idx -lt 0 -or $idx -ge $apps.Count) { Write-Host "  无效序号"; return }

  $a = $apps[$idx]
  Write-Host ("  卸载: {0}" -f $a.DisplayName) -ForegroundColor Yellow
  Write-Host ("  原始命令: {0}" -f $a.UninstallString)
  $ok = Read-Host "  确认卸载? (y=是)"
  if ($ok -ne "y") { Write-Host "  已取消"; return }

  try {
    if ($a.UninstallString -match "(?i)msiexec" -and $a.UninstallString -match '\{([0-9A-Fa-f\-]+)\}') {
      $guid = $Matches[1]
      Start-Process msiexec.exe -ArgumentList "/x {$guid}" -Verb RunAs -Wait -ErrorAction Stop
    } else {
      $parts = Parse-UninstallCommand $a.UninstallString
      $exe = $parts.Exe; $args = $parts.Args
      if ([string]::IsNullOrWhiteSpace($exe)) { throw "无法解析卸载程序路径" }
      if ([string]::IsNullOrWhiteSpace($args)) {
        Start-Process -FilePath $exe -Verb RunAs -Wait -ErrorAction Stop
      } else {
        Start-Process -FilePath $exe -ArgumentList $args -Verb RunAs -Wait -ErrorAction Stop
      }
    }
    Write-Host "  卸载程序已完成/退出，可重新扫描确认效果。" -ForegroundColor Green
    Log "触发卸载: $($a.DisplayName)"
  } catch {
    Write-Host ("  [失败] 无法启动卸载程序：{0}" -f $_.Exception.Message) -ForegroundColor Red
  }
}

# ---------- 4. 安全清理（仅可再生缓存/临时文件） ----------
function Invoke-CleanJunk {
  Write-Host "`n===== 安全清理（保守模式）=====" -ForegroundColor Cyan
  Write-Host "  会清理：用户/系统临时文件、缩略图、浏览器缓存、着色器缓存。"
  Write-Host "  明确保留：Windows Logs、WER、CrashDumps、Minidump、个人文件、回收站。" -ForegroundColor Green
  Write-Host "  Windows Update 下载缓存 v1.2 也不自动删除，避免在更新/诊断期间误清。" -ForegroundColor DarkGray
  $ok = Read-Host "  确认清理? (y=是)"
  if ($ok -ne "y") { Write-Host "  已取消"; return }

  $script:freed2 = 0
  function CleanDirContents($label, $path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $before = (Get-DirStats $path).Bytes
    Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $after = (Get-DirStats $path).Bytes
    $d = [math]::Max(0, $before - $after)
    $script:freed2 += $d
    Write-Host ("  清理 {0}: 释放 {1} MB" -f $label, (MB $d))
  }

  CleanDirContents "用户临时" $env:TEMP
  CleanDirContents "系统临时" "C:\Windows\Temp"
  CleanDirContents "DirectX 着色器缓存" "$env:LOCALAPPDATA\D3DSCache"
  CleanDirContents "NVIDIA DX 缓存" "$env:LOCALAPPDATA\NVIDIA\DXCache"
  CleanDirContents "NVIDIA GL 缓存" "$env:LOCALAPPDATA\NVIDIA\GLCache"

  $td = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
  if (Test-Path -LiteralPath $td) {
    $before = @(Get-ChildItem -LiteralPath $td -Filter "thumbcache_*" -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Get-ChildItem -LiteralPath $td -Filter "thumbcache_*" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $after = @(Get-ChildItem -LiteralPath $td -Filter "thumbcache_*" -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($null -eq $before) { $before = 0 }; if ($null -eq $after) { $after = 0 }
    $d = [math]::Max(0, $before - $after)
    $script:freed2 += $d
    Write-Host ("  清理 缩略图缓存: 释放 {0} MB" -f (MB $d))
  }

  foreach ($ud in @("$env:LOCALAPPDATA\Google\Chrome\User Data", "$env:LOCALAPPDATA\Microsoft\Edge\User Data")) {
    if (-not (Test-Path -LiteralPath $ud)) { continue }
    Get-ChildItem -LiteralPath $ud -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" } | ForEach-Object {
      foreach ($c in @("Cache", "Code Cache")) {
        CleanDirContents ((Split-Path $ud -Leaf) + " " + $_.Name + " " + $c) (Join-Path $_.FullName $c)
      }
    }
  }

  Write-Host ("`n  本次清理共释放: {0} MB" -f (MB $script:freed2)) -ForegroundColor Green
  Log ("安全清理释放: " + (MB $script:freed2) + " MB")
}

# ---------- 5. 报告 ----------
function Show-Report {
  Write-Host "`n===== 瘦身报告 =====" -ForegroundColor Cyan
  $c = Get-PSDrive C
  $delta = $c.Free - $script:startFree
  if ($delta -ge 0) {
    Write-Host ("  本次会话 C盘: 开始剩余 {0} GB -> 当前剩余 {1} GB（净释放 {2} GB）" -f (GB $script:startFree), (GB $c.Free), (GB $delta))
  } else {
    Write-Host ("  本次会话 C盘: 开始剩余 {0} GB -> 当前剩余 {1} GB（净新增占用 {2} GB）" -f (GB $script:startFree), (GB $c.Free), (GB (-$delta)))
  }
  Show-Disk
}

# ---------- 6. 迁移收尾 / 回滚 ----------
function Invoke-MigrationMaintenance {
  Write-Host "`n===== 迁移收尾 / 回滚 =====" -ForegroundColor Cyan
  $candidates = @()
  for ($i=0; $i -lt $script:Targets.Count; $i++) {
    $t = $script:Targets[$i]
    $backup = "$($t.S).old"
    if ((Test-Path -LiteralPath $backup) -and (Is-ReparsePoint $t.S)) {
      $bs = Get-DirStats $backup
      $actualTarget = Get-LinkTarget $t.S
      $candidates += [PSCustomObject]@{ I=$i; T=$t; B=$backup; MB=(MB $bs.Bytes); ActualTarget=$actualTarget }
      $where = if ($actualTarget) { " -> $actualTarget" } else { "" }
      Write-Host ("  [{0}] {1}  备份 {2} MB{3}" -f $i, $t.N, (MB $bs.Bytes), $where)
    }
  }
  if ($candidates.Count -eq 0) {
    Write-Host "  没有检测到“Junction + .old 备份”的待收尾迁移。"
    return
  }

  $sel = Read-Host "  选择序号，或 q 返回"
  if ($sel -eq "q") { return }
  if ($sel -notmatch "^\d+$") { Write-Host "  无效序号"; return }
  $row = $candidates | Where-Object { $_.I -eq [int]$sel } | Select-Object -First 1
  if ($null -eq $row) { Write-Host "  无效序号"; return }

  $t = $row.T; $backup = $row.B
  $dataTarget = if ($row.ActualTarget) { $row.ActualTarget } else { $t.D }
  Write-Host "`n  [1] 已验证软件正常，删除 C盘 .old 备份并真正释放空间"
  Write-Host "  [2] 回滚迁移：移除 Junction，把 .old 恢复回原目录"
  Write-Host "  [q] 返回"
  $act = Read-Host "  请选择"

  if ($act -eq "1") {
    $confirm = Read-Host "  请确认你已实际打开并正常使用对应软件；输入 DELETE 才会删除备份"
    if ($confirm -ne "DELETE") { Write-Host "  已取消"; return }
    $bakStats = Get-DirStats $backup
    $dstStats = Get-DirStats $dataTarget
    if ($dstStats.Bytes + 3MB -lt $bakStats.Bytes -or $dstStats.Files -lt $bakStats.Files) {
      Write-Host ("  [中止] 目标数据看起来比备份少，拒绝自动删除 .old。目标：{0}" -f $dataTarget) -ForegroundColor Red
      return
    }
    try {
      Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop
      Write-Host ("  [成功] 已删除备份，约释放 {0} MB。" -f (MB $bakStats.Bytes)) -ForegroundColor Green
      Log "迁移收尾完成: $($t.N), deleted=$backup"
    } catch {
      Write-Host ("  [失败] 删除备份失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
    }
  }
  elseif ($act -eq "2") {
    $confirm = Read-Host "  回滚会让软件重新使用 C盘原数据；输入 ROLLBACK 继续"
    if ($confirm -ne "ROLLBACK") { Write-Host "  已取消"; return }
    try {
      Remove-JunctionOnly $t.S
      Move-Item -LiteralPath $backup -Destination $t.S -ErrorAction Stop
      Write-Host "  [成功] 已恢复到迁移前的 C盘目录。D盘副本仍保留，未自动删除。" -ForegroundColor Green
      Log "迁移已回滚: $($t.N)"
    } catch {
      Write-Host ("  [失败] 回滚未完成：{0}" -f $_.Exception.Message) -ForegroundColor Red
      Write-Host "  请停止继续操作，并保留 C盘 .old 与 D盘副本。" -ForegroundColor Yellow
    }
  }
}

# ---------- 提权 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $ReportOnly) {
  Write-Host "正在请求管理员权限..." -ForegroundColor Yellow
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}

$script:startFree = (Get-PSDrive C).Free

# ---------- 主入口 ----------
if ($ReportOnly) { Show-Disk; Show-TopDirs; Show-Report; exit }

while ($true) {
  Write-Host "`n==============================================" -ForegroundColor Cyan
  Write-Host "  C盘瘦身助手 v1.2（保守安全版）" -ForegroundColor Cyan
  Write-Host "==============================================" -ForegroundColor Cyan
  Write-Host "  [1] 扫描C盘（只读）"
  Write-Host "  [2] 软件数据迁移到D盘"
  Write-Host "  [3] 卸载软件"
  Write-Host "  [4] 安全清理（仅缓存/临时文件，不删诊断日志）"
  Write-Host "  [5] 生成报告"
  Write-Host "  [6] 迁移收尾 / 回滚（处理 .old 备份）"
  Write-Host "  [0] 退出"
  $c2 = Read-Host "`n  请选择"
  switch ($c2) {
    "1" { Show-Disk; Show-TopDirs }
    "2" { Invoke-MigrateMenu }
    "3" { Invoke-UninstallMenu }
    "4" { Invoke-CleanJunk }
    "5" { Show-Report }
    "6" { Invoke-MigrationMaintenance }
    "0" { Write-Host "再见!"; exit 0 }
    default { Write-Host "无效输入" }
  }
}
