#Requires -Version 7
<#
  pcx - 在 PC1 上用一個指令管理並操作遠端電腦 (Windows / Ubuntu / 雲端 VM)。

  pcx wizard                           Windows 互動精靈：一步步詢問並代為執行 (也可雙擊 WIZARD.cmd)
  pcx guide [名稱]                     引導流程：檢查目前做到哪一步，並告訴你下一個要執行的指令 (從這裡開始)
  pcx help [主題]                      完整中文使用說明；主題: setup admin errors env daily remove security ai notes
  pcx install                          安裝成全域指令 (只需一次)
  pcx invite windows|ubuntu            產生「給 PC2 的明文資料夾」(腳本 + 你的公鑰，無編碼/混淆；加 -SingleFile 改為單一檔案)
  pcx add <名稱> <user@主機>           註冊一台電腦並測試連線 (同時檢查遠端是否具管理員/sudo 權限)
  pcx <名稱> "<指令>"                  在遠端執行指令，回傳完整輸出與 [exit code: N]
  pcx <名稱> -File script.ps1|.sh      在遠端執行本機的腳本檔
  pcx put <名稱> <本機路徑> <遠端路徑>  上傳檔案或資料夾
  pcx get <名稱> <遠端路徑> <本機路徑>  下載檔案或資料夾
  pcx harden <名稱>                    確認金鑰可用後，關閉 PC2 的密碼登入 (只留金鑰)
  pcx list                             列出已註冊的電腦 (含連線目標與 admin 狀態)
  pcx forget <名稱>                    只刪 PC1 本機的註冊紀錄，不連到 PC2 (舊名 pcx remove 仍可用)
  pcx status [名稱]                    檢測已註冊的電腦是否存活 (平行檢測，約 5 秒內完成；有離線時結束碼為 1)
  pcx clean                            一鍵清理：取消註冊「遠端存取已不存在」的電腦 (離線的預設保留，加 -IncludeOffline 才一併清)
  pcx teardown <名稱>                  一鍵移除 PC2 上的遠端存取 (金鑰、防火牆、SSH 設定都還原)，並取消註冊
  pcx uninstall -All -Yes              一鍵全部移除：所有 PC2 的遠端存取 + PC1 上的 pcx 與金鑰
  pcx agents                           在目前資料夾的 AGENTS.md 加入給 AI 的使用說明

  add 的選項:    -Port 22  -Key <已有的私鑰，例如雲端 VM 的 .pem>  -Jump <user@跳板機>  -Force (同一台已用別的名稱註冊時仍要新增)
  invite 的選項: -AllowFrom <LocalSubnet | 192.168.1.0/24 | 100.64.0.0/10 | Any>  -DisablePassword (安裝時就關閉密碼登入，建議改用 pcx harden)
                 -UpgradeServer (Ubuntu：順便升級 openssh-server)  -PasswordlessSudo (Ubuntu：授權免密碼 sudo，等同 root，請謹慎)  -Out <名稱>
  執行的選項:    -RunTimeout 120 (遠端指令總逾時秒數)  -Timeout 60 (連線逾時)  -Encoding utf-8 (遠端輸出亂碼時改 950)
  teardown / uninstall 的選項: -UninstallServer  -Yes (不詢問)；uninstall 另有 -All  -Force (遠端失敗也繼續清本機)

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
$Verbs      = 'install', 'add', 'run', 'put', 'get', 'harden', 'list', 'status', 'clean', 'remove', 'forget', 'teardown', 'uninstall', 'invite', 'agents', 'help', 'guide', 'wizard'

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
    if (-not $txt) { return }   # 空的 config (第一次 add 時) 沒有要移除的區塊
    $pat ="(?ms)^# >>> pcx $([regex]::Escape($name)) >>>.*?^# <<< pcx $([regex]::Escape($name)) <<<\r?\n?"
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
# 不帶金鑰連線，回傳伺服器在 "Permission denied (...)" 裡列出的可用認證方式 (例如 publickey,password)；讀不到則回傳 $null
function Get-OfferedAuth([string]$name) {
    $a = @('-o', 'BatchMode=yes', '-o', "ConnectTimeout=$Timeout", '-o', 'PubkeyAuthentication=no', '-o', 'GSSAPIAuthentication=no', '-T', $name, 'exit')
    $r = Invoke-Capture -CmdArgs $a -TimeoutSec ($Timeout + 15)
    if (($r.Out + $r.Err) -match 'Permission denied \(([^)]*)\)') { return $Matches[1] }
    return $null
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
# 讀 ~/.ssh/config 裡 pcx 的區塊，回傳 名稱 -> 連線目標 @{ host; user; port; jump }
function Get-HostTargets {
    $map = @{}
    if (-not (Test-Path $SshConfig)) { return $map }
    $txt = Get-Content $SshConfig -Raw
    if (-not $txt) { return $map }
    foreach ($m in [regex]::Matches($txt, '(?ms)^# >>> pcx (\S+) >>>\r?\n(.*?)^# <<< pcx \1 <<<')) {
        $t = @{ host = ''; user = ''; port = '22'; jump = '' }
        foreach ($line in ($m.Groups[2].Value -split '\r?\n')) {
            if     ($line -match '^\s*HostName\s+(\S+)')  { $t.host = $Matches[1].ToLower() }
            elseif ($line -match '^\s*User\s+(\S+)')      { $t.user = $Matches[1] }
            elseif ($line -match '^\s*Port\s+(\d+)')      { $t.port = $Matches[1] }
            elseif ($line -match '^\s*ProxyJump\s+(\S+)') { $t.jump = $Matches[1].ToLower() }
        }
        $map[$m.Groups[1].Value] = $t
    }
    return $map
}
function New-HostTarget([string]$hostName, [string]$user, [string]$port, [string]$jump) {
    @{ host = "$hostName".ToLower(); user = "$user"; port = $(if ($port) { "$port" } else { '22' }); jump = "$jump".ToLower() }
}
function Format-Target($t) {
    $s = if ($t.user) { "$($t.user)@$($t.host)" } else { $t.host }
    if ($t.port -ne '22') { $s += ":$($t.port)" }
    if ($t.jump) { $s += " (經 $($t.jump))" }
    return $s
}
# 找出指向同一台主機 (位址 + 埠 + 跳板機相同) 的其他已註冊名稱；-SameUser 時帳號也要相同
# 只比對註冊時填的位址，同一台用 IP 與電腦名稱分別註冊時偵測不到
function Find-SameHost($t, [string]$except, [switch]$SameUser) {
    if (-not $t -or -not $t.host) { return @() }
    $all = Get-HostTargets; $reg = Get-Hosts
    @($all.Keys | Where-Object { $_ -ne $except -and $reg.ContainsKey($_) } | Where-Object {
        $o = $all[$_]
        $o.host -eq $t.host -and $o.port -eq $t.port -and $o.jump -eq $t.jump -and (-not $SameUser -or $o.user -eq $t.user)
    } | Sort-Object)
}
# 確認提示：只有明確回答 y 才算同意。stdin 為空或已到 EOF 時 Read-Host 不回傳任何值，一律當成「否」
function Confirm-Yes([string]$prompt) {
    $v = Read-Host $prompt
    return ("$v" -match '^[yY]')
}
function Show-Usage {
    $self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $t = Get-Content $self -Raw
    if ($t -match '(?s)<#(.*?)#>') { $Matches[1].TrimEnd() }
}

# ---------------------------------------------------------------------------
# 內建使用說明 (與 README.md / AI-GUIDE.md 內容一致；不依賴外部檔案，pcx install 後也能用)
#   pcx help            指令速查 + 完整使用說明
#   pcx help <主題>     只看某一節；pcx guide 與 pcx help 相同
# ---------------------------------------------------------------------------
$GuideOrder = 'setup', 'admin', 'errors', 'env', 'daily', 'remove', 'security', 'ai', 'notes'
$GuideTitle = [ordered]@{
    setup    = '設定流程 (約 3 步)'
    admin    = '管理員 / root 權限'
    errors   = '遇到無法自行解決的狀況：errorRequest'
    env      = '各種連線環境與參數'
    daily    = '日常操作'
    remove   = '一鍵移除'
    security = '安全性與 OpenSSH 更新'
    ai       = '給 AI 的操作守則'
    notes    = '注意事項'
}
$GuideText = @{
setup = @'
最簡單：在 Windows 的 PC1 雙擊 WIZARD.cmd (或執行 pcx wizard)，互動精靈會一步步問你並代為執行下面的步驟；
PC2 是 Ubuntu 時精靈會改帶你看 pcx guide。想自己打指令就照以下步驟，隨時可用 pcx guide 看進度。

PC1 = 你正在用的電腦 (Windows，需要 PowerShell 7 與 OpenSSH 客戶端)。
PC2 = 要被操作的電腦 (Windows 或 Ubuntu)。PC2 只開 OpenSSH，不裝 AI、不登入帳號。

1) PC1：安裝並產生給 PC2 的安裝資料夾
     .\pcx.ps1 install            一次性；重開終端機後任何地方都能用 pcx
                                  (目前這個終端機請用 & <資料夾>\pcx.ps1 代替 pcx)
     pcx invite windows           或 pcx invite ubuntu
   會產生明文資料夾 pcx-pc2-windows / pcx-pc2-ubuntu (腳本 + 你的公鑰 + README.txt，沒有任何編碼)。
   加 -SingleFile 改產生單一檔案；-Out <名稱> 指定輸出名稱。

2) PC2：把整個資料夾複製過去 (隨身碟、雲端硬碟、scp 皆可) 後執行
     Windows：雙擊 INSTALL.cmd (會自動跳出 UAC 要求系統管理員權限)
     Ubuntu ：bash install.sh
   畫面最後會印出 PC2 的 IP 與可直接複製的 pcx add 指令。

