#Requires -Version 7
<#
  pcx - 在 PC1 上用一個指令管理並操作遠端電腦 (Windows / Ubuntu / 雲端 VM)。

  pcx install                          安裝成全域指令 (只需一次)
  pcx invite windows|ubuntu            產生「給 PC2 的明文資料夾」(腳本 + 你的公鑰，無編碼/混淆；加 -SingleFile 改為單一檔案)
  pcx add <名稱> <user@主機>           註冊一台電腦並測試連線 (同時檢查遠端是否具管理員/sudo 權限)
  pcx <名稱> "<指令>"                  在遠端執行指令，回傳完整輸出與 [exit code: N]
  pcx <名稱> -File script.ps1|.sh      在遠端執行本機的腳本檔
  pcx put <名稱> <本機路徑> <遠端路徑>  上傳檔案或資料夾
  pcx get <名稱> <遠端路徑> <本機路徑>  下載檔案或資料夾
  pcx harden <名稱>                    確認金鑰可用後，關閉 PC2 的密碼登入 (只留金鑰)
  pcx list | pcx remove <名稱>         列出 (含 admin 狀態) / 只取消本機註冊
  pcx status [名稱]                    檢測已註冊的電腦是否存活 (平行檢測，約 5 秒內完成；有離線時結束碼為 1)
  pcx clean                            一鍵清理：取消註冊「遠端存取已不存在」的電腦 (離線的預設保留，加 -IncludeOffline 才一併清)
  pcx teardown <名稱>                  一鍵移除 PC2 上的遠端存取 (金鑰、防火牆、SSH 設定都還原)，並取消註冊
  pcx uninstall -All -Yes              一鍵全部移除：所有 PC2 的遠端存取 + PC1 上的 pcx 與金鑰
  pcx agents                           在目前資料夾的 AGENTS.md 加入給 AI 的使用說明

  add 的選項:    -Port 22  -Key <已有的私鑰，例如雲端 VM 的 .pem>  -Jump <user@跳板機>
  invite 的選項: -AllowFrom <LocalSubnet | 192.168.1.0/24 | 100.64.0.0/10 | Any>  -DisablePassword (安裝時就關閉密碼登入，建議改用 pcx harden)
                 -UpgradeServer (Ubuntu：順便升級 openssh-server)  -PasswordlessSudo (Ubuntu：授權免密碼 sudo，等同 root，請謹慎)  -Out <名稱>
  執行的選項:    -RunTimeout 120 (遠端指令總逾時秒數)  -Timeout 60 (連線逾時)  -Encoding utf-8 (遠端輸出亂碼時改 950)
  teardown / uninstall 的選項: -UninstallServer  -All  -Yes (不詢問)  -Force (遠端失敗也繼續清本機)

  遇到 pcx 無法自行解決的狀況，會印出 [errorRequest:代碼] 區塊，說明問題與需要使用者做什麼。
