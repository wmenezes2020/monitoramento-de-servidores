
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

# monta_corpo METRICA CHAVE VALOR LIMIAR ACAO NIVEL DURACAO PICO EXTRA_HTML
#
# Ordem do e-mail, de cima para baixo, e a ordem das perguntas de quem abre:
# o que houve (no titulo), o que isso causa, se precisa de alguem agora, o que
# fazer, e so entao o numero. Antes o e-mail abria com "Load average em 1.56",
# que obriga a pessoa a traduzir o numero para saber se precisa levantar.
monta_corpo() {
  local metrica="$1" chave="$2" valor="$3" limiar="$4" acao="$5" nivel="$6"
  local dur="$7" pico="$8" extra="${9:-}"
  local rot uni corpo=""
  rot="$(rotulo_metrica "$metrica")"
  uni="$(unidade_metrica "$metrica")"

  # 1. O que isso causa para quem usa o servidor.
  if [[ "$acao" == "resolver" ]]; then
    corpo+="<p style=\"font-size:15px;line-height:1.5;margin:0 0 14px\">$(t corpo_normalizou "$rot" "$valor" "$uni" "$(duracao_humana "$dur")" "$pico" "$uni")</p>"
  else
    corpo+="<p style=\"font-size:15px;line-height:1.5;margin:0 0 14px\">$(impacto_metrica "$metrica")</p>"
  fi

  # 2. Precisa de alguem agora? Sem numero: e esta linha que decide se a
  #    pessoa levanta da cama ou le amanha.
  local fundo borda texto
  case "$acao|$nivel" in
    resolver*)   fundo="#ecfdf5"; borda="#15803d"; texto="#14532d" ;;  # verde
    *\|critico)  fundo="#fef2f2"; borda="#b91c1c"; texto="#7f1d1d" ;;  # vermelho
    *)           fundo="#fffbeb"; borda="#b45309"; texto="#7c2d12" ;;  # laranja escuro
  esac
  local linha_urg
  linha_urg="$(urgencia "$acao" "$nivel")"
  [[ "$acao" != "resolver" && "${dur:-0}" -gt 0 ]] && \
    linha_urg="${linha_urg} $(t urgencia_desde "$(duracao_humana "$dur")")"
  corpo+="<p style=\"margin:0 0 20px;padding:11px 15px;background:${fundo};border-left:3px solid ${borda};color:${texto};font-size:14px;font-weight:bold\">${linha_urg}</p>"

  # 3. O que fazer. Nao existe em alerta de recuperacao: nao ha o que fazer.
  if [[ "$acao" != "resolver" ]]; then
    corpo+="<div style=\"background:#f8fafc;border-left:3px solid #64748b;padding:12px 16px;margin:0 0 22px;font-size:13px;line-height:1.5\"><strong>$(t rotulo_fazer)</strong><br/>$(diagnostico "$metrica" "$valor")</div>"
  fi

  # 4. O numero, o limiar e a tabela. Quem chegou ate aqui vai investigar.
  corpo+="<p style=\"margin:0 0 10px;font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:#94a3b8\"><strong>$(t rotulo_tecnico)</strong></p>"
  if [[ "$acao" != "resolver" ]]; then
    corpo+="<p style=\"margin:0 0 4px\">$(t corpo_valor "$rot" "$valor" "$uni" "$limiar" "$uni")</p>"
    corpo+="<p style=\"margin:0 0 16px;color:#6b7280;font-size:13px\">$(t corpo_desde "$(duracao_humana "$dur")" "$pico" "$uni" "$CICLOS_CONFIRMACAO")</p>"
  fi

  local td_rot="padding:3px 14px 3px 0;color:#6b7280"
  corpo+="<p style=\"margin:0 0 4px\"><strong>$(t corpo_estado)</strong></p>"
  corpo+="<table style=\"border-collapse:collapse;font-size:13px;margin:0 0 18px\">"
  [[ -n "${MEDIDA_CPU:-}" ]] && corpo+="<tr><td style=\"${td_rot}\">CPU</td><td>${MEDIDA_CPU}% ($(t corpo_media_de "$(duracao_humana "${MEDIDA_CPU_JANELA:-0}")"))</td></tr>"
  [[ -n "${MEDIDA_IOWAIT:-}" ]] && corpo+="<tr><td style=\"${td_rot}\">iowait</td><td>${MEDIDA_IOWAIT}%</td></tr>"
  [[ -n "${MEDIDA_STEAL:-}" ]] && corpo+="<tr><td style=\"${td_rot}\">$(t tabela_steal)</td><td>${MEDIDA_STEAL}%</td></tr>"
  [[ -n "${MEDIDA_MEM:-}" ]] && corpo+="<tr><td style=\"${td_rot}\">$(t rotulo_memoria)</td><td>${MEDIDA_MEM}% ($(t corpo_disponiveis "$(awk -v k="${MEDIDA_MEM_DISP_KB:-0}" 'BEGIN{printf "%.1f", k/1048576}')"))</td></tr>"
  if [[ "${MEDIDA_SWAP_TOTAL_KB:-0}" -gt 0 ]]; then
    corpo+="<tr><td style=\"${td_rot}\">Swap</td><td>${MEDIDA_SWAP:-0}%</td></tr>"
  else
    corpo+="<tr><td style=\"${td_rot}\">Swap</td><td>$(t corpo_sem_swap)</td></tr>"
  fi
  [[ -n "${MEDIDA_LOAD:-}" ]] && corpo+="<tr><td style=\"${td_rot}\">$(t rotulo_load)</td><td>${MEDIDA_LOAD_BRUTO} ($(t corpo_por_nucleo "$MEDIDA_LOAD" "${MEDIDA_NUCLEOS:-?}"))</td></tr>"
  corpo+="</table>"

  printf '%s%s' "$corpo" "$extra"
}

