# SSH-Remote-Setup 開發資訊

> 用途：記錄這個工具的目標、架構、設計決策、已驗證與未驗證的部分、已知限制，方便日後維護或交接。
> 使用說明見 [README.md](README.md)；給 AI 的操作指引見 [AI-GUIDE.md](AI-GUIDE.md)。
> 最後整理日期：2026-11-23。目前沒有版本號。

## 1. 目標與範圍

- 讓 **PC1** 上的 AI CLI（Codex，可用自訂別名 `cloude` 啟動）能透過 SSH 操作 **PC2**，並讀回完整輸出與結束碼。
- PC2 只需開 OpenSSH，不安裝 AI、不登入任何帳號。
- 環境：區網、網線直連、VPN、雲端 VM、跳板機；PC2 以 Windows 為主，可能是 Ubuntu。
- 要求：設定與操作盡量簡單；用完可**一鍵完整移除**；遇到無法自行解決的狀況要明確提出需求（`errorRequest`）。
- 不在範圍：手機直接執行 `pcx`、一對多廣播指令（使用者明確表示不需要）、自動升級 OpenSSH、即時串流輸出（評估後省略）。

## 2. 檔案一覽

| 檔案 | 在哪台執行 | 作用 |
|---|---|---|
| `pcx.ps1` | PC1（PowerShell 7） | 主程式：安裝、產生 PC2 安裝資料夾、註冊、執行指令、傳檔、檢測、清理、移除 |
| `setup-remote.ps1` | PC2 Windows（管理員） | 安裝/啟動 OpenSSH Server、防火牆、寫入公鑰、預設 shell，並記錄原狀態 |
| `remove-remote.ps1` | PC2 Windows（管理員） | 依記錄的原狀態還原所有變更 |
| `setup-remote.sh` | PC2 Ubuntu | 安裝 `openssh-server`、ufw、公鑰、可選免密碼 sudo，並記錄原狀態 |
| `remove-remote.sh` | PC2 Ubuntu | 依記錄的原狀態還原所有變更 |
| `README.md` | — | 使用者說明 |
| `AI-GUIDE.md` | — | 給 AI 的逐步指引與規則 |
| `DEVELOPMENT.md` | — | 本文件 |

使用說明內建於 `pcx.ps1`（`$GuideText` 各節，與 README / AI-GUIDE 內容一致；改文件時要一併更新）：`pcx help [主題]` 印出完整說明，`pcx guide [名稱]` 是唯讀的引導流程，依 PC1 環境、全域指令、金鑰、`hosts.json`（含 `admin`、`hardened` 欄位；`hardened` 由 `pcx harden` 驗證成功後寫入）與 `AGENTS.md` 判斷進度並印出下一步。

`pcx invite` 會把 `setup-*` / `remove-*` 原樣複製成「給 PC2 的明文資料夾」（`pcx-pc2-windows` 或 `pcx-pc2-ubuntu`，內含 `pcx.pub`、`INSTALL.cmd` / `install.sh`、`REMOVE.cmd` / `remove.sh`、`README.txt`）。`-SingleFile` 才會產生 base64 內嵌的單一檔案。

## 3. 架構與資料流

```
PC1: AI CLI ──呼叫──> pcx.ps1 ──ssh/scp──> PC2: sshd ──> 指令
                         │                    ▲
                         └─ ~/.ssh/config 別名 + 專用金鑰 id_ed25519_pcx
```

1. `pcx invite` 在 PC1 建立專用 ed25519 金鑰（註解固定為 `pcx`），把公鑰與腳本放進資料夾。
2. 使用者把資料夾搬到 PC2 執行，PC2 開 SSH 並授權這把公鑰。
3. `pcx add` 寫入 `~/.ssh/config` 的區塊並測試連線；偵測作業系統（`uname -s`）與管理員/sudo 狀態，寫入 `hosts.json`。
4. `pcx <名稱> "<指令>"` 以 `ssh -T` 執行，stdin 關閉，有總逾時；輸出後印 `[exit code: N]`。

### 狀態存放位置

