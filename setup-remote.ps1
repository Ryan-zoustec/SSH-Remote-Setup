#Requires -RunAsAdministrator
<#
  在「被管理的 Windows 電腦」上執行：啟用 OpenSSH Server，只允許金鑰登入，並限制連入來源。
  會把「動手前的狀態」記錄到 %ProgramData%\ssh\pcx-state.json，remove-remote.ps1 依此完整還原。
    .\setup-remote.ps1 -PublicKey "ssh-ed25519 AAAA... pcx"
    .\setup-remote.ps1 -PublicKey .\id.pub -AllowFrom 192.168.1.0/24,100.64.0.0/10 -DisablePasswordLogin
  -AllowFrom: LocalSubnet (預設) | 網段/IP，可用逗號分隔 | Any
#>
param(
    [Parameter(Mandatory)][string]$PublicKey,   # 公鑰內容，或 .pub 檔路徑
    [string]$AllowFrom = 'LocalSubnet',
    [switch]$DisablePasswordLogin
)
$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $PublicKey) { $PublicKey = (Get-Content -LiteralPath $PublicKey -Raw).Trim() }
if ($PublicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) \S+') {
    throw '公鑰格式不正確，請提供 ssh-ed25519 / ssh-rsa / ecdsa 開頭的整行內容 (.pub 檔)。'
}
$addr = @($AllowFrom -split '\s*,\s*' | Where-Object { $_ })
foreach ($a in $addr) {
    if ($a -notin 'LocalSubnet', 'Any' -and $a -notmatch '^[0-9A-Fa-f:.]+(/\d{1,3})?$') {
        Write-Host '[errorRequest:INVALID_ALLOW_FROM]' -ForegroundColor Red
        Write-Host "  問題: 來源限制格式不正確: $a"
        Write-Host '  需要: 請用 LocalSubnet、Any，或 IP / CIDR 網段 (例如 192.168.1.0/24)，多個以逗號分隔。'
        exit 1
    }
}
# 金鑰的 from= 來源清單：LocalSubnet => 私有網段 (網路變動也不會被鎖在外面)；含 Any => 不限制
$privateNets = '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '127.0.0.0/8', 'fc00::/7', 'fe80::/10', '::1/128'
$srcNets = @()
if ($addr -notcontains 'Any') {
    foreach ($a in $addr) { if ($a -eq 'LocalSubnet') { $srcNets += $privateNets } else { $srcNets += $a } }
}
if ($addr -contains 'Any') { Write-Warning 'AllowFrom=Any：任何來源都連得到 22 埠。請確認雲端安全群組已限制來源，或改用 VPN。' }

$sshDir    = Join-Path $env:ProgramData 'ssh'
$stateFile = Join-Path $sshDir 'pcx-state.json'
$ruleName  = 'OpenSSH-Server-In-TCP'

# 無法自行解決時，輸出固定格式的 errorRequest，請使用者處理
function Stop-WithErrorRequest([string]$code, [string]$problem, [string]$need) {
    Write-Host "[errorRequest:$code]" -ForegroundColor Red
    Write-Host "  問題: $problem"
    Write-Host "  需要: $need"
    exit 1
}

# 1. 安裝並啟動 OpenSSH Server (先記下原本狀態)
try { $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1 }
catch { Stop-WithErrorRequest 'WINDOWS_CAPABILITY_QUERY_FAILED' "無法查詢 Windows 選用功能: $($_.Exception.Message)" '請確認 Windows Update 服務未被停用，並以系統管理員身分執行；重開機後再試。' }
if (-not $cap) { Stop-WithErrorRequest 'OPENSSH_NOT_AVAILABLE' '這個 Windows 版本找不到 OpenSSH Server 選用功能 (需要 Windows 10 1809 / Server 2019 以上)。' '請升級 Windows，或手動安裝 Win32-OpenSSH 後再重新執行本安裝。' }
$installedBefore = ($cap.State -eq 'Installed')
$svcBefore  = Get-Service sshd -ErrorAction SilentlyContinue
$wasRunning = [bool]($svcBefore -and $svcBefore.Status -eq 'Running')
if (-not $installedBefore) {
    Write-Host '安裝 OpenSSH Server ...'
    try { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
    catch { Stop-WithErrorRequest 'OPENSSH_INSTALL_FAILED' "安裝 OpenSSH Server 失敗: $($_.Exception.Message)" '這個功能需要連上 Windows Update。請確認這台電腦能上網、沒有被公司 WSUS/群組原則擋住，稍後重試；離線環境請手動安裝 Win32-OpenSSH。' }
}
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

$state = $null
if (Test-Path $stateFile) { $state = Get-Content $stateFile -Raw | ConvertFrom-Json }
if (-not $state) {
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    $prevAddr = $null; $prevEnabled = $null
    if ($rule) {
        $prevAddr = @((Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule).RemoteAddress)
        $prevEnabled = [string]$rule.Enabled
    }
    $shellProp = Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue
    $state = [pscustomobject]@{
        installedServer   = (-not $installedBefore)
        wasRunning        = $wasRunning
        firewallExisted   = [bool]$rule
        prevRemoteAddress = $prevAddr
        prevEnabled       = $prevEnabled
        prevDefaultShell  = $(if ($shellProp) { $shellProp.DefaultShell } else { $null })
        setDefaultShell   = $false
        passwordDisabled  = $false
    }
}

try {
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
} catch { Stop-WithErrorRequest 'SSHD_START_FAILED' "sshd 服務無法啟動: $($_.Exception.Message)" '請檢查 22 埠是否被其他程式佔用，或到事件檢視器 > OpenSSH 記錄查看原因。' }

# 2. 防火牆：只允許指定來源連入 22 埠
if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name $ruleName -Enabled True -RemoteAddress $addr
} else {
    New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (pcx)' -Enabled True `
        -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -RemoteAddress $addr | Out-Null
}

