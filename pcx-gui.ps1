#Requires -Version 7
<#
  pcx 視窗精靈 (WinForms)。由 pcx.ps1 的「pcx gui」以 dot-source 載入，沿用 pcx.ps1 的函式與設定；請勿直接執行。
  啟動方式：雙擊 WIZARD.cmd，或執行 pcx gui。文字版精靈仍可用：WIZARD-TEXT.cmd 或 pcx wizard。

  守則與文字版精靈 (pcx wizard) 相同：
  - 不詢問、不儲存任何密碼；不碰私鑰內容。PC2 的安裝由使用者自己在 PC2 做。
  - 每一步都用子行程執行 pcx <功能> (子行程 stdin 為空，不會等輸入)，沿用 pcx 原本的檢查與 errorRequest。
  - 會改變 PC2 的動作 (harden / teardown) 先確認；teardown 要輸入電腦名稱確認；同一台主機的重複註冊會提示。
  - 子行程以計時器輪詢輸出，視窗執行中不會凍結；可按「停止」中止。
#>
if (-not (Get-Command Get-HostTargets -ErrorAction SilentlyContinue) -or -not $PcxSelf) {
    Write-Host '請用 pcx gui 或雙擊 WIZARD.cmd 開啟視窗精靈。'
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
try { [void][Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::SystemAware) } catch { }
[Windows.Forms.Application]::EnableVisualStyles()

$GuiFont     = [Drawing.Font]::new('Microsoft JhengHei UI', 10)
$GuiFontBold = [Drawing.Font]::new('Microsoft JhengHei UI', 10, [Drawing.FontStyle]::Bold)
$GuiFontLog  = [Drawing.Font]::new('Consolas', 10)
$script:GuiJob = $null       # 執行中的子行程
$script:GuiStatus = @{}      # 名稱 -> 最近一次 pcx status 的結果文字
$script:GuiUI = @{}          # 主視窗的控制項

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
function Show-GuiMsg([string]$text, [string]$title = 'pcx', [string]$icon = 'Information') {
    [void][Windows.Forms.MessageBox]::Show($script:GuiUI.Form, $text, $title, 'OK', $icon)
}
# 是/否 詢問；$defaultYes 決定按 Enter 時的預設按鈕
function Ask-GuiYesNo([string]$text, [bool]$defaultYes = $true, [string]$icon = 'Question') {
    $def = if ($defaultYes) { 'Button1' } else { 'Button2' }
    return [Windows.Forms.MessageBox]::Show($script:GuiUI.Form, $text, 'pcx', 'YesNo', $icon, $def) -eq 'Yes'
}
function Add-GuiLog([string]$line) {
    $tb = $script:GuiUI.Log
    if (-not $tb) { return }
    $line = $line -replace "\x1b\[[0-9;?]*[ -/]*[@-~]", ''   # 去掉 ANSI 色碼
    $tb.AppendText($line + "`r`n")
}
function New-GuiButton([string]$text, [int]$w = 200, [int]$h = 34) {
    $b = [Windows.Forms.Button]::new()
    $b.Text = $text; $b.Width = $w; $b.Height = $h; $b.Font = $GuiFont
    $b.TextAlign = 'MiddleLeft'; $b.Margin = [Windows.Forms.Padding]::new(4, 3, 4, 3)
    return $b
}
function New-GuiLabel([string]$text, [switch]$Bold) {
    $l = [Windows.Forms.Label]::new()
    $l.Text = $text; $l.AutoSize = $true; $l.Font = $(if ($Bold) { $GuiFontBold } else { $GuiFont })
    $l.Margin = [Windows.Forms.Padding]::new(3, 8, 3, 3)
    return $l
}
function Get-GuiWorkDir {
    $d = $script:GuiUI.WorkDir.Text.Trim()
    if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { return $null }
    return (Resolve-Path -LiteralPath $d).Path
}

# ---------------------------------------------------------------------------
# 以子行程執行 pcx <argv>，完成後呼叫 $OnDone($code, $output, $Ctx)
# 不用 DataReceived 事件 (它在別的執行緒，PowerShell 腳本區塊不能在那裡跑)，改用 UI 執行緒上的計時器輪詢 ReadLineAsync
# ---------------------------------------------------------------------------
function Start-GuiStep([string[]]$argv, [scriptblock]$OnDone, $Ctx) {
    if ($script:GuiJob) { Show-GuiMsg '還有一個步驟正在執行，請等它結束。'; return }
    $wd = Get-GuiWorkDir
    if (-not $wd) { Show-GuiMsg '上方「工作資料夾」不存在，請重新選擇。' 'pcx' 'Warning'; return }
    $shown = ($argv | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    Add-GuiLog ''
    Add-GuiLog "> pcx $shown"

    $psi = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)   # 目前的 pwsh.exe
    foreach ($x in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PcxSelf) + $argv) { $psi.ArgumentList.Add($x) }
    $psi.WorkingDirectory = $wd
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $psi.Environment['PCX_UTF8_OUT'] = '1'      # 讓子行程的 pcx.ps1 以 UTF-8 輸出
    try { $p = [Diagnostics.Process]::Start($psi) }
    catch { Add-GuiLog "無法啟動: $($_.Exception.Message)"; return }
    try { $p.StandardInput.Close() } catch { }   # stdin 為空：確認提示一律視為「否」，不會卡住

    $script:GuiJob = @{
        Proc = $p; Argv = $argv; OnDone = $OnDone; Ctx = $Ctx
        Buf = [Text.StringBuilder]::new()
        OutTask = $p.StandardOutput.ReadLineAsync(); ErrTask = $p.StandardError.ReadLineAsync()
    }
    Set-GuiBusy $true "執行中: pcx $shown"
}
function Update-GuiStep {
    $j = $script:GuiJob
    if (-not $j) { return }
    foreach ($k in 'OutTask', 'ErrTask') {
        while ($j[$k] -and $j[$k].IsCompleted) {
            $line = if ($j[$k].IsFaulted) { $null } else { $j[$k].Result }
            if ($null -eq $line) { $j[$k] = $null; break }
            Add-GuiLog $line
            [void]$j.Buf.AppendLine($line)
            $reader = if ($k -eq 'OutTask') { $j.Proc.StandardOutput } else { $j.Proc.StandardError }
            $j[$k] = $reader.ReadLineAsync()
        }
    }
    if ($j.OutTask -or $j.ErrTask -or -not $j.Proc.HasExited) { return }
    $script:GuiJob = $null       # 先清掉，避免重入時重複收尾
    $j.Proc.WaitForExit()
    $code = $j.Proc.ExitCode
    $j.Proc.Dispose()
    Add-GuiLog "[結束碼 $code]"
    Set-GuiBusy $false
    Update-GuiHostList
    if ($j.OnDone) {
        try { & $j.OnDone $code $j.Buf.ToString() $j.Ctx }
        catch { Show-GuiMsg "精靈內部錯誤: $($_.Exception.Message)" 'pcx' 'Error' }
    }
}
function Stop-GuiStep {
    $j = $script:GuiJob
    if (-not $j) { return }
    $j.OnDone = $null            # 使用者中止：不接續後面的步驟
    try { $j.Proc.Kill($true) } catch { }
    Add-GuiLog '(已由使用者停止)'
}
# 失敗時說明；有 errorRequest 就把那一段顯示在對話框。回傳 $true 代表失敗
function Show-GuiStepFailure([int]$code, [string]$text) {
    if ($code -eq 0) { return $false }
    $m = [regex]::Match($text, '(?ms)^\[errorRequest:[^\]]+\].*?(?=^\s*\(AI 請停止|\z)')
    if ($m.Success) {
        Show-GuiMsg ("這一步需要你處理：`n`n" + $m.Value.Trim() + "`n`n處理完後再重新操作一次即可。") 'pcx - 需要你處理' 'Warning'
    } else {
        Show-GuiMsg "這一步失敗了 (結束碼 $code)，請看視窗下方的輸出。" 'pcx' 'Warning'
    }
    return $true
}