3) PC1：註冊並測試
     pcx add pc2 admin@192.168.1.50   註冊並測試連線，同時檢查 PC2 有沒有管理員/sudo 權限
     pcx pc2 "hostname"               回傳 PC2 名稱與 [exit code: 0] 就完成了
     pcx harden pc2                   建議：確認金鑰可用後，關閉 PC2 的密碼登入
     pcx agents                       (選用) 在目前資料夾的 AGENTS.md 寫入「請用 pcx 操作遠端」

雲端 VM 若已有 SSH 與 .pem 金鑰，可跳過 1、2 步：pcx add vm1 ubuntu@公網IP -Key C:\keys\vm.pem
'@
admin = @'
很多操作需要管理員權限 (裝服務、改設定、重啟服務)。pcx add 會檢查並記錄，pcx list 看得到。

  Windows：用 PC2 的「管理員帳號」登入，SSH 工作階段就是已提升的管理員權限，不會有 UAC 提示。
           安裝時若是本機管理員帳號，會設定 LocalAccountTokenFilterPolicy=1 (解除 UAC 對本機帳號遠端登入的限制)，
           否則 SSH 登入只會拿到降級的權限；原值會記錄，移除時還原。注意：這也讓 SMB/WinRM 等遠端登入取得完整管理員權限。
           一般使用者帳號無法透過 SSH 提升權限，這種情況 pcx 會提出 ADMIN_REQUIRED / NO_ADMIN。
  Ubuntu ：SSH 是非互動式，sudo 要密碼就會失敗。兩種做法：
           (1) 產生安裝資料夾時加 -PasswordlessSudo (授權免密碼 sudo，等同 root，移除時自動撤銷)
           (2) 不加，需要 root 的操作請自己在 PC2 做。
           AI 一律用 sudo -n，不會也不應該取得你的密碼。
'@
errors = @'
pcx 與安裝腳本遇到自己解決不了的問題 (沒權限、連不上、金鑰被拒、主機金鑰變更、沙盒擋網路、
Windows Update 失敗、apt 被鎖住等)，會印出固定格式的區塊：

  [errorRequest:AUTH_REJECTED]
    問題: ...
    需要: ...

請照「需要」欄位處理後再繼續；AI 看到時會停下來把內容轉告你。
([hint:...] 只是提示，例如 [hint:ENCODING] 代表輸出亂碼，可加 -Encoding 950 重試。)

常見代碼：
  HOST_NOT_REGISTERED     還沒 pcx add，或執行身分 (AI 沙盒) 看不到 ~\.pcx
  DUPLICATE_HOST          同一台 (帳號+位址+埠+跳板機) 已用別的名稱註冊；沿用舊名稱，或 forget 後再 add，確定要並存才加 -Force
  CONNECT_FAILED          pcx add 連線失敗，原因不在已知清單內 (看上方 ssh 訊息)
  AUTH_REJECTED           PC2 拒絕金鑰：沒在 PC2 執行「這台 PC1 產生」的安裝檔、使用者名稱錯、或非管理員帳號
  UNREACHABLE             連不到 (關機/睡眠、IP 變了、不同網段、訪客 Wi-Fi 隔離、雲端安全群組)
  SSH_NOT_RUNNING         主機在線但 sshd 沒跑或埠不對 (重新執行安裝檔，或 -Port 重新註冊)
  DNS_FAILED              主機名稱解析不到，改用 IP
  HOSTKEY_CHANGED         PC2 主機金鑰變了 (重灌/換機/被冒充)；確認後 ssh-keygen -R <IP>
  KEY_UNREADABLE          讀不到私鑰 (權限、檔案不存在、沙盒看不到使用者資料夾)
  NETWORK_BLOCKED         本機擋了連線 (AI 沙盒、防火牆、防毒)
  SSH_CLIENT_MISSING      PC1 沒有 ssh (設定 > 選用功能 > OpenSSH 用戶端)
  ADMIN_REQUIRED          Windows 操作需要管理員帳號
  SUDO_PASSWORD_REQUIRED  Ubuntu 的 sudo 要密碼 (見 pcx help admin)
  NO_ADMIN                註冊的帳號沒有管理員/免密碼 sudo
  RUN_TIMEOUT             遠端指令超過 -RunTimeout 秒 (多半在等輸入；改非互動寫法或調高逾時)
  HARDEN_*                關閉密碼登入的前檢/執行/驗證失敗；HARDEN_NOT_EFFECTIVE = 設定已寫入但伺服器仍提供密碼登入
  INVALID_ALLOW_FROM      -AllowFrom 格式不對 (LocalSubnet、Any，或 IP / CIDR，逗號分隔)
  TEARDOWN_FAILED / UNINSTALL_PARTIAL   遠端移除失敗
  PC2 安裝腳本的問題：
    Windows  WINDOWS_CAPABILITY_QUERY_FAILED / OPENSSH_NOT_AVAILABLE / OPENSSH_INSTALL_FAILED / SSHD_START_FAILED / NO_IP_ADDRESS
    Ubuntu   NOT_DEBIAN / NO_SYSTEMD / APT_FAILED / APT_UPGRADE_FAILED / SSHD_START_FAILED / SUDOERS_INVALID / NO_IP_ADDRESS
'@
env = @'
  區網                預設就是區網 (防火牆只允許 LocalSubnet，Ubuntu 需 ufw 已啟用；金鑰的 from= 限私有網段)
  網線直連            兩邊手動設同網段固定 IP (例如 192.168.50.1 / .2)，其餘相同
  VPN (Tailscale 等)  pcx invite windows -AllowFrom 100.64.0.0/10；pcx add 用 VPN 的 IP 或名稱
  指定來源網段        pcx invite ubuntu -AllowFrom 192.168.1.0/24
  雲端 VM             pcx add vm1 ubuntu@公網IP -Key C:\keys\vm.pem  (通常不需要 invite)
  經跳板機            pcx add pc2 admin@內網IP -Jump user@跳板機
  非 22 埠            加 -Port 2222

雲端不要把 22 埠對全網際網路開放：安全群組只允許你的固定 IP，或改走 VPN。

