#!/usr/bin/env bash
#
# Atualiza os scripts de monitoramento para a versao mais recente (relatorios
# completos com snapshot top, top 25 processos, etc.) preservando configuracoes.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/wmenezes2020/monitoramento-de-servidores/main/update_scripts.sh | sudo bash
#   ou: sudo ./update_scripts.sh
#
set -euo pipefail

log() { echo "[update_scripts] $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  log "Execute como root: sudo bash -s"
  exit 1
fi

for f in /usr/local/bin/monitor_cpu.sh /usr/local/bin/monitor_memory.sh /usr/local/bin/monitor_disk.sh; do
  if [[ ! -f "$f" ]]; then
    log "Erro: $f nao encontrado. Execute o instalador primeiro."
    exit 1
  fi
done

# Extrai configuracao dos scripts atuais
RECIPIENTS=$(grep -m1 'RECIPIENTS=' /usr/local/bin/monitor_cpu.sh 2>/dev/null | sed 's/.*RECIPIENTS="\([^"]*\)".*/\1/' || true)
[[ "$RECIPIENTS" == "RECIPIENTS_PLACEHOLDER" || "$RECIPIENTS" == *"PLACEHOLDER"* ]] && RECIPIENTS=""
CPU_THRESHOLD=$(grep -m1 '^CPU_THRESHOLD=' /usr/local/bin/monitor_cpu.sh 2>/dev/null | sed 's/.*=\([0-9]*\).*/\1/' || echo "90")
MEM_THRESHOLD=$(grep -m1 '^MEM_THRESHOLD=' /usr/local/bin/monitor_memory.sh 2>/dev/null | sed 's/.*=\([0-9]*\).*/\1/' || echo "90")
DISK_THRESHOLD=$(grep -m1 '^DISK_THRESHOLD=' /usr/local/bin/monitor_disk.sh 2>/dev/null | sed 's/.*=\([0-9]*\).*/\1/' || echo "90")

if [[ -z "$RECIPIENTS" ]]; then
  log "AVISO: nao foi possivel extrair RECIPIENTS. Os e-mails de alerta nao serao enviados."
  log "Edite manualmente RECIPIENTS= em /usr/local/bin/monitor_cpu.sh (e memory/disk) com os e-mails."
fi

log "Preservando: RECIPIENTS=${RECIPIENTS:-'(vazio)'} CPU=${CPU_THRESHOLD}% RAM=${MEM_THRESHOLD}% DISCO=${DISK_THRESHOLD}%"

# Backup antes de sobrescrever
for f in monitor_cpu monitor_memory monitor_disk; do
  cp -a "/usr/local/bin/${f}.sh" "/usr/local/bin/${f}.sh.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
done

# --- monitor_cpu.sh ---
cat > /usr/local/bin/monitor_cpu.sh << 'MONITORCPU'
#!/usr/bin/env bash
set -euo pipefail
[[ -f /opt/monitoring/email.conf ]] && source /opt/monitoring/email.conf
SERVER_ID="${SERVER_ID:-$(hostname)}"
TEMPLATE_PATH="/opt/alerts/templates/cpu-alert.html"
RECIPIENTS="RECIPIENTS_PLACEHOLDER"
CPU_THRESHOLD=90
CPU_USAGE=$(timeout 3 mpstat 1 2 2>/dev/null | awk '/Average/ {print 100 - $NF}')
if [[ $(echo "$CPU_USAGE > $CPU_THRESHOLD" | bc -l) == 1 ]]; then
  SYS_SNAP=$(top -b -n 1 2>/dev/null | head -35 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "top indisponivel")
  TOP_CPU=$(ps aux --sort=-%cpu | head -26 | tail -25 | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd $i " "; printf "%-8s %-12s %5s %5s %.70s\n", $2, $1, $3, $4, substr(cmd,1,70)}')
  TOP_CPU_ESC=$(echo "$TOP_CPU" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  TOP_MEM=$(ps aux --sort=-%mem | head -26 | tail -25 | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd $i " "; printf "%-8s %-12s %5s %5s %.70s\n", $2, $1, $4, $3, substr(cmd,1,70)}')
  TOP_MEM_ESC=$(echo "$TOP_MEM" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  MSG_HTML="Uso medio CPU: <strong>${CPU_USAGE}%</strong> (threshold: ${CPU_THRESHOLD}%)<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Snapshot do sistema (top):</strong><br/><pre>${SYS_SNAP}</pre><br/><strong>Top 25 processos por CPU (PID USER %CPU %MEM COMANDO):</strong><br/><pre>${TOP_CPU_ESC}</pre><br/><strong>Top 25 processos por RAM:</strong><br/><pre>${TOP_MEM_ESC}</pre>"
  /usr/local/bin/send_html_alert.sh "$TEMPLATE_PATH" "$RECIPIENTS" "ALERTA CPU ${CPU_USAGE}% - ${SERVER_ID}" "CPU em ${CPU_USAGE}% (CRITICO)" "$MSG_HTML"
  TG_TOP=$(ps aux --sort=-%cpu | head -13 | tail -12 | awk '{printf "%-8s %4s %4s %.45s\n", $2, $3"%", $4"%", $11}')
  /usr/local/bin/send_telegram_alert.sh "ALERTA CPU ${CPU_USAGE}% - ${SERVER_ID}\n\nTop processos (PID %CPU %MEM CMD):\n${TG_TOP}" || true
fi
MONITORCPU
sed -i "s|RECIPIENTS_PLACEHOLDER|${RECIPIENTS}|g" /usr/local/bin/monitor_cpu.sh
sed -i "s/CPU_THRESHOLD=90/CPU_THRESHOLD=${CPU_THRESHOLD}/" /usr/local/bin/monitor_cpu.sh
chmod +x /usr/local/bin/monitor_cpu.sh
log "monitor_cpu.sh atualizado."

# --- monitor_memory.sh ---
cat > /usr/local/bin/monitor_memory.sh << 'MONITORMEM'
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
fi
MONITORMEM
sed -i "s|RECIPIENTS_PLACEHOLDER|${RECIPIENTS}|g" /usr/local/bin/monitor_memory.sh
sed -i "s/MEM_THRESHOLD=90/MEM_THRESHOLD=${MEM_THRESHOLD}/" /usr/local/bin/monitor_memory.sh
chmod +x /usr/local/bin/monitor_memory.sh
log "monitor_memory.sh atualizado."

# --- monitor_disk.sh ---
cat > /usr/local/bin/monitor_disk.sh << 'MONITORDISK'
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
  fi
done
MONITORDISK
sed -i "s|RECIPIENTS_PLACEHOLDER|${RECIPIENTS}|g" /usr/local/bin/monitor_disk.sh
sed -i "s/DISK_THRESHOLD=90/DISK_THRESHOLD=${DISK_THRESHOLD}/" /usr/local/bin/monitor_disk.sh
chmod +x /usr/local/bin/monitor_disk.sh
log "monitor_disk.sh atualizado."

log ""
log "Scripts de monitoramento atualizados com sucesso."
log "Relatorios agora incluem: snapshot top, top 25 processos, (disco: top diretorios)."
log "Backups em /usr/local/bin/*.sh.bak.*"