#>
param(
    [Parameter(Position = 0)][string]$Cmd,
    [Parameter(Position = 1)][string]$A,
    [Parameter(Position = 2)][string]$B,
    [Parameter(Position = 3)][string]$C,
    [int]$Port = 22,
    [string]$Key,
    [string]$Jump,
    [string]$AllowFrom = 'LocalSubnet',
    [switch]$DisablePassword,
    [switch]$UpgradeServer,
    [switch]$PasswordlessSudo,
    [switch]$SingleFile,
    [string]$File,
    [string]$Out,
    [int]$Timeout = 60,
    [int]$RunTimeout = 120,
    [string]$Encoding = 'utf-8',
    [switch]$UninstallServer,
    [switch]$All,
    [switch]$IncludeOffline,
    [switch]$Yes,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

$PcxDir     = Join-Path $HOME '.pcx'
$HostsFile  = Join-Path $PcxDir 'hosts.json'
$SshDir     = Join-Path $HOME '.ssh'
$SshConfig  = Join-Path $SshDir 'config'
$DefaultKey = Join-Path $SshDir 'id_ed25519_pcx'
$Verbs      = 'install', 'add', 'run', 'put', 'get', 'harden', 'list', 'status', 'clean', 'remove', 'teardown', 'uninstall', 'invite', 'agents', 'help'

# ---------------------------------------------------------------------------
# errorRequest：pcx 無法自行解決時，輸出固定格式的區塊，請使用者(或 AI 轉告使用者)處理
# ---------------------------------------------------------------------------
function Write-ErrorRequest([string]$code, [string]$problem, [string]$need) {
    Write-Host "[errorRequest:$code]"
    Write-Host "  問題: $problem"
    Write-Host "  需要: $need"
    Write-Host '  (AI 請停止目前流程，把以上內容原樣轉告使用者，待使用者處理並回覆後再繼續。)'
}

# 依 ssh/scp 的錯誤訊息判斷原因並輸出 errorRequest；有輸出則回傳 $true
function Write-SshErrorRequest([string]$text, [string]$name) {
    $h = if ($name) { $name } else { '目標電腦' }
    if ($text -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed') {
        Write-ErrorRequest 'HOSTKEY_CHANGED' "$h 的主機金鑰與先前記錄的不同 (可能是重灌/換機，也可能是被冒充)。" "請確認 $h 是否真的重灌或更換過。確認無誤後，執行 ssh-keygen -R <該電腦的 IP> 再重試；若不確定，請不要繼續連線。"
    } elseif ($text -match 'Load key .*(Permission denied|No such file|invalid format|error in libcrypto)|UNPROTECTED PRIVATE KEY|Bad permissions') {
        Write-ErrorRequest 'KEY_UNREADABLE' '讀不到或不能使用私鑰檔 (檔案不存在、權限不對，或目前執行身分(例如 Codex 沙盒)看不到你的使用者資料夾)。' '請用你自己的帳號在一般終端機執行 pcx；若是在 AI 工具裡，請放寬沙盒或核准該指令以你的身分執行。私鑰預設在 ~/.ssh/id_ed25519_pcx。'
    } elseif ($text -match 'connect to host .* port \d+: (Permission denied|Operation not permitted)|Unknown error|WSAStartup') {
        Write-ErrorRequest 'NETWORK_BLOCKED' '本機阻擋了這次網路連線 (常見於 AI 工具的沙盒，或防火牆/防毒軟體)。' '請放寬 AI 工具的沙盒網路限制，或在防火牆/防毒設定中允許 ssh.exe 對外連線。'
    } elseif ($text -match 'Could not resolve hostname') {
        Write-ErrorRequest 'DNS_FAILED' "解析不到 $h 的主機名稱。" '請確認主機名稱拼字，或改用 IP；VPN 或區網名稱解析(如 .local)可能尚未啟用。'
    } elseif ($text -match 'Permission denied') {
        Write-ErrorRequest 'AUTH_REJECTED' "$h 拒絕了這把金鑰。" "請依序確認: (1) 已在 PC2 執行『這台 PC1 產生』的安裝資料夾；(2) 登入的使用者名稱正確，Windows 版金鑰只授權給 PC2 的管理員帳號；(3) 若安裝時加了 -DisablePassword，金鑰必須正確才能登入。無法確定時請到 PC2 本機檢查 SSH 設定。"
    } elseif ($text -match 'refused') {
        Write-ErrorRequest 'SSH_NOT_RUNNING' "$h 在線，但 SSH 服務沒有執行或 22 埠不對。" '請在 PC2 重新執行安裝 (INSTALL.cmd / install.sh)，或確認 sshd 服務已啟動；非 22 埠請用 -Port 重新註冊。'
    } elseif ($text -match 'timed out|No route|unreachable|Network is|banner exchange|Connection closed|Connection reset') {
        Write-ErrorRequest 'UNREACHABLE' "連不到 $h (逾時或路徑不通)。" '請確認 PC2 已開機且沒有睡眠、IP 沒有變動、兩台在同一網路 (注意訪客 Wi-Fi 的裝置隔離、不同 VLAN)；若走 VPN/雲端，確認防火牆與安全群組允許你的來源。'
    } else { return $false }
    return $true
}

# 依遠端指令的輸出判斷是否因權限不足失敗；有輸出則回傳 $true
function Write-PrivilegeErrorRequest([string]$text, [string]$name, $info) {
    if ($text -match 'sudo: a password is required|sudo: no tty present|sudo: a terminal is required') {
        Write-ErrorRequest 'SUDO_PASSWORD_REQUIRED' "$name 上的 sudo 需要輸入密碼，pcx 是非互動式，無法代為輸入。" "請選擇其一: (1) 在 $name 設定免密碼 sudo (重新產生安裝資料夾時加 -PasswordlessSudo，注意等同給予 root 權限)；(2) 由你在 $name 本機自行執行該指令；(3) 改用不需要 root 的做法。我不會也不應該取得你的密碼。"
    } elseif ($text -match 'Access is denied|requested operation requires elevation|拒絕存取|需要提升|UnauthorizedAccess') {
        Write-ErrorRequest 'ADMIN_REQUIRED' "$name 上的這項操作需要管理員權限，目前登入的帳號沒有。SSH 連線無法跳出 UAC 提示。" '請改用 PC2 上的「管理員帳號」重新註冊 (pcx add <名稱> <管理員帳號>@<IP>)；一般使用者帳號無法透過 SSH 提升權限。'
    } else { return $false }
    return $true
}

# ---------------------------------------------------------------------------
function Get-Hosts {
    if (Test-Path $HostsFile) { return Get-Content $HostsFile -Raw | ConvertFrom-Json -AsHashtable }
    return @{}
}
function Save-Hosts($h) {
    New-Item -ItemType Directory -Force -Path $PcxDir | Out-Null
    $h | ConvertTo-Json | Set-Content $HostsFile -Encoding utf8NoBOM
}
function Ensure-Key {
    if (-not (Test-Path $DefaultKey)) {
        New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
        ssh-keygen -t ed25519 -N '' -C 'pcx' -f $DefaultKey -q
        if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen 失敗' }
        Write-Host "已建立專用金鑰: $DefaultKey"
    }
}
function Remove-ConfigBlock($name) {
    if (-not (Test-Path $SshConfig)) { return }
    $txt = Get-Content $SshConfig -Raw
    $pat = "(?ms)^# >>> pcx $([regex]::Escape($name)) >>>.*?^# <<< pcx $([regex]::Escape($name)) <<<\r?\n?"
    Set-Content $SshConfig ([regex]::Replace($txt, $pat, '')) -Encoding utf8NoBOM -NoNewline
}
function Get-SshOpts {
    @('-o', 'BatchMode=yes', '-o', "ConnectTimeout=$Timeout", '-o', 'ServerAliveInterval=10',
      '-o', ('ServerAliveCountMax=' + [Math]::Max(1, [int]($Timeout / 10))))
}
function Assert-Ssh {
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Write-ErrorRequest 'SSH_CLIENT_MISSING' '這台電腦找不到 ssh 指令 (OpenSSH 客戶端)。' '請安裝 OpenSSH 客戶端: 設定 > 應用程式 > 選用功能 > 新增功能 > OpenSSH 用戶端；安裝後重開終端機。'
        exit 1
    }
}
function Assert-Host($name) {
    $h = Get-Hosts
    if (-not $h.ContainsKey($name)) {
        Write-ErrorRequest 'HOST_NOT_REGISTERED' "找不到已註冊的電腦 '$name'。" "請先執行 pcx add $name <使用者>@<IP>；pcx list 可看已註冊的電腦。若你確定註冊過，可能是目前執行身分(例如 AI 沙盒)看不到 $PcxDir。"
        exit 1
    }
    return $h[$name]
}
function ConvertTo-B64([string]$path, [switch]$Lf) {
    $t = Get-Content -LiteralPath $path -Raw
    if ($Lf) { $t = $t -replace "`r`n", "`n" }
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t))
}
function Get-OutEncoding {
    [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
    try { if ($Encoding -match '^\d+$') { [Text.Encoding]::GetEncoding([int]$Encoding) } else { [Text.Encoding]::GetEncoding($Encoding) } }
    catch { [Text.Encoding]::UTF8 }
}
# 執行 ssh/scp：有總逾時、stdin 一律關閉 (遠端若在等輸入會直接得到 EOF，不會卡住)
function Invoke-Capture {
    param([string[]]$CmdArgs, [string]$StdIn, [int]$TimeoutSec = $RunTimeout, [string]$Exe = 'ssh')
    $psi = [Diagnostics.ProcessStartInfo]::new($Exe)
    foreach ($x in $CmdArgs) { $psi.ArgumentList.Add($x) }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $enc = Get-OutEncoding
    $psi.StandardOutputEncoding = $enc; $psi.StandardErrorEncoding = $enc
    $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $p = [Diagnostics.Process]::Start($psi)
    $ot = $p.StandardOutput.ReadToEndAsync(); $et = $p.StandardError.ReadToEndAsync()
    try { if ($StdIn) { $p.StandardInput.Write($StdIn) }; $p.StandardInput.Close() } catch { }
    $done = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $done) { try { $p.Kill($true) } catch { } }
    [void]$ot.Wait(3000); [void]$et.Wait(3000)
    [pscustomobject]@{
        Code     = $(if ($done) { $p.ExitCode } else { 124 })
        Out      = $(if ($ot.IsCompleted) { $ot.Result } else { '' })
        Err      = $(if ($et.IsCompleted) { $et.Result } else { '' })
        TimedOut = (-not $done)
    }
}
# 印出結果，並在失敗時輸出對應的 errorRequest；回傳結束碼
function Show-Result($r, $name, $info) {
    $text = ($r.Out + $r.Err)
    if ($r.Out) { [Console]::Out.Write($r.Out); if (-not $r.Out.EndsWith("`n")) { [Console]::Out.WriteLine() } }
    if ($r.Err) { [Console]::Out.Write($r.Err); if (-not $r.Err.EndsWith("`n")) { [Console]::Out.WriteLine() } }
    if ($text.Contains([string][char]0xFFFD) -and $Encoding -eq 'utf-8') {
        Write-Host '[hint:ENCODING] 輸出疑似亂碼 (遠端不是 UTF-8)。可加 -Encoding 950 重試。'
    }
    if ($r.TimedOut) {
        Write-ErrorRequest 'RUN_TIMEOUT' "$name 上的指令超過 $RunTimeout 秒仍未結束，已中止。可能在等待輸入 (sudo 密碼、確認提示)，或工作本身太久。" '請改用不需要互動的指令寫法 (例如 apt 加 -y、sudo 加 -n)，或用 -RunTimeout 調高逾時秒數。'
    } elseif ($r.Code -eq 255) {
        [void](Write-SshErrorRequest $text $name)
    } elseif ($r.Code -ne 0) {
        [void](Write-PrivilegeErrorRequest $text $name $info)
    }
    [Console]::Out.WriteLine("[exit code: $($r.Code)]")
    return [int]$r.Code
}
# 把「移除腳本」從 PC1 送到 PC2，以排程/背景方式延遲執行 (因為移除會關掉正在使用的 SSH 連線)
function Invoke-Teardown($name) {
    $info = Assert-Host $name
    $o = Get-SshOpts
    if ($info.os -eq 'linux') {
        $b64 = ConvertTo-B64 (Join-Path $PSScriptRoot 'remove-remote.sh') -Lf
        $flags = if ($UninstallServer) { ' --uninstall-server' } else { '' }
        $tpl = @'
f="$(mktemp)"
echo '@@B64@@' | base64 -d > "$f"
setsid -f bash "$f" --delayed@@FLAGS@@ >/dev/null 2>&1 </dev/null
echo "已排程移除，約 3 秒後 PC2 的 SSH 會關閉。"
'@
        $remote = 'bash -s'
    } else {
        $b64 = ConvertTo-B64 (Join-Path $PSScriptRoot 'remove-remote.ps1')
        $flags = if ($UninstallServer) { ' -UninstallServer' } else { '' }
        $tpl = @'
$f = Join-Path $env:ProgramData 'pcx-remove.ps1'
[IO.File]::WriteAllText($f, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@B64@@')), (New-Object Text.UTF8Encoding $true))
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $f + '" -Delayed@@FLAGS@@')
Register-ScheduledTask -TaskName 'pcx-remove' -Action $act -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'pcx-remove'
Write-Host '已排程移除，約 3 秒後 PC2 的 SSH 會關閉。'
'@
        $remote = 'powershell -NoProfile -Command -'
    }
    $launcher = ($tpl -replace "`r`n", "`n").Replace('@@B64@@', $b64).Replace('@@FLAGS@@', $flags)
    $r = Invoke-Capture -CmdArgs (@($o) + @('-T', $name, $remote)) -StdIn $launcher -TimeoutSec 60
    Write-Host ($r.Out + $r.Err).Trim()
    if ($r.Code -ne 0) {
        $text = $r.Out + $r.Err
        if (-not (Write-SshErrorRequest $text $name) -and -not (Write-PrivilegeErrorRequest $text $name $info)) {
            Write-ErrorRequest 'TEARDOWN_FAILED' "$name 的遠端移除沒有成功 (離線、或遠端帳號沒有管理員/sudo 權限)。" "請讓 $name 連得上後重試；或到 $name 本機執行安裝資料夾裡的 REMOVE.cmd / remove.sh。"
        }
        return $false
    }
    return $true
}
$StateLabel = @{
    'online'       = '在線'
    'key-rejected' = '在線，但金鑰被拒 (遠端存取多半已被移除)'
    'ssh-off'      = '主機在線，但 SSH 未開 (遠端存取多半已被移除)'
    'offline'      = '離線 / 連不上 (可能關機或換了網路)'
    'error'        = '其他錯誤'
}
# 同時檢測多台 (平行)，回傳 Name / State / Ms / Detail
function Test-Hosts([string[]]$names, [int]$timeout) {
    $names | ForEach-Object -ThrottleLimit 8 -Parallel {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $o = (& ssh -o BatchMode=yes -o ConnectTimeout=$using:timeout $_ 'echo pcx-ok' 2>&1 | ForEach-Object { $_.ToString() }) -join ' '
        $code = $LASTEXITCODE
        $sw.Stop()
        $state = if ($code -eq 0 -and $o -match 'pcx-ok') { 'online' }
                 elseif ($o -match 'Permission denied')    { 'key-rejected' }
                 elseif ($o -match 'refused')              { 'ssh-off' }
                 elseif ($o -match 'timed out|No route|Could not resolve|unreachable|Network is|banner exchange|Connection closed') { 'offline' }
                 else { 'error' }
        [pscustomobject]@{ Name = $_; State = $state; Ms = $sw.ElapsedMilliseconds; Detail = $o }
    } | Sort-Object Name
}
# 從 known_hosts 清掉該電腦 (須在移除 ssh config 區塊之前呼叫)
function Forget-KnownHost($name) {
    $hn = & ssh -G $name 2>$null | Where-Object { $_ -match '^hostname ' } | Select-Object -First 1
    if ($hn) { ssh-keygen -R ($hn -replace '^hostname ', '') *> $null }
}
function Show-Usage {
    $self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $t = Get-Content $self -Raw
    if ($t -match '(?s)<#(.*?)#>') { $Matches[1].TrimEnd() }
}

