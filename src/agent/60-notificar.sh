
# ---------------------------------------------------------------------------
# Notificacao
# ---------------------------------------------------------------------------
#
# Mantem as assinaturas dos auxiliares que o instalador ja cria, para nao
# quebrar servidor nenhum na migracao:
#   send_html_alert.sh TEMPLATE DESTINATARIOS ASSUNTO TITULO CORPO_HTML
#   send_telegram_alert.sh TEXTO
#   send_dashboard_metrics.sh incident|metrics   (JSON no stdin)

# prefixo_assunto vive em 25-idioma.sh.

# Escolhe o template entre os que o instalador escreve; cai no generico.
template_de() {
  local metrica="$1" base="/opt/alerts/templates"
  case "$metrica" in
    cpu|load|steal) printf '%s/cpu-alert.html' "$base" ;;
    memoria|swap)   printf '%s/memory-alert.html' "$base" ;;
    disco|inode)    printf '%s/disk-alert.html' "$base" ;;
    *)              printf '%s/alert.html' "$base" ;;
  esac
}

# monta_corpo METRICA VALOR LIMIAR ACAO DURACAO PICO EXTRA_HTML
monta_corpo() {
  local metrica="$1" valor="$2" limiar="$3" acao="$4" dur="$5" pico="$6" extra="${7:-}"
  local rot uni diag
  rot="$(rotulo_metrica "$metrica")"
  uni="$(unidade_metrica "$metrica")"
  diag="$(diagnostico "$metrica" "$valor")"

  local linha_estado
  if [[ "$acao" == "resolver" ]]; then
    linha_estado="<p style=\"margin:0 0 18px\">$(t corpo_normalizou "$rot" "$valor" "$uni" "$(duracao_humana "$dur")" "$pico" "$uni")</p>"
  else
    linha_estado="<p style=\"margin:0 0 6px\">$(t corpo_valor "$rot" "$valor" "$uni" "$limiar" "$uni")</p>"
    linha_estado+="<p style=\"margin:0 0 18px;color:#6b7280\">$(t corpo_desde "$(duracao_humana "$dur")" "$pico" "$uni" "$CICLOS_CONFIRMACAO")</p>"
  fi

  local contexto="" td_rot="padding:3px 14px 3px 0;color:#6b7280"
  contexto+="<p style=\"margin:0 0 4px\"><strong>$(t corpo_estado)</strong></p>"
  contexto+="<table style=\"border-collapse:collapse;font-size:13px;margin:0 0 18px\">"
  [[ -n "${MEDIDA_CPU:-}" ]] && contexto+="<tr><td style=\"${td_rot}\">CPU</td><td>${MEDIDA_CPU}% ($(t corpo_media_de "$(duracao_humana "${MEDIDA_CPU_JANELA:-0}")"))</td></tr>"
  [[ -n "${MEDIDA_IOWAIT:-}" ]] && contexto+="<tr><td style=\"${td_rot}\">iowait</td><td>${MEDIDA_IOWAIT}%</td></tr>"
  [[ -n "${MEDIDA_STEAL:-}" ]] && contexto+="<tr><td style=\"${td_rot}\">$(t tabela_steal)</td><td>${MEDIDA_STEAL}%</td></tr>"
  [[ -n "${MEDIDA_MEM:-}" ]] && contexto+="<tr><td style=\"${td_rot}\">$(t rotulo_memoria)</td><td>${MEDIDA_MEM}% ($(t corpo_disponiveis "$(awk -v k="${MEDIDA_MEM_DISP_KB:-0}" 'BEGIN{printf "%.1f", k/1048576}')"))</td></tr>"
  if [[ "${MEDIDA_SWAP_TOTAL_KB:-0}" -gt 0 ]]; then
    contexto+="<tr><td style=\"${td_rot}\">Swap</td><td>${MEDIDA_SWAP:-0}%</td></tr>"
  else
    contexto+="<tr><td style=\"${td_rot}\">Swap</td><td>$(t corpo_sem_swap)</td></tr>"
  fi
  [[ -n "${MEDIDA_LOAD:-}" ]] && contexto+="<tr><td style=\"${td_rot}\">$(t rotulo_load)</td><td>${MEDIDA_LOAD_BRUTO} ($(t corpo_por_nucleo "$MEDIDA_LOAD" "${MEDIDA_NUCLEOS:-?}"))</td></tr>"
  contexto+="</table>"

  local bloco_diag
  bloco_diag="<div style=\"background:#f8fafc;border-left:3px solid #64748b;padding:12px 16px;margin:0 0 18px;font-size:13px\"><strong>$(t corpo_comecar)</strong><br/>${diag}</div>"

  printf '%s%s%s%s' "$linha_estado" "$bloco_diag" "$contexto" "$extra"
}

