# pcx：讓 PC1 的 AI CLI 操作 PC2

[English](README.en.md) ｜ 繁體中文

PC2 只開 OpenSSH（不裝 AI、不登入帳號）。PC1 用 `pcx <名稱> "<指令>"` 送指令，讀回完整輸出與最後一行 `[exit code: N]`。
區網、網線直連、VPN、雲端 VM、跳板機都用同一套指令。

- **PC1**：你正在用的電腦。需要 Windows、PowerShell 7（`pwsh`）與 OpenSSH 用戶端。
- **PC2**：要被操作的電腦，Windows 或 Ubuntu/Debian（也可以是已經有 SSH 的雲端 VM）。

其他文件：[AI-GUIDE.md](AI-GUIDE.md)（給 AI 的操作守則）、[DEVELOPMENT.md](DEVELOPMENT.md)（設計與開發紀錄）。

## 設定

### 最簡單：互動精靈（PC2 是 Windows）

雙擊 `WIZARD.cmd`（或執行 `pcx wizard`）。精靈會一步步詢問並代為執行：安裝 pcx、選連線環境、產生安裝資料夾、提示你到 PC2 執行 `INSTALL.cmd`、註冊並測試、詢問是否關閉密碼登入、寫入 `AGENTS.md`。已註冊的電腦也能從選單檢查在線、harden、teardown（要輸入電腦名稱確認）或 forget。精靈不會詢問或儲存任何密碼；PC2 是 Ubuntu 時，精靈會改帶你看 `pcx guide`。

### 手動（約 3 步）

**1. PC1：安裝並產生給 PC2 的安裝資料夾**

```powershell
.\pcx.ps1 install                 # 一次性；重開終端機後任何地方都能用 pcx
pcx invite windows                # 或 pcx invite ubuntu
```

`invite` 會在目前資料夾產生明文資料夾 `pcx-pc2-windows` / `pcx-pc2-ubuntu`（腳本、你的公鑰 `pcx.pub` 與 `README.txt`，沒有任何編碼）。加 `-SingleFile` 改產生單一檔案，`-Out <名稱>` 指定輸出名稱。

**2. PC2：把整個資料夾複製過去後執行**

- Windows：雙擊 `INSTALL.cmd`，會自動跳出 UAC 要求系統管理員權限（右鍵「以系統管理員身分執行」也可以）。
- Ubuntu：`bash install.sh`（會用 sudo 執行）。

畫面最後會印出可直接複製的 `pcx add ...` 指令與 IP。

**3. PC1：註冊並測試**

```powershell
pcx add pc2 admin@192.168.1.50    # 註冊並測試連線，同時檢查 PC2 有沒有管理員/sudo 權限
pcx pc2 "hostname"                # 回傳 PC2 名稱與 [exit code: 0] 就完成了
pcx harden pc2                    # 建議：確認金鑰可用後，關閉 PC2 的密碼登入
pcx agents                        # 選用：在目前資料夾的 AGENTS.md 寫入「請用 pcx 操作遠端」
```

同一台 PC2（帳號、位址、埠、跳板機都相同）已經用別的名稱註冊過時，`pcx add` 會拒絕並提出 `DUPLICATE_HOST`；確定要兩個名稱並存才加 `-Force`。

**更新 pcx**：`git pull` 後在專案資料夾再執行一次 `pcx install`，會把新版複製到 `~\.pcx`。

## 內建說明與引導

使用說明已內建在 `pcx.ps1` 裡，`pcx install` 之後不需要這份 README 也能查：

```powershell
pcx guide            # 檢查目前做到哪一步（安裝 → invite → PC2 安裝 → add → 權限 → harden → agents），並印出下一步
pcx guide pc2        # 同上，並實際檢測 pc2 是否在線
pcx help             # 完整中文使用說明
pcx help errors      # 只看某一節；主題：setup admin errors env daily remove security ai notes
pcx wizard           # Windows 互動精靈（給人用；在 AI 工具等非互動終端機中會被拒絕）
```

`pcx guide` 只讀取狀態、不會詢問輸入也不會修改任何東西，AI CLI 也能安全執行。

## 管理員 / root 權限