# ---- 未帶指令 / help -------------------------------------------------------
if (-not $Cmd -or $Cmd -eq 'help') { Show-Usage; exit 0 }

# ---- 非內建動詞 => 視為「pcx <名稱> "<指令>"」 -------------------------------
if ($Cmd -notin $Verbs) { $B = $A; $A = $Cmd; $Cmd = 'run' }

if ($Cmd -in 'add', 'run', 'put', 'get', 'harden', 'status', 'clean', 'teardown') { Assert-Ssh }

switch ($Cmd) {

'install' {
    New-Item -ItemType Directory -Force -Path $PcxDir | Out-Null
    if ((Resolve-Path $PSScriptRoot).Path -ne (Resolve-Path $PcxDir).Path) {
        Copy-Item (Join-Path $PSScriptRoot '*.ps1'), (Join-Path $PSScriptRoot '*.sh') -Destination $PcxDir -Force
    }
    $npm = Join-Path $env:APPDATA 'npm'
    if (($env:Path -split ';') -contains $npm -and (Test-Path $npm)) { $shimDir = $npm } else { $shimDir = $PcxDir }
    $shim = "@echo off`r`npwsh -NoProfile -File `"%USERPROFILE%\.pcx\pcx.ps1`" %*"
    Set-Content (Join-Path $shimDir 'pcx.cmd') $shim -Encoding ascii
    if ($shimDir -eq $PcxDir) {
        $up = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (($up -split ';') -notcontains $PcxDir) { [Environment]::SetEnvironmentVariable('Path', "$up;$PcxDir", 'User') }
    }
    Write-Host "已安裝。重新開啟終端機後，可在任何位置使用: pcx help"
}

'invite' {
    $os = $A
    if ($os -notin 'windows', 'ubuntu') { throw '用法: pcx invite windows|ubuntu [-AllowFrom ...] [-DisablePassword] [-UpgradeServer] [-PasswordlessSudo] [-Out 名稱]' }
    Ensure-Key
    $pub = (Get-Content "$DefaultKey.pub" -Raw).Trim()
    if ($AllowFrom -eq 'Any') { Write-Warning 'AllowFrom=Any 會讓任何來源都連得到 22 埠。請確認雲端安全群組已限制來源，或改用 VPN。' }
    if ($PasswordlessSudo -and $os -eq 'windows') { Write-Warning '-PasswordlessSudo 只對 Ubuntu 有效，已忽略。' }
    if ($PasswordlessSudo -and $os -eq 'ubuntu') { Write-Warning '-PasswordlessSudo 會讓持有 PC1 金鑰的人在 PC2 取得完整 root 權限，不需密碼。' }

    if (-not $SingleFile) {
        # 預設：明文資料夾 (腳本原樣放入，沒有任何編碼或混淆，防毒與人都看得懂)
        if (-not $Out) { $Out = "pcx-pc2-$os" }
        $dir = Join-Path (Get-Location) $Out
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $utf8 = New-Object Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $dir 'pcx.pub'), "$pub`n", $utf8)
        if ($os -eq 'windows') {
            Copy-Item (Join-Path $PSScriptRoot 'setup-remote.ps1'), (Join-Path $PSScriptRoot 'remove-remote.ps1') -Destination $dir -Force
            $flag = if ($DisablePassword) { ' -DisablePasswordLogin' } else { '' }
            $bat = @'
@echo off
chcp 65001 >nul
net session >nul 2>&1
if errorlevel 1 (
  echo 請在這個檔案上按右鍵，選「以系統管理員身分執行」。
  pause
  exit /b 1
)
@@CMD@@
pause
'@
            $inst = $bat.Replace('@@CMD@@', 'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-remote.ps1" -PublicKey "%~dp0pcx.pub" -AllowFrom "' + $AllowFrom + '"' + $flag)
            $rem  = $bat.Replace('@@CMD@@', 'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0remove-remote.ps1"')
            [IO.File]::WriteAllText((Join-Path $dir 'INSTALL.cmd'), (($inst -replace "`r?`n", "`r`n")), $utf8)
            [IO.File]::WriteAllText((Join-Path $dir 'REMOVE.cmd'),  (($rem  -replace "`r?`n", "`r`n")), $utf8)
            $how = '在 PC2 對 INSTALL.cmd 按右鍵「以系統管理員身分執行」；要移除就執行 REMOVE.cmd。'
        } else {
            foreach ($f in 'setup-remote.sh', 'remove-remote.sh') {
                [IO.File]::WriteAllText((Join-Path $dir $f), ((Get-Content (Join-Path $PSScriptRoot $f) -Raw) -replace "`r`n", "`n"), $utf8)
            }
            $flag = if ($DisablePassword) { '--no-password' } else { '' }
            if ($UpgradeServer) { $flag += ' --upgrade' }
            if ($PasswordlessSudo) { $flag += ' --sudo-nopasswd' }
            $instSh = "#!/usr/bin/env bash`ncd `"`$(dirname `"`$0`")`"`nsudo env ALLOW_FROM='$AllowFrom' bash ./setup-remote.sh ./pcx.pub $flag`n"
            $remSh  = "#!/usr/bin/env bash`ncd `"`$(dirname `"`$0`")`"`nsudo bash ./remove-remote.sh`n"
            [IO.File]::WriteAllText((Join-Path $dir 'install.sh'), $instSh, $utf8)
            [IO.File]::WriteAllText((Join-Path $dir 'remove.sh'),  $remSh,  $utf8)
            $how = '在 PC2 執行: bash install.sh；要移除就執行: bash remove.sh。'
        }
        $pwLine = if ($DisablePassword) { '已關閉密碼登入，只能用金鑰登入' } else { '密碼登入維持原樣；確認金鑰可用後，在 PC1 執行 pcx harden <名稱> 再關閉密碼登入' }
        $sudoLine = if ($PasswordlessSudo -and $os -eq 'ubuntu') { "`n  4. 授權此帳號免密碼 sudo (等同 root)；移除時會一併撤銷" } else { '' }
        $readme = @"
這個資料夾是由 pcx 產生，用來讓另一台電腦 (PC1) 透過 SSH 管理這台電腦。內容全部是明文，可直接用文字編輯器檢視。

會做的事:
  1. 安裝並啟動 OpenSSH Server
  2. 防火牆只允許指定來源連入 22 埠 (來源: $AllowFrom)
  3. 把 pcx.pub (PC1 的公鑰) 加入授權金鑰；$pwLine$sudoLine
不會做的事: 不連到任何網路伺服器、不收集資料、不安裝其他程式。

使用: $how
移除會依安裝前的狀態還原所有變更。
"@
        [IO.File]::WriteAllText((Join-Path $dir 'README.txt'), $readme, $utf8)
        $Out = $dir
        $how2 = $how
    } elseif ($os -eq 'windows') {
        $strip = { param($p) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(((Get-Content (Join-Path $PSScriptRoot $p) -Raw) -replace '(?m)^#Requires.*\r?\n', ''))) }
        $b64  = & $strip 'setup-remote.ps1'
        $rm64 = & $strip 'remove-remote.ps1'
        $flag = if ($DisablePassword) { ' -DisablePasswordLogin' } else { '' }
        $tpl = @'
#Requires -RunAsAdministrator
# 由 pcx invite 產生。以「系統管理員 PowerShell」執行:
#   安裝: .\檔名.ps1        一鍵移除: .\檔名.ps1 -Remove
param([switch]$Remove)
if ($Remove) {
    $r = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@RM64@@'))
    & ([scriptblock]::Create($r))
    Remove-Item -LiteralPath $PSCommandPath -Force
} else {
    $s = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('@@B64@@'))
    & ([scriptblock]::Create($s)) -PublicKey '@@KEY@@' -AllowFrom '@@ALLOW@@'@@FLAG@@
}
'@
        $content = $tpl.Replace('@@B64@@', $b64).Replace('@@RM64@@', $rm64).Replace('@@KEY@@', $pub).Replace('@@ALLOW@@', $AllowFrom).Replace('@@FLAG@@', $flag)
        if (-not $Out) { $Out = 'pcx-setup-windows.ps1' }
        Set-Content -LiteralPath $Out $content -Encoding utf8NoBOM
    } else {
        $b64  = ConvertTo-B64 (Join-Path $PSScriptRoot 'setup-remote.sh') -Lf
        $rm64 = ConvertTo-B64 (Join-Path $PSScriptRoot 'remove-remote.sh') -Lf
        $flag = if ($DisablePassword) { '--no-password' } else { '' }
        if ($UpgradeServer) { $flag += ' --upgrade' }
        if ($PasswordlessSudo) { $flag += ' --sudo-nopasswd' }
        $tpl = @'
#!/usr/bin/env bash
# 由 pcx invite 產生。  安裝: bash 檔名      一鍵移除: bash 檔名 remove
set -e
tmp="$(mktemp)"
if [ "${1:-}" = "remove" ]; then
base64 -d > "$tmp" <<'B64R'
@@RM64@@
B64R
  sudo bash "$tmp"; rm -f "$tmp" "$0"; exit 0
fi
base64 -d > "$tmp" <<'B64'
@@B64@@
B64
sudo env ALLOW_FROM='@@ALLOW@@' bash "$tmp" '@@KEY@@' @@FLAG@@
rm -f "$tmp"
'@
        $content = ($tpl -replace "`r`n", "`n").Replace('@@B64@@', $b64).Replace('@@RM64@@', $rm64).Replace('@@KEY@@', $pub).Replace('@@ALLOW@@', $AllowFrom).Replace('@@FLAG@@', $flag)
        if (-not $Out) { $Out = 'pcx-setup-ubuntu.sh' }
        [IO.File]::WriteAllText((Join-Path (Get-Location) $Out), $content, (New-Object Text.UTF8Encoding $false))
    }
    Write-Host "已產生: $Out"
    if (-not $SingleFile) { Write-Host "把整個資料夾複製到 PC2 (隨身碟、雲端硬碟、scp 皆可)。$how2" }
    else { Write-Host '把這個檔案複製到 PC2 (隨身碟、雲端硬碟、scp 皆可)，執行方式見檔案開頭註解。' }
    Write-Host '執行後會印出 IP。接著在 PC1: pcx add <名稱> <user@IP>；確認可連線後建議執行 pcx harden <名稱> 關閉密碼登入。'
}

