#Requires -Version 7
<#
  重複主機註冊防呆的隔離測試 (不連到任何電腦、不碰真正的 ~/.ssh 與 ~\.pcx)。
  執行: pwsh -NoProfile -File tests\duplicate-host.tests.ps1
  名稱用 tst-* 、位址用 192.0.2.x (RFC 5737 測試網段)，避免 ssh -G / ssh-keygen -R 動到真正 known_hosts 裡的紀錄。
  做法: 把 HOME / USERPROFILE 指到暫存資料夾，直接寫入假的 hosts.json 與 ~/.ssh/config 區塊，
        再以子行程執行 pcx.ps1，只測「不需要連線」就會結束的路徑。
#>
$ErrorActionPreference = 'Stop'
$pcx = Join-Path $PSScriptRoot '..' 'pcx.ps1' | Resolve-Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("pcx-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0

function Reset-Env {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force (Join-Path $tmp '.pcx'), (Join-Path $tmp '.ssh') | Out-Null
    $cfg = @"
# >>> pcx tst-a >>>
Host tst-a
    HostName 192.0.2.43
    User Admin
    Port 22
    IdentityFile "x"
# <<< pcx tst-a <<<
# >>> pcx tst-b >>>
Host tst-b
    HostName 192.0.2.43
    User guest
    Port 22
    IdentityFile "x"
# <<< pcx tst-b <<<
# >>> pcx tst-vm >>>
Host tst-vm
    HostName 192.0.2.5
    User ubuntu
    Port 2222
    IdentityFile "x"
# <<< pcx tst-vm <<<
"@
    Set-Content (Join-Path $tmp '.ssh/config') $cfg -Encoding utf8NoBOM
    '{"tst-a":{"os":"windows","admin":true},"tst-b":{"os":"windows","admin":false},"tst-vm":{"os":"linux","admin":true}}' |
        Set-Content (Join-Path $tmp '.pcx/hosts.json') -Encoding utf8NoBOM
}
function Invoke-Pcx([string[]]$argv) {
    $old = $env:HOME, $env:USERPROFILE
    $env:HOME = $tmp; $env:USERPROFILE = $tmp
    try { $out = (@() | & pwsh -NoProfile -File $pcx @argv 2>&1 | ForEach-Object { "$_" }) -join "`n"; $code = $LASTEXITCODE }
    finally { $env:HOME, $env:USERPROFILE = $old }
    [pscustomobject]@{ Code = $code; Out = $out }
}
function Check([string]$title, [bool]$ok, $r) {
    if ($ok) { Write-Host "[PASS] $title" -ForegroundColor Green }
    else { Write-Host "[FAIL] $title`n$($r.Out)`n(exit $($r.Code))" -ForegroundColor Red; $script:fail++ }
}
function Get-Registered { (Get-Content (Join-Path $tmp '.pcx/hosts.json') -Raw | ConvertFrom-Json -AsHashtable).Keys }

try {
    # 語法
    $errs = $null; [void][Management.Automation.Language.Parser]::ParseFile($pcx, [ref]$null, [ref]$errs)
    Check 'pcx.ps1 語法 0 錯誤' ($errs.Count -eq 0) ([pscustomobject]@{ Out = ($errs -join "`n"); Code = '' })

    Reset-Env
    $r = Invoke-Pcx @('add', 'tst-c', 'admin@192.0.2.43')
    Check 'add: 同主機同帳號 (大小寫不同) 換名稱 → DUPLICATE_HOST 並指出 tst-a' ($r.Code -eq 1 -and $r.Out -match 'errorRequest:DUPLICATE_HOST' -and $r.Out -match 'tst-a') $r
    Check 'add: 被拒時不會寫入 ssh 設定' (-not ((Get-Content (Join-Path $tmp '.ssh/config') -Raw) -match 'pcx tst-c')) $r

    $r = Invoke-Pcx @('add', 'tst-vm2', 'ubuntu@192.0.2.5', '-Port', '2222')
    Check 'add: 非 22 埠也能比對' ($r.Code -eq 1 -and $r.Out -match 'DUPLICATE_HOST' -and $r.Out -match 'tst-vm') $r

    $r = Invoke-Pcx @('list')
    Check 'list: 顯示連線目標並標出同一台主機' ($r.Out -match 'Admin@192\.0\.2\.43' -and $r.Out -match '與 tst-b 同一台主機' -and $r.Out -match 'ubuntu@192\.0\.2\.5:2222') $r

    $r = Invoke-Pcx @('teardown', 'tst-a')
    Check 'teardown: 有其他名稱指向同一台時警告，未確認就取消 (不連線)' ($r.Code -eq 0 -and $r.Out -match 'tst-b' -and $r.Out -match '也會失效' -and $r.Out -match '已取消') $r
    Check 'teardown: 取消後註冊不變' ((Get-Registered).Count -eq 3) $r

    $r = Invoke-Pcx @('forget', 'tst-b')
    Check 'forget: 只刪本機紀錄並提示仍可用 tst-a' ($r.Code -eq 0 -and $r.Out -match '仍可用 tst-a') $r
    Check 'forget: hosts.json 與 ssh 設定都移除' (-not ((Get-Registered) -contains 'tst-b') -and -not ((Get-Content (Join-Path $tmp '.ssh/config') -Raw) -match 'pcx tst-b')) $r
    Check 'forget: 其他名稱的設定保留' (((Get-Registered) -contains 'tst-a') -and ((Get-Content (Join-Path $tmp '.ssh/config') -Raw) -match 'pcx tst-a')) $r

    $r = Invoke-Pcx @('forget', 'tst-vm')
    Check 'forget: 最後一個名稱時提醒 PC2 遠端存取仍保留' ($r.Code -eq 0 -and $r.Out -match 'REMOVE\.cmd') $r

    $r = Invoke-Pcx @('remove', 'tst-a')
    Check 'remove: 舊名稱仍可用' ($r.Code -eq 0 -and -not ((Get-Registered) -contains 'tst-a')) $r

    $r = Invoke-Pcx @('forget', 'nobody')
    Check 'forget: 未註冊的名稱 → HOST_NOT_REGISTERED' ($r.Code -eq 1 -and $r.Out -match 'HOST_NOT_REGISTERED') $r
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($fail) { Write-Host "`n$fail 項失敗" -ForegroundColor Red; exit 1 }
Write-Host "`n全部通過" -ForegroundColor Green