很多操作需要管理員權限（裝服務、改設定、重啟服務、`harden`、`teardown`）。`pcx add` 會檢查並記錄，`pcx list` 看得到。

| PC2 | 怎麼處理 |
|---|---|
| Windows | 用 PC2 的**管理員帳號**註冊（金鑰寫在 `administrators_authorized_keys`，只對管理員帳號有效），SSH 工作階段就是已提升的管理員權限，不會有 UAC 提示。本機管理員帳號安裝時會設定 `LocalAccountTokenFilterPolicy=1`（否則 Windows 會把本機帳號的遠端登入降成一般權限），原值會記錄，移除時還原。**這也會讓 SMB/WinRM 等遠端登入取得完整管理員權限**，請確保本機管理員帳號都有強密碼。 |
| Ubuntu | SSH 是非互動式，`sudo` 要密碼就會失敗。兩種做法：① 產生安裝資料夾時加 `-PasswordlessSudo`（授權免密碼 sudo，**等同 root**，移除時自動撤銷）；② 不加，需要 root 的操作請自己在 PC2 做。AI 一律用 `sudo -n`，不會也不應該取得你的密碼。 |

沒有權限時 pcx 會提出 `NO_ADMIN`（註冊時）、`ADMIN_REQUIRED` 或 `SUDO_PASSWORD_REQUIRED`（執行時）。

## 遇到無法自行解決的狀況：errorRequest

pcx 與安裝腳本遇到自己解決不了的問題時，會印出固定格式的區塊：

```
[errorRequest:AUTH_REJECTED]
  問題: ...
  需要: ...
```

請照「需要」欄位處理後再繼續；AI 看到時會停下來把內容轉告你。`[hint:...]` 只是提示（例如 `[hint:ENCODING]`），不是錯誤。

| 來源 | 代碼 |
|---|---|
| PC1 連線 | `SSH_CLIENT_MISSING`、`HOST_NOT_REGISTERED`、`DUPLICATE_HOST`、`AUTH_REJECTED`、`UNREACHABLE`、`SSH_NOT_RUNNING`、`DNS_FAILED`、`HOSTKEY_CHANGED`、`KEY_UNREADABLE`、`NETWORK_BLOCKED`、`CONNECT_FAILED` |
| 權限與執行 | `NO_ADMIN`、`ADMIN_REQUIRED`、`SUDO_PASSWORD_REQUIRED`、`RUN_TIMEOUT` |
| harden / 移除 | `HARDEN_PRECHECK_FAILED`、`HARDEN_NO_ADMIN`、`HARDEN_NO_SUDO`、`HARDEN_FAILED`、`HARDEN_VERIFY_FAILED`、`HARDEN_NOT_EFFECTIVE`、`TEARDOWN_FAILED`、`UNINSTALL_PARTIAL` |
| PC2 安裝（Windows） | `INVALID_ALLOW_FROM`、`WINDOWS_CAPABILITY_QUERY_FAILED`、`OPENSSH_NOT_AVAILABLE`、`OPENSSH_INSTALL_FAILED`、`SSHD_START_FAILED`、`NO_IP_ADDRESS` |
| PC2 安裝（Ubuntu） | `INVALID_ALLOW_FROM`、`NOT_DEBIAN`、`NO_SYSTEMD`、`APT_FAILED`、`APT_UPGRADE_FAILED`、`SSHD_START_FAILED`、`SUDOERS_INVALID`、`NO_IP_ADDRESS` |

各代碼的說明見 `pcx help errors`。

## 各種環境

| 環境 | 做法 |
|---|---|
| 區網 | 預設（`-AllowFrom LocalSubnet`） |
| 網線直連 | 兩邊手動設同網段固定 IP（例如 192.168.50.1 / .2），其餘相同 |
| VPN（Tailscale 等） | `pcx invite windows -AllowFrom 100.64.0.0/10`，`pcx add` 用 VPN 的 IP 或名稱 |
| 指定來源網段 | `pcx invite ubuntu -AllowFrom 192.168.1.0/24` |
| 雲端 VM | 通常已有 SSH 與金鑰：`pcx add vm1 ubuntu@公網IP -Key C:\keys\vm.pem`，不需要 invite |
| 經跳板機 | `pcx add pc2 admin@內網IP -Jump user@跳板機` |
| 非 22 埠 | `pcx add` 加 `-Port 2222` |