| 位置 | 內容 |
|---|---|
| PC1 `~\.pcx\hosts.json` | `{名稱: {os, admin}}` |
| PC1 `~\.pcx\` | `pcx install` 複製的腳本；`pcx.cmd` 捷徑（優先放 `%APPDATA%\npm`，否則放此處並加入使用者 PATH） |
| PC1 `~/.ssh/config` | 以 `# >>> pcx 名稱 >>>` 到 `# <<< pcx 名稱 <<<` 包住的區塊 |
| PC1 `~/.ssh/id_ed25519_pcx(.pub)` | 專用金鑰（無密碼） |
| PC2 Windows `%ProgramData%\ssh\pcx-state.json` | `installedServer, wasRunning, firewallExisted, prevRemoteAddress, prevEnabled, prevDefaultShell, setDefaultShell, passwordDisabled` |
| PC2 Windows 其他 | `administrators_authorized_keys`、防火牆規則 `OpenSSH-Server-In-TCP`、`sshd_config.pcx-bak`、暫時的排程工作 `pcx-remove` / `pcx-restart` |
| PC2 Ubuntu `/etc/ssh/pcx-state` | `installed_server`、`was_active`、`ufw=規則`、`password_disabled`、`sudoers` |
| PC2 Ubuntu 其他 | `~/.ssh/authorized_keys`、`/etc/ssh/sshd_config.d/99-remote.conf`、`/etc/sudoers.d/pcx` |

## 4. pcx 指令對照

| 指令 | 說明 |
|---|---|
| `install` | 複製腳本到 `~\.pcx`，建立 `pcx.cmd` |
| `invite windows\|ubuntu` | 產生給 PC2 的資料夾；選項 `-AllowFrom`、`-DisablePassword`、`-UpgradeServer`、`-PasswordlessSudo`、`-SingleFile`、`-Out` |
| `add 名稱 user@主機` | 註冊並測試；選項 `-Port`、`-Key`、`-Jump` |
| `<名稱> "<指令>"` / `-File` | 遠端執行；`-RunTimeout`（預設 120）、`-Timeout`（連線，預設 60）、`-Encoding` |
| `put` / `get` | 以 `scp -r` 傳檔 |
| `harden 名稱` | 確認金鑰可登入後關閉密碼登入，再驗證一次 |
| `list` / `status` / `clean` | 列出（含 admin）、平行檢測存活、清理已失效的註冊 |
| `remove` / `teardown` / `uninstall` | 取消本機註冊 / 移除遠端存取 / 全部移除 |
| `agents` | 在 `AGENTS.md` 寫入給 AI 的使用規則 |

結束碼：`124` 逾時、`255` ssh 連線層失敗、`3` harden 前置條件不足（遠端腳本內）、`1` 一般失敗。

## 5. 設計決策與理由

| 決策 | 理由 |
|---|---|
| 以 OpenSSH 為通道，不自製常駐程式 | 標準、可稽核，PC2 不需額外程式；任何 SSH 客戶端都能用 |
| 專用金鑰、不重用使用者既有金鑰 | 可單獨撤銷與清理；`pcx` 只刪註解為 `pcx` 的授權行 |
| 預設輸出「明文資料夾」，不用 base64 | base64 + `[scriptblock]::Create` 是惡意程式常見手法，易被 AMSI/防毒誤判；明文可被人與防毒檢視 |
| 安裝時記錄「原本狀態」，移除依此還原 | 避免關掉原本就在用的 SSH、或蓋掉使用者原有的防火牆/設定 |
| 遠端移除用排程工作（Windows）/ `setsid`（Ubuntu）延遲執行 | 移除會停掉正在使用的 SSH 連線，必須脫離該連線才不會中途中斷 |
| 密碼登入預設不關，改由 `pcx harden` 關閉 | 避免金鑰沒生效時鎖死；`harden` 先驗證金鑰、事後再驗證 |
| 防火牆預設只允許區網（`LocalSubnet`），可用 `-AllowFrom` 指定 | 降低暴露面；雲端/VPN 時由使用者明確指定來源 |
| 不自動升級 OpenSSH，預設只檢查並提醒；`-UpgradeServer` 才升級 | 升級會重啟 sshd、可能連帶升級相依套件，不應在使用者不知情時發生 |
| 遠端指令一律 `-T`、關閉 stdin、有總逾時 | 避免遠端等輸入（sudo 密碼、確認提示）卡住 AI |
| 輸出一次性擷取，不即時串流 | 見第 8 節 |
| `errorRequest` 固定格式 | 讓 AI 能機器判讀「需要人處理」並停下轉告，不自行繞過 |
| Windows 預設 shell 一律設定（pwsh 7，沒有就 Windows PowerShell） | 否則 OpenSSH 預設是 cmd.exe，PowerShell 語法會失敗 |

## 6. errorRequest 代碼

格式：`[errorRequest:代碼]` + `問題` + `需要`。AI 規則：立即停止、原樣轉告使用者、待回覆才繼續。`[hint:...]` 只是提示，AI 可自行處理。