# ---------------------------------------------------------------------------
# 主視窗：已註冊電腦清單、狀態
# ---------------------------------------------------------------------------
function Get-GuiSelected {
    $lv = $script:GuiUI.List
    if ($lv.SelectedItems.Count -eq 0) { return $null }
    return $lv.SelectedItems[0].Name
}
function Update-GuiHostList {
    $lv = $script:GuiUI.List
    $keep = Get-GuiSelected
    $h = Get-Hosts; $tg = Get-HostTargets
    $lv.BeginUpdate()
    $lv.Items.Clear()
    foreach ($n in ($h.Keys | Sort-Object)) {
        $v = $h[$n]; $t = $tg[$n]
        $target = if ($t) { Format-Target $t } else { '(ssh 設定中找不到)' }
        $same = @(Find-SameHost $t $n)
        if ($same.Count) { $target += "  [與 $($same -join ', ') 同一台]" }
        $it = [Windows.Forms.ListViewItem]::new($n)
        $it.Name = $n
        [void]$it.SubItems.Add("$($v.os)")
        [void]$it.SubItems.Add($target)
        [void]$it.SubItems.Add($(if ($v.admin) { '有' } elseif ($null -eq $v.admin) { '未檢查' } else { '沒有' }))
        [void]$it.SubItems.Add($(if ($v.hardened) { '已關閉' } else { '未關閉' }))
        [void]$it.SubItems.Add($(if ($script:GuiStatus[$n]) { $script:GuiStatus[$n] } else { '(未檢查)' }))
        [void]$lv.Items.Add($it)
        if ($n -eq $keep) { $it.Selected = $true }
    }
    $lv.EndUpdate()
    $script:GuiUI.Empty.Visible = ($h.Count -eq 0)
    Update-GuiButtons
}
function Update-GuiButtons {
    $busy = [bool]$script:GuiJob
    $sel = [bool](Get-GuiSelected)
    $has = $script:GuiUI.List.Items.Count -gt 0
    $script:GuiUI.BtnNew.Enabled    = -not $busy
    $script:GuiUI.BtnStatus.Enabled = -not $busy -and $has
    $script:GuiUI.BtnGuide.Enabled  = -not $busy
    foreach ($b in 'BtnTest', 'BtnHarden', 'BtnTeardown', 'BtnForget') { $script:GuiUI[$b].Enabled = -not $busy -and $sel }
    $script:GuiUI.BtnStop.Enabled   = $busy
}
function Set-GuiBusy([bool]$busy, [string]$text = '') {
    $script:GuiUI.Status.Text = if ($busy) { $text } else { '就緒' }
    $script:GuiUI.Form.UseWaitCursor = $false
    Update-GuiButtons
}

