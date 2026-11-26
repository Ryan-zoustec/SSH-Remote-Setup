#!/usr/bin/env bash
# 一鍵還原 setup-remote.sh 的所有變更 (依 /etc/ssh/pcx-state 回到安裝前的狀態)。
#   ./remove-remote.sh                    移除 pcx 金鑰、ufw 規則、密碼登入設定，並視情況停用 SSH
#   ./remove-remote.sh --uninstall-server 連 openssh-server 一併移除 (僅限 pcx 當初裝的)
#   --delayed: 先等 3 秒再執行並刪除自己 (給 pcx teardown 從遠端觸發用)
set -u

DELAYED=0; UNINSTALL=0
for a in "$@"; do
  case "$a" in --delayed) DELAYED=1 ;; --uninstall-server) UNINSTALL=1 ;; esac
done
[ "$DELAYED" -eq 1 ] && sleep 3

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

# 1. 移除 pcx 金鑰 (只刪註解為 pcx 的那一行；一般使用者權限即可)
AK="$TARGET_HOME/.ssh/authorized_keys"
if [ -f "$AK" ]; then
  grep -vE '[[:space:]]pcx[[:space:]]*$' "$AK" > "$AK.pcx.tmp" || true
  if [ -s "$AK.pcx.tmp" ]; then cat "$AK.pcx.tmp" > "$AK"; else rm -f "$AK"; fi
  rm -f "$AK.pcx.tmp"
fi

# 2. 其餘需要 root：可 sudo 就自動提權，否則只做到金鑰移除
if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true 2>/dev/null; then exec sudo -n -E bash "$0" "$@"; fi
  echo "已移除 pcx 金鑰。沒有 root 權限，SSH 服務與防火牆設定未變動。"
  [ "$DELAYED" -eq 1 ] && rm -f "$0"
  exit 0
fi

STATE=/etc/ssh/pcx-state
if [ ! -f "$STATE" ]; then
  echo "找不到 pcx 的安裝紀錄：只移除了 pcx 金鑰，其餘設定未變動。"
else
  rm -f /etc/ssh/sshd_config.d/00-pcx.conf /etc/ssh/sshd_config.d/99-remote.conf   # 99-remote.conf 是舊版 pcx 的檔名
  sed -i '/^# >>> pcx >>>$/,/^# <<< pcx <<<$/d' /etc/ssh/sshd_config                 # sshd 層的來源限制
  grep -qx 'sudoers=1' "$STATE" && rm -f /etc/sudoers.d/pcx   # 撤銷免密碼 sudo
  if command -v ufw >/dev/null; then
    grep '^ufw=' "$STATE" | cut -d= -f2- | while read -r spec; do ufw delete allow $spec >/dev/null 2>&1 || true; done
  fi
  installed_server=0; was_active=1
  grep -qx 'installed_server=1' "$STATE" && installed_server=1
  grep -qx 'was_active=0' "$STATE" && was_active=0
  if [ "$installed_server" -eq 1 ] || [ "$was_active" -eq 0 ]; then
    systemctl disable --now ssh 2>/dev/null || true
    [ "$UNINSTALL" -eq 1 ] && [ "$installed_server" -eq 1 ] && apt-get purge -y openssh-server >/dev/null 2>&1
  else
    systemctl reload ssh 2>/dev/null || true
  fi
  rm -f "$STATE"
  echo "已還原：金鑰、防火牆、SSH 設定與服務都回到安裝前的狀態。"
fi

[ "$DELAYED" -eq 1 ] && rm -f "$0"
exit 0
