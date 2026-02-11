#!/usr/bin/env bash
#
# Atualiza o threshold (%) dos monitores CPU, RAM e Disco.
# Uso: curl -fsSL URL | bash -s 95
#   ou: THRESHOLD=95 curl -fsSL URL | bash
#   ou: sudo ./update_monitor.sh 95
#
# Exemplos de chamada unica:
#   curl -fsSL https://raw.githubusercontent.com/wmenezes2020/monitoramento-de-servidores/main/update_monitor.sh | sudo bash -s 95
#   THRESHOLD=90 curl -fsSL https://... | sudo bash
#
set -euo pipefail

log() { echo "[update_monitor] $*" >&2; }

THRESHOLD="${1:-${THRESHOLD:-}}"
if [[ -z "$THRESHOLD" ]]; then
  log "Uso: informe o threshold (1-100) como parametro ou variavel THRESHOLD"
  log "Ex.: curl -fsSL URL | sudo bash -s 95"
  log "Ex.: THRESHOLD=90 curl -fsSL URL | sudo bash"
  exit 1
fi

if [[ ! "$THRESHOLD" =~ ^[0-9]+$ ]] || [[ "$THRESHOLD" -lt 1 ]] || [[ "$THRESHOLD" -gt 100 ]]; then
  log "Erro: threshold deve ser um numero entre 1 e 100 (ex.: 95)"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  log "Execute como root: sudo bash -s 95"
  exit 1
fi

UPDATED=0
[[ -f /usr/local/bin/monitor_cpu.sh ]]    && sed -i "s/CPU_THRESHOLD=[0-9]*/CPU_THRESHOLD=${THRESHOLD}/"    /usr/local/bin/monitor_cpu.sh    && ((UPDATED++)) || true
[[ -f /usr/local/bin/monitor_memory.sh ]] && sed -i "s/MEM_THRESHOLD=[0-9]*/MEM_THRESHOLD=${THRESHOLD}/"   /usr/local/bin/monitor_memory.sh && ((UPDATED++)) || true
[[ -f /usr/local/bin/monitor_disk.sh ]]   && sed -i "s/DISK_THRESHOLD=[0-9]*/DISK_THRESHOLD=${THRESHOLD}/" /usr/local/bin/monitor_disk.sh   && ((UPDATED++)) || true

if [[ $UPDATED -eq 0 ]]; then
  log "Erro: scripts de monitoramento nao encontrados. Execute o instalador primeiro."
  exit 1
fi

log "Threshold atualizado para ${THRESHOLD}% em CPU, RAM e Disco."
log "Os alertas serao disparados quando o uso ultrapassar ${THRESHOLD}%."