# 3. 寫入公鑰 (系統管理員群組使用 administrators_authorized_keys)
#    加上 from= (只接受來自允許來源的連線，私鑰外流也無法從別處使用) 與 restrict (關閉轉發/agent/X11/pty)
$keyFile = Join-Path $sshDir 'administrators_authorized_keys'
if (-not (Test-Path $keyFile)) { New-Item -ItemType File -Path $keyFile -Force | Out-Null }
$keyBody = ($PublicKey -split '\s+')[1]
$opts = if ($srcNets.Count) { 'from="' + ($srcNets -join ',') + '",restrict' } else { 'restrict' }
# 同一把金鑰已存在 (舊版沒有選項，或來源不同) 時先移除舊行再寫入
$keep = @(Get-Content $keyFile | Where-Object { $_ -and -not $_.Contains($keyBody) })
Set-Content -Path $keyFile -Value ($keep + "$opts $PublicKey") -Encoding ascii
icacls $keyFile /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

# 4. 預設 shell：有 PowerShell 7 就用它，否則用 Windows PowerShell (否則 SSH 預設會是 cmd.exe)
$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$winps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shell = if (Test-Path $pwsh) { $pwsh } else { $winps }
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $shell -PropertyType String -Force | Out-Null
$state.setDefaultShell = $true

# 4b. 本機管理員帳號：讓 SSH 登入拿到完整 (已提升) 的管理員權限
#     Windows 預設會把「本機帳號的遠端登入」降成一般權限 (UAC 遠端限制)，設 LocalAccountTokenFilterPolicy=1 解除。
#     安全影響：此電腦所有本機管理員帳號的遠端登入 (SSH、SMB、WinRM 等) 都會是完整管理員權限。原值記入狀態檔，移除時還原。
$polPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
if ($env:USERDOMAIN -eq $env:COMPUTERNAME) {
    if (-not ($state.PSObject.Properties.Name -contains 'tokenFilterSet') -or -not $state.tokenFilterSet) {
        $prop = Get-ItemProperty -Path $polPath -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
        $prev = if ($prop) { [int]$prop.LocalAccountTokenFilterPolicy } else { $null }
        $state | Add-Member -Force -NotePropertyName prevTokenFilter -NotePropertyValue $prev
        $state | Add-Member -Force -NotePropertyName tokenFilterSet  -NotePropertyValue $true
    }
    New-ItemProperty -Path $polPath -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host '已設定 LocalAccountTokenFilterPolicy=1：本機管理員帳號經 SSH 登入時具有完整管理員權限 (移除時會還原)。'
    Write-Host '  注意：這也適用於其他遠端登入方式 (SMB/WinRM)，請確保本機管理員帳號都有強密碼。' -ForegroundColor Yellow
}

# 5. 可選：關閉密碼登入
if ($DisablePasswordLogin) {
    $cfg = Join-Path $sshDir 'sshd_config'
    $cfgLines = @(Get-Content $cfg)
    foreach ($kv in @(@('PasswordAuthentication', 'PasswordAuthentication'), @('KbdInteractiveAuthentication', '(KbdInteractiveAuthentication|ChallengeResponseAuthentication)'))) {
        $out = New-Object System.Collections.Generic.List[string]; $hit = $false
        foreach ($l in $cfgLines) { if ($l -match ('^\s*#?\s*' + $kv[1] + '\s')) { $out.Add($kv[0] + ' no'); $hit = $true } else { $out.Add($l) } }
        if (-not $hit) {
            $o2 = New-Object System.Collections.Generic.List[string]; $done = $false
            foreach ($l in $out) { if (-not $done -and $l -match '^\s*Match\s') { $o2.Add($kv[0] + ' no'); $done = $true }; $o2.Add($l) }
            if (-not $done) { $o2.Add($kv[0] + ' no') }
            $out = $o2
        }
        $cfgLines = $out.ToArray()
    }
    $cfgLines | Set-Content $cfg -Encoding ascii
    $state.passwordDisabled = $true
    Restart-Service sshd
}

$state | ConvertTo-Json | Set-Content $stateFile -Encoding utf8

$sshd = Join-Path $env:windir 'System32\OpenSSH\sshd.exe'
if (Test-Path $sshd) { Write-Host "OpenSSH Server 版本: $((Get-Item $sshd).VersionInfo.ProductVersion) (由 Windows Update 維護，請定期更新 Windows)" }

$all = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^127\.' } | Select-Object -ExpandProperty IPAddress)
if ($all.Count -eq 0) {
    Stop-WithErrorRequest 'NO_IP_ADDRESS' 'SSH 已安裝，但這台電腦目前沒有任何 IPv4 位址 (沒接網路?)。' '請接上網路或用網線直連 PC1，並替兩台設定同網段的固定 IP (例如 192.168.50.1 / 192.168.50.2)，再重新執行本安裝或自行查 IP。'
}
Write-Host "`n完成。從 PC1 註冊：" -ForegroundColor Green
$all | ForEach-Object {
    $note = if ($_ -like '169.254.*') { '   (自動配置位址：網線直連且沒設固定 IP 時才會出現，建議改設固定 IP)' } else { '' }
    Write-Host "  pcx add pc2 $env:USERNAME@$_$note"
}
Write-Host "`n提醒：此帳號 ($env:USERNAME) 必須是這台電腦的管理員，金鑰才會生效；SSH 無法跳出 UAC，一般帳號不能提升權限。"