# ---------------------------------------------------------------------------
# 一般動作
# ---------------------------------------------------------------------------
function Invoke-GuiStatus {
    Start-GuiStep @('status') {
        param($code, $text)
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '^(\S+)\s+\S*\s+(\d+) ms  (.+)$') { $script:GuiStatus[$Matches[1]] = $Matches[3].Trim() }
        }
        Update-GuiHostList
        if ($code -ne 0 -and $text -match '\[errorRequest:') { [void](Show-GuiStepFailure $code $text) }
    }
}
function Invoke-GuiTest {
    $n = Get-GuiSelected; if (-not $n) { return }
    Start-GuiStep @($n, 'hostname') { param($code, $text) [void](Show-GuiStepFailure $code $text) }
}
function Invoke-GuiHarden {
    $n = Get-GuiSelected; if (-not $n) { return }
    $info = (Get-Hosts)[$n]
    if ($info.hardened) { if (-not (Ask-GuiYesNo "$n 已經關閉過密碼登入。要再執行一次 harden 嗎?" $false)) { return } }
    elseif (-not $info.admin) {
        if (-not (Ask-GuiYesNo "$n 這個帳號沒有管理員/sudo 權限，harden 多半會失敗 (見 pcx help admin)。仍要嘗試嗎?" $false 'Warning')) { return }
    }
    if (-not (Ask-GuiYesNo "關閉 $n 的密碼登入，只留金鑰?`n`n會先確認金鑰可以登入才動手，結束後再驗證一次。")) { return }
    Start-GuiStep @('harden', $n) { param($code, $text) if (-not (Show-GuiStepFailure $code $text)) { Show-GuiMsg '已關閉密碼登入。' } }
}
function Invoke-GuiTeardown {
    $n = Get-GuiSelected; if (-not $n) { return }
    $others = @(Find-SameHost (Get-HostTargets)[$n] $n)
    $msg = "會移除 $n 上 pcx 的金鑰、防火牆規則與 SSH 設定 (依安裝前狀態還原)，並取消本機註冊。移除後就無法再從這台 PC1 連到 $n。"
    if ($others.Count) {
        $msg += "`n`n注意: $($others -join ', ') 也指向同一台主機，移除後 $($others -join ', ') 也會失效，並一併取消註冊。`n如果只是想刪掉多出來的名稱，請改用「只刪本機註冊 (forget)」。"
    }
    $typed = Read-GuiText 'pcx - 移除遠端存取 (teardown)' ($msg + "`n`n確定請輸入電腦名稱 $n ：") '' -Warning
    if ($null -eq $typed) { return }
    if ($typed -cne $n) { Show-GuiMsg '名稱不符，已取消。'; return }
    Start-GuiStep @('teardown', $n, '-Yes') { param($code, $text) if (-not (Show-GuiStepFailure $code $text)) { Show-GuiMsg '已移除遠端存取並取消註冊。' } }
}
function Invoke-GuiForget {
    $n = Get-GuiSelected; if (-not $n) { return }
    if (-not (Ask-GuiYesNo "只刪除 PC1 上 $n 的註冊紀錄?`n`n不會連到 PC2，PC2 的設定 (金鑰、防火牆、SSH) 不會改變。")) { return }
    Start-GuiStep @('forget', $n) { param($code, $text) [void](Show-GuiStepFailure $code $text) }
}

# 單行輸入對話框；取消回傳 $null
function Read-GuiText([string]$title, [string]$prompt, [string]$default = '', [switch]$Warning) {
    $f = [Windows.Forms.Form]::new()
    $f.Text = $title; $f.Font = $GuiFont; $f.AutoScaleMode = 'Dpi'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterParent'; $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $f.Padding = [Windows.Forms.Padding]::new(12)
    $t = [Windows.Forms.TableLayoutPanel]::new(); $t.AutoSize = $true; $t.AutoSizeMode = 'GrowAndShrink'; $t.ColumnCount = 1; $t.Location = [Drawing.Point]::new(12, 12)
    $l = New-GuiLabel $prompt; $l.MaximumSize = [Drawing.Size]::new(520, 0)
    if ($Warning) { $l.ForeColor = [Drawing.Color]::DarkRed }
    $tb = [Windows.Forms.TextBox]::new(); $tb.Width = 520; $tb.Text = $default
    $row = [Windows.Forms.FlowLayoutPanel]::new(); $row.AutoSize = $true; $row.FlowDirection = 'RightToLeft'; $row.Dock = 'Fill'
    $ok = [Windows.Forms.Button]::new(); $ok.Text = '確定'; $ok.DialogResult = 'OK'; $ok.AutoSize = $true
    $no = [Windows.Forms.Button]::new(); $no.Text = '取消'; $no.DialogResult = 'Cancel'; $no.AutoSize = $true
    $row.Controls.AddRange(@($no, $ok))
    $t.Controls.AddRange(@($l, $tb, $row))
    $f.Controls.Add($t); $f.AcceptButton = $ok; $f.CancelButton = $no
    $r = $f.ShowDialog($script:GuiUI.Form)
    $v = $tb.Text.Trim(); $f.Dispose()
    if ($r -ne 'OK') { return $null }
    return $v
}

# ---------------------------------------------------------------------------
# 新增一台 PC2 (完整流程)：選系統與連線方式 → 產生安裝資料夾 → 使用者到 PC2 安裝 → 填資料註冊 → 測試 → harden → AGENTS.md
# ---------------------------------------------------------------------------
$GuiConnItems = @(
    '同一個區網 (家裡/公司同一個路由器)',
    '網線直連 (兩台用網路線直接接)',
    'VPN (例如 Tailscale)',
    '指定來源網段 (例如 192.168.1.0/24)',
    '經跳板機',
    '雲端 VM，已經有 SSH 與 .pem 金鑰')