雲端不要把 22 埠對全網際網路開放：安全群組只允許你的固定 IP，或改走 VPN。

## 日常操作

```powershell
pcx pc2 "Get-Service sshd"            # Windows 用 PowerShell 語法；Ubuntu 用 bash
pcx pc2 -File .\fix.ps1               # 在 PC2 執行本機腳本（Ubuntu 用 .sh）
pcx put pc2 .\app.zip C:/temp/app.zip # 上傳（檔案或資料夾；Windows 遠端路徑用 C:/temp/x 形式）
pcx get pc2 /var/log/syslog .\syslog  # 下載
pcx list                              # 已註冊的電腦、連線目標、作業系統與 admin 狀態；同一台有多個名稱會標出
pcx status                            # 平行檢測所有已註冊電腦是否在線（約 5 秒內；有離線時結束碼為 1）
pcx clean                             # 清理「遠端存取已不存在」的註冊；離線的預設保留，確定不用再加 -IncludeOffline
pcx forget pc2                        # 只刪 PC1 本機的註冊紀錄，不連到 PC2（舊名 pcx remove 仍可用）
```

- 遠端指令預設最多執行 120 秒（`-RunTimeout` 可調），連線逾時 60 秒（`-Timeout`）。
- stdin 會被關閉，在等輸入的指令不會卡住，而是回報 `RUN_TIMEOUT`；請用非互動寫法（`apt -y`、`sudo -n`）。
- 中文 Windows 的輸出若亂碼，加 `-Encoding 950`。

## 一鍵移除

| 想做的事 | 指令 |
|---|---|
| 只移除某台 PC2 的遠端存取，並取消註冊 | `pcx teardown pc2` |
| 只刪 PC1 上的某個名稱，不動 PC2 | `pcx forget pc2` |
| **全部清乾淨（所有 PC2 + PC1）** | `pcx uninstall -All -Yes` |
| 只清 PC1，不動 PC2 | `pcx uninstall -Yes` |
| 連 OpenSSH Server 也一併卸載 | `teardown` / `uninstall` 加 `-UninstallServer` |
| 遠端移除失敗也照樣清 PC1 | `uninstall` 加 `-Force`（PC2 會留著你的金鑰授權） |
| PC1 已不在手邊，直接在 PC2 移除 | Windows：雙擊資料夾裡的 `REMOVE.cmd`　Ubuntu：`bash remove.sh` |

同一台主機有多個名稱時，`teardown` 會先警告並要你確認（`-Yes` 略過），成功後所有指向它的名稱都會取消註冊；只想刪掉多出來的名稱請用 `forget`。

PC2 依安裝時記下的「原本狀態」還原：只移除 pcx 自己的金鑰（其他金鑰保留）、還原防火牆規則、密碼登入設定、預設 shell 與 `LocalAccountTokenFilterPolicy`、撤銷免密碼 sudo；SSH 若是 pcx 裝的或原本沒在執行就停用，原本就在用的雲端 VM 不會被關掉。
PC1 會刪除 `pcx` 指令、`~\.pcx`、專用金鑰 `id_ed25519_pcx`、`~/.ssh/config` 裡 pcx 的區塊。

## 安全性與 OpenSSH 更新

