# pcx：讓 PC1 的 AI CLI 操作 PC2

PC2 只開 OpenSSH（不裝 AI、不登入帳號）。PC1 用 `pcx` 送指令，讀回完整輸出與結束碼。
區網、網線直連、VPN、雲端 VM、跳板機都用同一套指令。

## 內建說明與引導流程

**Windows 最簡單的方式**：雙擊 `WIZARD.cmd`（或執行 `pcx wizard`）。互動精靈會一步步詢問並代為執行：安裝 pcx、選 PC2 系統與連線環境、產生安裝資料夾、提示你到 PC2 執行 `INSTALL.cmd`、輸入 IP 註冊並測試、詢問是否關閉密碼登入、寫入 `AGENTS.md`。已註冊的電腦也能從選單檢查在線、harden 或 teardown（teardown 要輸入電腦名稱確認）。精靈不會詢問或儲存任何密碼；PC2 是 Ubuntu 時，精靈會改帶你看 `pcx guide`。

使用說明已內建在 `pcx.ps1` 裡，`pcx install` 之後不需要這份 README 也能查：

```powershell
pcx wizard           # Windows 互動精靈（給人用；AI 工具中執行會被拒絕）
pcx guide            # 引導流程：檢查目前做到哪一步（安裝 → invite → PC2 安裝 → add → 權限 → harden → agents），並印出「下一步」要執行的指令
pcx guide pc2        # 同上，並實際檢測 pc2 是否在線
pcx help             # 完整中文使用說明（指令速查 + 以下各節）
pcx help errors      # 只看某一節；主題：setup admin errors env daily remove security ai notes
```

`pcx guide` 只讀取狀態、不會詢問輸入也不會修改任何東西，AI CLI 也能安全執行。

## 設定（約 3 步）

PC1（需要 PowerShell 7）：

```powershell
.\pcx.ps1 install                 # 一次性：之後任何地方都能用 pcx
pcx invite windows                # 或 ubuntu → 產生明文資料夾 pcx-pc2-windows / pcx-pc2-ubuntu（腳本 + 你的公鑰，沒有任何編碼）
```

PC2：把產生的資料夾整個複製過去。Windows 對 `INSTALL.cmd` 按右鍵「以系統管理員身分執行」，Ubuntu 執行 `bash install.sh`。畫面最後會印出 IP。

PC1：

```powershell
pcx add pc2 admin@192.168.1.50    # 註冊並測試連線，同時檢查 PC2 有沒有管理員/sudo 權限
pcx pc2 "hostname"                # 完成
pcx harden pc2                    # 建議：確認金鑰可用後，關閉 PC2 的密碼登入
```

## 管理員 / root 權限

很多操作需要管理員權限（裝服務、改設定、重啟服務）。`pcx add` 會檢查並記錄，`pcx list` 看得到。

| PC2 | 怎麼處理 |
|---|---|
| Windows | 用 PC2 的**管理員帳號**登入，SSH 工作階段就是已提升的管理員權限，不會有 UAC 提示。本機管理員帳號安裝時會設定 `LocalAccountTokenFilterPolicy=1`（否則 Windows 會把本機帳號的遠端登入降成一般權限），原值會記錄，移除時還原；**這也會讓 SMB/WinRM 等遠端登入取得完整管理員權限**，請確保管理員帳號都有強密碼。一般使用者帳號無法透過 SSH 提升權限，這種情況 pcx 會提出 `ADMIN_REQUIRED` |
| Ubuntu | SSH 是非互動式，`sudo` 要密碼就會失敗。兩種做法：① 產生安裝資料夾時加 `-PasswordlessSudo`（授權免密碼 sudo，**等同 root**，移除時自動撤銷）；② 不加，需要 root 的操作請自己在 PC2 做。AI 一律用 `sudo -n`，不會也不應該取得你的密碼 |

## 遇到無法自行解決的狀況：errorRequest

pcx 與安裝腳本遇到自己解決不了的問題（沒權限、連不上、金鑰被拒、主機金鑰變更、沙盒擋網路、Windows Update 失敗、`apt` 被鎖住等），會印出固定格式的區塊：

```
[errorRequest:AUTH_REJECTED]
  問題: ...
  需要: ...
```

代碼包括：`HOST_NOT_REGISTERED`、`AUTH_REJECTED`、`UNREACHABLE`、`SSH_NOT_RUNNING`、`DNS_FAILED`、`HOSTKEY_CHANGED`、`KEY_UNREADABLE`、`NETWORK_BLOCKED`、`ADMIN_REQUIRED`、`SUDO_PASSWORD_REQUIRED`、`NO_ADMIN`、`RUN_TIMEOUT`、`HARDEN_*`、`TEARDOWN_FAILED`、`UNINSTALL_PARTIAL`、`OPENSSH_INSTALL_FAILED`、`APT_FAILED`、`NO_SYSTEMD`、`NO_IP_ADDRESS` 等。看到這個區塊時，請照「需要」欄位處理後再繼續；AI 會停下來把內容轉告你。

## 各種環境

