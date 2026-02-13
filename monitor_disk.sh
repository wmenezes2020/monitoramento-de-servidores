#!/usr/bin/env bash
set -euo pipefail
[[ -f /opt/monitoring/email.conf ]] && source /opt/monitoring/email.conf
SERVER_ID="${SERVER_ID:-$(hostname)}"
TEMPLATE_PATH="/opt/alerts/templates/disk-alert.html"
RECIPIENTS="RECIPIENTS_PLACEHOLDER"
DISK_THRESHOLD=90
df -P -x tmpfs -x devtmpfs -x squashfs | tail -n +2 | while read -r FS SIZE USED AVAIL PCT MOUNT; do
  USAGE=${PCT%%%}
  if [[ "$USAGE" -gt "$DISK_THRESHOLD" ]]; then
    TOP_DIRS=$(timeout 15 du -h --max-depth=1 "$MOUNT" 2>/dev/null | sort -hr | head -21 | tail -20 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    SYS_SNAP=$(top -b -n 1 2>/dev/null | head -35 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "top indisponivel")
    MSG_HTML="Particao: <strong>${MOUNT}</strong><br/>Dispositivo: <strong>${FS}</strong><br/>Uso: <strong>${USAGE}%</strong> (threshold: ${DISK_THRESHOLD}%)<br/>Total: ${SIZE}K | Usado: ${USED}K | Livre: ${AVAIL}K<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Top diretorios em ${MOUNT}:</strong><br/><pre>${TOP_DIRS:-N/A}</pre><br/><strong>Snapshot do sistema (top):</strong><br/><pre>${SYS_SNAP}</pre>"
    /usr/local/bin/send_html_alert.sh "$TEMPLATE_PATH" "$RECIPIENTS" "ALERTA DISCO ${USAGE}% - ${SERVER_ID} (${MOUNT})" "Disco em ${USAGE}% (CRITICO) em ${MOUNT}" "$MSG_HTML"
    /usr/local/bin/send_telegram_alert.sh "ALERTA DISCO ${USAGE}% - ${SERVER_ID} ${MOUNT}

Top dirs:
${TOP_DIRS:-N/A}" || true
    if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
    if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
      SNAP_ESC=$(echo "$SYS_SNAP" | sed 's/"/\\"/g' | tr '\n' ' ')
      printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","type":"disk","value":%s,"threshold":%s,"mount":"%s","subject":"ALERTA DISCO %s%% - %s (%s)","snapshot_top":"%s","notifications_sent":{"email":true,"telegram":true}}\n' \
        "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${USAGE}" "${DISK_THRESHOLD}" "${MOUNT}" "${USAGE}" "${SERVER_ID}" "${MOUNT}" "${SNAP_ESC}" | /usr/local/bin/send_dashboard_metrics.sh incident 2>/dev/null || true
    fi
  fi
done
if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
  MEM_INFO=$(free | grep Mem 2>/dev/null)
  TOTAL_MEM=$(echo "$MEM_INFO" | awk '{print $2}')
  USED_MEM=$(echo "$MEM_INFO" | awk '{print $3+$6}')
  MEM_PCT=$(echo "scale=1; ($USED_MEM/$TOTAL_MEM)*100" 2>/dev/null | bc -l 2>/dev/null || echo "0")
  CPU_USAGE=$(timeout 3 mpstat 1 2 2>/dev/null | awk '/Average/ {print 100-$NF}' || echo "0")
  DISK_JSON=$(df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2 | while read -r FS SIZE USED AVAIL PCT MNT; do
    U="${PCT%%%}"; echo -n "{\"mount\":\"$MNT\",\"usage\":$U},"; done | sed 's/,$//')
  printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","metrics":{"cpu":%s,"memory":%s,"disk":[%s]}}\n' \
    "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${CPU_USAGE}" "${MEM_PCT}" "${DISK_JSON:-}" | /usr/local/bin/send_dashboard_metrics.sh metrics 2>/dev/null || true
fi