'add' {
    $name = $A; $target = $B
    if (-not $name -or -not $target) { throw '用法: pcx add <名稱> <user@主機> [-Port 22] [-Key 私鑰] [-Jump user@跳板機]' }
    if ($name -notmatch '^[A-Za-z0-9_-]+$' -or $name -in $Verbs) { throw "名稱只能用英數字、- 、_，且不可與指令同名: $name" }

    if ($Key) { $idFile = (Resolve-Path $Key).Path } else { Ensure-Key; $idFile = $DefaultKey }
    if ($target -match '^(.+)@(.+)$') { $user = $Matches[1]; $hostName = $Matches[2] } else { $user = $null; $hostName = $target }

    $lines = @("# >>> pcx $name >>>", "Host $name", "    HostName $hostName")
    if ($user) { $lines += "    User $user" }
    $lines += "    Port $Port", "    IdentityFile `"$($idFile -replace '\\', '/')`"", '    IdentitiesOnly yes',
              '    StrictHostKeyChecking accept-new', '    ServerAliveInterval 15'
    if ($Jump) { $lines += "    ProxyJump $Jump" }
    $lines += "# <<< pcx $name <<<"

    New-Item -ItemType Directory -Force -Path $SshDir | Out-Null
    if (-not (Test-Path $SshConfig)) { New-Item -ItemType File -Path $SshConfig | Out-Null }
    Remove-ConfigBlock $name
    $existing = Get-Content $SshConfig -Raw
    if ($existing -and -not $existing.EndsWith("`n")) { Add-Content $SshConfig '' }
    Add-Content $SshConfig ($lines -join "`n")

    Write-Host "測試連線到 $target ..."
    $r = Invoke-Capture -CmdArgs (@(Get-SshOpts) + @('-T', $name, 'uname -s')) -TimeoutSec ($Timeout + 15)
    $text = $r.Out + $r.Err
    if ($r.Code -eq 255 -or $r.TimedOut) {
        Remove-ConfigBlock $name
        Write-Host $text.Trim()
        if (-not (Write-SshErrorRequest $text $name)) {
            Write-ErrorRequest 'CONNECT_FAILED' "連線到 $target 失敗，原因不在已知的清單內 (見上方 ssh 訊息)。" '請把上方訊息交給可協助的人判斷，或確認 PC2 的 SSH 設定與網路。'
        }
        exit 1
    }
    $os = if ($r.Code -eq 0 -and $text -match 'Linux') { 'linux' } else { 'windows' }

    # 管理員 / sudo 檢查
    if ($os -eq 'linux') {
        $a = Invoke-Capture -CmdArgs (@(Get-SshOpts) + @('-T', $name, 'sudo -n true 2>&1 && echo PCX_SUDO_OK')) -TimeoutSec 30
        $isAdmin = ($a.Out -match 'PCX_SUDO_OK')
    } else {
        $a = Invoke-Capture -CmdArgs (@(Get-SshOpts) + @('-T', $name, 'whoami /groups')) -TimeoutSec 30
        $isAdmin = ($a.Out -match 'S-1-5-32-544') -and ($a.Out -match 'Mandatory Label\\High')
    }
    $h = Get-Hosts; $h[$name] = @{ os = $os; admin = [bool]$isAdmin }; Save-Hosts $h
    Write-Host "連線成功 ($os，管理員權限: $(if ($isAdmin) { '有' } else { '沒有' }))。現在可執行: pcx $name `"hostname`""
    if (-not $isAdmin) {
        if ($os -eq 'linux') {
            Write-ErrorRequest 'NO_ADMIN' "$name 上這個帳號沒有『免密碼 sudo』，需要 root 的操作 (安裝套件、重啟服務、pcx harden/teardown) 會失敗。" '若需要，請讓 PC2 設定免密碼 sudo (重新產生安裝資料夾時加 -PasswordlessSudo，等同給予 root 權限)；不需要 root 的操作可以照常使用。'
        } else {
            Write-ErrorRequest 'NO_ADMIN' "$name 上這個帳號沒有管理員(已提升)權限，改設定、裝服務、pcx harden/teardown 會失敗。SSH 無法跳出 UAC 提示。" '若需要管理員操作，請改用 PC2 上的管理員帳號重新註冊 (pcx add <名稱> <管理員帳號>@<IP>)。'
        }
    }
}

'run' {
    $name = $A; $command = $B
    $info = Assert-Host $name
    if (-not $command -and -not $File) { throw '用法: pcx <名稱> "<指令>"  或  pcx <名稱> -File script' }
    $o = @(Get-SshOpts) + @('-T', $name)
    if ($File) {
        $remote = if ($info.os -eq 'linux') { 'bash -s' } else { 'powershell -NoProfile -Command -' }
        $r = Invoke-Capture -CmdArgs ($o + @($remote)) -StdIn (Get-Content -LiteralPath $File -Raw)
    } else {
        $r = Invoke-Capture -CmdArgs ($o + @($command))
    }
    exit (Show-Result $r $name $info)
}

'put' {
    $info = Assert-Host $A
    if (-not $B -or -not $C) { throw '用法: pcx put <名稱> <本機路徑> <遠端路徑>' }
    $r = Invoke-Capture -Exe 'scp' -CmdArgs (@('-r') + @(Get-SshOpts) + @($B, "${A}:$C"))
    exit (Show-Result $r $A $info)
}

'get' {
    $info = Assert-Host $A
    if (-not $B -or -not $C) { throw '用法: pcx get <名稱> <遠端路徑> <本機路徑>' }
    $r = Invoke-Capture -Exe 'scp' -CmdArgs (@('-r') + @(Get-SshOpts) + @("${A}:$B", $C))
    exit (Show-Result $r $A $info)
}

'harden' {
    $name = $A
    if (-not $name) { throw '用法: pcx harden <名稱>' }
    $info = Assert-Host $name
    $o = @(Get-SshOpts) + @('-T', $name)
    # 先確認金鑰登入確實可用，避免關掉密碼後鎖死自己
    $pre = Invoke-Capture -CmdArgs ($o + @('echo pcx-ok')) -TimeoutSec ($Timeout + 15)
    if ($pre.Code -ne 0 -or $pre.Out -notmatch 'pcx-ok') {
        Write-Host ($pre.Out + $pre.Err).Trim()
        if (-not (Write-SshErrorRequest ($pre.Out + $pre.Err) $name)) {
            Write-ErrorRequest 'HARDEN_PRECHECK_FAILED' "無法用金鑰登入 $name，所以不會關閉密碼登入 (否則可能把自己鎖在外面)。" '請先讓金鑰登入正常 (pcx status 可檢測)，再重試 pcx harden。'
        }
        exit 1
    }
    if ($info.os -eq 'linux') {
        $script = @'
S=""
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then S="sudo -n"; else echo "[errorRequest:HARDEN_NO_SUDO]"; echo "  問題: 這個帳號沒有免密碼 sudo，無法修改 sshd 設定。"; echo "  需要: 請在 PC2 本機執行: echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/99-remote.conf && sudo systemctl reload ssh"; exit 3; fi
fi
echo 'PasswordAuthentication no' | $S tee /etc/ssh/sshd_config.d/99-remote.conf >/dev/null
grep -qxF 'password_disabled=1' /etc/ssh/pcx-state 2>/dev/null || echo 'password_disabled=1' | $S tee -a /etc/ssh/pcx-state >/dev/null
$S systemctl reload ssh && echo "已關閉密碼登入 (只留金鑰)。"
'@
        $remote = 'bash -s'
    } else {
        $script = @'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host '[errorRequest:HARDEN_NO_ADMIN]'; Write-Host '  問題: 這個帳號不是管理員，無法修改 sshd 設定。'; Write-Host '  需要: 請改用管理員帳號重新註冊後再執行 pcx harden，或在 PC2 本機修改 sshd_config。'; exit 3 }
$cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
Copy-Item $cfg "$cfg.pcx-bak" -Force
(Get-Content $cfg) -replace '^\s*#?\s*PasswordAuthentication\s+.*$', 'PasswordAuthentication no' | Set-Content $cfg -Encoding ascii
$sf = Join-Path $env:ProgramData 'ssh\pcx-state.json'
if (Test-Path $sf) { $s = Get-Content $sf -Raw | ConvertFrom-Json; $s.passwordDisabled = $true; $s | ConvertTo-Json | Set-Content $sf -Encoding utf8 }
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -Command "Start-Sleep 3; Restart-Service sshd; Unregister-ScheduledTask -TaskName pcx-restart -Confirm:$false"'
Register-ScheduledTask -TaskName 'pcx-restart' -Action $act -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName 'pcx-restart'
Write-Host '已設定關閉密碼登入，sshd 約 3 秒後重啟。'
'@
        $remote = 'powershell -NoProfile -Command -'
    }
    $r = Invoke-Capture -CmdArgs ($o + @($remote)) -StdIn (($script -replace "`r`n", "`n")) -TimeoutSec 60
    Write-Host ($r.Out + $r.Err).Trim()
    if ($r.Code -ne 0) {
        if (($r.Out + $r.Err) -notmatch 'errorRequest') {
            Write-ErrorRequest 'HARDEN_FAILED' "關閉 $name 的密碼登入沒有成功 (結束碼 $($r.Code))。" "請查看上方訊息；必要時到 $name 本機修改 sshd 設定 (PasswordAuthentication no) 並重啟 SSH 服務。"
        }
        exit 1
    }
    # 確認金鑰仍可登入 (sshd 重啟需要幾秒)
    Start-Sleep -Seconds 8
    $post = Invoke-Capture -CmdArgs ($o + @('echo pcx-ok')) -TimeoutSec ($Timeout + 15)
    if ($post.Out -match 'pcx-ok') { "完成：$name 已只允許金鑰登入，並確認金鑰登入仍可使用。" }
    else {
        Write-ErrorRequest 'HARDEN_VERIFY_FAILED' "已送出設定，但重新連線 $name 失敗 (sshd 可能仍在重啟，或設定有誤)。" "請稍後執行 pcx status $name 確認；若持續連不上，需要到 $name 本機把 sshd_config 的 PasswordAuthentication 改回 yes (備份在 sshd_config.pcx-bak 或 99-remote.conf) 並重啟 SSH 服務。"
        exit 1
    }
}

