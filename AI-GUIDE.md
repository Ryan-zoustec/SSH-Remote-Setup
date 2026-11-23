# 給 AI 的操作指引：用 pcx 連線並操作 PC2

> 使用者會在 PC1 對你說：「讀 `E:\SSH-Remote-Setup\AI-GUIDE.md`，照指引幫我連到 PC2」。
> 本檔說明你要做什麼、不能做什麼、每一步怎麼驗證。工具與腳本都在同一個資料夾（下稱 `<資料夾>`，預設 `E:\SSH-Remote-Setup`）。

## 0. 前提與角色

- **PC1** = 你正在執行的這台電腦（Windows，PowerShell 7）。**PC2** = 要被操作的電腦（Windows 或 Ubuntu）。
- 你只能直接操作 PC1；操作 PC2 一律透過 `pcx`（底層是 SSH）。
- `pcx` 的輸出最後一行 `[exit code: N]` 是遠端結束碼，非 0 就是失敗，必須讀輸出並處理，不可假裝成功。
- 你的沙盒可能擋網路或 `ssh`。若 `pcx` 因沙盒失敗，告訴使用者需要放寬沙盒或核准該指令，不要改用其他方式繞過。
- **`[errorRequest:代碼]` 規則（最重要）**：輸出中出現這個區塊，代表 `pcx` 或安裝腳本遇到自己無法解決的狀況。你必須**立刻停止**目前流程，把「問題」與「需要」原樣轉告使用者，等使用者處理並回覆後才繼續。不要自行猜測原因、不要換方法繞過、不要重複重試同一個指令。（`[hint:...]` 是提示，不是 errorRequest，可以自行依提示調整。）
- 遠端指令預設最多 120 秒（`-RunTimeout` 可調）且 stdin 已關閉：指令必須是非互動式（`apt -y`、`sudo -n`）。

## 1. 絕對不可以做的事

- 不要輸入、猜測或儲存任何密碼；不要讀取或顯示私鑰（`~/.ssh/id_ed25519_pcx`，只有 `.pub` 可以顯示）。
- 不要替使用者在 PC2 上執行任何東西；PC2 的安裝**必須由使用者自己**在 PC2 執行（需要 UAC / sudo）。
- 不要用 `-AllowFrom Any`、不要加 `-PasswordlessSudo`（等同給 root），除非使用者明確要求並已了解風險。
- 需要 root/管理員卻沒有權限時，不要嘗試取得或輸入密碼，也不要找其他提權方式；照 errorRequest 請使用者處理。
- 會修改設定、刪除檔案、重啟服務、關機的遠端指令，先向使用者確認再執行。
- 沒有使用者同意，不要執行 `pcx uninstall`、`pcx teardown`。

## 2. 連線流程（逐步，每步都要驗證）

### 步驟 A：確認環境

```powershell
$PSVersionTable.PSVersion          # 必須 >= 7
ssh -V                             # 必須有 OpenSSH client
Test-Path <資料夾>\pcx.ps1         # 必須 True
```

不符合就停下來告訴使用者缺什麼（PowerShell 7、OpenSSH 客戶端），不要自行安裝系統元件。

### 步驟 B：安裝 pcx（只做一次）

```powershell
cd <資料夾>
.\pcx.ps1 install
```

完成後新開的終端機才有 `pcx` 全域指令；在目前的工作階段請直接用 `& <資料夾>\pcx.ps1 ...` 代替 `pcx ...`。驗證：`& <資料夾>\pcx.ps1 help` 會印出用法。

### 步驟 C：問使用者 4 件事（缺一不可，不要猜）

1. PC2 的作業系統：Windows 還是 Ubuntu？
2. 連線環境：區網 / 網線直連 / VPN（如 Tailscale）/ 雲端 VM / 經跳板機？
3. PC2 目前 IP（或網域）與要登入的使用者名稱？（還不知道的話，產生安裝檔後由 PC2 印出）
4. 雲端 VM 且已有 SSH 與 `.pem` 金鑰嗎？（有的話跳到步驟 E，不需要 invite）

### 步驟 D：產生給 PC2 的安裝檔

依環境選參數（原則：能限制來源就限制）：

| 環境 | 指令 |
|---|---|
| 區網 / 網線直連（預設） | `pcx invite windows` 或 `pcx invite ubuntu` |
| VPN（Tailscale） | `pcx invite windows -AllowFrom 100.64.0.0/10` |
| 指定來源網段 | `pcx invite ubuntu -AllowFrom 192.168.1.0/24` |
| Ubuntu 並順便升級 openssh-server | 加 `-UpgradeServer`（建議使用者先確認，會重啟 sshd） |

驗證：目前資料夾出現 `pcx-pc2-windows` 或 `pcx-pc2-ubuntu` 資料夾（內容是明文腳本、`pcx.pub` 與 `README.txt`；加 `-SingleFile` 才會改產生單一檔案）。

然後**請使用者自己**：

- 把整個資料夾複製到 PC2（隨身碟、雲端硬碟、scp 皆可）。
- Windows：對 `INSTALL.cmd` 按右鍵「以系統管理員身分執行」；Ubuntu：`bash install.sh`。
- 把畫面最後印出的 IP / 指令貼回給你。

在使用者回報完成前，不要繼續。

### 步驟 E：註冊並測試連線

```powershell
pcx add pc2 <使用者>@<IP>
```

其他情況：雲端 VM 用 `pcx add vm1 ubuntu@<公網IP> -Key <pem路徑>`；經跳板機加 `-Jump 使用者@跳板機`；非 22 埠加 `-Port N`。