# envia_alerta METRICA ROTULO_CHAVE VALOR LIMIAR ACAO DURACAO PICO EXTRA_HTML EXTRA_TEXTO
envia_alerta() {
  local metrica="$1" chave="$2" valor="$3" limiar="$4" acao="$5"
  local dur="$6" pico="$7" extra_html="${8:-}" extra_txt="${9:-}"

  if silencio_ativo; then
    log_info "alerta ${chave} suprimido: silencio ativo ($(duracao_humana "$SILENCIO_RESTA") restantes, ${SILENCIO_MOTIVO:-sem motivo})"
    return 0
  fi

  if ! consome_orcamento; then
    log_erro "orcamento de ${MAX_ALERTAS_HORA} alertas/hora estourado; ${chave} nao enviado individualmente"
    registra_agregado "$chave" "$valor"
    return 0
  fi

  local rot uni assunto titulo corpo
  rot="$(rotulo_metrica "$metrica")"
  uni="$(unidade_metrica "$metrica")"
  assunto="$(prefixo_assunto "$acao") ${rot} ${valor}${uni} - ${SERVER_ID}"
  # Em disco e inode o ponto de montagem entra no assunto: sem ele, dois
  # alertas do mesmo servidor ficam identicos na caixa de entrada.
  [[ "$metrica" == "disco" || "$metrica" == "inode" ]] &&     assunto="$(prefixo_assunto "$acao") ${rot} ${valor}${uni} ${chave#*:} - ${SERVER_ID}"
  if [[ "$acao" == "resolver" ]]; then
    titulo="$(t titulo_normalizou "$rot" "$SERVER_ID")"
  else
    # O nivel ja aparece no assunto, entre colchetes. Repetir no titulo gastava
    # a linha mais visivel do e-mail com informacao duplicada; o nome do
    # servidor serve melhor, principalmente quando o alerta e encaminhado.
    titulo="$(t titulo_alerta "$rot" "$valor" "$uni" "$SERVER_ID")"
  fi

  corpo="$(monta_corpo "$metrica" "$valor" "$limiar" "$acao" "$dur" "$pico" "$extra_html")"

  if [[ "${CANAL_EMAIL:-1}" == "1" && -n "${RECIPIENTS:-}" && -x "${AGENTE_BIN}/send_html_alert.sh" ]]; then
    "${AGENTE_BIN}/send_html_alert.sh" "$(template_de "$metrica")" "$RECIPIENTS" "$assunto" "$titulo" "$corpo" \
      >/dev/null 2>&1 || log_erro "envio de e-mail falhou para ${chave}"
  fi

  local manda_tg=1
  [[ "$acao" == "resolver" && "${RECUPERACAO_TELEGRAM:-0}" != "1" ]] && manda_tg=0
  if [[ "${CANAL_TELEGRAM:-1}" == "1" && "$manda_tg" == "1" && -x "${AGENTE_BIN}/send_telegram_alert.sh" ]]; then
    local txt
    if [[ "$acao" == "resolver" ]]; then
      txt="$(t tg_normalizou "$(prefixo_assunto "$acao")" "$rot" "$SERVER_ID"         "$valor" "$uni" "$(duracao_humana "$dur")" "$pico" "$uni")"
    else
      txt="$(t tg_alerta "$(prefixo_assunto "$acao")" "$rot" "$valor" "$uni" "$SERVER_ID"         "$(duracao_humana "$dur")" "$pico" "$uni" "$limiar" "$uni"         "$(diagnostico "$metrica" "$valor")")"
      [[ -n "$extra_txt" ]] && txt="${txt}"$'

'"${extra_txt}"
    fi
    "${AGENTE_BIN}/send_telegram_alert.sh" "$txt" >/dev/null 2>&1 || log_erro "envio ao Telegram falhou para ${chave}"
  fi

  if [[ "${CANAL_DASHBOARD:-1}" == "1" && "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
    envia_incidente_dashboard "$metrica" "$chave" "$valor" "$limiar" "$acao" "$dur" "$pico" "$assunto"
  fi

  log_info "alerta enviado: ${chave} acao=${acao} valor=${valor} limiar=${limiar}"
  return 0
}

registra_agregado() {
  printf '%s %s %s\n' "$(agora)" "$1" "$2" >>"${AGENTE_ESTADO}/agregado" 2>/dev/null || true
}

# Envia o resumo do que foi agregado quando o orcamento estourou, no maximo um
# por hora. Serve o caso de o servidor estar caindo de verdade: uma mensagem
# util no lugar de trinta inuteis.
despacha_agregado() {
  local arq="${AGENTE_ESTADO}/agregado"
  [[ -s "$arq" ]] || return 0
  local marca="${AGENTE_ESTADO}/agregado.ultimo" ultimo
  ultimo="$(cat "$marca" 2>/dev/null || echo 0)"
  [[ "${ultimo:-0}" =~ ^[0-9]+$ ]] || ultimo=0
  [[ $(( $(agora) - ultimo )) -lt 3600 ]] && return 0

  local total linhas
  total="$(wc -l <"$arq" 2>/dev/null || echo 0)"
  linhas="$(awk '{printf "%s: %s\n", $2, $3}' "$arq" 2>/dev/null | sort | uniq -c | sort -rn | head -15)"

  if [[ "${CANAL_TELEGRAM:-1}" == "1" && -x "${AGENTE_BIN}/send_telegram_alert.sh" ]]; then
    "${AGENTE_BIN}/send_telegram_alert.sh"       "$(t resumo_tg "$SERVER_ID" "$total" "$MAX_ALERTAS_HORA" "$linhas")" >/dev/null 2>&1 || true
  fi
  if [[ "${CANAL_EMAIL:-1}" == "1" && -n "${RECIPIENTS:-}" && -x "${AGENTE_BIN}/send_html_alert.sh" ]]; then
    "${AGENTE_BIN}/send_html_alert.sh" "/opt/alerts/templates/alert.html" "$RECIPIENTS"       "$(prefixo_assunto resumo) $(t resumo_assunto "$total") - ${SERVER_ID}"       "$(t resumo_titulo)"       "<p>$(t resumo_corpo "$MAX_ALERTAS_HORA")</p><pre>$(printf '%s' "$linhas" | escapa_html)</pre>"       >/dev/null 2>&1 || true
  fi

  printf '%s' "$(agora)" | escreve_atomico "$marca" 2>/dev/null || true
  : >"$arq" 2>/dev/null || true
  log_info "resumo agregado de ${total} alertas despachado"
}

envia_incidente_dashboard() {
  local metrica="$1" chave="$2" valor="$3" limiar="$4" acao="$5" dur="$6" pico="$7" assunto="$8"
  [[ -x "${AGENTE_BIN}/send_dashboard_metrics.sh" ]] || return 0

  local sev status snap mount=""
  case "$acao" in
    escalar) sev="critical"; status="open" ;;
    resolver) sev="info"; status="resolved" ;;
    *) sev="warning"; status="open" ;;
  esac
  [[ "$metrica" == "disco" || "$metrica" == "inode" ]] && mount="${chave#*:}"

  snap="$(printf '%s\n\n%s' "$(diagnostico "$metrica" "$valor")" "$(top_processos cpu 12)" | escapa_json)"

  printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","type":"%s","value":%s,"threshold":%s,"severity":"%s","status":"%s","duration_seconds":%s,"peak_value":%s,"agent_version":"%s"%s,"subject":"%s","snapshot_top":"%s","notifications_sent":{"email":%s,"telegram":%s}}\n' \
    "$DASHBOARD_SERVER_UUID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SERVER_ID" \
    "$metrica" "$(num "$valor" 2)" "$(num "$limiar" 2)" "$sev" "$status" \
    "${dur:-0}" "$(num "$pico" 2)" "$AGENTE_VERSAO" \
    "${mount:+,\"mount\":\"$mount\"}" \
    "$assunto" "$snap" \
    "$([[ "${CANAL_EMAIL:-1}" == "1" && -n "${RECIPIENTS:-}" ]] && printf true || printf false)" \
    "$([[ "${CANAL_TELEGRAM:-1}" == "1" ]] && printf true || printf false)" \
    | "${AGENTE_BIN}/send_dashboard_metrics.sh" incident >/dev/null 2>&1 \
    || log_erro "envio do incidente ao painel falhou"
}