參數一覽：
  add       -Port 22  -Key <私鑰>  -Jump <user@跳板機>  -Force (同一台已用別的名稱註冊時仍要新增)
  invite    -AllowFrom <LocalSubnet | 網段 | 100.64.0.0/10 | Any>  -DisablePassword  -UpgradeServer
            -PasswordlessSudo (僅 Ubuntu，等同 root)  -SingleFile  -Out <名稱>
  執行      -RunTimeout 120 (遠端指令總逾時秒數)  -Timeout 60 (連線逾時)  -Encoding utf-8 (亂碼改 950)
  status/clean   -Timeout 5  -IncludeOffline  -Yes
  teardown/uninstall   -UninstallServer  -Yes (不詢問)；uninstall 另有 -All  -Force (遠端失敗也繼續清本機)
'@
daily = @'
  pcx pc2 "Get-Service sshd"              Windows 遠端用 PowerShell 語法；Ubuntu 用 bash
  pcx pc2 -File .\fix.ps1                 在 PC2 執行本機腳本 (遠端是 linux 則用 .sh)
  pcx put pc2 .\app.zip C:/temp/app.zip   上傳 (Windows 遠端路徑用 C:/temp/x 形式)
  pcx get pc2 /var/log/syslog .\syslog    下載
  pcx list                                已註冊的電腦、連線目標、作業系統與 admin/sudo 狀態 (同一台有多個名稱會標出)
  pcx status [名稱]                       平行檢測是否存活 (約 5 秒內)：在線 / 金鑰被拒 / SSH 未開 / 離線
  pcx clean                               清理「遠端存取已不存在」的註冊；離線的預設保留，確定不用再加 -IncludeOffline
  pcx forget <名稱>                       只刪 PC1 本機的註冊紀錄，不連到 PC2 (舊名 pcx remove 仍可用)
  pcx agents                              在目前資料夾的 AGENTS.md 寫入給 AI 的用法

輸出最後一行 [exit code: N] 是遠端指令的結束碼，非 0 代表失敗。
遠端指令預設最多 120 秒 (-RunTimeout 可調)，stdin 會被關閉，等輸入的指令不會卡住而是回報逾時；
所以請用非互動寫法 (apt -y、sudo -n)。中文 Windows 輸出若亂碼，加 -Encoding 950。
'@
remove = @'
  只移除某台 PC2 的遠端存取          pcx teardown pc2   (同一台還有其他名稱時會警告，確認後一併取消註冊)
  只刪 PC1 的註冊、不動 PC2          pcx forget pc2
  全部清乾淨 (所有 PC2 + PC1)        pcx uninstall -All -Yes
  只清 PC1，不動 PC2                 pcx uninstall -Yes
  連 OpenSSH Server 也一併卸載       加 -UninstallServer
  PC1 已不在手邊，直接在 PC2 移除    Windows：資料夾裡的 REMOVE.cmd (右鍵以系統管理員身分執行)
                                     Ubuntu ：bash remove.sh

PC2 依安裝時記下的「原本狀態」還原：只移除 pcx 自己的金鑰 (其他金鑰保留)、還原防火牆規則與密碼登入設定、
還原預設 shell；SSH 若是 pcx 裝的或原本沒在執行就停用，原本就在用的雲端 VM 不會被關掉。
PC1 會刪除 pcx 指令、~\.pcx、專用金鑰 id_ed25519_pcx、~/.ssh/config 裡 pcx 的區塊。
'@
security = @'
- 密碼登入在安裝時維持原樣 (避免金鑰沒生效時把自己鎖在外面)。pcx add 確認金鑰可用後，執行
  pcx harden <名稱> 關閉密碼登入；它會先確認金鑰登入成功才動手，事後再驗證金鑰仍可登入，
  並以不帶金鑰的連線確認伺服器已不再提供 password / keyboard-interactive。
- Windows PC2 會設定 LocalAccountTokenFilterPolicy=1，本機管理員帳號的所有遠端登入 (含 SMB/WinRM) 都是完整管理員權限；
  請確保本機管理員帳號都有強密碼，用完 pcx teardown 或 REMOVE.cmd 會還原成原值。
- 來源限制 (-AllowFrom，預設 LocalSubnet) 分三層：
    1) 金鑰：authorized_keys 的 pcx 金鑰加上 from="<來源>",restrict，私鑰外流也無法從其他來源使用，且不能做連接埠轉發。
       LocalSubnet 在這裡代表私有網段 (10/8、172.16/12、192.168/16、169.254/16 與 IPv6 對應網段)，PC2 換網路也不會被鎖在外面。
    2) sshd (Ubuntu)：sshd_config 最後加上 Match Address 區塊，不在允許來源的連線不接受密碼登入；ufw 沒啟用也有效。
    3) 防火牆：Windows 一律設定；Ubuntu 只有 ufw 已啟用時才加規則 (沒啟用時 22 埠仍對所有來源開放，但第 1、2 層仍有效)。
  -AllowFrom Any 會略過第 1、2 層的來源限制 (restrict 仍會加上)。
- 不用時執行 pcx teardown <名稱>，SSH 就不會一直開著，這是最有效的防護。
- 腳本不會自動升級 OpenSSH，只會在安裝結束時印出版本；Ubuntu 若有可用更新會提醒。
    Ubuntu ：評估後自行 sudo apt install --only-upgrade openssh-server；
             或 pcx invite ubuntu -UpgradeServer (非互動、保留設定檔，但會重啟 sshd，可能連帶升級 openssl/libc)。
    Windows：OpenSSH 由 Windows Update 維護，請定期更新 Windows。
- 發現 OpenSSH 重大漏洞時，請對照官方公告與發行版的安全追蹤確認影響範圍。
  例如 CVE-2026-123158 (SSHole) 主要影響 musl 且無 PAM 的系統 (如 Alpine)，緩解方式之一是關閉密碼登入 (pcx harden)。
'@
ai = @'
(完整版見 AI-GUIDE.md；以下為重點)
- pcx wizard 是給人用的互動精靈，AI 不要執行它 (非互動終端機會被拒絕)；AI 用 pcx guide 看進度。
- 操作 PC2 一律用 pcx <名稱> "<指令>"，不要改用其他連線方式；先 pcx status <名稱> 確認在線。
- 讀最後一行 [exit code: N]，非 0 就是失敗，不可假裝成功。
- 出現 [errorRequest:代碼]：立刻停止，把「問題」與「需要」原樣轉告使用者，等回覆後才繼續；
  不要猜原因、不要繞過、不要重複重試。[hint:...] 可自行依提示調整。
- 不輸入、猜測或儲存任何密碼；不讀取或顯示私鑰 (只有 .pub 可以顯示)。需要 root 時用 sudo -n。
- PC2 的安裝必須由使用者自己在 PC2 執行；連線前先問清楚：PC2 作業系統、連線環境、IP 與使用者名稱、
  是否為已有 .pem 的雲端 VM。
- 不要用 -AllowFrom Any、-PasswordlessSudo，除非使用者明確要求並了解風險。
- 會修改設定、刪除檔案、重啟服務或關機的指令，先向使用者確認；pcx harden / teardown / uninstall 也要先取得同意。
- 先唯讀診斷，再提修復建議；修改前先備份，修改後立刻驗證。回報：執行了什麼、結束碼、關鍵輸出、下一步建議。
- AI 沙盒 (例如 Codex) 可能擋網路或 ssh，請使用者放寬沙盒或核准，不要繞過。
'@
notes = @'
- 登入後的權限：Windows 是管理員，Ubuntu 是 invite 時使用的帳號 (加了 -PasswordlessSudo 就等同 root)。
  私鑰外洩就等於 PC2 被控制，請妥善保管。專用金鑰沒有加密碼 (為了免輸入)，跨網路使用建議搭配 VPN 或來源限制。