- 成功：印出「連線成功 (windows|linux，管理員權限: 有/沒有)」。
- 失敗：會印出 `[errorRequest:...]`，依上方規則停下來轉告使用者。
- 若顯示「管理員權限: 沒有」並出現 `NO_ADMIN` 的 errorRequest：需要 root/管理員的操作會失敗，請使用者決定要換管理員帳號、設定免密碼 sudo，或接受只做不需權限的操作。

### 步驟 F：驗證可用，並告知使用者

```powershell
pcx pc2 "hostname"
```

應回傳 PC2 的電腦名稱與 `[exit code: 0]`。成功後回報使用者：已連上、PC2 作業系統、管理員/sudo 狀態、之後怎麼叫你操作。可建議執行 `pcx agents`，讓此資料夾的 `AGENTS.md` 記住用法。

### 步驟 G：建議關閉密碼登入

安裝預設保留密碼登入（避免鎖死）。金鑰連線驗證成功後，**建議使用者同意後**執行：

```powershell
pcx harden pc2
```

它會先確認金鑰可登入才動手，結束後再驗證一次。需要 PC2 的管理員/sudo 權限，沒有就會出現 errorRequest，照規則處理。

## 3. 日常操作守則

```powershell
pcx pc2 "<指令>"                  # Windows 遠端用 PowerShell 語法；linux 遠端用 bash 語法
pcx pc2 -File .\script.ps1        # 多行腳本（遠端是 linux 則用 .sh）
pcx put pc2 <本機路徑> <遠端路徑>    # 上傳（Windows 遠端路徑用 C:/temp/x 形式）
pcx get pc2 <遠端路徑> <本機路徑>    # 下載
pcx list                           # 已註冊的電腦、作業系統與 admin/sudo 狀態
pcx status [名稱]                  # 檢測是否存活：在線 / 金鑰被拒 / SSH 未開 / 離線
pcx clean                          # 清理遠端存取已不存在的註冊（離線的預設保留；加 -IncludeOffline 需先問使用者）
```

- 開始工作前先 `pcx status <名稱>` 確認目標在線；不在線就回報使用者，不要反覆重試。

- 先唯讀診斷（查狀態、讀記錄），再提出修復建議，**經使用者同意後**才修改。
- 修改前先備份要改的檔案或記下原值；修改後立刻驗證結果並回報。
- 每次回報要包含：執行了什麼、結束碼、關鍵輸出、下一步建議。
- 輸出若很長，只摘要重點，並說明完整內容在哪裡可再取得。

## 4. 錯誤對照

多數情況 `pcx` 會直接印出對應的 `[errorRequest:代碼]`（如 `AUTH_REJECTED`、`UNREACHABLE`、`SSH_NOT_RUNNING`、`HOSTKEY_CHANGED`、`KEY_UNREADABLE`、`NETWORK_BLOCKED`、`ADMIN_REQUIRED`、`SUDO_PASSWORD_REQUIRED`、`RUN_TIMEOUT`），請依規則轉告使用者。下表是這些情況的背景說明，**不是讓你自行處理的步驟**：

| 現象 | 可能原因 | 處理 |
|---|---|---|
| `Permission denied (publickey)` | PC2 還沒執行安裝，或用了別台 PC1 產生的資料夾 | 請使用者確認 PC2 已執行**這台 PC1 產生**的安裝檔；必要時重新 `pcx invite` |
| `Connection timed out` / `No route to host` | 不同網段、防火牆、IP 錯誤、PC2 沒開機 | 確認 IP 與網路；若是 VPN/雲端，確認 `-AllowFrom` 包含 PC1 的來源 |
| `Connection refused` | PC2 的 sshd 沒在執行 | 請使用者在 PC2 重新執行安裝檔 |
| `Host key verification failed` | PC2 重灌或換機，主機金鑰變了 | 向使用者確認是預期的變更後，才可 `ssh-keygen -R <IP>` 再重連 |
| `找不到 'pc2'` | 尚未 `pcx add` | 回步驟 E |
| 指令逾時 (`RUN_TIMEOUT`，結束碼 124) | 遠端指令在等輸入，或工作太久 | 改寫成非互動式，或經使用者同意後用 `-RunTimeout` 調高 |
| 輸出出現 `[hint:ENCODING]` | 遠端是 cp950 等非 UTF-8 編碼 | 同一指令加 `-Encoding 950` 重試（這是提示，可自行處理） |
| 被沙盒擋下 | PC1 的 Codex 沙盒限制網路 | 請使用者放寬沙盒或核准，不要繞過 |

## 5. 用完要收尾

- 作業告一段落、之後不再需要時，**建議**使用者移除遠端存取（SSH 不要一直開著）：
  - 只移除某台：`pcx teardown pc2`
  - 全部清乾淨（PC2 與 PC1）：`pcx uninstall -All -Yes`
  - PC1 不在手邊時，在 PC2 執行安裝檔並加參數：Windows 執行資料夾裡的 `REMOVE.cmd`（右鍵以系統管理員身分執行）、Ubuntu `bash remove.sh`
- 這些會改變 PC2 設定，須取得使用者明確同意後才執行；執行後回報結果。

## 6. 安全備忘

- PC2 上被授權的是 PC1 的專用金鑰；Windows 登入後是**管理員權限**，Ubuntu 是安裝時使用的帳號。所有操作都等同該身分，請謹慎。
- 預設只允許區網來源；密碼登入在驗證金鑰可用後，建議以 `pcx harden` 關閉。不要為了「連得上」而放寬這些設定。
- OpenSSH 重大漏洞出現時，請使用者核對官方公告並更新 PC2 的 OpenSSH；本工具不會自動升級（除非產生安裝檔時使用 `-UpgradeServer`）。
