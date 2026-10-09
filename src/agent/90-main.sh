
# ---------------------------------------------------------------------------
# Sincronia de configuracao com o painel
# ---------------------------------------------------------------------------
#
# Substitui o dashboard_fetch_updates.sh, que aplicava "sed" dentro dos
# scripts de monitoramento. Agora a configuracao chega num lugar so, o
# agent.conf, e o script fica imutavel.

sincroniza_config() {
  [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  local resp
  resp="$(curl -fsS -X GET "${DASHBOARD_API_URL}/agent/updates" \
    -H "X-Server-UUID: ${DASHBOARD_SERVER_UUID}" \
    -H "X-Agent-Version: ${AGENTE_VERSAO}" \
    --max-time 15 2>/dev/null)" || { log_erro "painel nao respondeu na sincronia"; return 1; }
  [[ -z "$resp" ]] && return 1

  local arq="${AGENTE_RAIZ}/agent.conf" mudou=0

  _grava_conf() {
    local chave="$1" valor="$2"
    [[ -z "$valor" ]] && return 0
    local atual
    atual="$(grep -m1 "^${chave}=" "$arq" 2>/dev/null | cut -d= -f2-)"
    [[ "$atual" == "$valor" ]] && return 0
    if grep -q "^${chave}=" "$arq" 2>/dev/null; then
      sed -i "s|^${chave}=.*|${chave}=${valor}|" "$arq" 2>/dev/null || return 1
    else
      printf '%s=%s\n' "$chave" "$valor" >>"$arq" 2>/dev/null || return 1
    fi
    mudou=1
    return 0
  }

  local v
  for par in \
    "cpu_warning:CPU_ATENCAO" "cpu_critical:CPU_CRITICO" \
    "memory_warning:MEM_ATENCAO" "memory_critical:MEM_CRITICO" \
    "disk_warning:DISCO_ATENCAO" "disk_critical:DISCO_CRITICO" \
    "confirm_cycles:CICLOS_CONFIRMACAO" "recover_cycles:CICLOS_RECUPERACAO" \
    "renotify_minutes:RENOTIFICAR_MIN" "max_alerts_hour:MAX_ALERTAS_HORA" \
    "exit_band:BANDA_SAIDA"
  do
    v="$(printf '%s' "$resp" | grep -o "\"${par%%:*}\":[0-9]\+" | head -1 | cut -d: -f2)"
    _grava_conf "${par#*:}" "$v"
  done

  # Compatibilidade com o painel antes da migracao do backend, que devolve um
  # limiar unico por metrica dentro de "thresholds".
  local bloco
  bloco="$(printf '%s' "$resp" | grep -o '"thresholds":{[^}]*}' | head -1)"
  if [[ -n "$bloco" ]]; then
    for par in "cpu:CPU_CRITICO" "memory:MEM_CRITICO" "disk:DISCO_CRITICO"; do
      v="$(printf '%s' "$bloco" | grep -o "\"${par%%:*}\":[0-9]\+" | head -1 | cut -d: -f2)"
      _grava_conf "${par#*:}" "$v"
    done
  fi

  local nome
  nome="$(printf '%s' "$resp" | sed -n 's/.*"server_name":"\([^"]*\)".*/\1/p' | head -1)"
  if [[ -n "$nome" && -f "${AGENTE_RAIZ}/email.conf" ]]; then
    grep -q '^SERVER_ID=' "${AGENTE_RAIZ}/email.conf" 2>/dev/null \
      && sed -i "s|^SERVER_ID=.*|SERVER_ID=\"${nome}\"|" "${AGENTE_RAIZ}/email.conf" 2>/dev/null \
      || printf 'SERVER_ID="%s"\n' "$nome" >>"${AGENTE_RAIZ}/email.conf" 2>/dev/null || true
  fi

  local emails
  emails="$(printf '%s' "$resp" | grep -o '"emails":\[[^]]*\]' | head -1 | sed 's/"emails":\[//; s/\]$//; s/","/,/g; s/"//g')"
  if [[ -n "$emails" ]]; then
    if [[ -f "${AGENTE_RAIZ}/email.conf" ]] && grep -q '^RECIPIENTS=' "${AGENTE_RAIZ}/email.conf" 2>/dev/null; then
      sed -i "s|^RECIPIENTS=.*|RECIPIENTS=\"${emails}\"|" "${AGENTE_RAIZ}/email.conf" 2>/dev/null || true
    else
      printf 'RECIPIENTS="%s"\n' "$emails" >>"${AGENTE_RAIZ}/email.conf" 2>/dev/null || true
    fi
  fi

  local tg_token tg_chat
  tg_token="$(printf '%s' "$resp" | sed -n 's/.*"telegram_bot_token":"\([^"]*\)".*/\1/p' | head -1)"
  tg_chat="$(printf '%s' "$resp" | sed -n 's/.*"telegram_chat_id":"\([^"]*\)".*/\1/p' | head -1)"
  if [[ -n "$tg_token" || -n "$tg_chat" ]]; then
    mkdir -p "$AGENTE_RAIZ" 2>/dev/null || true
    if [[ -f "${AGENTE_RAIZ}/telegram.conf" ]]; then
      [[ -n "$tg_token" ]] && sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=\"${tg_token}\"|" "${AGENTE_RAIZ}/telegram.conf" 2>/dev/null || true
      [[ -n "$tg_chat" ]] && sed -i "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=\"${tg_chat}\"|" "${AGENTE_RAIZ}/telegram.conf" 2>/dev/null || true
    else
      printf 'TELEGRAM_BOT_TOKEN="%s"\nTELEGRAM_CHAT_ID="%s"\n' "$tg_token" "$tg_chat" >"${AGENTE_RAIZ}/telegram.conf" 2>/dev/null || true
      chmod 640 "${AGENTE_RAIZ}/telegram.conf" 2>/dev/null || true
    fi
  fi

  # Manutencao programada pelo painel vale como janela de silencio local.
  local manut
  manut="$(printf '%s' "$resp" | grep -o '"maintenance_seconds":[0-9]\+' | head -1 | cut -d: -f2)"
  if [[ -n "$manut" && "$manut" -gt 0 ]]; then
    inicia_silencio "${manut}s" "manutencao programada no painel"
  fi

  [[ "$mudou" -eq 1 ]] && log_info "configuracao sincronizada com o painel"
  return 0
}

# ---------------------------------------------------------------------------
# A rodada
# ---------------------------------------------------------------------------

avalia_e_notifica() {
  local metrica="$1" chave="$2" valor="$3" extra_html="${4:-}" extra_txt="${5:-}"
  [[ -z "$valor" ]] && return 0

  local lim_at lim_cr
  read -r lim_at lim_cr <<<"$(limiar_de "$metrica")"

  avalia "$chave" "$valor" "$lim_at" "$lim_cr"

  case "$AV_ACAO" in
    nada) return 0 ;;
    resolver)
      [[ "${ALERTA_RECUPERACAO:-1}" == "1" ]] || return 0
      envia_alerta "$metrica" "$chave" "$valor" "$lim_at" "resolver" "$AV_DURACAO" "$AV_PICO" "$extra_html" "$extra_txt"
      ;;
    *)
      local lim_usado="$lim_at"
      [[ "$AV_NIVEL" == "critico" ]] && lim_usado="$lim_cr"
      envia_alerta "$metrica" "$chave" "$valor" "$lim_usado" "$AV_ACAO" "$AV_DURACAO" "$AV_PICO" "$extra_html" "$extra_txt"
      ;;
  esac
  return 0
}

rodada() {
  carrega_config
  mkdir -p "$AGENTE_ESTADO" 2>/dev/null || true

  if ! pega_trava rodada; then
    log_info "outra rodada em andamento; saindo"
    return 0
  fi

  mede_cpu     || log_info "CPU sem medida nesta rodada"
  mede_memoria || log_erro "memoria sem medida nesta rodada"
  mede_load    || true
  mede_disco   || true

  local proc_cpu proc_mem html_cpu html_mem
  proc_cpu="$(top_processos cpu 12)"
  proc_mem="$(top_processos mem 12)"
  html_cpu="<p style=\"margin:0 0 4px\"><strong>Processos por CPU</strong></p><pre style=\"font-size:12px;background:#f8fafc;padding:12px;overflow-x:auto\">$(printf '%s' "$proc_cpu" | escapa_html)</pre>"
  html_mem="<p style=\"margin:0 0 4px\"><strong>Processos por memoria</strong></p><pre style=\"font-size:12px;background:#f8fafc;padding:12px;overflow-x:auto\">$(printf '%s' "$proc_mem" | escapa_html)</pre>"

  [[ "${VIGIAR_CPU:-1}" == "1" ]] && \
    avalia_e_notifica cpu cpu "${MEDIDA_CPU:-}" "${html_cpu}${html_mem}" "$proc_cpu"

  [[ "${VIGIAR_STEAL:-1}" == "1" ]] && \
    avalia_e_notifica steal steal "${MEDIDA_STEAL:-}" "$html_cpu" "$proc_cpu"

  [[ "${VIGIAR_MEMORIA:-1}" == "1" ]] && \
    avalia_e_notifica memoria memoria "${MEDIDA_MEM:-}" "${html_mem}${html_cpu}" "$proc_mem"

  # Swap so e metrica onde existe swap. Em EC2 o padrao e nao ter, e medir
  # percentual de zero nao significa nada.
  [[ "${VIGIAR_SWAP:-1}" == "1" && "${MEDIDA_SWAP_TOTAL_KB:-0}" -gt 0 ]] && \
    avalia_e_notifica swap swap "${MEDIDA_SWAP:-}" "$html_mem" "$proc_mem"

  [[ "${VIGIAR_LOAD:-1}" == "1" ]] && \
    avalia_e_notifica load load "${MEDIDA_LOAD:-}" "$html_cpu" "$proc_cpu"

  if [[ "${VIGIAR_DISCO:-1}" == "1" || "${VIGIAR_INODE:-1}" == "1" ]]; then
    local mnt uso ino resto dirs html_dirs
    while read -r mnt uso ino resto; do
      [[ -z "${mnt:-}" ]] && continue
      if [[ "${VIGIAR_DISCO:-1}" == "1" ]]; then
        dirs=""
        # du so quando ja passou do limiar de atencao: varrer disco em toda
        # rodada seria o monitoramento virando a carga do servidor.
        if maior "$uso" "${DISCO_ATENCAO:-85}"; then
          dirs="$(maiores_diretorios "$mnt")"
        fi
        html_dirs=""
        [[ -n "$dirs" ]] && html_dirs="<p style=\"margin:0 0 4px\"><strong>Maiores diretorios em ${mnt}</strong></p><pre style=\"font-size:12px;background:#f8fafc;padding:12px\">$(printf '%s' "$dirs" | escapa_html)</pre>"
        avalia_e_notifica disco "disco:${mnt}" "$uso" "$html_dirs" "$dirs"
      fi
      [[ "${VIGIAR_INODE:-1}" == "1" ]] && \
        avalia_e_notifica inode "inode:${mnt}" "$ino" "" ""
    done <<<"${MEDIDA_DISCO_LINHAS:-}"
  fi

  despacha_agregado
  envia_metricas_dashboard

  # Sincronia e atualizacao nao precisam de todo minuto. A cada 5 minutos
  # mantem a reacao rapida sem transformar a frota em trafego constante, que
  # era o que o canal antigo fazia ao baixar tres arquivos por minuto.
  local m
  m="$(date +%M)"
  if [[ $(( 10#$m % 5 )) -eq 0 ]]; then
    sincroniza_config || true
    atualiza_agente || true
  fi

  registra_heartbeat
  return 0
}

registra_heartbeat() {
  printf '%s %s\n' "$(agora)" "$AGENTE_VERSAO" | escreve_atomico "${AGENTE_ESTADO}/heartbeat" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Autoteste: o portao que impede uma versao quebrada de ficar instalada
# ---------------------------------------------------------------------------

autoteste() {
  local falhas=0
  _ok() { printf '  ok   %s\n' "$1"; }
  _fail() { printf '  FALHA %s\n' "$1"; falhas=$(( falhas + 1 )); }

  printf 'autoteste do agente %s\n' "$AGENTE_VERSAO"

  carrega_config || { _fail "carrega_config"; }

  [[ "$(pct 50 200)" == "25.0" ]] && _ok "aritmetica de percentual" || _fail "aritmetica de percentual"
  maior 10 5 && _ok "comparacao maior" || _fail "comparacao maior"
  maior 5 10 && _fail "comparacao maior (falso positivo)" || _ok "comparacao maior negativa"
  [[ "$(delta 10 30)" == "0" ]] && _ok "delta nao negativo" || _fail "delta nao negativo"

  if mede_memoria; then
    if [[ -n "$MEDIDA_MEM" ]] && ! maior "$MEDIDA_MEM" 100 && ! menor "$MEDIDA_MEM" 0; then
      _ok "memoria medida (${MEDIDA_MEM}%)"
    else
      _fail "memoria fora de 0-100 (${MEDIDA_MEM})"
    fi
  else
    _fail "mede_memoria"
  fi

  mede_load && _ok "load medido (${MEDIDA_LOAD})" || _fail "mede_load"
  mede_disco && _ok "disco medido" || _fail "mede_disco"

  local estado_teste="__autoteste__"
  AGENTE_ESTADO="${AGENTE_ESTADO}" ; mkdir -p "$AGENTE_ESTADO" 2>/dev/null || true
  rm -f "$(caminho_estado "$estado_teste")" 2>/dev/null || true
  local i
  for i in 1 2; do avalia "$estado_teste" 99 85 95; done
  [[ "$AV_ACAO" == "nada" ]] && _ok "histerese segura os primeiros ciclos" || _fail "histerese disparou cedo (${AV_ACAO})"
  avalia "$estado_teste" 99 85 95
  [[ "$AV_ACAO" == "abrir" || "$AV_ACAO" == "escalar" ]] && _ok "alerta abre no terceiro ciclo" || _fail "alerta nao abriu (${AV_ACAO})"
  for i in 1 2 3; do avalia "$estado_teste" 10 85 95; done
  [[ "$AV_ACAO" == "resolver" ]] && _ok "recuperacao detectada" || _fail "recuperacao nao detectada (${AV_ACAO})"
  rm -f "$(caminho_estado "$estado_teste")" 2>/dev/null || true

  printf '%s\n' "$([[ "$falhas" -eq 0 ]] && printf 'autoteste verde' || printf "autoteste com ${falhas} falha(s)")"
  return "$falhas"
}

# ---------------------------------------------------------------------------
# Status: o que um humano precisa ver ao entrar no servidor
# ---------------------------------------------------------------------------

status() {
  carrega_config
  mede_cpu >/dev/null 2>&1 || true
  mede_memoria >/dev/null 2>&1 || true
  mede_load >/dev/null 2>&1 || true
  mede_disco >/dev/null 2>&1 || true

  printf 'Agente de monitoramento %s\n' "$AGENTE_VERSAO"
  printf 'Servidor: %s\n\n' "$SERVER_ID"
  printf '  CPU      %6s%%  (media de %s)\n' "${MEDIDA_CPU:-?}" "$(duracao_humana "${MEDIDA_CPU_JANELA:-0}")"
  printf '  iowait   %6s%%\n' "${MEDIDA_IOWAIT:-?}"
  printf '  steal    %6s%%\n' "${MEDIDA_STEAL:-?}"
  printf '  Memoria  %6s%%  (%.1f GB disponiveis de %.1f GB)\n' "${MEDIDA_MEM:-?}" \
    "$(awk -v k="${MEDIDA_MEM_DISP_KB:-0}" 'BEGIN{print k/1048576}')" \
    "$(awk -v k="${MEDIDA_MEM_TOTAL_KB:-0}" 'BEGIN{print k/1048576}')"
  if [[ "${MEDIDA_SWAP_TOTAL_KB:-0}" -gt 0 ]]; then
    printf '  Swap     %6s%%\n' "${MEDIDA_SWAP:-?}"
  else
    printf '  Swap          sem swap configurado\n'
  fi
  printf '  Load     %6s   (%s por nucleo, %s nucleos)\n' "${MEDIDA_LOAD_BRUTO:-?}" "${MEDIDA_LOAD:-?}" "${MEDIDA_NUCLEOS:-?}"
  printf '\n  Disco\n'
  local mnt uso ino resto
  while read -r mnt uso ino resto; do
    [[ -z "${mnt:-}" ]] && continue
    printf '    %-28s %3s%% usado  %3s%% inodes\n' "$mnt" "$uso" "$ino"
  done <<<"${MEDIDA_DISCO_LINHAS:-}"

  printf '\n  Limiares  atencao / critico\n'
  printf '    CPU      %s / %s\n' "$CPU_ATENCAO" "$CPU_CRITICO"
  printf '    Memoria  %s / %s\n' "$MEM_ATENCAO" "$MEM_CRITICO"
  printf '    Disco    %s / %s\n' "$DISCO_ATENCAO" "$DISCO_CRITICO"
  printf '  Confirma em %s leituras, recupera em %s, repete a cada %s min\n' \
    "$CICLOS_CONFIRMACAO" "$CICLOS_RECUPERACAO" "$RENOTIFICAR_MIN"

  if silencio_ativo; then
    printf '\n  SILENCIO ATIVO: %s restantes (%s)\n' "$(duracao_humana "$SILENCIO_RESTA")" "${SILENCIO_MOTIVO:-sem motivo}"
  fi

  printf '\n  Estados abertos\n'
  local achou=0 f chave
  for f in "$AGENTE_ESTADO"/*.state; do
    [[ -f "$f" ]] || continue
    grep -q '^NIVEL=ok$' "$f" 2>/dev/null && continue
    chave="$(basename "$f" .state)"
    printf '    %-24s %s desde %s\n' "$chave" \
      "$(awk -F= '/^NIVEL=/{print $2}' "$f")" \
      "$(date -d "@$(awk -F= '/^DESDE=/{print $2}' "$f")" '+%d/%m %H:%M' 2>/dev/null || printf '?')"
    achou=1
  done
  [[ "$achou" -eq 0 ]] && printf '    nenhum\n'
  printf '\n'
}

# ---------------------------------------------------------------------------
# Entrada
# ---------------------------------------------------------------------------

uso() {
  cat <<'AJUDA'
Agente de monitoramento de servidores.

  monitoring-agent.sh rodada            mede, avalia e notifica (e o que o cron chama)
  monitoring-agent.sh status            mostra o estado atual do servidor
  monitoring-agent.sh autoteste         valida a instalacao; sai diferente de 0 se algo quebrou
  monitoring-agent.sh silenciar 15m "deploy da api"
                                        suprime alertas por um tempo, sem parar a coleta
  monitoring-agent.sh falar             encerra o silencio agora
  monitoring-agent.sh atualizar         busca e aplica atualizacao, com rollback se o autoteste falhar
  monitoring-agent.sh instalar          (re)instala o agente e migra o cron
  monitoring-agent.sh versao

Configuracao: /opt/monitoring/agent.conf
Registro:     /var/log/monitoring-agent.log
AJUDA
}

principal() {
  local comando="${1:-}"

  # Chamado pelo nome antigo (monitor_cpu.sh e companhia) a partir de um cron
  # que ainda nao migrou: faz a migracao e segue com a rodada.
  local eu_chamado
  eu_chamado="$(basename "${0:-monitoring-agent.sh}")"
  case "$eu_chamado" in
    monitor_cpu.sh|monitor_memory.sh|monitor_disk.sh)
      carrega_config
      if precisa_bootstrap; then
        roda_bootstrap || true
      fi
      # Apenas um dos tres executa a rodada; os outros sairiam na trava de
      # qualquer forma, mas assim nem tentam.
      [[ "$eu_chamado" == "monitor_cpu.sh" ]] && { rodada; return $?; }
      return 0
      ;;
  esac

  case "$comando" in
    rodada|"")
      carrega_config
      if precisa_bootstrap; then roda_bootstrap || true; fi
      rodada
      ;;
    status)     status ;;
    autoteste)  autoteste ;;
    silenciar)  carrega_config; inicia_silencio "${2:-15m}" "${3:-manutencao}"; printf 'Alertas suprimidos por %s (%s). A coleta continua.\n' "${2:-15m}" "${3:-manutencao}" ;;
    falar)      carrega_config; encerra_silencio; printf 'Silencio encerrado.\n' ;;
    atualizar)  carrega_config; atualiza_agente; printf 'Versao instalada: %s\n' "$(versao_instalada)" ;;
    instalar)   carrega_config; roda_bootstrap && printf 'Agente %s instalado.\n' "$AGENTE_VERSAO" ;;
    versao)     printf '%s\n' "$AGENTE_VERSAO" ;;
    ajuda|-h|--help) uso ;;
    *)          uso; return 1 ;;
  esac
}

# A bateria de testes carrega este arquivo com "source" para exercitar as
# funcoes uma a uma. Nesse caso nao ha comando a executar.
if [[ "${AGENTE_SO_CARREGAR:-0}" != "1" ]]; then
  principal "$@"
fi