| 環境 | 做法 |
|---|---|
| 區網 | 預設就是區網 |
| 網線直連 | 兩邊手動設同網段固定 IP（例如 192.168.50.1 / .2），其餘相同 |
| VPN（Tailscale 等） | `pcx invite windows -AllowFrom 100.64.0.0/10`，`pcx add` 用 VPN 的 IP 或名稱 |
| 雲端 VM | 通常已有 SSH 與金鑰：`pcx add vm1 ubuntu@公網IP -Key C:\keys\vm.pem`，不需要 invite |
| 經跳板機 | `pcx add pc2 admin@內網IP -Jump user@跳板機` |
| 非 22 埠 | `-Port 2222` |

雲端不要把 22 埠對全網際網路開放：安全群組只允許你的固定 IP，或改走 VPN。

## 日常操作

```powershell
pcx pc2 "Get-Service sshd"            # Windows 用 PowerShell 語法；Ubuntu 用 bash
pcx pc2 -File .\fix.ps1               # 在 PC2 執行本機腳本
pcx put pc2 .\app.zip C:/temp/app.zip # 上傳
pcx get pc2 /var/log/syslog .\syslog  # 下載
pcx list
pcx status                            # 平行檢測所有已註冊電腦是否存活（約 5 秒內）
pcx clean                             # 一鍵清理「遠端存取已不存在」的註冊；離線的預設保留，確定不用再加 -IncludeOffline
pcx agents                            # 在目前資料夾的 AGENTS.md 寫入「請用 pcx 操作遠端」
```

輸出最後一行 `[exit code: N]` 是遠端指令的結束碼。遠端指令預設最多執行 120 秒（`-RunTimeout` 可調），stdin 會被關閉，所以在等輸入的指令不會卡住，而是回報逾時。中文 Windows 的輸出若亂碼，加 `-Encoding 950`。

## 一鍵移除

| 想做的事 | 指令 |
|---|---|
| 只移除某台 PC2 的遠端存取 | `pcx teardown pc2` |
| **全部清乾淨（所有 PC2 + PC1）** | `pcx uninstall -All -Yes` |
| 只清 PC1，不動 PC2 | `pcx uninstall -Yes` |
| 連 OpenSSH Server 也一併卸載 | 加 `-UninstallServer` |
| PC1 已不在手邊，直接在 PC2 移除 | Windows: 執行資料夾裡的 `REMOVE.cmd`（右鍵以系統管理員身分執行）　Ubuntu: `bash remove.sh` |

PC2 的還原依據是安裝時記下的「原本狀態」：只移除 pcx 自己的金鑰（其他金鑰保留）、還原防火牆規則與密碼登入設定、還原預設 shell；SSH 若是 pcx 裝的或原本沒在執行就停用，原本就在用的雲端 VM 不會被關掉。
PC1 會刪除 `pcx` 指令、`~\.pcx`、專用金鑰 `id_ed25519_pcx`、`~/.ssh/config` 裡 pcx 的區塊。

## 安全性與 OpenSSH 更新

- 密碼登入在安裝時維持原樣（避免金鑰沒生效時把自己鎖在外面）。請在 `pcx add` 確認金鑰可用後，執行 `pcx harden <名稱>` 關閉密碼登入；它會先確認金鑰登入成功才動手，事後再驗證一次。這可擋掉密碼認證類的 sshd 漏洞。
- Windows PC2 會設定 `LocalAccountTokenFilterPolicy=1`（見上方「管理員 / root 權限」），移除時還原。
- 預設只開放區網來源。不用時執行 `pcx teardown <名稱>`，SSH 就不會一直開著，這是最有效的防護。
- 腳本**不會自動升級** OpenSSH，只會在安裝結束時印出版本；Ubuntu 若有可用更新會提醒。
  - Ubuntu：評估後自行 `sudo apt install --only-upgrade openssh-server`；要在安裝時一起升級可加 `pcx invite ubuntu -UpgradeServer`（非互動、保留現有設定檔，不會刪資料，但會重啟 sshd 並可能連帶升級 openssl/libc）。
  - Windows：OpenSSH 由 Windows Update 維護，請定期更新 Windows。
- 發現 OpenSSH 重大漏洞時，請對照官方公告確認影響範圍（例如 CVE-2026-123158 主要影響 musl 且無 PAM 的 Linux，如 Alpine）。

## 注意

- PC1 的 Codex 沙盒預設會擋網路，`ssh` 可能被擋，需放寬沙盒或用核准模式。
- 登入後的權限：Windows 是管理員，Ubuntu 是 invite 時使用的帳號（加了 `-PasswordlessSudo` 就等同 root）。私鑰外洩就等於 PC2 被控制，請妥善保管。
- 網線直連沒設固定 IP 時，系統會自動配 `169.254.x.x`；安裝完成畫面會列出並標註，建議改設固定 IP。
- Windows PC2 的 SSH 預設 shell 會設成 PowerShell 7（沒有就用 Windows PowerShell），所以遠端指令用 PowerShell 語法。
- 專用金鑰沒有加密碼（為了免輸入）。跨網路使用時建議搭配 VPN 或來源 IP 限制。