| 來源 | 代碼 |
|---|---|
| `pcx.ps1` | `HOST_NOT_REGISTERED` `SSH_CLIENT_MISSING` `HOSTKEY_CHANGED` `KEY_UNREADABLE` `NETWORK_BLOCKED` `DNS_FAILED` `AUTH_REJECTED` `SSH_NOT_RUNNING` `UNREACHABLE` `CONNECT_FAILED` `SUDO_PASSWORD_REQUIRED` `ADMIN_REQUIRED` `NO_ADMIN` `RUN_TIMEOUT` `HARDEN_PRECHECK_FAILED` `HARDEN_FAILED` `HARDEN_VERIFY_FAILED` `TEARDOWN_FAILED` `UNINSTALL_PARTIAL` |
| `setup-remote.ps1` | `WINDOWS_CAPABILITY_QUERY_FAILED` `OPENSSH_NOT_AVAILABLE` `OPENSSH_INSTALL_FAILED` `SSHD_START_FAILED` `NO_IP_ADDRESS` |
| `setup-remote.sh` | `NOT_DEBIAN` `NO_SYSTEMD` `APT_FAILED` `APT_UPGRADE_FAILED` `SSHD_START_FAILED` `SUDOERS_INVALID` `NO_IP_ADDRESS` |
| harden 遠端腳本 | `HARDEN_NO_SUDO` `HARDEN_NO_ADMIN` |

新增代碼時：在對應位置加分支，並同步更新 README 的代碼清單。

## 7. 安全模型

- 登入後的權限：Windows 為管理員（金鑰寫入 `administrators_authorized_keys`），Ubuntu 為安裝時的帳號；加 `-PasswordlessSudo` 等同 root。**PC1 私鑰外洩 = 所有已授權的 PC2 被控制**。
- 專用金鑰沒有密碼（為了免互動）。跨網路使用建議搭配 VPN 或來源 IP 限制，並可自行用 `ssh-keygen -p` 加密碼（需搭配 ssh-agent，目前 `pcx` 未整合）。
- 所有 PC2 共用同一把金鑰；雲端 VM 可用 `-Key` 指定各自金鑰。
- 公鑰不是機密，zip 與安裝資料夾裡只有公鑰。
- 2026-11 的 OpenSSH 漏洞 CVE-2026-123158（sshhole）：依搜尋結果，主要影響 musl 且無 PAM 的 Linux（如 Alpine），緩解方式為關閉密碼認證；本工具的 `harden` 對應此緩解。**以上來自二手報導，未對照官方公告逐項驗證**。
- 防毒/EDR：開啟 SSH、改防火牆、以 SYSTEM 排程工作執行腳本等行為，在管理嚴格的環境仍可能被攔截或通報，需先取得 IT 同意。

## 8. 已知限制

| 項目 | 說明 |
|---|---|
| 非即時輸出 | 遠端指令結束後才一次輸出（逾時時保留已讀到的部分）。對 AI 工具無影響，對人看進度不便；若要改，需用 `Process` 的非同步讀取並同步存檔給錯誤分類用 |
| 一般使用者帳號 | Windows 版金鑰只授權管理員帳號；非管理員帳號無法登入或提權 |
| 共用金鑰 | 見第 7 節；目前沒有「新增第二把金鑰」或輪替金鑰的指令（例如給手機用的金鑰需手動加入） |
| `pcx.cmd` 捷徑 | 經 cmd 傳遞參數，含 `%`、`^`、`&` 的指令可能被改寫；複雜指令請用 `-File` |
| 中文 Windows 輸出 | 遠端 cp950 與 UTF-8 不一致時亂碼，需 `-Encoding 950`；ssh.exe 自己的錯誤訊息會以八進位跳脫顯示（僅外觀） |
| 長輸出 | 不截斷，可能塞滿 AI 上下文 |
| Windows 離線/受管環境 | `Add-WindowsCapability` 需連 Windows Update（WSUS、離線、1809 以前、LTSC 都可能失敗），已有 errorRequest 但無自動替代方案 |
| 睡眠 / DHCP | PC2 睡眠會離線，不支援網路喚醒；IP 變動需重新註冊 |
| 手機 | `pcx` 是 PowerShell 7 腳本，不能在手機執行；手機可用 SSH 客戶端直接連 PC2（用獨立金鑰），或經 PC1 跳板 |
| `status` 的測試 | 平行檢測使用 ssh 自己的設定位置，無法用「隔離 HOME」測試註冊於 `~/.ssh/config` 的主機 |

## 9. 測試紀錄

### 已驗證（在開發用的 PC1 上）