# Metricas vao ao painel em toda rodada, haja alerta ou nao. E o grafico que
# permite ver a tendencia antes de virar incidente.
envia_metricas_dashboard() {
  [[ "${CANAL_DASHBOARD:-1}" == "1" ]] || return 0
  [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]] || return 0
  [[ -x "${AGENTE_BIN}/send_dashboard_metrics.sh" ]] || return 0

  local disco_json="" linha mnt uso ino resto
  while read -r mnt uso ino resto; do
    [[ -z "${mnt:-}" ]] && continue
    disco_json+="{\"mount\":\"${mnt}\",\"usage\":${uso},\"inodes\":${ino}},"
  done <<<"${MEDIDA_DISCO_LINHAS:-}"
  disco_json="${disco_json%,}"

  printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","agent_version":"%s","metrics":{"cpu":%s,"memory":%s,"disk":[%s],"iowait":%s,"steal":%s,"load":%s,"swap":%s}}\n' \
    "$DASHBOARD_SERVER_UUID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SERVER_ID" "$AGENTE_VERSAO" \
    "$(num "${MEDIDA_CPU:-0}" 2)" "$(num "${MEDIDA_MEM:-0}" 2)" "$disco_json" \
    "$(num "${MEDIDA_IOWAIT:-0}" 2)" "$(num "${MEDIDA_STEAL:-0}" 2)" \
    "$(num "${MEDIDA_LOAD:-0}" 2)" "$(num "${MEDIDA_SWAP:-0}" 2)" \
    | "${AGENTE_BIN}/send_dashboard_metrics.sh" metrics >/dev/null 2>&1 \
    || log_erro "envio de metricas ao painel falhou"
}
