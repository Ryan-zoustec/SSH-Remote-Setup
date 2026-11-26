#Requires -RunAsAdministrator
<#
  一鍵還原 setup-remote.ps1 的所有變更 (依 pcx-state.json 回到安裝前的狀態)：
  移除 pcx 金鑰、還原防火牆與密碼登入設定、還原預設 shell，
  若 OpenSSH 是 pcx 裝的 (或原本沒在執行) 就停用；加 -UninstallServer 連 OpenSSH Server 一併移除。
    .\remove-remote.ps1
    .\remove-remote.ps1 -UninstallServer
  -Delayed: 先等 3 秒再執行並刪除自己 (給 pcx teardown 從遠端觸發用)
#>
param([switch]$UninstallServer, [switch]$Delayed)
$ErrorActionPreference = 'Continue'
if ($Delayed) { Start-Sleep -Seconds 3 }

$sshDir    = Join-Path $env:ProgramData 'ssh'
$stateFile = Join-Path $sshDir 'pcx-state.json'
$ruleName  = 'OpenSSH-Server-In-TCP'
$state = $null
if (Test-Path $stateFile) { $state = Get-Content $stateFile -Raw | ConvertFrom-Json }

# 1. 移除 pcx 金鑰 (只刪註解為 pcx 的那一行，其他金鑰保留)
$keyFile = Join-Path $sshDir 'administrators_authorized_keys'
if (Test-Path $keyFile) {
    $keep = @(Get-Content $keyFile | Where-Object { $_ -and $_ -notmatch '\spcx\s*$' })
    if ($keep.Count -eq 0) { Remove-Item $keyFile -Force } else { Set-Content $keyFile $keep -Encoding ascii }
}

if (-not $state) {
    Write-Host '找不到 pcx 的安裝紀錄：只移除了 pcx 金鑰，其餘設定未變動。'
} else {
    # 2. 還原密碼登入設定
    if ($state.passwordDisabled) {
        $cfg = Join-Path $sshDir 'sshd_config'
        (Get-Content $cfg) -replace '^PasswordAuthentication\s+no\s*$', '#PasswordAuthentication yes' -replace '^KbdInteractiveAuthentication\s+no\s*$', '#KbdInteractiveAuthentication yes' | Set-Content $cfg -Encoding ascii
    }
    # 3. 還原預設 shell
    if ($state.setDefaultShell) {
        if ($state.prevDefaultShell) {
            New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $state.prevDefaultShell -PropertyType String -Force | Out-Null
        } else {
            Remove-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue
        }
    }
    # 3b. 還原 LocalAccountTokenFilterPolicy (安裝前沒有這個值就刪除)
    if ($state.tokenFilterSet) {
        $polPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        if ($null -ne $state.prevTokenFilter) {
            New-ItemProperty -Path $polPath -Name LocalAccountTokenFilterPolicy -Value ([int]$state.prevTokenFilter) -PropertyType DWord -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $polPath -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
        }
    }
    # 4. 還原防火牆
    if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
        if ($state.firewallExisted) {
            Set-NetFirewallRule -Name $ruleName -RemoteAddress @($state.prevRemoteAddress) -Enabled $state.prevEnabled
        } else {
            Remove-NetFirewallRule -Name $ruleName
        }
    }
    # 5. 服務：pcx 裝的、或原本沒在執行 => 停用；否則維持執行並套用還原後的設定
    if (Get-Service sshd -ErrorAction SilentlyContinue) {
        if ($state.installedServer -or -not $state.wasRunning) {
            Stop-Service sshd -Force
            Set-Service sshd -StartupType Disabled
        } else {
            Restart-Service sshd
        }
    }
    if ($UninstallServer -and $state.installedServer) {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
        if ($cap.State -eq 'Installed') { Remove-WindowsCapability -Online -Name $cap.Name | Out-Null }
    }
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    Write-Host '已還原：金鑰、防火牆、SSH 設定、管理員遠端權限原則與服務都回到安裝前的狀態。'
}

if ($Delayed) {
    if ($PSCommandPath) { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName 'pcx-remove' -Confirm:$false -ErrorAction SilentlyContinue
}