- 所有腳本語法：`pcx.ps1`、`setup-remote.ps1`、`remove-remote.ps1`（PowerShell 解析器 0 錯誤）、`setup-remote.sh`、`remove-remote.sh`（`bash -n`）。
- 在隔離的暫存 `HOME`/`APPDATA`（不碰真正的 `~/.ssh`）：
  - `invite windows|ubuntu`（資料夾與 `-SingleFile`）：結構、LF 換行、`pcx.pub` 註解、`INSTALL.cmd` / `install.sh` 內容、內嵌腳本可解碼且語法正確。
  - `install` → `uninstall -Yes`：檔案與使用者 PATH 皆清乾淨。
  - `status`、`clean`（假電腦）：離線判定、預設保留離線、`-IncludeOffline` 才清。
  - errorRequest 路徑：`HOST_NOT_REGISTERED`、`SSH_NOT_RUNNING`、`DNS_FAILED`、`UNREACHABLE`、`RUN_TIMEOUT`；結束碼 255、124、1 正確；`list` 顯示 admin 欄位。
  - 用真實 ssh 的「連線被拒」「逾時」訊息確認分類規則可比對。
- 發現並修正的錯誤：`ServerAliveCountMax` 參數優先序錯誤；`Show-Result` 回傳值混入輸出導致 `exit` 為 0。
- 打包：`SSH-Remote-Setup.zip` 解壓後 7 個檔案逐一比對雜湊一致，且 `pcx.ps1 help` 可執行。**此 zip 是 2026-11-11 的內容，不含本文件**，更新檔案後需重新壓縮並重算 `.sha256`。

### 尚未驗證（需在真正的 PC2 上實測）

- `pcx add`（含 OS 偵測、管理員/sudo 偵測）、`harden`、`teardown`、`uninstall -All`、`put` / `get`、`-File`。
- Windows：實際安裝 OpenSSH、防火牆、`administrators_authorized_keys` 權限、預設 shell、`harden` 以排程工作重啟 sshd、`REMOVE.cmd` 的還原。
- Ubuntu：`apt` 安裝/升級、ufw 規則、`-PasswordlessSudo`、`setsid` 延遲移除、`sudoers.d` 撤銷。
- 開著 Defender / 防毒的 PC2 是否攔截；`INSTALL.cmd` 的 `chcp 65001` 在不同語系下的顯示。
- Codex 沙盒下執行 `pcx`（沙盒使用者可能看不到 `~/.ssh` 與 `~\.pcx`、可能擋網路）。

## 10. 維護與測試方法

- **隔離測試**（避免動到真正的 `~/.ssh`）：先設定 `$env:USERPROFILE` 與 `$env:HOME` 為暫存資料夾，再以 `pwsh -File` 執行；`pcx.ps1` 以 `$HOME` 決定 `~\.pcx` 與 `~\.ssh` 位置。注意 `ssh.exe` 讀的是真正的設定位置。
- **語法檢查**：`[System.Management.Automation.Language.Parser]::ParseFile(...)`；`.sh` 轉 LF 後 `bash -n`。
- **修改腳本後**：`pcx invite` 會讀同資料夾的 `setup-remote.*` / `remove-remote.*`，改完請重新產生 PC2 資料夾；`pcx install` 過的機器需再執行一次 `install` 同步 `~\.pcx` 的副本。
- **換行**：`.sh` 一律 LF。產生資料夾與 Windows 的 `.cmd`（CRLF）由 `pcx invite` 處理。
- **新增 errorRequest**：同步更新本文件第 6 節與 README。

## 11. 開發背景紀錄

- Codex CLI 以 `npm install -g @openai/codex` 安裝（開發時為 0.167.1）；為了用 `cloude` 啟動，建立 `%APPDATA%\npm\cloude.cmd`（內容為呼叫 `codex`）。
- Codex 在 Windows 的沙盒（`[windows] sandbox = "elevated"`）會替工作目錄加存取權限（ACL）；在 `C:\Windows\System32` 啟動會因無法修改系統資料夾權限而失敗（`setup refresh had errors`），在使用者資料夾啟動則會對家目錄大量授權。建議在專案資料夾啟動，需要完整權限時改用放寬沙盒並搭配核准模式。
- 開發過程中的主要演進：單一安裝檔 → 加入還原狀態記錄與一鍵移除 → 檢測與清理 → 明文資料夾取代 base64 → 修正管理員/預設 shell/網線直連/逾時/鎖死風險並加入 `errorRequest`。

## 12. 待辦 / 可能的後續

- 在真正的 PC2（Windows 與 Ubuntu 各一）完整跑過第 9 節「尚未驗證」清單。
- 新增 `pcx addkey`（替手機或第二台 PC1 加入額外金鑰，並可單獨撤銷）。
- 每台電腦各用一把金鑰的選項；金鑰輪替。
- 整合 ssh-agent 以支援有密碼的金鑰。
- 輸出截斷選項（避免長輸出塞滿 AI 上下文）。
- 視需要改為即時串流輸出。
