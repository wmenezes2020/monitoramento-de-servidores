
# ---------------------------------------------------------------------------
# Estado entre execucoes
# ---------------------------------------------------------------------------
#
# Histerese, cooldown e recuperacao so existem se a execucao de agora souber o
# que aconteceu na anterior. O agente antigo nao guardava nada, e por isso cada
# rodada era a primeira: a mesma rajada de dois segundos virava alerta novo.
#
# Um arquivo key=value por metrica, em /var/lib/monitoring/state/.

nome_seguro() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

caminho_estado() { printf '%s/%s.state' "$AGENTE_ESTADO" "$(nome_seguro "$1")"; }

# Carrega em E_* ; metrica nova comeca em OK
le_estado() {
  local chave="$1" arq
  arq="$(caminho_estado "$chave")"
  E_NIVEL="ok"; E_ACIMA=0; E_ACIMA_CRIT=0; E_ABAIXO=0; E_DESDE=0
  E_ULTIMO_ALERTA=0; E_VALOR_PICO=0; E_NOTIFICADO="ok"
  [[ -f "$arq" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      NIVEL)          E_NIVEL="$v" ;;
      ACIMA)          E_ACIMA="${v:-0}" ;;
      ACIMA_CRIT)     E_ACIMA_CRIT="${v:-0}" ;;
      ABAIXO)         E_ABAIXO="${v:-0}" ;;
      DESDE)          E_DESDE="${v:-0}" ;;
      ULTIMO_ALERTA)  E_ULTIMO_ALERTA="${v:-0}" ;;
      VALOR_PICO)     E_VALOR_PICO="${v:-0}" ;;
      NOTIFICADO)     E_NOTIFICADO="${v:-ok}" ;;
    esac
  done <"$arq" 2>/dev/null
  [[ "$E_ACIMA" =~ ^[0-9]+$ ]] || E_ACIMA=0
  [[ "$E_ACIMA_CRIT" =~ ^[0-9]+$ ]] || E_ACIMA_CRIT=0
  [[ "$E_ABAIXO" =~ ^[0-9]+$ ]] || E_ABAIXO=0
  return 0
}

grava_estado() {
  local chave="$1"
  printf 'NIVEL=%s\nACIMA=%s\nACIMA_CRIT=%s\nABAIXO=%s\nDESDE=%s\nULTIMO_ALERTA=%s\nVALOR_PICO=%s\nNOTIFICADO=%s\n' \
    "$E_NIVEL" "$E_ACIMA" "$E_ACIMA_CRIT" "$E_ABAIXO" "$E_DESDE" "$E_ULTIMO_ALERTA" "$E_VALOR_PICO" "$E_NOTIFICADO" \
    | escreve_atomico "$(caminho_estado "$chave")"
}

# --- Janela de silencio ---------------------------------------------------
#
# Deploy e manutencao programada nao sao incidente. Sem isso, a saida facil e
# baixar o limiar, e aí o alerta para de servir para o resto do tempo.
# A coleta de metricas continua: so a notificacao e suprimida.

silencio_ativo() {
  local arq="${AGENTE_RAIZ}/silencio"
  [[ -f "$arq" ]] || return 1
  local ate
  ate="$(awk -F= '/^ATE=/{print $2; exit}' "$arq" 2>/dev/null)"
  [[ "${ate:-0}" =~ ^[0-9]+$ ]] || return 1
  if [[ "$(agora)" -lt "$ate" ]]; then
    SILENCIO_MOTIVO="$(awk -F= '/^MOTIVO=/{sub(/^MOTIVO=/,""); print; exit}' "$arq" 2>/dev/null)"
    SILENCIO_RESTA=$(( ate - $(agora) ))
    return 0
  fi
  rm -f "$arq" 2>/dev/null || true
  return 1
}

inicia_silencio() {
  local dur seg motivo
  dur="${1:-15m}"; motivo="${2:-manutencao}"
  seg="$(para_segundos "$dur")"
  [[ "$seg" =~ ^[0-9]+$ ]] || seg=900
  # Teto de 24h: silencio esquecido ligado e um servidor sem vigilancia.
  [[ "$seg" -gt 86400 ]] && seg=86400
  mkdir -p "$AGENTE_RAIZ" 2>/dev/null || true
  printf 'ATE=%s\nMOTIVO=%s\nCRIADO=%s\n' "$(( $(agora) + seg ))" "$motivo" "$(agora)" \
    | escreve_atomico "${AGENTE_RAIZ}/silencio"
  log_info "silencio por ${seg}s: ${motivo}"
}

encerra_silencio() {
  rm -f "${AGENTE_RAIZ}/silencio" 2>/dev/null || true
  log_info "silencio encerrado"
}

# --- Orcamento de alertas por hora ----------------------------------------
#
# Teto para o caso que nenhuma histerese cobre: muitas metricas estourando ao
# mesmo tempo (o servidor de verdade caindo). Em vez de trinta mensagens, as
# excedentes viram um resumo so.

consome_orcamento() {
  local arq="${AGENTE_ESTADO}/orcamento" janela inicio usados n
  janela=3600
  n="$(agora)"
  inicio=0; usados=0
  if [[ -f "$arq" ]]; then
    read -r inicio usados <"$arq" 2>/dev/null || true
    [[ "${inicio:-0}" =~ ^[0-9]+$ ]] || inicio=0
    [[ "${usados:-0}" =~ ^[0-9]+$ ]] || usados=0
  fi
  if [[ $(( n - inicio )) -ge $janela ]]; then
    inicio="$n"; usados=0
  fi
  usados=$(( usados + 1 ))
  printf '%s %s\n' "$inicio" "$usados" | escreve_atomico "$arq" 2>/dev/null || true
  [[ "$usados" -le "$MAX_ALERTAS_HORA" ]]
}

orcamento_estourado() {
  local arq="${AGENTE_ESTADO}/orcamento" inicio usados
  [[ -f "$arq" ]] || return 1
  read -r inicio usados <"$arq" 2>/dev/null || return 1
  [[ "${usados:-0}" =~ ^[0-9]+$ ]] || return 1
  [[ "$usados" -gt "$MAX_ALERTAS_HORA" ]]
}