- 網線直連沒設固定 IP 時，系統會自動配 169.254.x.x；安裝完成畫面會標註，建議改設固定 IP。
- Windows PC2 的 SSH 預設 shell 會設成 PowerShell 7 (沒有就用 Windows PowerShell)，遠端指令用 PowerShell 語法。
- 設定檔位置：已註冊電腦 ~\.pcx\hosts.json；連線設定 ~\.ssh\config 中的 # >>> pcx <名稱> >>> 區塊。
'@
}
function Show-Guide([string]$topic) {
    if ($topic) {
        $t = $topic.ToLower()
        "== $($GuideTitle[$t]) ==`n"
        $GuideText[$t].TrimEnd()
        return
    }
    'pcx - 讓 PC1 (含 AI CLI) 透過 SSH 操作遠端電腦 PC2 (Windows / Ubuntu / 雲端 VM)'
    ''
    '== 指令速查 =='
    Show-Usage
    foreach ($k in $GuideOrder) {
        ''
        "== $($GuideTitle[$k])  (pcx help $k) =="
        ''
        $GuideText[$k].TrimEnd()
    }
    ''
    "只看某一節: pcx help <主題>   主題: $($GuideOrder -join ', ')"
}

# ---------------------------------------------------------------------------
# pcx guide：引導流程。偵測目前進度，把各功能串成一條路線並指出「下一步」要執行的指令。
# 不會詢問輸入、不會自動修改任何東西 (AI CLI 也能安全執行)；加名稱時會實際檢測該台連線。
# ---------------------------------------------------------------------------
function Show-Wizard([string]$name) {
    $ok = '[v]'; $no = '[ ]'
    $mark = { param($cond) if ($cond) { $ok } else { $no } }
    # 只記下第一個未完成步驟的指令，作為「下一步」
    $setNext = { param($cmd, $why) if (-not $script:wizNext) { $script:wizNext = @($cmd, $why) } }
    $script:wizNext = $null

    'pcx 引導流程 (pcx guide [名稱])  —  [v] 已完成  [ ] 尚未完成'
    ''
    # 步驟 1：PC1 環境
    $psOk  = $PSVersionTable.PSVersion.Major -ge 7
    $sshOk = [bool](Get-Command ssh -ErrorAction SilentlyContinue)
    "$(& $mark ($psOk -and $sshOk)) 1. PC1 環境：PowerShell $($PSVersionTable.PSVersion) / OpenSSH 客戶端 $(if ($sshOk) { '有' } else { '沒有' })"
    if (-not $sshOk) { & $setNext '安裝 OpenSSH 用戶端 (設定 > 應用程式 > 選用功能 > 新增功能)，重開終端機' '沒有 ssh 無法連線' }

    # 步驟 2：安裝成全域指令
    $shimOk = (Test-Path (Join-Path $env:APPDATA 'npm\pcx.cmd')) -or (Test-Path (Join-Path $PcxDir 'pcx.cmd'))
    $instOk = $shimOk -and (Test-Path (Join-Path $PcxDir 'pcx.ps1'))
    "$(& $mark $instOk) 2. 安裝 pcx 全域指令 (pcx install)"
    if (-not $instOk) { & $setNext "& `"$(Join-Path $PSScriptRoot 'pcx.ps1')`" install" '之後任何資料夾都能直接打 pcx (需重開終端機)' }

    # 步驟 3：產生給 PC2 的安裝資料夾
    $keyOk  = Test-Path $DefaultKey
    $kits   = @(Get-ChildItem -Directory -Filter 'pcx-pc2-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $h      = Get-Hosts
    "$(& $mark ($keyOk -or $h.Count)) 3. 產生給 PC2 的安裝資料夾 (pcx invite windows|ubuntu)$(if ($kits) { "  目前資料夾已有: $($kits -join ', ')" })"
    if (-not $keyOk -and $h.Count -eq 0) { & $setNext 'pcx invite windows   (或 pcx invite ubuntu；VPN 加 -AllowFrom 100.64.0.0/10，見 pcx help env)' '產生明文資料夾給 PC2；雲端 VM 已有 .pem 可跳過，直接 pcx add ... -Key <pem>' }

    # 步驟 4：PC2 執行安裝 (只能由使用者在 PC2 做)
    "$(& $mark $h.Count) 4. 在 PC2 執行安裝：Windows 右鍵 INSTALL.cmd「以系統管理員身分執行」/ Ubuntu bash install.sh"
    if ($h.Count -eq 0) { & $setNext '把 pcx-pc2-* 資料夾複製到 PC2 並執行安裝 (需由你在 PC2 操作)，記下畫面最後印出的 IP' 'PC2 要先開 SSH 並授權 PC1 的金鑰' }

    # 步驟 5：註冊並測試
    "$(& $mark $h.Count) 5. 註冊並測試連線 (pcx add <名稱> <user@IP>)  已註冊 $($h.Count) 台"
    foreach ($k in ($h.Keys | Sort-Object)) {
        $v = $h[$k]
        "      - {0,-14} {1,-8} 管理員/sudo: {2,-4} 密碼登入: {3}" -f $k, $v.os, $(if ($v.admin) { '有' } else { '沒有' }), $(if ($v.hardened) { '已關閉' } else { '未關閉' })
    }
    if ($h.Count -eq 0) { & $setNext 'pcx add pc2 <使用者>@<PC2 的 IP>   (非 22 埠 -Port N；跳板機 -Jump user@host)' '註冊後會自動測試連線並檢查管理員/sudo 權限' }

    # 指定名稱：實際檢測
    $targets = if ($name) { Assert-Host $name | Out-Null; @($name) } else { @($h.Keys | Sort-Object) }
    if ($name) {
        Assert-Ssh
        $res = Test-Hosts @($name) 5
        $st = $res[0].State
        "      檢測 ${name}: $($StateLabel[$st]) ($($res[0].Ms) ms)"
        if ($st -ne 'online') { & $setNext "pcx status $name" "$name 目前不在線；請確認 PC2 開機、IP 未變、在同一網路 (詳見 pcx help errors)" }
    }

    # 步驟 6：權限
    $noAdmin = @($targets | Where-Object { -not $h[$_].admin })
    "$(& $mark ($h.Count -and -not $noAdmin.Count)) 6. 管理員 / sudo 權限$(if ($noAdmin.Count) { "  沒有: $($noAdmin -join ', ')" })"
    if ($noAdmin.Count) { & $setNext "需要管理員操作時：Windows 改用管理員帳號重新 pcx add；Ubuntu 見 pcx help admin" "$($noAdmin -join ', ') 不能做裝服務/改設定/harden/teardown；只做一般操作可略過此步" }

    # 步驟 7：關閉密碼登入
    $soft = @($targets | Where-Object { -not $h[$_].hardened })
    "$(& $mark ($h.Count -and -not $soft.Count)) 7. 關閉密碼登入，只留金鑰 (pcx harden <名稱>)$(if ($soft.Count) { "  未關閉: $($soft -join ', ')" })"
    if ($soft.Count) { & $setNext "pcx harden $($soft[0])" '確認金鑰可用後才動手，事後再驗證一次 (見 pcx help security)' }

    # 步驟 8：讓 AI 知道怎麼用
    $agentsOk = (Test-Path 'AGENTS.md') -and ((Get-Content 'AGENTS.md' -Raw) -match 'pcx')
    "$(& $mark $agentsOk) 8. (選用) 在目前資料夾的 AGENTS.md 寫入 AI 用法 (pcx agents)"

    ''
    '日常操作：pcx <名稱> "<指令>"、pcx <名稱> -File 腳本、pcx put/get、pcx status、pcx list   (pcx help daily)'
    '想要一步步問答、代為執行：pcx wizard (Windows 互動精靈，也可雙擊 WIZARD.cmd)'
    '用完收尾：pcx teardown <名稱> 移除某台；pcx uninstall -All -Yes 全部清乾淨          (pcx help remove)'
    '遇到 [errorRequest:代碼]：照「需要」處理後再繼續                                   (pcx help errors)'
    ''
    if ($script:wizNext) {
        "下一步: $($script:wizNext[0])"
        "  原因: $($script:wizNext[1])"
    } elseif (-not $agentsOk -and $h.Count) {
        '下一步: (選用) pcx agents，或直接開始使用 pcx <名稱> "<指令>"'
    } else {
        '設定已全部完成，可以直接使用 pcx <名稱> "<指令>"。'
    }
}

# ---------------------------------------------------------------------------
# pcx wizard：Windows 互動精靈。一步步詢問，代為執行 PC1 端的指令 (install / invite / add / harden / agents …)。
# 守則同 AI-GUIDE：不碰密碼與私鑰；PC2 的安裝由使用者自己在 PC2 做；會改變 PC2 的動作先確認；errorRequest 會停下說明。
# PC2 是 Ubuntu 時不走精靈，改用 pcx guide。
# ---------------------------------------------------------------------------
function Read-Answer([string]$prompt, [string]$default = '') {
    $p = if ($default) { "$prompt [$default]" } else { $prompt }
    if ([Console]::IsInputRedirected) { Write-Host -NoNewline "$p`: "; $v = [Console]::In.ReadLine(); Write-Host $v }
    else { $v = Read-Host $p }
    if ($null -eq $v) { Write-Host "`n(輸入已結束，精靈離開)"; exit 1 }
    $v = $v.Trim()
    if ($v -eq '' -and $default) { return $default }
    return $v
}
function Read-YesNo([string]$prompt, [bool]$default = $true) {
    $d = if ($default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $v = Read-Answer "$prompt ($d)"
        if ($v -eq '') { return $default }
        if ($v -match '^[yY]') { return $true }
        if ($v -match '^[nN]') { return $false }
    }
}
function Read-Menu([string]$title, [string[]]$items, [string]$default = '1') {
    Write-Host $title
    for ($i = 0; $i -lt $items.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $items[$i]) }
    while ($true) {
        $v = Read-Answer '請選擇' $default
        if ($v -match '^[qQ]$') { return 0 }
        if ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le $items.Count) { return [int]$v }
        Write-Host "請輸入 1-$($items.Count)，或 q 離開。"
    }
}
# 以子行程執行 pcx 的某個功能 (沿用原本的程式路徑與錯誤處理)，畫面即時顯示；回傳結束碼，輸出存在 $script:WizOut
function Invoke-PcxStep([string[]]$argv) {
    Write-Host ("`n> pcx " + (($argv | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')) -ForegroundColor Cyan
    $lines = @(@() | & pwsh -NoProfile -File $PSCommandPath @argv 2>&1 | ForEach-Object { $s = "$_"; Write-Host $s; $s })
    $script:WizOut = $lines -join "`n"
    return $LASTEXITCODE
}
function Stop-OnErrorRequest([int]$code) {
    if ($code -eq 0) { return $false }
    if ($script:WizOut -match '\[errorRequest:') { Write-Host "`n上面的 [errorRequest] 說明了問題與需要你處理的事。處理完後可重新執行 pcx wizard。" -ForegroundColor Yellow }
    else { Write-Host "`n這一步失敗了 (結束碼 $code)，請看上方訊息。" -ForegroundColor Yellow }
    return $true
}
function Read-HostName([hashtable]$h) {
    while ($true) {
        $n = Read-Answer '幫這台 PC2 取個名稱 (英數字、- 、_)' 'pc2'
        if ($n -notmatch '^[A-Za-z0-9_-]+$' -or $n -in $Verbs) { Write-Host '名稱只能用英數字、- 、_，且不可與 pcx 的指令同名。'; continue }
        if ($h.ContainsKey($n) -and -not (Read-YesNo "$n 已經註冊過，要覆蓋嗎?" $false)) { continue }
        return $n
    }
}
# 防呆：這組 帳號@位址:埠 已經用別的名稱註冊過時，提示並回傳已存在的名稱
function Find-WizardDuplicate([string]$name, [string]$user, [string]$ip, [string]$port, [string]$jump) {
    $t = New-HostTarget $ip $user $port $jump
    $dup = @(Find-SameHost $t $name -SameUser)
    if (-not $dup.Count) { return $null }
    Write-Host "`n$(Format-Target $t) 已經註冊為 $($dup -join ', ')。同一台電腦不需要兩個名稱：之後對其中一個 teardown，另一個也會跟著失效。" -ForegroundColor Yellow
    return $dup[0]
}

function Start-WizardNewHost {
    $os = Read-Menu "`nPC2 是什麼系統?" @('Windows', 'Ubuntu')
    if ($os -eq 0) { return }
    if ($os -eq 2) {
        Write-Host "`nUbuntu 的 PC2 請照 pcx guide 的步驟進行 (每一步會告訴你下一個指令)："
        [void](Invoke-PcxStep @('guide'))
        Write-Host "`n完整說明: pcx help setup"
        return
    }
    $conn = Read-Menu "`nPC1 和 PC2 怎麼連線?" @(
        '同一個區網 (家裡/公司同一個路由器)',
        '網線直連 (兩台用網路線直接接)',
        'VPN (例如 Tailscale)',
        '指定來源網段 (例如 192.168.1.0/24)',
        '經跳板機',
        '雲端 VM，已經有 SSH 與 .pem 金鑰')
    if ($conn -eq 0) { return }
    $h = Get-Hosts

    if ($conn -eq 6) {
        $name = Read-HostName $h
        $user = Read-Answer '登入的使用者名稱' 'Administrator'
        $ip   = Read-Answer 'VM 的公網 IP 或網域'
        while (-not (Test-Path -LiteralPath ($pem = Read-Answer '.pem 私鑰檔的路徑'))) { Write-Host '找不到這個檔案，請再輸入一次。' }
        $port = Read-Answer 'SSH 埠' '22'
        if ($d = Find-WizardDuplicate $name $user $ip $port '') {
            if (Read-YesNo "直接沿用 $d (不另外建立 $name)?" $true) { Complete-WizardHost $d }
            return
        }
        if (Stop-OnErrorRequest (Invoke-PcxStep @('add', $name, "$user@$ip", '-Key', $pem, '-Port', $port))) { return }
        Complete-WizardHost $name
        return
    }

    $allow = switch ($conn) { 3 { '100.64.0.0/10' } 4 { $null } default { 'LocalSubnet' } }
    if ($conn -eq 3) { Write-Host 'VPN 預設允許 Tailscale 網段 100.64.0.0/10。'; if (-not (Read-YesNo '使用這個網段?' $true)) { $allow = $null } }
    while (-not $allow) {
        $v = Read-Answer '允許連入的來源網段 (CIDR，例如 192.168.1.0/24)'
        if ($v -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') { $allow = $v } else { Write-Host '格式不對，請輸入像 192.168.1.0/24 的網段。' }
    }
    if ($conn -eq 2) { Write-Host "`n提醒：網線直連請先在兩台手動設定同網段的固定 IP (例如 192.168.50.1 / 192.168.50.2)。" }

    # 產生安裝資料夾 (若已產生過且 PC2 已安裝，可直接跳到註冊)
    $outName = 'pcx-pc2-windows'
    $kit = Join-Path (Get-Location) $outName
    $skipKit = (Test-Path $kit) -and (Test-Path $DefaultKey) -and (Read-YesNo "`n這裡已經有 $outName。PC2 已經用它安裝完成了嗎? (是 = 直接跳到註冊)" $false)
    if (-not $skipKit) {
        Write-Host "`n接下來會在 $(Get-Location) 產生資料夾 $outName (明文腳本 + PC1 的公鑰，不含私鑰)。來源限制: $allow"
        if (-not (Read-YesNo '產生安裝資料夾?' $true)) { return }
        if (Stop-OnErrorRequest (Invoke-PcxStep @('invite', 'windows', '-AllowFrom', $allow))) { return }
        if (Read-YesNo '要開啟檔案總管顯示這個資料夾嗎?' $true) { Start-Process explorer.exe "/select,`"$kit`"" }

        Write-Host "`n===== 請你到 PC2 操作 (這一步只能由你做) =====" -ForegroundColor Green
        Write-Host "  1. 把整個 $outName 資料夾複製到 PC2 (隨身碟、雲端硬碟皆可)"
        Write-Host '  2. 在 PC2 對 INSTALL.cmd 按右鍵，選「以系統管理員身分執行」'
        Write-Host '  3. 等畫面最後印出 IP，記下來'
        Write-Host '  (要登入的帳號必須是 PC2 的「管理員帳號」，否則之後無法做需要管理員的操作)'
        if (-not (Read-YesNo "`nPC2 安裝完成了嗎?" $true)) { Write-Host '完成後重新執行 pcx wizard，選「新增一台 PC2」，在同一個資料夾會問你是否直接跳到註冊。'; return }
    }

    $name = Read-HostName $h
    while ($true) {
        $user = Read-Answer 'PC2 的管理員帳號名稱'
        $ip   = Read-Answer 'PC2 畫面印出的 IP (或電腦名稱)'
        $argv = @('add', $name, "$user@$ip")
        $jump = ''
        if ($conn -eq 5) { $jump = Read-Answer '跳板機 (使用者@主機)'; $argv += @('-Jump', $jump) }
        $port = Read-Answer 'SSH 埠' '22'
        if ($port -ne '22') { $argv += @('-Port', $port) }
        if ($d = Find-WizardDuplicate $name $user $ip $port $jump) {
            if (Read-YesNo "直接沿用 $d (不另外建立 $name)?" $true) { Complete-WizardHost $d; return }
            if (-not (Read-YesNo '要重新輸入帳號/IP 嗎?' $true)) { return }
            continue
        }
        $code = Invoke-PcxStep $argv
        if ($code -eq 0) { break }
        [void](Stop-OnErrorRequest $code)
        if (-not (Read-YesNo '要修正後重新輸入帳號/IP 再試一次嗎?' $true)) { return }
    }
    Complete-WizardHost $name
}

# 註冊成功後：測試、harden、agents
function Complete-WizardHost([string]$name) {
    Write-Host "`n測試在 $name 上執行 hostname ..."
    if (Stop-OnErrorRequest (Invoke-PcxStep @($name, 'hostname'))) { return }
    $info = (Get-Hosts)[$name]
    if ($info.hardened) { Write-Host "`n$name 已經關閉密碼登入。" }
    elseif (-not $info.admin) { Write-Host "`n$name 這個帳號沒有管理員/sudo 權限，先略過「關閉密碼登入」。(pcx help admin)" }
    else {
        Write-Host "`n建議關閉 $name 的密碼登入，只留金鑰：會先確認金鑰可登入才動手，結束後再驗證一次。"
        if (Read-YesNo "現在關閉 $name 的密碼登入?" $true) { [void](Stop-OnErrorRequest (Invoke-PcxStep @('harden', $name))) }
        else { Write-Host "之後可執行: pcx harden $name" }
    }
    if (Read-YesNo "`n要在目前資料夾 ($(Get-Location)) 的 AGENTS.md 寫入給 AI 的用法嗎?" $false) { [void](Invoke-PcxStep @('agents')) }
    Write-Host "`n完成！之後可以這樣用：" -ForegroundColor Green
    Write-Host "  pcx $name `"Get-Service sshd`"        在 PC2 執行指令 (Windows 用 PowerShell 語法)"
    Write-Host "  pcx put $name .\a.zip C:/temp/a.zip  上傳；pcx get 下載"
    Write-Host "  pcx status                          檢查是否在線"
    Write-Host "  pcx teardown $name                  用完移除 PC2 的遠端存取"
}

function Select-WizardHost([hashtable]$h) {
    $names = @($h.Keys | Sort-Object)
    $tg = Get-HostTargets
    $i = Read-Menu "`n選一台電腦:" ($names | ForEach-Object { '{0}  ({1}, {2})' -f $_, $h[$_].os, $(if ($tg[$_]) { Format-Target $tg[$_] } else { '?' }) })
    if ($i -eq 0) { return $null }
    return $names[$i - 1]
}

function Start-Wizard {
    if (-not $IsWindows) { Write-Host '互動精靈只在 Windows 上使用；請改用 pcx guide。'; exit 1 }
    if ([Console]::IsInputRedirected -and -not $env:PCX_WIZARD_STDIN) {
        Write-Host '偵測到不是互動式終端機 (例如 AI 工具在執行)。互動精靈需要你親自回答問題；AI 請改用 pcx guide。'
        exit 1
    }
    Write-Host '==============================================' -ForegroundColor Green
    Write-Host ' pcx 互動精靈：讓這台電腦 (PC1) 操作另一台 PC2' -ForegroundColor Green
    Write-Host ' 隨時輸入 q 或按 Ctrl+C 離開。不會詢問或儲存任何密碼。' -ForegroundColor Green
    Write-Host '==============================================' -ForegroundColor Green

    # 環境
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Write-ErrorRequest 'SSH_CLIENT_MISSING' '這台電腦找不到 ssh 指令 (OpenSSH 客戶端)。' '請安裝 OpenSSH 客戶端: 設定 > 應用程式 > 選用功能 > 新增功能 > OpenSSH 用戶端；安裝後重開終端機再執行精靈。'
        exit 1
    }
    # 安裝全域指令
    $shimOk = (Test-Path (Join-Path $env:APPDATA 'npm\pcx.cmd')) -or (Test-Path (Join-Path $PcxDir 'pcx.cmd'))
    if (-not ($shimOk -and (Test-Path (Join-Path $PcxDir 'pcx.ps1')))) {
        Write-Host "`n還沒安裝 pcx 全域指令 (安裝後任何資料夾都能直接打 pcx)。"
        if (Read-YesNo '現在安裝?' $true) { if (Stop-OnErrorRequest (Invoke-PcxStep @('install'))) { exit 1 } }
    }

    while ($true) {
        $h = Get-Hosts
        $items = @('新增一台 PC2 (完整流程)')
        if ($h.Count) { $items += @('檢查已註冊的電腦是否在線', '關閉某台的密碼登入 (harden)', '移除某台 PC2 的遠端存取 (teardown)', '只刪本機的註冊名稱，不動 PC2 (forget)') }
        $items += '顯示目前進度 (pcx guide)'
        $c = Read-Menu "`n要做什麼? (q 離開)" $items
        if ($c -eq 0) { Write-Host '再見。'; return }
        switch ($items[$c - 1]) {
            '新增一台 PC2 (完整流程)'      { Start-WizardNewHost }
            '檢查已註冊的電腦是否在線'      { [void](Invoke-PcxStep @('status')) }
            '關閉某台的密碼登入 (harden)'   {
                $n = Select-WizardHost $h
                if ($n -and (Read-YesNo "關閉 $n 的密碼登入 (只留金鑰)?" $true)) { [void](Stop-OnErrorRequest (Invoke-PcxStep @('harden', $n))) }
            }
            '移除某台 PC2 的遠端存取 (teardown)' {
                $n = Select-WizardHost $h
                if ($n) {
                    Write-Host "會移除 $n 上 pcx 的金鑰、防火牆規則與 SSH 設定 (依安裝前狀態還原)，並取消本機註冊。"
                    $tg = Get-HostTargets; $others = @(Find-SameHost $tg[$n] $n)
                    if ($others.Count) {
                        Write-Host "注意: $($others -join ', ') 也指向同一台主機，移除後 $($others -join ', ') 也會失效，並一併取消註冊。" -ForegroundColor Yellow
                        Write-Host "如果只是想刪掉多出來的名稱，請改選「只刪本機的註冊名稱，不動 PC2 (forget)」。"
                    }
                    if ((Read-Answer "確定請輸入電腦名稱 $n") -ceq $n) { [void](Stop-OnErrorRequest (Invoke-PcxStep @('teardown', $n, '-Yes'))) }
                    else { Write-Host '名稱不符，已取消。' }
                }
            }
            '只刪本機的註冊名稱，不動 PC2 (forget)' {
                $n = Select-WizardHost $h
                if ($n -and (Read-YesNo "只刪除 PC1 上 $n 的註冊紀錄 (不連到 PC2，PC2 的設定不變)?" $true)) { [void](Stop-OnErrorRequest (Invoke-PcxStep @('forget', $n))) }
            }
            '顯示目前進度 (pcx guide)'      { [void](Invoke-PcxStep @('guide')) }
        }
    }
}

# ---- 未帶指令 / help / guide ----------------------------------------------
if (-not $Cmd -or $Cmd -eq 'help') {
    if ($A -and -not $GuideText.ContainsKey($A.ToLower())) {
        Write-Host "沒有這個主題: $A"; Write-Host "可用主題: $($GuideOrder -join ', ')"; exit 1
    }
    Show-Guide $A; exit 0
}
if ($Cmd -eq 'guide') { Show-Wizard $A; exit 0 }
if ($Cmd -eq 'wizard') { Start-Wizard; exit 0 }

# ---- 非內建動詞 => 視為「pcx <名稱> "<指令>"」 -------------------------------
if ($Cmd -notin $Verbs) { $B = $A; $A = $Cmd; $Cmd = 'run' }

if ($Cmd -in 'add', 'run', 'put', 'get', 'harden', 'status', 'clean', 'teardown') { Assert-Ssh }

switch ($Cmd) {

'install' {
    New-Item -ItemType Directory -Force -Path $PcxDir | Out-Null
    # 來源：執行中的 pcx.ps1 所在資料夾。若是透過全域指令 (~\.pcx 的副本) 執行，改用目前資料夾裡的 pcx.ps1 (例如 git pull 後的專案資料夾)
    $src = (Resolve-Path $PSScriptRoot).Path
    if ($src -eq (Resolve-Path $PcxDir).Path) {
        $here = (Get-Location).Path
        if ((Test-Path (Join-Path $here 'pcx.ps1')) -and $here -ne $src) { $src = $here }
        else { Write-Warning "目前執行的是已安裝的副本 ($PcxDir)，沒有可更新的來源。要更新，請到專案資料夾執行 pcx install，或執行: pwsh -NoProfile -File <專案資料夾>\pcx.ps1 install" }
    }
    if ($src -ne (Resolve-Path $PcxDir).Path) {
        Copy-Item (Join-Path $src '*.ps1'), (Join-Path $src '*.sh'), (Join-Path $src 'WIZARD.cmd') -Destination $PcxDir -Force
        Write-Host "已從 $src 複製最新版到 $PcxDir"
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
    foreach ($a in @($AllowFrom -split '\s*,\s*' | Where-Object { $_ })) {
        if ($a -notin 'LocalSubnet', 'Any' -and $a -notmatch '^[0-9A-Fa-f:.]+(/\d{1,3})?$') {
            Write-ErrorRequest 'INVALID_ALLOW_FROM' "來源限制格式不正確: $a" '請用 LocalSubnet、Any，或 IP / CIDR 網段 (例如 192.168.1.0/24)，多個以逗號分隔。'
            exit 1
        }
    }
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
            # PC2 用的是 Windows PowerShell 5.1：無 BOM 的 UTF-8 會被當成 ANSI (cp950) 讀取，中文吃掉引號導致語法錯誤，所以一律寫成 UTF-8 with BOM
            $bom = New-Object Text.UTF8Encoding $true
            foreach ($f in 'setup-remote.ps1', 'remove-remote.ps1') {
                [IO.File]::WriteAllText((Join-Path $dir $f), (Get-Content (Join-Path $PSScriptRoot $f) -Raw -Encoding utf8), $bom)
            }
            $flag = if ($DisablePassword) { ' -DisablePasswordLogin' } else { '' }
            $bat = @'
@echo off
chcp 65001 >nul
net session >nul 2>&1
if errorlevel 1 (
  echo 需要系統管理員權限，正在要求提升權限 ^(請在 UAC 視窗按「是」^)...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
  if errorlevel 1 (
    echo 無法提升權限。請按 Win+X 開啟「終端機 ^(系統管理員^)」，cd 到這個資料夾後執行 .\%~nx0
    pause
  )
  exit /b
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
        $sudoLine = if ($PasswordlessSudo -and $os -eq 'ubuntu') { "`n  4. 授權此帳號免密碼 sudo (等同 root)；移除時會一併撤銷" }
                    elseif ($os -eq 'windows') { "`n  4. 本機管理員帳號：設定 LocalAccountTokenFilterPolicy=1，讓 SSH 登入取得完整管理員權限 (也適用 SMB/WinRM 等遠端登入；移除時還原原值)" } else { '' }
        $sshdLine = if ($os -eq 'ubuntu' -and $AllowFrom -notmatch '(^|,)\s*Any\s*(,|$)') { "`n  5. sshd 設定：不在允許來源的連線一律不接受密碼登入 (即使 ufw 沒啟用也有效)；移除時還原" } else { '' }
        $readme = @"
這個資料夾是由 pcx 產生，用來讓另一台電腦 (PC1) 透過 SSH 管理這台電腦。內容全部是明文，可直接用文字編輯器檢視。

會做的事:
  1. 安裝並啟動 OpenSSH Server
  2. 防火牆只允許指定來源連入 22 埠 (來源: $AllowFrom；Ubuntu 需 ufw 已啟用)
  3. 把 pcx.pub (PC1 的公鑰) 加入授權金鑰，並加上 from= (只接受來自上述來源的連線；LocalSubnet 代表私有網段) 與 restrict (關閉轉發)；$pwLine$sudoLine$sshdLine
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
        Set-Content -LiteralPath $Out $content -Encoding utf8BOM   # Windows PowerShell 5.1 需要 BOM
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

    if ($target -match '^(.+)@(.+)$') { $user = $Matches[1]; $hostName = $Matches[2] } else { $user = $null; $hostName = $target }

    # 防呆：同一台 (位址 + 埠 + 帳號 + 跳板機) 已經用別的名稱註冊過，就不再多建一個名稱
    $newT = New-HostTarget $hostName $user $Port $Jump
    $dup = @(Find-SameHost $newT $name -SameUser)
    if ($dup.Count -and -not $Force) {
        Write-ErrorRequest 'DUPLICATE_HOST' "$(Format-Target $newT) 已經註冊為 $($dup -join ', ')，不需要再用 $name 註冊一次。同一台電腦有兩個名稱時，對其中一個執行 pcx teardown 會移除整台的遠端存取，另一個名稱也會跟著失效。" "請直接使用 pcx $($dup[0]) `"<指令>`"。想改名請先 pcx forget $($dup[0])，再 pcx add $name $target；確定要兩個名稱並存才加 -Force。"
        exit 1
    }
    $same = @(Find-SameHost $newT $name)
    if ($same.Count) {
        Write-Host "提醒: $($same -join ', ') 也指向同一台主機 ($($newT.host))。對其中任何一個執行 pcx teardown，都會移除這台主機的遠端存取，其他名稱也會失效。" -ForegroundColor Yellow
    }

    if ($Key) { $idFile = (Resolve-Path $Key).Path } else { Ensure-Key; $idFile = $DefaultKey }

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
            Write-ErrorRequest 'NO_ADMIN' "$name 上這個帳號沒有管理員(已提升)權限，改設定、裝服務、pcx harden/teardown 會失敗。SSH 無法跳出 UAC 提示。" '若需要管理員操作：(1) 若這個帳號是 PC2 的管理員，請用最新版 pcx invite 產生的安裝資料夾在 PC2 重新執行 INSTALL.cmd (會設定 LocalAccountTokenFilterPolicy)，再重新 pcx add；(2) 否則改用 PC2 上的管理員帳號重新註冊 (pcx add <名稱> <管理員帳號>@<IP>)。'
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
  if sudo -n true 2>/dev/null; then S="sudo -n"; else echo "[errorRequest:HARDEN_NO_SUDO]"; echo "  問題: 這個帳號沒有免密碼 sudo，無法修改 sshd 設定。"; echo "  需要: 請在 PC2 本機執行: printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/00-pcx.conf && sudo systemctl reload ssh"; exit 3; fi
fi
# 檔名用 00- 開頭：sshd 對同一設定採用「最先讀到的值」，用 99- 會被 50-cloud-init.conf 等檔案的 PasswordAuthentication yes 蓋過
D=/etc/ssh/sshd_config.d
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | $S tee "$D/00-pcx.conf" >/dev/null
if ! $S /usr/sbin/sshd -t; then
  $S rm -f "$D/00-pcx.conf"
  echo "[errorRequest:HARDEN_FAILED]"; echo "  問題: 寫入 00-pcx.conf 後 sshd 設定檢查失敗 (見上方訊息)，已還原，密碼登入未變動。"; echo "  需要: 請在 PC2 本機執行 sudo sshd -t 查看設定錯誤。"; exit 4
fi
$S rm -f "$D/99-remote.conf"   # 舊版 pcx 的檔名
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
# 密碼與 keyboard-interactive 都關掉 (設定行不存在時插在第一個 Match 之前，確保是全域設定)；經 -Command - 由 stdin 執行，每個敘述須寫在同一行
$cfgLines = @(Get-Content $cfg)
foreach ($kv in @(@('PasswordAuthentication', 'PasswordAuthentication'), @('KbdInteractiveAuthentication', '(KbdInteractiveAuthentication|ChallengeResponseAuthentication)'))) { $out = New-Object System.Collections.Generic.List[string]; $hit = $false; foreach ($l in $cfgLines) { if ($l -match ('^\s*#?\s*' + $kv[1] + '\s')) { $out.Add($kv[0] + ' no'); $hit = $true } else { $out.Add($l) } }; if (-not $hit) { $o2 = New-Object System.Collections.Generic.List[string]; $done = $false; foreach ($l in $out) { if (-not $done -and $l -match '^\s*Match\s') { $o2.Add($kv[0] + ' no'); $done = $true }; $o2.Add($l) }; if (-not $done) { $o2.Add($kv[0] + ' no') }; $out = $o2 }; $cfgLines = $out.ToArray() }
$cfgLines | Set-Content $cfg -Encoding ascii
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
    if ($post.Out -notmatch 'pcx-ok') {
        Write-ErrorRequest 'HARDEN_VERIFY_FAILED' "已送出設定，但重新連線 $name 失敗 (sshd 可能仍在重啟，或設定有誤)。" "請稍後執行 pcx status $name 確認；若持續連不上，需要到 $name 本機移除 /etc/ssh/sshd_config.d/00-pcx.conf (Ubuntu)，或用 sshd_config.pcx-bak 還原 sshd_config (Windows)，並重啟 SSH 服務。"
        exit 1
    }
    # 確認密碼登入「真的」關了：以不帶金鑰的方式連線，讀伺服器回報的可用認證方式
    $methods = Get-OfferedAuth $name
    $h = Get-Hosts
    if ($null -eq $methods) {
        Write-ErrorRequest 'HARDEN_VERIFY_FAILED' "金鑰登入正常，但無法確認 $name 是否仍提供密碼登入 (讀不到伺服器回報的認證方式)。" "請在 PC1 執行 ssh -o PubkeyAuthentication=no -o BatchMode=yes $name exit，看最後一行 Permission denied (...) 括號內是否還有 password；有的話請到 $name 本機檢查 sshd 設定。"
        exit 1
    }
    if ($methods -match 'password|keyboard-interactive') {
        if ($h.ContainsKey($name)) { $h[$name].hardened = $false; Save-Hosts $h }
        Write-ErrorRequest 'HARDEN_NOT_EFFECTIVE' "$name 的設定已寫入，但伺服器仍提供: $methods (密碼登入沒有關掉；可能有其他設定檔或 Match 區塊覆蓋)。" "請到 $name 本機執行 sudo sshd -T | grep -i passwordauthentication (Windows 看 C:\ProgramData\ssh\sshd_config)，找出仍開啟密碼登入的設定後再重試 pcx harden。"
        exit 1
    }
    if ($h.ContainsKey($name)) { $h[$name].hardened = $true; Save-Hosts $h }
    "完成：$name 只接受金鑰登入 (伺服器提供的認證方式: $methods)，並確認金鑰登入仍可使用。"
}

'list' {
    $h = Get-Hosts
    if ($h.Count -eq 0) { '(尚未註冊任何電腦。用 pcx add <名稱> <user@主機>)'; break }
    $tg = Get-HostTargets
    $h.GetEnumerator() | Sort-Object Key | ForEach-Object {
        $t = $tg[$_.Key]
        $line = '{0,-16} {1,-8} {2,-28} admin/sudo: {3}' -f $_.Key, $_.Value.os, $(if ($t) { Format-Target $t } else { '(ssh 設定中找不到)' }), $(if ($_.Value.admin) { '有' } elseif ($null -eq $_.Value.admin) { '未檢查' } else { '沒有' })
        $same = @(Find-SameHost $t $_.Key)
        if ($same.Count) { $line += "   [與 $($same -join ', ') 同一台主機]" }
        $line
    }
}

{ $_ -in 'forget', 'remove' } {
    # 只刪 PC1 本機的註冊紀錄 (hosts.json、~/.ssh/config 區塊、known_hosts)，不連到 PC2、不改 PC2 任何設定
    if (-not $A) { throw '用法: pcx forget <名稱>' }
    $h = Get-Hosts; $tg = Get-HostTargets
    if (-not $h.ContainsKey($A) -and -not $tg.ContainsKey($A)) {
        Write-ErrorRequest 'HOST_NOT_REGISTERED' "找不到已註冊的電腦 '$A'。" 'pcx list 可看已註冊的電腦。'
        exit 1
    }
    $same = @(Find-SameHost $tg[$A] $A)
    if (-not $same.Count) { Forget-KnownHost $A }   # 還有別的名稱指向同一台時，保留主機金鑰紀錄
    Remove-ConfigBlock $A
    $h.Remove($A); Save-Hosts $h
    "已取消 $A 的本機註冊 (沒有連到 PC2；私鑰保留)。"
    if ($same.Count) { "這台主機仍可用 $($same -join ', ') 操作。" }
    else { '注意: PC2 上的遠端存取 (金鑰、防火牆、SSH) 仍保留。若不再使用，請到 PC2 執行 REMOVE.cmd / remove.sh，或重新 pcx add 後再 pcx teardown。' }
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
    if (-not $Yes) { if (-not (Confirm-Yes '確定? (y/N)')) { '已取消。'; exit 0 } }
    foreach ($n in $drop) { Forget-KnownHost $n; Remove-ConfigBlock $n; $h.Remove($n) }
    Save-Hosts $h
    "已清理 $($drop.Count) 台，剩餘 $($h.Count) 台。"
}

'teardown' {
    if (-not $A) { throw '用法: pcx teardown <名稱> [-UninstallServer] [-Yes]' }
    [void](Assert-Host $A)
    $t = (Get-HostTargets)[$A]
    $others = @(Find-SameHost $t $A)
    if ($others.Count) {
        Write-Host "注意: $($others -join ', ') 也指向同一台主機 ($($t.host))。teardown 會移除這台主機上 pcx 的金鑰、防火牆規則與 SSH 設定，移除後 $($others -join ', ') 也會失效，並會一併取消註冊。" -ForegroundColor Yellow
        Write-Host "若只是要刪掉多出來的名稱，請改用 pcx forget <名稱> (不連到 PC2)。"
        if (-not $Yes) { if (-not (Confirm-Yes '確定要繼續 teardown? (y/N)')) { '已取消。'; exit 0 } }
    }
    if (Invoke-Teardown $A) {
        $gone = @($A) + $others
        foreach ($n in $gone) { Forget-KnownHost $n; Remove-ConfigBlock $n }
        $h = Get-Hosts; foreach ($n in $gone) { $h.Remove($n) }; Save-Hosts $h
        "已移除 $A 的遠端存取並取消註冊。"
        if ($others.Count) { "同一台主機的 $($others -join ', ') 也已取消註冊。" }
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
        if (-not (Confirm-Yes '確定要執行? (y/N)')) { '已取消。'; exit 0 }
    }
    $failed = @()
    if ($All) {
        Assert-Ssh
        $tg = Get-HostTargets; $seen = @{}
        foreach ($n in $names) {
            # 同一台主機只 teardown 一次 (第二次會因為遠端存取已移除而失敗)
            $t = $tg[$n]; $k = if ($t -and $t.host) { "$($t.host)|$($t.port)|$($t.jump)" } else { "name:$n" }
            if ($seen.ContainsKey($k)) { Write-Host "$n 與 $($seen[$k]) 是同一台主機，已一併處理。"; continue }
            $seen[$k] = $n
            if (-not (Invoke-Teardown $n)) { $failed += $n }
        }
    }
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
