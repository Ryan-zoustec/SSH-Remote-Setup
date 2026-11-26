#!/usr/bin/env bash
# 在「被管理的 Ubuntu 電腦」上執行：安裝 OpenSSH Server，只允許金鑰登入並限制連入來源。
# 動手前的狀態會記錄到 /etc/ssh/pcx-state，remove-remote.sh 依此完整還原。
# 用法: ./setup-remote.sh "ssh-ed25519 AAAA... pcx" [--no-password]
#       ./setup-remote.sh /path/id.pub --no-password
# 環境變數 ALLOW_FROM: LocalSubnet (預設) | 網段/IP (逗號分隔) | Any
set -euo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo -E bash "$0" "$@"

# 無法自行解決時，輸出固定格式的 errorRequest，請使用者處理
fail_request() {
  echo "[errorRequest:$1]"; echo "  問題: $2"; echo "  需要: $3"; exit 1
}

KEY=""; NOPASS=0; UPGRADE=0; SUDO_NOPASS=0
for a in "$@"; do
  case "$a" in
    --no-password) NOPASS=1 ;;
    --upgrade) UPGRADE=1 ;;
    --sudo-nopasswd) SUDO_NOPASS=1 ;;
    *) KEY="$a" ;;
  esac
done
[ -n "$KEY" ] || { echo "用法: $0 \"<公鑰內容或.pub路徑>\" [--no-password] [--upgrade] [--sudo-nopasswd]"; exit 1; }
[ -f "$KEY" ] && KEY="$(tr -d '\r\n' < "$KEY")"
case "$KEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
  *) echo "公鑰格式不正確"; exit 1 ;;
esac

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
STATE=/etc/ssh/pcx-state
ALLOW="${ALLOW_FROM:-LocalSubnet}"

# 來源限制：把 ALLOW_FROM 轉成 CIDR 清單 (用於 authorized_keys 的 from= 與 sshd 的 Match Address)。
#   LocalSubnet => 私有網段 (網路變動也不會被鎖在外面)；Any => 不限制 (空字串)
PRIVATE_NETS="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,127.0.0.0/8,fc00::/7,fe80::/10,::1/128"
SRC_NETS=""
IFS=',' read -ra _ITEMS <<< "$ALLOW"
for _it in "${_ITEMS[@]}"; do
  _it="$(printf '%s' "$_it" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$_it" ] || continue
  case "$_it" in
    Any) SRC_NETS=""; break ;;
    LocalSubnet) _it="$PRIVATE_NETS" ;;
    *) printf '%s' "$_it" | grep -qE '^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$' \
         || fail_request INVALID_ALLOW_FROM "來源限制格式不正確: $_it" "請用 LocalSubnet、Any，或 IP / CIDR 網段 (例如 192.168.1.0/24)，多個以逗號分隔。" ;;
  esac
  SRC_NETS="${SRC_NETS:+$SRC_NETS,}$_it"
done

command -v apt-get >/dev/null || fail_request NOT_DEBIAN "這台電腦沒有 apt-get，這個安裝只支援 Ubuntu/Debian 系列。" "請手動安裝並啟用 OpenSSH Server，再把 pcx.pub 的內容加入 ~/.ssh/authorized_keys。"
[ -d /run/systemd/system ] || fail_request NO_SYSTEMD "這個環境沒有執行 systemd (可能是 WSL 或容器)，無法用 systemctl 管理 SSH 服務。" "請改在實體機/VM 上執行，或手動啟動 sshd 並自行設定開機啟動。"

