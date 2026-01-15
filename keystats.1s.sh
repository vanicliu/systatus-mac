#!/bin/zsh
set -euo pipefail

# ===== 配置 =====
CACHE_FILE="/tmp/swiftbar_sysinfo_cache.txt"
CACHE_TS_FILE="/tmp/swiftbar_sysinfo_cache_ts.txt"
SYSINFO_INTERVAL=5  # 秒
NET_CACHE_FILE="/tmp/swiftbar_net_cache.txt"
# 右侧列（Upload / VPN / CPU）起始列位置（字符列，基于等宽字体 Menlo）
RIGHT_COL=28
LEFT_MAX=$((RIGHT_COL - 1))

# ===== 找默认网卡 =====
pick_iface() {
  local iface="$1"
  if [[ -n "$iface" && "$iface" != lo0 ]]; then
    echo "$iface"
    return
  fi

  local out=""
  out=$(/usr/sbin/netstat -ibn 2>/dev/null | /usr/bin/awk '
    $1 != "" {
      iface=$1;
      if (iface ~ /^lo0$/) next;
      rx=$7+0; tx=$10+0; total=rx+tx;
      if (total > max) {max=total; best=iface;}
    }
    END{if (best!="") print best}
  ' || true)
  if [[ -n "$out" ]]; then
    echo "$out"
    return
  fi

  out=$(/usr/bin/sudo -n /usr/sbin/netstat -ibn 2>/dev/null | /usr/bin/awk '
    $1 != "" {
      iface=$1;
      if (iface ~ /^lo0$/) next;
      rx=$7+0; tx=$10+0; total=rx+tx;
      if (total > max) {max=total; best=iface;}
    }
    END{if (best!="") print best}
  ' || true)
  if [[ -n "$out" ]]; then
    echo "$out"
    return
  fi

  echo "en0"
}

IFACE=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}' || true)
IFACE="$(pick_iface "$IFACE")"

read_bytes() {
  local netstat_out="" out="" rx=0 tx=0
  netstat_out=$(/usr/sbin/netstat -ibn 2>/dev/null || true)
  if [[ -z "$netstat_out" || "$netstat_out" == Name* ]]; then
    netstat_out=$(/usr/bin/sudo -n /usr/sbin/netstat -ibn 2>/dev/null || true)
  fi

  if [[ -n "$netstat_out" ]]; then
    out=$(echo "$netstat_out" | /usr/bin/awk -v iface="$IFACE" '
      $1 == iface {
        rx += $7; tx += $10; found = 1
      }
      END { if (found) print rx+0, tx+0 }
    ')
    if [[ -n "$out" ]]; then
      read -r rx tx <<<"$out"
    fi

    if (( rx + tx == 0 )); then
      out=$(echo "$netstat_out" | /usr/bin/awk '
        $1 == "Name" { next }
        $1 == "lo0" { next }
        $1 != "" {
          iface = $1
          rx[iface] += $7
          tx[iface] += $10
          total = rx[iface] + tx[iface]
          if (total > max) {
            max = total; best = iface
          }
        }
        END {
          if (best != "") print best, rx[best]+0, tx[best]+0
        }
      ')
      if [[ -n "$out" ]]; then
        read -r IFACE rx tx <<<"$out"
      fi
    fi
  fi

  echo "${rx:-0} ${tx:-0}"
}

human_rate() {
  # bytes per second -> human string
  /usr/bin/awk -v b="$1" 'BEGIN{
    if (b < 1024)            printf("%d B/s", b);
    else if (b < 1024^2)     printf("%.1f KB/s", b/1024);
    else if (b < 1024^3)     printf("%.1f MB/s", b/1024/1024);
    else                     printf("%.2f GB/s", b/1024/1024/1024);
  }'
}

get_battery_pct() {
  /usr/bin/pmset -g batt 2>/dev/null | /usr/bin/awk '
    NR==2 {
      match($0, /[0-9]+%/);
      if (RSTART > 0) print substr($0, RSTART, RLENGTH);
    }
  '
}

get_wifi_name() {
  /usr/sbin/networksetup -listpreferredwirelessnetworks en0 2>/dev/null | /usr/bin/sed -n '2 p' | /usr/bin/tr -d '\t'
}

get_vpn_status() {
  /usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/awk '
    /Connected/ {found=1}
    END {print (found ? "ON" : "OFF")}
  '
}

format_two_col() {
  local left_label="$1" left_value="$2" right_label="$3" right_value="$4"
  local left="${left_label} ${left_value}"
  if (( ${#left} > LEFT_MAX )); then
    left="${left:0:$((LEFT_MAX-2))}.."
  fi
  local pad=$((RIGHT_COL - ${#left}))
  (( pad < 1 )) && pad=1
  /usr/bin/printf "%s%*s%s %s" "$left" "$pad" "" "$right_label" "$right_value"
}

# ===== 网速（基于缓存的上次采样，避免 sleep）=====
read -r rx_now tx_now <<<"$(read_bytes)"
now_epoch=$(/bin/date +%s)

rx_last=0
tx_last=0
ts_last=0
if [[ -f "$NET_CACHE_FILE" ]]; then
  read -r rx_last tx_last ts_last < "$NET_CACHE_FILE" || true
fi

dt=$((now_epoch - ts_last))
if (( dt <= 0 )); then
  dt=1
fi

RX=$(((rx_now - rx_last) / dt)); ((RX<0)) && RX=0
TX=$(((tx_now - tx_last) / dt)); ((TX<0)) && TX=0

echo "$rx_now $tx_now $now_epoch" > "$NET_CACHE_FILE"

RX_H="$(human_rate "$RX")"
TX_H="$(human_rate "$TX")"

# ===== 系统信息（5s 刷新：写缓存；其他时间读缓存）=====
last_epoch=0
if [[ -f "$CACHE_TS_FILE" ]]; then
  last_epoch="$(/bin/cat "$CACHE_TS_FILE" 2>/dev/null || echo 0)"
fi

update_sysinfo() {
  # CPU
  CPU_LINE="$({ /usr/bin/top -l 2 -n 0 2>/dev/null | /usr/bin/grep '^CPU usage' | /usr/bin/tail -n 1; } || true)"
  if [[ -n "$CPU_LINE" ]]; then
    CPU_IDLE="$(echo "$CPU_LINE" | /usr/bin/awk -F'[:,%]' '{gsub(/ /,"",$6); print $6}')"
    CPU_USED="$(/usr/bin/awk -v idle="$CPU_IDLE" 'BEGIN{printf("%d", 100-idle+0.5)}')"
  else
    CPU_USED="0"
  fi

  BATT_PCT="$(get_battery_pct)"
  [[ -z "$BATT_PCT" ]] && BATT_PCT="--%"

  # Memory
  PAGE_SIZE=$(/usr/bin/vm_stat | /usr/bin/awk '/page size of/ {gsub("\\.","",$8); print $8}')
  VM=$(/usr/bin/vm_stat)

  P_FREE=$(echo "$VM" | /usr/bin/awk '/Pages free/ {gsub("\\.","",$3); print $3}')
  P_ACTIVE=$(echo "$VM" | /usr/bin/awk '/Pages active/ {gsub("\\.","",$3); print $3}')
  P_INACTIVE=$(echo "$VM" | /usr/bin/awk '/Pages inactive/ {gsub("\\.","",$3); print $3}')
  P_SPEC=$(echo "$VM" | /usr/bin/awk '/Pages speculative/ {gsub("\\.","",$3); print $3}')
  P_WIRED=$(echo "$VM" | /usr/bin/awk '/Pages wired down/ {gsub("\\.","",$4); print $4}')
  P_COMP=$(echo "$VM" | /usr/bin/awk '/Pages occupied by compressor/ {gsub("\\.","",$5); print $5}')

  TOTAL_MEM=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)
  if [[ -z "$TOTAL_MEM" || "$TOTAL_MEM" == "0" ]]; then
    # fallback to vm_stat total if sysctl is unavailable
    USED_PAGES=$((P_ACTIVE + P_INACTIVE + P_WIRED + P_COMP))
    TOTAL_PAGES=$((USED_PAGES + P_FREE))
    TOTAL_MEM=$((TOTAL_PAGES * PAGE_SIZE))
  fi

  # "Not easily reclaimable" ≈ Active + Wired + Compressed
  USED_MEM=$(((P_ACTIVE + P_WIRED + P_COMP) * PAGE_SIZE))

  used_gb=$(/usr/bin/awk -v b="$USED_MEM" 'BEGIN{printf("%.0f", b/1024/1024/1024)}')
  total_gb=$(/usr/bin/awk -v b="$TOTAL_MEM" 'BEGIN{printf("%.0f", b/1024/1024/1024)}')
  mem_pct=$(/usr/bin/awk -v u="$USED_MEM" -v t="$TOTAL_MEM" 'BEGIN{printf("%d", (u/t)*100 + 0.5)}')

  # Disk (use Data volume on modern macOS for real usage)
  DISK_PATH="/"
  [[ -d "/System/Volumes/Data" ]] && DISK_PATH="/System/Volumes/Data"
  DF=$(/bin/df -k "$DISK_PATH" | /usr/bin/tail -n 1)
  DISK_USED_K=$(echo "$DF" | /usr/bin/awk '{print $3}')
  DISK_TOTAL_K=$(echo "$DF" | /usr/bin/awk '{print $2}')
  DISK_PCT=$(/usr/bin/awk -v u="$DISK_USED_K" -v t="$DISK_TOTAL_K" 'BEGIN{printf("%d", (u/t)*100 + 0.5)}')

  disk_used_gb=$(/usr/bin/awk -v k="$DISK_USED_K" 'BEGIN{printf("%.1f", k/1024/1024)}')
  disk_total_gb=$(/usr/bin/awk -v k="$DISK_TOTAL_K" 'BEGIN{printf("%.1f", k/1024/1024)}')

  {
    format_two_col "🔋 Battery:" "$BATT_PCT" "⚙️ CPU:" "${CPU_USED}%"
    echo
    echo "🧠 Memory: ${used_gb}GB / ${total_gb}GB (${mem_pct}%)"
    echo "🗄️ Disk: ${disk_used_gb}GB / ${disk_total_gb}GB (${DISK_PCT}%)"
  } > "$CACHE_FILE"

  echo "$now_epoch" > "$CACHE_TS_FILE"
}

# 如果缓存超过 5 秒或不存在，就更新
if [[ ! -f "$CACHE_FILE" ]] || (( now_epoch - last_epoch >= SYSINFO_INTERVAL )); then
  update_sysinfo
fi

SYSINFO="$(/bin/cat "$CACHE_FILE" 2>/dev/null || true)"

# ===== SwiftBar 输出 =====
# 菜单栏：电量低时显示图标+百分比，否则只显示图标
BATT_PCT="$(get_battery_pct)"
BATT_NUM="${BATT_PCT%%%}"
if [[ -n "$BATT_NUM" && "$BATT_NUM" -lt 30 ]]; then
  echo "📊 $BATT_PCT"
else
  echo "📊"
fi

# 下拉菜单：你想要的格式（网速+系统信息）
# SwiftBar 菜单项样式：用等宽字体保证两列对齐（多空格不会被“视觉压缩”）
ITEM_OPTS="color=black font=SF Mono size=13 bash=/usr/bin/true terminal=false"
echo "---"
NET_LINE="$(format_two_col "📉 Download:" "$RX_H" "📈 Upload:" "$TX_H")"
echo "$NET_LINE | $ITEM_OPTS"
echo "---"
WIFI_NAME="$(get_wifi_name)"
[[ -z "$WIFI_NAME" ]] && WIFI_NAME="无"
VPN_STATUS="$(get_vpn_status)"
WIFI_LINE="$(format_two_col "📡 WiFi:" "$WIFI_NAME" "🔐 VPN:" "$VPN_STATUS")"
echo "$WIFI_LINE | $ITEM_OPTS"
echo "---"
while IFS= read -r line; do
  if [[ -n "$line" ]]; then
    echo "$line | $ITEM_OPTS"
    echo "---"
  fi
done <<< "$SYSINFO"