'list' {
    $h = Get-Hosts
    if ($h.Count -eq 0) { '(尚未註冊任何電腦。用 pcx add <名稱> <user@主機>)'; break }
    $h.GetEnumerator() | ForEach-Object { '{0,-16} {1,-8} admin/sudo: {2}' -f $_.Key, $_.Value.os, $(if ($_.Value.admin) { '有' } elseif ($null -eq $_.Value.admin) { '未檢查' } else { '沒有' }) }
}

'remove' {
    $h = Get-Hosts
    if ($A) { Forget-KnownHost $A; Remove-ConfigBlock $A; $h.Remove($A); Save-Hosts $h; "已移除 $A (私鑰仍保留)" } else { throw '用法: pcx remove <名稱>' }
}

'status' {
    $h = Get-Hosts
    $names = if ($A) { Assert-Host $A | Out-Null; @($A) } else { @($h.Keys) }
    if ($names.Count -eq 0) { '(尚未註冊任何電腦。用 pcx add <名稱> <user@主機>)'; break }
    $t = if ($PSBoundParameters.ContainsKey('Timeout')) { $Timeout } else { 5 }
    $res = Test-Hosts $names $t
    $res | ForEach-Object { '{0,-14} {1,-8} {2,6} ms  {3}' -f $_.Name, $h[$_.Name].os, $_.Ms, $StateLabel[$_.State] }
    $bad = @($res | Where-Object State -ne 'online').Count
    "`n在線 $($res.Count - $bad) / $($res.Count)"
    if ($bad) { exit 1 }
}