- 密碼登入在安裝時維持原樣（避免金鑰沒生效時把自己鎖在外面）。`pcx add` 確認金鑰可用後，執行 `pcx harden <名稱>` 關閉密碼登入；它會先確認金鑰登入成功才動手，事後再確認金鑰仍可登入，並以不帶金鑰的連線確認 PC2 已不再提供 `password` / `keyboard-interactive`（沒關掉會回報 `HARDEN_NOT_EFFECTIVE`，不會標記為已關閉）。Ubuntu 的設定寫在 `/etc/ssh/sshd_config.d/00-pcx.conf`：sshd 對同一設定採用最先讀到的值，檔名排在最前面才不會被 `50-cloud-init.conf` 之類的檔案蓋過。用舊版 pcx harden 過的 Ubuntu，請重新執行一次 `pcx harden`。
- 來源限制（`-AllowFrom`，預設 `LocalSubnet`）分三層：
  1. **金鑰**：pcx 的公鑰在 PC2 上寫成 `from="<來源>",restrict ssh-ed25519 ... pcx`。私鑰就算外流，也不能從其他來源使用；`restrict` 關閉連接埠轉發、agent/X11 轉發與 pty（pcx 本來就不用這些）。`LocalSubnet` 在這裡代表私有網段（`10/8`、`172.16/12`、`192.168/16`、`169.254/16` 與 IPv6 的 `fc00::/7`、`fe80::/10`），PC2 換網路也不會被鎖在外面。
  2. **sshd（Ubuntu）**：在 `sshd_config` 最後加上 `Match Address` 區塊，不在允許來源的連線一律不接受密碼登入。ufw 沒啟用也有效，移除時還原。
  3. **防火牆**：Windows 一律設定防火牆規則；Ubuntu **只有在 ufw 已啟用時**才加規則。ufw 沒啟用（桌面版預設）時 22 埠仍對所有來源開放，但第 1、2 層照樣生效；這台電腦其他帳號的金鑰登入則不受限制，要在網路層擋掉請自行啟用 ufw。
  - `-AllowFrom Any` 會略過第 1、2 層的來源限制（`restrict` 仍會加上）。經跳板機時，跳板機若也是用 pcx 安裝的 PC2，因為 `restrict` 禁止轉發，無法當跳板。
  - 已經安裝過的 PC2 要套用新的限制，請用新版 `pcx invite` 重新產生安裝資料夾，在 PC2 再執行一次 `INSTALL.cmd` / `install.sh`（會更新同一把金鑰那一行，不會重複新增）。
- 不用時執行 `pcx teardown <名稱>`，SSH 就不會一直開著，這是最有效的防護。
- 腳本**不會自動升級** OpenSSH，只會在安裝結束時印出版本；Ubuntu 若有可用更新會提醒。
  - Ubuntu：評估後自行 `sudo apt install --only-upgrade openssh-server`；要在安裝時一起升級可加 `pcx invite ubuntu -UpgradeServer`（非互動、保留現有設定檔，但會重啟 sshd，並可能連帶升級 openssl/libc）。
  - Windows：OpenSSH 由 Windows Update 維護，請定期更新 Windows。
- 發現 OpenSSH 重大漏洞時，請對照 OpenSSH 官方公告與你的發行版安全追蹤（例如 [Ubuntu CVE](https://ubuntu.com/security/cves)、[Debian Security Tracker](https://security-tracker.debian.org/tracker/)）確認影響範圍。例如 2026 年 11 月公開的 [CVE-2026-123158](https://security-tracker.debian.org/tracker/CVE-2026-123158)（SSHole）主要影響使用 musl 且沒有 PAM 的系統（如 Alpine），緩解方式之一是關閉密碼登入，也就是 `pcx harden` 做的事。

## 注意

- 登入後的權限：Windows 是管理員，Ubuntu 是安裝時執行 `install.sh` 的帳號（加了 `-PasswordlessSudo` 就等同 root）。
- 專用金鑰 `~/.ssh/id_ed25519_pcx` 沒有加密碼（為了免輸入）。私鑰外洩就等於 PC2 被控制，請妥善保管；安裝時金鑰已加上 `from=` 來源限制（見上方「安全性」）；跨網路使用時建議搭配 VPN。
- PC1 的 AI 沙盒（例如 Codex）預設可能擋網路，`ssh` 會被擋（`NETWORK_BLOCKED`、`KEY_UNREADABLE`），需放寬沙盒或用核准模式。
- 網線直連沒設固定 IP 時，系統會自動配 `169.254.x.x`；安裝完成畫面會標註，建議改設固定 IP。
- Windows PC2 的 SSH 預設 shell 會設成 PowerShell 7（沒有就用 Windows PowerShell），所以遠端指令用 PowerShell 語法。
- 設定檔位置：已註冊電腦在 `~\.pcx\hosts.json`；連線設定在 `~\.ssh\config` 中的 `# >>> pcx <名稱> >>>` 區塊。