# 第一頁：系統、連線方式、來源網段。回傳 @{ os; conn (1-6); allow } 或 $null
function Show-GuiNewHostOptions {
    $f = [Windows.Forms.Form]::new()
    $f.Text = '新增一台 PC2 - 1/2 連線環境'; $f.Font = $GuiFont; $f.AutoScaleMode = 'Dpi'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterParent'; $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $f.Padding = [Windows.Forms.Padding]::new(12)
    $t = [Windows.Forms.TableLayoutPanel]::new(); $t.AutoSize = $true; $t.AutoSizeMode = 'GrowAndShrink'; $t.ColumnCount = 1; $t.Location = [Drawing.Point]::new(12, 12)

    $t.Controls.Add((New-GuiLabel 'PC2 是什麼系統?' -Bold))
    $osWin = [Windows.Forms.RadioButton]::new(); $osWin.Text = 'Windows'; $osWin.Checked = $true; $osWin.AutoSize = $true
    $osUbu = [Windows.Forms.RadioButton]::new(); $osUbu.Text = 'Ubuntu (改看 pcx guide 的步驟)'; $osUbu.AutoSize = $true
    $osRow = [Windows.Forms.FlowLayoutPanel]::new(); $osRow.AutoSize = $true; $osRow.Controls.AddRange(@($osWin, $osUbu))
    $t.Controls.Add($osRow)

    $t.Controls.Add((New-GuiLabel 'PC1 和 PC2 怎麼連線?' -Bold))
    $grp = [Windows.Forms.FlowLayoutPanel]::new(); $grp.AutoSize = $true; $grp.FlowDirection = 'TopDown'
    $radios = @()
    for ($i = 0; $i -lt $GuiConnItems.Count; $i++) {
        $rb = [Windows.Forms.RadioButton]::new(); $rb.Text = $GuiConnItems[$i]; $rb.AutoSize = $true; $rb.Tag = $i + 1
        if ($i -eq 0) { $rb.Checked = $true }
        $radios += $rb; $grp.Controls.Add($rb)
    }
    $t.Controls.Add($grp)

    $cidrLbl = New-GuiLabel '允許連入的來源網段 (CIDR)：'
    $cidr = [Windows.Forms.TextBox]::new(); $cidr.Width = 260
    $hint = New-GuiLabel ''; $hint.ForeColor = [Drawing.Color]::DimGray; $hint.MaximumSize = [Drawing.Size]::new(520, 0)
    $t.Controls.AddRange(@($cidrLbl, $cidr, $hint))

    $row = [Windows.Forms.FlowLayoutPanel]::new(); $row.AutoSize = $true; $row.FlowDirection = 'RightToLeft'; $row.Dock = 'Fill'
    $ok = [Windows.Forms.Button]::new(); $ok.Text = '下一步'; $ok.DialogResult = 'OK'; $ok.AutoSize = $true
    $no = [Windows.Forms.Button]::new(); $no.Text = '取消'; $no.DialogResult = 'Cancel'; $no.AutoSize = $true
    $row.Controls.AddRange(@($no, $ok))
    $t.Controls.Add($row)
    $f.Controls.Add($t); $f.AcceptButton = $ok; $f.CancelButton = $no

    $sync = {
        $isWin = $osWin.Checked
        $grp.Enabled = $isWin
        $sel = ($radios | Where-Object Checked | Select-Object -First 1).Tag
        $needCidr = $isWin -and $sel -in 3, 4
        $cidrLbl.Visible = $needCidr; $cidr.Visible = $needCidr
        if ($sel -eq 3 -and -not $cidr.Text) { $cidr.Text = '100.64.0.0/10' }
        if ($sel -eq 4 -and $cidr.Text -eq '100.64.0.0/10') { $cidr.Text = '' }
        $hint.Text = if (-not $isWin) { 'Ubuntu 的 PC2 不走精靈：按「下一步」會顯示 pcx guide，照它的步驟進行 (完整說明 pcx help setup)。' }
                     elseif ($sel -eq 2) { '提醒：網線直連請先在兩台手動設定同網段的固定 IP (例如 192.168.50.1 / 192.168.50.2)。' }
                     elseif ($sel -eq 3) { 'VPN 預設允許 Tailscale 網段 100.64.0.0/10，可改成你的 VPN 網段。' }
                     elseif ($sel -eq 6) { '雲端 VM 已經有 SSH，不需要產生安裝資料夾，直接用 .pem 註冊。' }
                     else { '' }
        $hint.Visible = [bool]$hint.Text
    }
    $osWin.Add_CheckedChanged($sync); $osUbu.Add_CheckedChanged($sync)
    foreach ($rb in $radios) { $rb.Add_CheckedChanged($sync) }
    & $sync

    $f.Add_FormClosing({
        param($s, $e)
        if ($f.DialogResult -ne 'OK' -or -not $osWin.Checked) { return }
        $sel = ($radios | Where-Object Checked | Select-Object -First 1).Tag
        if ($sel -in 3, 4 -and $cidr.Text.Trim() -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
            [void][Windows.Forms.MessageBox]::Show($f, '格式不對，請輸入像 192.168.1.0/24 的網段。', 'pcx', 'OK', 'Warning')
            $e.Cancel = $true
        }
    })
    $r = $f.ShowDialog($script:GuiUI.Form)
    $res = $null
    if ($r -eq 'OK') {
        $sel = [int]($radios | Where-Object Checked | Select-Object -First 1).Tag
        $allow = if ($sel -in 3, 4) { $cidr.Text.Trim() } else { 'LocalSubnet' }
        $res = @{ os = $(if ($osWin.Checked) { 'windows' } else { 'ubuntu' }); conn = $sel; allow = $allow }
    }
    $f.Dispose()
    return $res
}