'clean' {
    $h = Get-Hosts
    if ($h.Count -eq 0) { '沒有已註冊的電腦，不需要清理。'; break }
    $t = if ($PSBoundParameters.ContainsKey('Timeout')) { $Timeout } else { 5 }
    $res = Test-Hosts @($h.Keys) $t
    $res | ForEach-Object { '{0,-14} {1}' -f $_.Name, $StateLabel[$_.State] }
    $stale = @('key-rejected', 'ssh-off'); if ($IncludeOffline) { $stale += 'offline' }
    $drop = @($res | Where-Object { $_.State -in $stale } | Select-Object -ExpandProperty Name)
    $held = @($res | Where-Object { $_.State -eq 'offline' -and -not $IncludeOffline } | Select-Object -ExpandProperty Name)
    if ($held.Count) { Write-Host "`n保留 (離線、可能只是關機；它們可能仍留有你的金鑰，移除註冊後就無法再用 pcx teardown): $($held -join ', ')。確定不再使用請加 -IncludeOffline。" }
    if ($drop.Count -eq 0) { "`n沒有需要清理的項目。"; break }
    Write-Host "`n將取消註冊 (本機設定與 known_hosts 紀錄): $($drop -join ', ')"
    if (-not $Yes) { if ((Read-Host '確定? (y/N)') -notmatch '^[yY]') { '已取消。'; exit 0 } }
    foreach ($n in $drop) { Forget-KnownHost $n; Remove-ConfigBlock $n; $h.Remove($n) }
    Save-Hosts $h
    "已清理 $($drop.Count) 台，剩餘 $($h.Count) 台。"
}

