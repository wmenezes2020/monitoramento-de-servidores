#!/usr/bin/env bash
#
# Atualiza o threshold (%) dos monitores CPU, RAM e Disco (individualmente ou em conjunto).
#
# Uso:
#   Tres valores (CPU MEM DISCO):  curl ... | sudo bash -s 90 85 95
#   Um valor (aplica a todos):     curl ... | sudo bash -s 90
#   Variaveis de ambiente:        CPU_THRESHOLD=90 MEM_THRESHOLD=85 DISK_THRESHOLD=95 curl ... | sudo bash
#
set -euo pipefail

log() { echo "[update_monitor] $*" >&2; }

valida() {
  local v="$1" n="$2"
  if [[ -z "$v" ]]; then return 1; fi
  if [[ ! "$v" =~ ^[0-9]+$ ]] || [[ "$v" -lt 1 ]] || [[ "$v" -gt 100 ]]; then
    log "Erro: $n deve ser numero entre 1 e 100"
    return 1
  fi
  return 0
}

# Parametros: $1=CPU $2=MEM $3=DISCO. Se so $1: todos iguais. Variaveis env como fallback.
CPU="${1:-${CPU_THRESHOLD:-}}"
MEM="${2:-${MEM_THRESHOLD:-${1:-}}}"
DISK="${3:-${DISK_THRESHOLD:-${1:-}}}"

if [[ -z "$CPU" ]] && [[ -z "$MEM" ]] && [[ -z "$DISK" ]]; then
  log "Uso: informe os thresholds (1-100) para CPU, MEM, DISCO"
  log ""
  log "Ex.: curl ... | sudo bash -s 90 85 95   (CPU=90% MEM=85% DISCO=95%)"
  log "Ex.: curl ... | sudo bash -s 90         (todos = 90%)"
  log "Ex.: CPU_THRESHOLD=90 MEM_THRESHOLD=85 DISK_THRESHOLD=95 curl ... | sudo bash"
  exit 1
fi

# Se so CPU foi passado, aplicar aos tres
[[ -n "$CPU" ]] && [[ -z "$MEM" ]] && [[ -z "$DISK" ]] && MEM="$CPU" && DISK="$CPU"
[[ -n "$CPU" ]] && [[ -n "$MEM" ]] && [[ -z "$DISK" ]] && DISK="$MEM"

[[ -n "$CPU" ]] && valida "$CPU" "CPU" || CPU=""
[[ -n "$MEM" ]] && valida "$MEM" "MEM" || MEM=""
[[ -n "$DISK" ]] && valida "$DISK" "DISCO" || DISK=""

if [[ -z "$CPU" ]] && [[ -z "$MEM" ]] && [[ -z "$DISK" ]]; then
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  log "Execute como root: sudo bash -s ..."
  exit 1
fi

UPDATED=0
[[ -n "$CPU" ]] && [[ -f /usr/local/bin/monitor_cpu.sh ]]    && sed -i "s/CPU_THRESHOLD=[0-9]*/CPU_THRESHOLD=${CPU}/"    /usr/local/bin/monitor_cpu.sh    && ((UPDATED++)) && log "CPU: ${CPU}%" || true
[[ -n "$MEM" ]] && [[ -f /usr/local/bin/monitor_memory.sh ]] && sed -i "s/MEM_THRESHOLD=[0-9]*/MEM_THRESHOLD=${MEM}/"   /usr/local/bin/monitor_memory.sh && ((UPDATED++)) && log "RAM: ${MEM}%" || true
[[ -n "$DISK" ]] && [[ -f /usr/local/bin/monitor_disk.sh ]]  && sed -i "s/DISK_THRESHOLD=[0-9]*/DISK_THRESHOLD=${DISK}/" /usr/local/bin/monitor_disk.sh   && ((UPDATED++)) && log "Disco: ${DISK}%" || true

if [[ $UPDATED -eq 0 ]]; then
  log "Erro: scripts de monitoramento nao encontrados ou nenhum valor valido. Execute o instalador primeiro."
  exit 1
fi

log ""
log "Thresholds atualizados. Alertas serao disparados quando o uso ultrapassar os valores definidos."