# 第二頁：名稱、帳號、位址、埠、跳板機 / .pem。含名稱格式、覆蓋、重複主機防呆。
# 回傳 @{ name; user; ip; port; jump; pem } 或 @{ reuse = <已存在名稱> } 或 $null
function Show-GuiHostDetails([int]$conn, [hashtable]$prev) {
    $cloud = ($conn -eq 6)
    $f = [Windows.Forms.Form]::new()
    $f.Text = '新增一台 PC2 - 2/2 註冊並測試'; $f.Font = $GuiFont; $f.AutoScaleMode = 'Dpi'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterParent'; $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $f.Padding = [Windows.Forms.Padding]::new(12)
    $t = [Windows.Forms.TableLayoutPanel]::new(); $t.AutoSize = $true; $t.AutoSizeMode = 'GrowAndShrink'; $t.ColumnCount = 2; $t.Location = [Drawing.Point]::new(12, 12)

    $fields = [ordered]@{}
    $addField = {
        param($key, $label, $default)
        $l = New-GuiLabel $label
        $tb = [Windows.Forms.TextBox]::new(); $tb.Width = 300; $tb.Text = $default
        $tb.Margin = [Windows.Forms.Padding]::new(3, 5, 3, 3)
        $t.Controls.Add($l); $t.Controls.Add($tb)
        $fields[$key] = $tb
    }
    $pv = if ($prev) { $prev } else { @{} }
    & $addField 'name' '電腦名稱 (英數字、- 、_)' $(if ($pv.name) { $pv.name } else { 'pc2' })
    & $addField 'user' $(if ($cloud) { '登入的使用者名稱' } else { 'PC2 的管理員帳號名稱' }) $(if ($pv.user) { $pv.user } elseif ($cloud) { 'Administrator' } else { '' })
    & $addField 'ip'   $(if ($cloud) { 'VM 的公網 IP 或網域' } else { 'PC2 畫面印出的 IP (或電腦名稱)' }) "$($pv.ip)"
    & $addField 'port' 'SSH 埠' $(if ($pv.port) { $pv.port } else { '22' })
    if ($conn -eq 5) { & $addField 'jump' '跳板機 (使用者@主機)' "$($pv.jump)" }
    if ($cloud) {
        & $addField 'pem' '.pem 私鑰檔的路徑' "$($pv.pem)"
        $br = [Windows.Forms.Button]::new(); $br.Text = '瀏覽...'; $br.AutoSize = $true
        $br.Add_Click({
            $dlg = [Windows.Forms.OpenFileDialog]::new(); $dlg.Filter = '私鑰 (*.pem;*.key)|*.pem;*.key|所有檔案 (*.*)|*.*'
            if ($dlg.ShowDialog($f) -eq 'OK') { $fields.pem.Text = $dlg.FileName }
            $dlg.Dispose()
        })
        $t.Controls.Add([Windows.Forms.Label]::new()); $t.Controls.Add($br)
    }
    $note = New-GuiLabel $(if ($cloud) { '不會詢問或儲存任何密碼。' } else { '帳號必須是 PC2 的「管理員帳號」，否則之後無法做需要管理員的操作。不會詢問或儲存任何密碼。' })
    $note.ForeColor = [Drawing.Color]::DimGray; $note.MaximumSize = [Drawing.Size]::new(520, 0)
    $t.Controls.Add($note); $t.SetColumnSpan($note, 2)

    $row = [Windows.Forms.FlowLayoutPanel]::new(); $row.AutoSize = $true; $row.FlowDirection = 'RightToLeft'; $row.Dock = 'Fill'
    $ok = [Windows.Forms.Button]::new(); $ok.Text = '註冊並測試'; $ok.DialogResult = 'OK'; $ok.AutoSize = $true
    $no = [Windows.Forms.Button]::new(); $no.Text = '取消'; $no.DialogResult = 'Cancel'; $no.AutoSize = $true
    $row.Controls.AddRange(@($no, $ok))
    $t.Controls.Add($row); $t.SetColumnSpan($row, 2)
    $f.Controls.Add($t); $f.AcceptButton = $ok; $f.CancelButton = $no

    $state = @{ reuse = $null }
    $f.Add_FormClosing({
        param($s, $e)
        if ($f.DialogResult -ne 'OK') { return }
        $warn = { param($m) [void][Windows.Forms.MessageBox]::Show($f, $m, 'pcx', 'OK', 'Warning'); $e.Cancel = $true }
        $v = @{}; foreach ($k in $fields.Keys) { $v[$k] = $fields[$k].Text.Trim() }
        if ($v.name -notmatch '^[A-Za-z0-9_-]+$' -or $v.name -in $Verbs) { & $warn '名稱只能用英數字、- 、_，且不可與 pcx 的指令同名。'; return }
        if (-not $v.user) { & $warn '請輸入帳號名稱。'; return }
        if (-not $v.ip)   { & $warn '請輸入 IP 或電腦名稱。'; return }
        if ($v.port -notmatch '^\d+$' -or [int]$v.port -lt 1 -or [int]$v.port -gt 65535) { & $warn 'SSH 埠要是 1-65535 的數字。'; return }
        if ($fields.Contains('jump') -and -not $v.jump) { & $warn '請輸入跳板機 (使用者@主機)。'; return }
        if ($fields.Contains('pem') -and -not (Test-Path -LiteralPath $v.pem -PathType Leaf)) { & $warn '找不到這個 .pem 檔案，請再確認路徑。'; return }
        # 防呆：同一組 帳號@位址:埠 (含跳板機) 已用別的名稱註冊過
        $tgt = New-HostTarget $v.ip $v.user $v.port "$($v.jump)"
        $dup = @(Find-SameHost $tgt $v.name -SameUser)
        if ($dup.Count) {
            $ans = [Windows.Forms.MessageBox]::Show($f, "$(Format-Target $tgt) 已經註冊為 $($dup -join ', ')。`n同一台電腦不需要兩個名稱：之後對其中一個 teardown，另一個也會跟著失效。`n`n是：直接沿用 $($dup[0]) (不另外建立 $($v.name))`n否：回去修改帳號 / IP`n取消：結束新增", 'pcx - 已經註冊過', 'YesNoCancel', 'Warning')
            if ($ans -eq 'Yes') { $state.reuse = $dup[0]; return }
            if ($ans -eq 'No') { $e.Cancel = $true; return }
            $f.DialogResult = 'Cancel'; return
        }
        if ((Get-Hosts).ContainsKey($v.name)) {
            if ([Windows.Forms.MessageBox]::Show($f, "$($v.name) 已經註冊過，要覆蓋嗎?", 'pcx', 'YesNo', 'Question', 'Button2') -ne 'Yes') { $e.Cancel = $true; return }
        }
    })
    $r = $f.ShowDialog($script:GuiUI.Form)
    $res = $null
    if ($r -eq 'OK') {
        if ($state.reuse) { $res = @{ reuse = $state.reuse } }
        else { $res = @{}; foreach ($k in $fields.Keys) { $res[$k] = $fields[$k].Text.Trim() } }
    }
    $f.Dispose()
    return $res
}