# A mesma coisa em texto corrido, para o Telegram. Montado das mesmas pecas:
# dois catalogos para o mesmo alerta davam duas verdades, e a que ficava para
# tras chegava ao cliente.
monta_texto_tg() {
  local metrica="$1" frase="$2" acao="$3" nivel="$4" valor="$5" uni="$6"
  local limiar="$7" dur="$8" pico="$9"
  local linha_urg
  linha_urg="$(urgencia "$acao" "$nivel")"
  [[ "$acao" != "resolver" && "${dur:-0}" -gt 0 ]] && \
    linha_urg="${linha_urg} $(t urgencia_desde "$(duracao_humana "$dur")")"

  printf '%s %s: %s\n\n' "$(prefixo_assunto "$acao")" "$SERVER_ID" "$frase"
  if [[ "$acao" != "resolver" ]]; then
    printf '%s\n%s\n\n%s: %s\n\n%s: %s%s (%s %s%s, %s %s%s)\n' \
      "$(impacto_metrica "$metrica")" "$linha_urg" \
      "$(t rotulo_fazer)" "$(diagnostico "$metrica" "$valor")" \
      "$(rotulo_metrica "$metrica")" "$valor" "$uni" \
      "$(t tg_limiar)" "$limiar" "$uni" "$(t tg_pico)" "$pico" "$uni"
  else
    printf '%s\n\n%s %s | %s %s%s\n' "$linha_urg" \
      "$(t tg_durou)" "$(duracao_humana "$dur")" "$(t tg_pico)" "$pico" "$uni"
  fi
}

# envia_alerta METRICA CHAVE VALOR LIMIAR ACAO DURACAO PICO EXTRA_HTML EXTRA_TEXTO NIVEL
envia_alerta() {
  local metrica="$1" chave="$2" valor="$3" limiar="$4" acao="$5"
  local dur="$6" pico="$7" extra_html="${8:-}" extra_txt="${9:-}" nivel="${10:-atencao}"

  if silencio_ativo; then
    log_info "alerta ${chave} suprimido: silencio ativo ($(duracao_humana "$SILENCIO_RESTA") restantes, ${SILENCIO_MOTIVO:-sem motivo})"
    return 0
  fi

  if ! consome_orcamento; then
    log_erro "orcamento de ${MAX_ALERTAS_HORA} alertas/hora estourado; ${chave} nao enviado individualmente"
    registra_agregado "$chave" "$valor"
    return 0
  fi

  local uni frase assunto titulo corpo
  uni="$(unidade_metrica "$metrica")"
  # A frase diz o que houve em palavras que dispensam saber o que e load
  # average. Em disco e inode ela ja carrega o ponto de montagem: sem isso,
  # dois alertas do mesmo servidor ficam identicos na caixa de entrada.
  if [[ "$acao" == "resolver" ]]; then
    frase="$(frase_recuperacao "$metrica" "${valor}${uni}")"
  else
    frase="$(frase_problema "$metrica" "${valor}${uni}" "$chave")"
  fi
  assunto="$(prefixo_assunto "$acao") ${SERVER_ID}: ${frase}"
  titulo="$(t titulo_frase "$frase" "$SERVER_ID")"

  corpo="$(monta_corpo "$metrica" "$chave" "$valor" "$limiar" "$acao" "$nivel" "$dur" "$pico" "$extra_html")"

  if [[ "${CANAL_EMAIL:-1}" == "1" && -n "${RECIPIENTS:-}" && -x "${AGENTE_BIN}/send_html_alert.sh" ]]; then
    "${AGENTE_BIN}/send_html_alert.sh" "$(template_de "$metrica")" "$RECIPIENTS" "$assunto" "$titulo" "$corpo" \
      >/dev/null 2>&1 || log_erro "envio de e-mail falhou para ${chave}"
  fi

  local manda_tg=1
  [[ "$acao" == "resolver" && "${RECUPERACAO_TELEGRAM:-0}" != "1" ]] && manda_tg=0
  if [[ "${CANAL_TELEGRAM:-1}" == "1" && "$manda_tg" == "1" && -x "${AGENTE_BIN}/send_telegram_alert.sh" ]]; then
    local txt
    txt="$(monta_texto_tg "$metrica" "$frase" "$acao" "$nivel" "$valor" "$uni" "$limiar" "$dur" "$pico")"
    [[ -n "$extra_txt" && "$acao" != "resolver" ]] && txt="${txt}"$'\n'"${extra_txt}"
    "${AGENTE_BIN}/send_telegram_alert.sh" "$txt" >/dev/null 2>&1 || log_erro "envio ao Telegram falhou para ${chave}"
  fi

  if [[ "${CANAL_DASHBOARD:-1}" == "1" && "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
    envia_incidente_dashboard "$metrica" "$chave" "$valor" "$limiar" "$acao" "$dur" "$pico" "$assunto"
  fi

  log_info "alerta enviado: ${chave} acao=${acao} nivel=${nivel} valor=${valor} limiar=${limiar}"
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
