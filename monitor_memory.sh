#!/usr/bin/env bash
set -euo pipefail
[[ -f /opt/monitoring/email.conf ]] && source /opt/monitoring/email.conf
SERVER_ID="${SERVER_ID:-$(hostname)}"
TEMPLATE_PATH="/opt/alerts/templates/memory-alert.html"
RECIPIENTS="RECIPIENTS_PLACEHOLDER"
MEM_THRESHOLD=90
MEM_INFO=$(free | grep Mem)
TOTAL_MEM=$(echo $MEM_INFO | awk '{print $2}')
USED_MEM=$(echo $MEM_INFO | awk '{print $3 + $6}')
MEM_USAGE=$(echo "scale=1; ($USED_MEM / $TOTAL_MEM) * 100" | bc -l)
if [[ $(echo "$MEM_USAGE > $MEM_THRESHOLD" | bc -l) == 1 ]]; then
  TOTAL_MB=$(echo "scale=0; $TOTAL_MEM / 1024" | bc)
  USED_MB=$(echo "scale=0; $USED_MEM / 1024" | bc)
  SYS_SNAP=$(top -b -n 1 2>/dev/null | head -35 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "top indisponivel")
  TOP_MEM=$(ps aux --sort=-%mem | head -26 | tail -25 | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd $i " "; printf "%-8s %-12s %5s %5s %.70s\n", $2, $1, $4, $3, substr(cmd,1,70)}')
  TOP_MEM_ESC=$(echo "$TOP_MEM" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  TOP_CPU=$(ps aux --sort=-%cpu | head -26 | tail -25 | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd $i " "; printf "%-8s %-12s %5s %5s %.70s\n", $2, $1, $3, $4, substr(cmd,1,70)}')
  TOP_CPU_ESC=$(echo "$TOP_CPU" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  MSG_HTML="Uso RAM: <strong>${MEM_USAGE}%</strong> (threshold: ${MEM_THRESHOLD}%)<br/>Total: ${TOTAL_MB}MB | Usado: ${USED_MB}MB<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Snapshot do sistema (top):</strong><br/><pre>${SYS_SNAP}</pre><br/><strong>Top 25 processos por RAM (PID USER %MEM %CPU COMANDO):</strong><br/><pre>${TOP_MEM_ESC}</pre><br/><strong>Top 25 processos por CPU:</strong><br/><pre>${TOP_CPU_ESC}</pre>"
  /usr/local/bin/send_html_alert.sh "$TEMPLATE_PATH" "$RECIPIENTS" "ALERTA RAM ${MEM_USAGE}% - ${SERVER_ID}" "Memoria em ${MEM_USAGE}% (CRITICO)" "$MSG_HTML"
  TG_TOP=$(ps aux --sort=-%mem | head -13 | tail -12 | awk '{printf "%-8s %4s %4s %.45s\n", $2, $4"%", $3"%", $11}')
  /usr/local/bin/send_telegram_alert.sh "ALERTA RAM ${MEM_USAGE}% - ${SERVER_ID}\n\nTop processos (PID %MEM %CPU CMD):\n${TG_TOP}" || true
  if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
  if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
    SNAP_ESC=$(echo "$SYS_SNAP" | sed 's/"/\\"/g' | tr '\n' ' ')
    printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","type":"memory","value":%s,"threshold":%s,"subject":"ALERTA RAM %s%% - %s","snapshot_top":"%s","notifications_sent":{"email":true,"telegram":true}}\n' \
      "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${MEM_USAGE}" "${MEM_THRESHOLD}" "${MEM_USAGE}" "${SERVER_ID}" "${SNAP_ESC}" | /usr/local/bin/send_dashboard_metrics.sh incident 2>/dev/null || true
  fi
fi
if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
  CPU_USAGE=$(timeout 3 mpstat 1 2 2>/dev/null | awk '/Average/ {print 100-$NF}' || echo "0")
  DISK_JSON=$(df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2 | while read -r FS SIZE USED AVAIL PCT MNT; do U="${PCT%%%}"; echo -n "{\"mount\":\"$MNT\",\"usage\":$U},"; done | sed 's/,$//')
  printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","metrics":{"cpu":%s,"memory":%s,"disk":[%s]}}\n' \
    "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${CPU_USAGE}" "${MEM_USAGE}" "${DISK_JSON:-}" | /usr/local/bin/send_dashboard_metrics.sh metrics 2>/dev/null || true
fi