function Start-GuiNewHost {
    $opt = Show-GuiNewHostOptions
    if (-not $opt) { return }
    if ($opt.os -eq 'ubuntu') {
        Start-GuiStep @('guide') { Show-GuiMsg "Ubuntu 的 PC2 請照視窗下方 pcx guide 的步驟進行 (每一步會告訴你下一個指令)。`n完整說明: pcx help setup" }
        return
    }
    if ($opt.conn -eq 6) { Start-GuiRegister $opt $null; return }

    $wd = Get-GuiWorkDir
    if (-not $wd) { Show-GuiMsg '上方「工作資料夾」不存在，請重新選擇。' 'pcx' 'Warning'; return }
    $kit = Join-Path $wd 'pcx-pc2-windows'
    if ((Test-Path $kit) -and (Test-Path $DefaultKey) -and
        (Ask-GuiYesNo "工作資料夾裡已經有 pcx-pc2-windows。`n`nPC2 已經用它安裝完成了嗎? (是 = 直接跳到註冊)" $false)) {
        Start-GuiRegister $opt $null; return
    }
    if (-not (Ask-GuiYesNo "接下來會在`n$wd`n產生資料夾 pcx-pc2-windows (明文腳本 + PC1 的公鑰，不含私鑰)。`n來源限制: $($opt.allow)`n`n產生安裝資料夾?")) { return }
    Start-GuiStep @('invite', 'windows', '-AllowFrom', $opt.allow) {
        param($code, $text, $ctx)
        if (Show-GuiStepFailure $code $text) { return }
        if (Ask-GuiYesNo '要開啟檔案總管顯示這個資料夾嗎?') { Start-Process explorer.exe "/select,`"$($ctx.kit)`"" }
        $done = Ask-GuiYesNo ("請你到 PC2 操作 (這一步只能由你做)：`n`n" +
            "  1. 把整個 pcx-pc2-windows 資料夾複製到 PC2 (隨身碟、雲端硬碟皆可)`n" +
            "  2. 在 PC2 對 INSTALL.cmd 按右鍵，選「以系統管理員身分執行」`n" +
            "  3. 等畫面最後印出 IP，記下來`n" +
            "  (要登入的帳號必須是 PC2 的「管理員帳號」)`n`n" +
            "PC2 安裝完成了嗎?`n(選「否」可以先關掉，完成後再按「新增一台 PC2」，會問你是否直接跳到註冊)")
        if ($done) { Start-GuiRegister $ctx.opt $null }
    } @{ opt = $opt; kit = $kit }
}

function Start-GuiRegister([hashtable]$opt, [hashtable]$prev) {
    $d = Show-GuiHostDetails $opt.conn $prev
    if (-not $d) { return }
    if ($d.reuse) { Complete-GuiHost $d.reuse; return }
    $argv = @('add', $d.name, "$($d.user)@$($d.ip)")
    if ($d.jump) { $argv += @('-Jump', $d.jump) }
    if ($d.pem)  { $argv += @('-Key', $d.pem) }
    if ($d.port -ne '22') { $argv += @('-Port', $d.port) }
    Start-GuiStep $argv {
        param($code, $text, $ctx)
        if ($code -eq 0) { Complete-GuiHost $ctx.d.name; return }
        [void](Show-GuiStepFailure $code $text)
        if (Ask-GuiYesNo '要修正後重新輸入帳號 / IP 再試一次嗎?') { Start-GuiRegister $ctx.opt $ctx.d }
    } @{ opt = $opt; d = $d }
}