'teardown' {
    if (-not $A) { throw '用法: pcx teardown <名稱> [-UninstallServer]' }
    if (Invoke-Teardown $A) {
        Forget-KnownHost $A
        Remove-ConfigBlock $A
        $h = Get-Hosts; $h.Remove($A); Save-Hosts $h
        "已移除 $A 的遠端存取並取消註冊。"
    } else { exit 1 }
}

'uninstall' {
    $h = Get-Hosts
    $names = @($h.Keys)
    $shims = @((Join-Path $env:APPDATA 'npm\pcx.cmd'), (Join-Path $PcxDir 'pcx.cmd'))
    Write-Host '即將執行:'
    if ($All -and $names.Count) { Write-Host "  - 移除這些遠端電腦上的 SSH 存取: $($names -join ', ')" }
    elseif ($names.Count)       { Write-Host "  - 不會動遠端電腦 ($($names -join ', '))，它們仍開著 SSH。要一併移除請加 -All" }
    Write-Host "  - 刪除本機: pcx 指令、$PcxDir、專用金鑰 id_ed25519_pcx、~/.ssh/config 中的 pcx 區塊"
    if (-not $Yes) {
        if ((Read-Host '確定要執行? (y/N)') -notmatch '^[yY]') { '已取消。'; exit 0 }
    }
    $failed = @()
    if ($All) { Assert-Ssh; foreach ($n in $names) { if (-not (Invoke-Teardown $n)) { $failed += $n } } }
    if ($failed.Count -and -not $Force) {
        Write-ErrorRequest 'UNINSTALL_PARTIAL' "這些電腦的遠端移除失敗: $($failed -join ', ')。本機設定與金鑰先保留，避免之後無法再移除它們。" '請處理上方各電腦的 errorRequest 後重試；若確定要忽略 (遠端仍會留有你的金鑰授權)，可加 -Force 只清除本機。'
        exit 1
    }
    foreach ($n in $names) { Forget-KnownHost $n; Remove-ConfigBlock $n }
    foreach ($s in $shims) { Remove-Item -LiteralPath $s -Force -ErrorAction SilentlyContinue }
    Remove-Item "$DefaultKey", "$DefaultKey.pub" -Force -ErrorAction SilentlyContinue
    $up = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($up) {
        $new = (($up -split ';') | Where-Object { $_ -and $_ -ne $PcxDir }) -join ';'
        if ($new -ne $up) { [Environment]::SetEnvironmentVariable('Path', $new, 'User') }
    }
    Remove-Item -LiteralPath $PcxDir -Recurse -Force -ErrorAction SilentlyContinue
    '已全部移除。'
}