installed_before=0; dpkg -s openssh-server >/dev/null 2>&1 && installed_before=1
was_active=0; systemctl is-active --quiet ssh 2>/dev/null && was_active=1
apt-get update -y >/dev/null 2>&1 || true
if [ "$installed_before" -eq 0 ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server >/dev/null \
    || fail_request APT_FAILED "安裝 openssh-server 失敗 (可能沒有網路、軟體來源不可用，或 apt 被其他程式鎖住，例如正在自動更新)。" "請確認這台電腦能上網，等其他 apt/更新程序結束後重新執行安裝。"
elif [ "$UPGRADE" -eq 1 ]; then
  # 選用：只升級 openssh-server (非互動、保留現有設定檔)；不會動其他套件的資料
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
    -o Dpkg::Options::=--force-confold openssh-server >/dev/null \
    || fail_request APT_UPGRADE_FAILED "升級 openssh-server 失敗 (網路問題或 apt 被鎖住)。" "稍後重試；或不加 --upgrade 先完成連線設定。"
fi
if [ ! -f "$STATE" ]; then
  { echo "installed_server=$((1 - installed_before))"; echo "was_active=$was_active"; } > "$STATE"
fi
systemctl enable --now ssh || fail_request SSHD_START_FAILED "ssh 服務無法啟動。" "請執行 systemctl status ssh 與 journalctl -u ssh 查看原因 (常見: 22 埠被佔用、設定檔錯誤)。"

# 公鑰：加上 from= (只接受來自允許來源的連線，私鑰外流也無法從別處使用) 與 restrict (關閉轉發/agent/X11/pty)
install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.ssh"
AK="$TARGET_HOME/.ssh/authorized_keys"
touch "$AK"
KEY_BODY="$(echo "$KEY" | awk '{print $2}')"
OPTS="restrict"; [ -n "$SRC_NETS" ] && OPTS="from=\"$SRC_NETS\",restrict"
# 同一把金鑰已存在 (舊版沒有選項，或來源不同) 時先移除舊行再寫入
grep -vF -- "$KEY_BODY" "$AK" > "$AK.pcx.tmp" || true
cat "$AK.pcx.tmp" > "$AK"; rm -f "$AK.pcx.tmp"
echo "$OPTS $KEY" >> "$AK"
chown "$TARGET_USER:$TARGET_USER" "$AK"; chmod 600 "$AK"

# 可選：授權免密碼 sudo (等同 root；移除時會撤銷)。SSH 是非互動式，沒有它就無法使用需要 root 的操作
if [ "$SUDO_NOPASS" -eq 1 ]; then
  if [ "$TARGET_USER" = "root" ]; then
    echo "略過 --sudo-nopasswd：目前登入的就是 root。"
  else
    echo "$TARGET_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/pcx
    chmod 440 /etc/sudoers.d/pcx
    if ! visudo -cf /etc/sudoers.d/pcx >/dev/null 2>&1; then
      rm -f /etc/sudoers.d/pcx
      fail_request SUDOERS_INVALID "寫入 sudoers 設定後驗證失敗，已還原，未授權免密碼 sudo。" "請手動檢查 /etc/sudoers 設定，或不使用 --sudo-nopasswd。"
    fi
    grep -qxF "sudoers=1" "$STATE" || echo "sudoers=1" >> "$STATE"
    echo "已授權 $TARGET_USER 免密碼 sudo (等同 root，請妥善保管 PC1 的私鑰)。"
  fi
fi

# 防火牆 (ufw 啟用時才處理)
UFW_ACTIVE=0
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  UFW_ACTIVE=1
  add_rule() { ufw allow $1 >/dev/null; grep -qxF "ufw=$1" "$STATE" || echo "ufw=$1" >> "$STATE"; }
  if [ "$ALLOW" = "Any" ]; then
    add_rule "22/tcp"
  else
    IFS=',' read -ra ITEMS <<< "$ALLOW"
    for item in "${ITEMS[@]}"; do
      item="$(echo "$item" | xargs)"
      [ "$item" = "LocalSubnet" ] && item="$(ip -4 route show scope link | awk 'NR==1{print $1}')"
      [ -n "$item" ] && add_rule "from $item to any port 22 proto tcp"
    done
  fi
fi

# sshd 層的來源限制：不在允許來源的連線一律不接受密碼登入 (不依賴 ufw；ufw 沒啟用時也有效)。
#   寫在 sshd_config 最後面並以標記包住 (Match 區塊必須在檔案最後)，移除時依標記刪除。
SSHD_CFG=/etc/ssh/sshd_config
sed -i '/^# >>> pcx >>>$/,/^# <<< pcx <<<$/d' "$SSHD_CFG"
if [ -n "$SRC_NETS" ]; then
  [ -n "$(tail -c1 "$SSHD_CFG")" ] && echo >> "$SSHD_CFG"
  NEG="$(echo "$SRC_NETS" | sed 's/[^,]*/!&/g')"
  printf '%s\n' "# >>> pcx >>>" "Match Address 0.0.0.0/0,::/0,$NEG" \
    "    PasswordAuthentication no" "    KbdInteractiveAuthentication no" "# <<< pcx <<<" >> "$SSHD_CFG"
  if sshd -t 2>/dev/null; then
    grep -qxF "sshd_match=1" "$STATE" || echo "sshd_match=1" >> "$STATE"
  else
    sed -i '/^# >>> pcx >>>$/,/^# <<< pcx <<<$/d' "$SSHD_CFG"
    echo "警告: 這版 sshd 不接受來源限制設定，已略過 (金鑰的 from= 限制仍有效)。"
  fi
fi
if [ "$UFW_ACTIVE" -eq 0 ] && [ -n "$SRC_NETS" ]; then
  echo "注意: ufw 沒有啟用，22 埠仍對所有來源開放。pcx 的金鑰只接受來自 $ALLOW 的連線，其他來源也不能用密碼登入；"
  echo "      但這台電腦其他帳號的金鑰登入不受限制。要在網路層擋掉，請自行啟用 ufw。"
fi

# 可選：關閉密碼登入。檔名用 00- 開頭：sshd 對同一設定採用「最先讀到的值」，
#   用 99- 會被 50-cloud-init.conf 等檔案的 PasswordAuthentication yes 蓋過。
if [ "$NOPASS" -eq 1 ]; then
  rm -f /etc/ssh/sshd_config.d/99-remote.conf   # 舊版 pcx 的檔名
  printf '%s\n' "PasswordAuthentication no" "KbdInteractiveAuthentication no" > /etc/ssh/sshd_config.d/00-pcx.conf
  grep -qxF "password_disabled=1" "$STATE" || echo "password_disabled=1" >> "$STATE"
fi
systemctl reload ssh

echo "OpenSSH Server 版本: $(dpkg-query -W -f='${Version}' openssh-server)"
if apt list --upgradable 2>/dev/null | grep -q '^openssh-server/'; then
  echo "提醒: openssh-server 有可用更新，建議評估後升級: sudo apt install --only-upgrade openssh-server"
fi
IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' || true)"
[ -n "$IPS" ] || fail_request NO_IP_ADDRESS "SSH 已安裝，但這台電腦目前沒有 IPv4 位址 (沒接網路?)。" "請接上網路或用網線直連 PC1 並設定同網段固定 IP，再自行查 IP。"
echo "完成。從 PC1 註冊："
echo "$IPS" | while read -r ip; do
  case "$ip" in 169.254.*) note="   (自動配置位址：網線直連且沒設固定 IP 時才會出現，建議改設固定 IP)" ;; *) note="" ;; esac
  echo "  pcx add pc2 $TARGET_USER@$ip$note"
done