# 註冊成功後：測試 hostname → 詢問 harden → 詢問 AGENTS.md
function Complete-GuiHost([string]$name) {
    Add-GuiLog ''
    Add-GuiLog "測試在 $name 上執行 hostname ..."
    Start-GuiStep @($name, 'hostname') {
        param($code, $text, $ctx)
        if (Show-GuiStepFailure $code $text) { return }
        $n = $ctx.name
        $info = (Get-Hosts)[$n]
        if ($info.hardened) { Add-GuiLog "$n 已經關閉密碼登入。"; Complete-GuiAgents $n; return }
        if (-not $info.admin) { Add-GuiLog "$n 這個帳號沒有管理員/sudo 權限，先略過「關閉密碼登入」。(pcx help admin)"; Complete-GuiAgents $n; return }
        if (Ask-GuiYesNo "連線成功！`n`n建議關閉 $n 的密碼登入，只留金鑰：會先確認金鑰可登入才動手，結束後再驗證一次。`n`n現在關閉 $n 的密碼登入?") {
            Start-GuiStep @('harden', $n) { param($code, $text, $ctx) [void](Show-GuiStepFailure $code $text); Complete-GuiAgents $ctx.name } @{ name = $n }
        } else {
            Add-GuiLog "之後可按「關閉密碼登入 (harden)」或執行: pcx harden $n"
            Complete-GuiAgents $n
        }
    } @{ name = $name }
}
function Complete-GuiAgents([string]$name) {
    $wd = Get-GuiWorkDir
    $fin = {
        param($n)
        Add-GuiLog ''
        Add-GuiLog '完成！之後可以這樣用：'
        Add-GuiLog "  pcx $n `"Get-Service sshd`"        在 PC2 執行指令 (Windows 用 PowerShell 語法)"
        Add-GuiLog "  pcx put $n .\a.zip C:/temp/a.zip  上傳；pcx get 下載"
        Add-GuiLog '  pcx status                          檢查是否在線'
        Add-GuiLog "  pcx teardown $n                  用完移除 PC2 的遠端存取"
        Show-GuiMsg "$n 設定完成！使用方式已列在視窗下方。"
    }
    if ($wd -and (Ask-GuiYesNo "要在工作資料夾`n$wd`n的 AGENTS.md 寫入給 AI 的用法嗎?" $false)) {
        Start-GuiStep @('agents') { param($code, $text, $ctx) & $ctx.fin $ctx.name } @{ name = $name; fin = $fin }
    } else { & $fin $name }
}

# ---------------------------------------------------------------------------
# 建立主視窗
# ---------------------------------------------------------------------------
function New-GuiMainForm {
    $f = [Windows.Forms.Form]::new()
    $f.Text = 'pcx 精靈 - 讓這台電腦 (PC1) 操作另一台 PC2'
    $f.Font = $GuiFont; $f.AutoScaleMode = 'Dpi'
    $f.Size = [Drawing.Size]::new(1100, 720); $f.MinimumSize = [Drawing.Size]::new(860, 560)
    $f.StartPosition = 'CenterScreen'
    $script:GuiUI.Form = $f

    # 上方：說明 + 工作資料夾
    $top = [Windows.Forms.TableLayoutPanel]::new(); $top.Dock = 'Top'; $top.AutoSize = $true; $top.ColumnCount = 3
    $top.Padding = [Windows.Forms.Padding]::new(8, 6, 8, 2)
    [void]$top.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('AutoSize'))
    [void]$top.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100))
    [void]$top.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('AutoSize'))
    $intro = New-GuiLabel '選左邊的動作開始。不會詢問或儲存任何密碼；會改變 PC2 的動作都會先問你。'
    $top.Controls.Add($intro); $top.SetColumnSpan($intro, 3)
    $top.Controls.Add((New-GuiLabel '工作資料夾 (安裝資料夾、AGENTS.md 產生在這裡)：'))
    $wd = [Windows.Forms.TextBox]::new(); $wd.Dock = 'Fill'; $wd.Text = (Get-Location).Path
    $wd.Margin = [Windows.Forms.Padding]::new(3, 6, 3, 3)
    $top.Controls.Add($wd)
    $br = [Windows.Forms.Button]::new(); $br.Text = '選擇...'; $br.AutoSize = $true
    $br.Add_Click({
        $dlg = [Windows.Forms.FolderBrowserDialog]::new(); $dlg.SelectedPath = $script:GuiUI.WorkDir.Text
        if ($dlg.ShowDialog($script:GuiUI.Form) -eq 'OK') { $script:GuiUI.WorkDir.Text = $dlg.SelectedPath }
        $dlg.Dispose()
    })
    $top.Controls.Add($br)
    $script:GuiUI.WorkDir = $wd

    # 左側：動作按鈕
    $left = [Windows.Forms.FlowLayoutPanel]::new(); $left.Dock = 'Left'; $left.Width = 230
    $left.FlowDirection = 'TopDown'; $left.WrapContents = $false; $left.AutoScroll = $true
    $left.Padding = [Windows.Forms.Padding]::new(6)
    $mk = {
        param($key, $text, $action)
        $b = New-GuiButton $text 210
        $b.Add_Click($action)
        $script:GuiUI[$key] = $b
        $left.Controls.Add($b)
    }
    $left.Controls.Add((New-GuiLabel '開始' -Bold))
    & $mk 'BtnNew'      '＋ 新增一台 PC2 (完整流程)'  { Start-GuiNewHost }
    & $mk 'BtnStatus'   '檢查是否在線 (全部)'         { Invoke-GuiStatus }
    & $mk 'BtnGuide'    '顯示目前進度 (pcx guide)'    { Start-GuiStep @('guide') $null }
    $left.Controls.Add((New-GuiLabel '對選取的電腦' -Bold))
    & $mk 'BtnTest'     '測試連線 (執行 hostname)'    { Invoke-GuiTest }
    & $mk 'BtnHarden'   '關閉密碼登入 (harden)'       { Invoke-GuiHarden }
    & $mk 'BtnTeardown' '移除遠端存取 (teardown)'     { Invoke-GuiTeardown }
    & $mk 'BtnForget'   '只刪本機註冊 (forget)'       { Invoke-GuiForget }
    $left.Controls.Add((New-GuiLabel '其他' -Bold))
    & $mk 'BtnStop'     '■ 停止目前的步驟'            { Stop-GuiStep }
    & $mk 'BtnRefresh'  '重新整理清單'                { Update-GuiHostList }
    & $mk 'BtnClear'    '清除輸出'                    { $script:GuiUI.Log.Clear() }
    $script:GuiUI.BtnTeardown.ForeColor = [Drawing.Color]::DarkRed

    # 中間：清單 (上) + 輸出 (下)
    $split = [Windows.Forms.SplitContainer]::new(); $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'
    $lv = [Windows.Forms.ListView]::new(); $lv.Dock = 'Fill'; $lv.View = 'Details'
    $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false
    foreach ($col in @(@('名稱', 120), @('系統', 80), @('連線目標', 300), @('管理員/sudo', 100), @('密碼登入', 90), @('在線狀態', 260))) {
        [void]$lv.Columns.Add($col[0], $col[1])
    }
    $lv.Add_SelectedIndexChanged({ Update-GuiButtons })
    $lv.Add_DoubleClick({ if (-not $script:GuiJob) { Invoke-GuiTest } })
    $empty = New-GuiLabel '還沒有註冊任何電腦。按左邊「＋ 新增一台 PC2」開始。'
    $empty.ForeColor = [Drawing.Color]::DimGray; $empty.Dock = 'Top'; $empty.Padding = [Windows.Forms.Padding]::new(8)
    $split.Panel1.Controls.Add($lv); $split.Panel1.Controls.Add($empty)
    $script:GuiUI.List = $lv; $script:GuiUI.Empty = $empty; $script:GuiUI.Split = $split

    $log = [Windows.Forms.TextBox]::new(); $log.Dock = 'Fill'; $log.Multiline = $true; $log.ReadOnly = $true
    $log.ScrollBars = 'Both'; $log.WordWrap = $false; $log.Font = $GuiFontLog; $log.BackColor = [Drawing.Color]::White
    $log.MaxLength = 0
    $logLbl = New-GuiLabel '輸出 (每一步實際執行的 pcx 指令與結果)'; $logLbl.Dock = 'Top'
    $split.Panel2.Controls.Add($log); $split.Panel2.Controls.Add($logLbl)
    $script:GuiUI.Log = $log

    $ss = [Windows.Forms.StatusStrip]::new()
    $st = [Windows.Forms.ToolStripStatusLabel]::new(); $st.Text = '就緒'
    [void]$ss.Items.Add($st)
    $script:GuiUI.Status = $st

    # Dock 順序：先加 Fill，再加邊緣的
    $f.Controls.Add($split); $f.Controls.Add($left); $f.Controls.Add($top); $f.Controls.Add($ss)
    # 事件在 Application.Run 期間觸發，此時已離開這個函式，只能透過 $script:GuiUI 取用控制項
    $f.Add_Shown({ $sp = $script:GuiUI.Split; $sp.SplitterDistance = [int]($sp.Height * 0.42); Start-GuiStartup })

    $timer = [Windows.Forms.Timer]::new(); $timer.Interval = 100
    $timer.Add_Tick({
        try { Update-GuiStep }
        catch { $script:GuiJob = $null; Set-GuiBusy $false; Add-GuiLog "精靈內部錯誤: $($_.Exception.Message)" }
    })
    $timer.Start()
    $script:GuiUI.Timer = $timer
    $f.Add_FormClosing({
        param($s, $e)
        if ($script:GuiJob) {
            if (-not (Ask-GuiYesNo '還有步驟正在執行，要中止並關閉嗎?' $false 'Warning')) { $e.Cancel = $true; return }
            Stop-GuiStep
        }
        $script:GuiUI.Timer.Stop()
    })
    Update-GuiHostList
    return $f
}

# 開啟時：檢查 ssh、詢問是否安裝全域指令
function Start-GuiStartup {
    Add-GuiLog 'pcx 視窗精靈。每一步會以子行程執行 pcx 的對應指令，輸出顯示在這裡。'
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Show-GuiMsg "[errorRequest:SSH_CLIENT_MISSING]`n這台電腦找不到 ssh 指令 (OpenSSH 客戶端)。`n`n請安裝 OpenSSH 客戶端: 設定 > 應用程式 > 選用功能 > 新增功能 > OpenSSH 用戶端；安裝後再開啟精靈。" 'pcx - 需要你處理' 'Warning'
        $script:GuiUI.Form.Close(); return
    }
    $shimOk = (Test-Path (Join-Path $env:APPDATA 'npm\pcx.cmd')) -or (Test-Path (Join-Path $PcxDir 'pcx.cmd'))
    if (-not ($shimOk -and (Test-Path (Join-Path $PcxDir 'pcx.ps1')))) {
        if (Ask-GuiYesNo "還沒安裝 pcx 全域指令 (安裝後任何資料夾都能直接打 pcx，AI CLI 也靠它操作 PC2)。`n`n現在安裝?") {
            Start-GuiStep @('install') { param($code, $text) [void](Show-GuiStepFailure $code $text) }
        }
    }
}

try {
    $mainForm = New-GuiMainForm
    [Windows.Forms.Application]::Run($mainForm)
    exit 0
} catch {
    $err = "$($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)"
    try { [void][Windows.Forms.MessageBox]::Show("視窗精靈發生錯誤，可改用文字版精靈 (WIZARD-TEXT.cmd 或 pcx wizard)。`n`n$err", 'pcx', 'OK', 'Error') }
    catch { Write-Host $err }
    exit 1
}
