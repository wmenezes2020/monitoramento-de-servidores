
# ---------------------------------------------------------------------------
# Avaliacao: a maquina de estado que decide se alguem precisa ser avisado
# ---------------------------------------------------------------------------
#
#   OK ──── CICLOS_CONFIRMACAO acima do limiar de atencao ───▶ ATENCAO  (avisa)
#   ATENCAO ── CICLOS_CONFIRMACAO acima do critico ─────────▶ CRITICO  (escala)
#   ATENCAO/CRITICO ── CICLOS_RECUPERACAO abaixo da banda ──▶ OK       (resolve)
#
# A banda de saida existe porque um valor oscilando em torno do limiar geraria
# alerta e recuperacao alternados para sempre. Com BANDA_SAIDA=8 e limiar 85, a
# saida so acontece abaixo de 77.
#
# Resultado em: AV_ACAO (nada|abrir|escalar|repetir|resolver), AV_NIVEL,
# AV_DURACAO, AV_PICO.

avalia() {
  local chave="$1" valor="$2" lim_at="$3" lim_cr="$4"

  AV_ACAO="nada"; AV_NIVEL="ok"; AV_DURACAO=0; AV_PICO="$valor"

  if [[ -z "$valor" ]]; then
    return 0
  fi

  le_estado "$chave"
  local n; n="$(agora)"
  local nivel_agora="ok"

  if maior "$valor" "$lim_cr"; then
    nivel_agora="critico"
  elif maior "$valor" "$lim_at"; then
    nivel_agora="atencao"
  fi

  local saida
  saida="$(awk -v l="$lim_at" -v b="${BANDA_SAIDA:-8}" 'BEGIN{v=l-b; if (v<0) v=0; printf "%.2f", v}')"

  if [[ "$nivel_agora" == "ok" ]]; then
    # Abaixo do limiar, mas ainda dentro da banda: nao conta como recuperacao.
    if maior "$valor" "$saida" && [[ "$E_NIVEL" != "ok" ]]; then
      E_ABAIXO=0
      grava_estado "$chave"
      return 0
    fi
    E_ACIMA=0; E_ACIMA_CRIT=0
    if [[ "$E_NIVEL" != "ok" ]]; then
      E_ABAIXO=$(( E_ABAIXO + 1 ))
      if [[ "$E_ABAIXO" -ge "$CICLOS_RECUPERACAO" ]]; then
        # So anuncia recuperacao de um problema que chegou a ser anunciado.
        # Incidente que morreu durante a confirmacao nunca saiu, entao um
        # "voltou ao normal" sem o "deu problema" antes so confunde.
        [[ "$E_NOTIFICADO" != "ok" ]] && AV_ACAO="resolver"
        AV_NIVEL="$E_NIVEL"
        AV_DURACAO=$(( n - E_DESDE ))
        AV_PICO="$E_VALOR_PICO"
        E_NIVEL="ok"; E_ABAIXO=0; E_DESDE=0
        E_ULTIMO_ALERTA=0; E_VALOR_PICO=0; E_NOTIFICADO="ok"
      fi
    fi
    grava_estado "$chave"
    return 0
  fi

  # Acima de algum limiar
  E_ABAIXO=0
  E_ACIMA=$(( E_ACIMA + 1 ))
  # Contador proprio do nivel critico: a escalada tambem precisa de
  # confirmacao. Sem isso, um pico de um ciclo dentro de um incidente de
  # atencao viraria um alerta critico que nao corresponde a nada.
  if [[ "$nivel_agora" == "critico" ]]; then
    E_ACIMA_CRIT=$(( E_ACIMA_CRIT + 1 ))
  else
    E_ACIMA_CRIT=0
  fi
  maior "$valor" "$E_VALOR_PICO" && E_VALOR_PICO="$valor"
  [[ "$E_DESDE" -eq 0 ]] && E_DESDE="$n"
  AV_DURACAO=$(( n - E_DESDE ))
  AV_PICO="$E_VALOR_PICO"

  # Ainda confirmando: e aqui que o pico isolado morre sem virar mensagem.
  if [[ "$E_ACIMA" -lt "$CICLOS_CONFIRMACAO" ]]; then
    E_NIVEL="$nivel_agora"
    grava_estado "$chave"
    AV_NIVEL="$nivel_agora"
    return 0
  fi

  AV_NIVEL="$nivel_agora"

  if [[ "$E_NOTIFICADO" == "ok" ]]; then
    AV_ACAO="abrir"
  elif [[ "$nivel_agora" == "critico" && "$E_NOTIFICADO" == "atencao" ]] \
    && [[ "$E_ACIMA_CRIT" -ge "$CICLOS_CONFIRMACAO" ]]; then
    # Piorou de verdade e se manteve: vale interromper alguem de novo.
    AV_ACAO="escalar"
  else
    local espera=$(( ${RENOTIFICAR_MIN:-60} * 60 ))
    if [[ "$espera" -gt 0 ]] && [[ $(( n - E_ULTIMO_ALERTA )) -ge "$espera" ]]; then
      AV_ACAO="repetir"
    fi
  fi

  if [[ "$AV_ACAO" != "nada" ]]; then
    E_ULTIMO_ALERTA="$n"
    E_NOTIFICADO="$nivel_agora"
  fi
  E_NIVEL="$nivel_agora"
  grava_estado "$chave"
  return 0
}

# --- Diagnostico: a frase que diz o que conferir primeiro ------------------
#
# Alerta que so repete o numero obriga quem recebe a comecar a investigacao do
# zero. O agente ja tem o contexto na mao na hora de medir.

diagnostico() {
  local metrica="$1" valor="$2"
  case "$metrica" in
    cpu)
      if maior "${MEDIDA_STEAL:-0}" "${STEAL_ATENCAO:-10}"; then
        t diag_steal "$MEDIDA_STEAL"
      elif maior "${MEDIDA_IOWAIT:-0}" "25"; then
        t diag_iowait "$MEDIDA_IOWAIT"
      elif maior "${MEDIDA_LOAD:-0}" "1.5"; then
        t diag_load "$MEDIDA_LOAD"
      else
        t diag_cpu
      fi
      ;;
    memoria)
      local disp_mb
      disp_mb="$(awk -v k="${MEDIDA_MEM_DISP_KB:-0}" 'BEGIN{printf "%.0f", k/1024}')"
      if [[ "${MEDIDA_SWAP_TOTAL_KB:-0}" -eq 0 ]]; then
        t diag_mem_sem_swap "$disp_mb"
      else
        t diag_mem "$disp_mb"
      fi
      ;;
    disco) t diag_disco ;;
    inode) t diag_inode ;;
    swap)  t diag_swap ;;
    load)  t diag_load_m "$valor" ;;
    steal) t diag_steal_m ;;
    *)     t diag_padrao ;;
  esac
}