'agents' {
    $f = Join-Path (Get-Location) 'AGENTS.md'
    if ((Test-Path $f) -and ((Get-Content $f -Raw) -match 'pcx')) { 'AGENTS.md 已含 pcx 說明，未修改。'; break }
    $txt = @'

## 遠端電腦 (pcx)
- 要操作遠端電腦時，一律使用 `pcx <名稱> "<指令>"`，不要自行改用其他連線方式。`pcx list` 可看有哪些電腦、作業系統與 admin/sudo 狀態。
- 輸出最後一行 `[exit code: N]` 是遠端指令的結束碼，非 0 代表失敗，請讀取並處理輸出的錯誤訊息。
- 輸出中出現 `[errorRequest:代碼]` 區塊時，代表 pcx 無法自行解決：請立刻停止，把「問題」與「需要」原樣轉告使用者，等使用者處理並回覆後才繼續，不要自行繞過。
- Windows 遠端用 PowerShell 語法；linux 遠端用 bash 語法。需要 root 時用 `sudo -n`，不要嘗試輸入密碼。
- 傳檔用 `pcx put/get`；多行腳本用 `pcx <名稱> -File 檔案`。
- 會修改設定、刪除檔案、重啟服務或關機的指令，先向使用者確認再執行。
'@
    Add-Content -LiteralPath $f $txt -Encoding utf8NoBOM
    "已寫入 $f"
}
}
