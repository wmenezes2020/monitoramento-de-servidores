
# ---------------------------------------------------------------------------
# Bootstrap: migracao automatica da base ja instalada
# ---------------------------------------------------------------------------
#
# O unico canal que alcanca um servidor instalado hoje sao os tres arquivos que
# o dashboard_fetch_updates.sh baixa a cada minuto: monitor_cpu.sh,
# monitor_memory.sh e monitor_disk.sh. Por isso cada um deles passa a ser o
# bundle inteiro do agente.
#
# Ao rodar pela primeira vez, o bundle se instala como monitoring-agent.sh,
# converte a configuracao antiga, troca as quatro linhas do cron por uma, e seg
# ue com a rodada normal. Se qualquer passo falhar, os tres scripts continuam
# funcionando sozinhos, porque cada um e o agente completo. Nao existe estado
# intermediario quebrado.

# ATENCAO: as quatro linhas abaixo precisam comecar exatamente com estes nomes.
# O canal de atualizacao antigo (dashboard_fetch_updates.sh) aplica
#   sed -i "s/^CPU_THRESHOLD=.*/CPU_THRESHOLD=$CPU/"
#   sed -i "s|^RECIPIENTS=.*|RECIPIENTS=\"$NOVOS\"|"
# dentro do arquivo que ele baixa. Mantendo o formato, um servidor que ainda
# nao migrou continua recebendo limiar e destinatario do painel normalmente.
# Depois da migracao quem manda e o /opt/monitoring/agent.conf.
CPU_THRESHOLD=90
MEM_THRESHOLD=90
DISK_THRESHOLD=90
RECIPIENTS="RECIPIENTS_PLACEHOLDER"

CRON_MARCA_V2="# --- Agente de monitoramento v2 (gerado, nao editar a mao) ---"
CRON_MARCA_V1="# --- Monitoramento de CPU, Memoria, Disco e Antivirus ---"

# Via "id -u" e nao via $EUID porque $EUID e somente leitura no bash, o que
# impede o teste de integracao de encenar um servidor rodando como root.
sou_root() { [[ "$(id -u 2>/dev/null || printf 1000)" -eq 0 ]]; }

# Caminho do proprio arquivo em execucao, quando existe. Rodando por pipe
# (curl | bash) nao existe arquivo, e aí o bundle se baixa.
meu_caminho() {
  local p="${BASH_SOURCE[0]:-$0}"
  [[ -r "$p" && -f "$p" ]] && { printf '%s' "$p"; return 0; }
  return 1
}

precisa_bootstrap() {
  [[ ! -x "${AGENTE_BIN}/monitoring-agent.sh" ]] && return 0
  local v
  v="$(grep -m1 '^AGENTE_VERSAO=' "${AGENTE_BIN}/monitoring-agent.sh" 2>/dev/null | cut -d'"' -f2)"
  [[ -z "$v" ]] && return 0
  versao_maior "$AGENTE_VERSAO" "$v" && return 0
  # Cron ainda no formato antigo: migrar mesmo com a versao em dia.
  crontab -l 2>/dev/null | grep -qF "$CRON_MARCA_V2" || return 0
  return 1
}

# Converte a configuracao do agente antigo. Os limiares antigos eram um valor
# so por metrica, usado como "dispara aqui". Viram o limiar critico, e o de
# atencao fica 10 pontos abaixo, o que da espaco para o aviso chegar antes do
# problema.
escreve_config_inicial() {
  local arq="${AGENTE_RAIZ}/agent.conf"
  [[ -f "$arq" ]] && { log_info "agent.conf ja existe; preservado"; return 0; }

  local cpu_cr mem_cr disco_cr
  cpu_cr="$(le_legado CPU)"; mem_cr="$(le_legado MEM)"; disco_cr="$(le_legado DISK)"

  mkdir -p "$AGENTE_RAIZ" 2>/dev/null || true
  cat <<CONF | escreve_atomico "$arq"
# Configuracao do agente de monitoramento.
# Gerado na migracao em $(date '+%Y-%m-%d %H:%M:%S').
# Os limiares tambem chegam do painel; editar aqui vale ate a proxima sincronia.

# Limiares. "atencao" avisa, "critico" escala.
CPU_ATENCAO=$(awk -v v="$cpu_cr" 'BEGIN{r=v-10; if(r<50) r=50; printf "%d", r}')
CPU_CRITICO=${cpu_cr}
MEM_ATENCAO=$(awk -v v="$mem_cr" 'BEGIN{r=v-10; if(r<50) r=50; printf "%d", r}')
MEM_CRITICO=${mem_cr}
DISCO_ATENCAO=$(awk -v v="$disco_cr" 'BEGIN{r=v-10; if(r<50) r=50; printf "%d", r}')
DISCO_CRITICO=${disco_cr}

# Histerese. E o que separa "o valor passou do limiar num instante" de
# "existe um problema acontecendo".
CICLOS_CONFIRMACAO=3
CICLOS_RECUPERACAO=3
BANDA_SAIDA=8
RENOTIFICAR_MIN=60
MAX_ALERTAS_HORA=12
ALERTA_RECUPERACAO=1

# Canais
CANAL_EMAIL=1
CANAL_TELEGRAM=1
CANAL_DASHBOARD=1
RECUPERACAO_TELEGRAM=0

# Auto-atualizacao
AUTO_UPDATE=1
UPDATE_CANAL=main
CONF
  chmod 644 "$arq" 2>/dev/null || true
  log_info "agent.conf criado a partir da configuracao antiga (cpu=${cpu_cr} mem=${mem_cr} disco=${disco_cr})"
}

# O limiar antigo vem do proprio arquivo em execucao, porque e ali que o canal
# antigo gravava o valor do painel. Se este bundle veio limpo do repositorio,
# ainda ha os scripts instalados no disco para consultar.
le_legado() {
  local qual="$1" v="" arq
  v="$(eval "printf '%s' \"\${${qual}_THRESHOLD:-}\"" | tr -cd '0-9')"
  if [[ -z "$v" || "$v" == "90" ]]; then
    case "$qual" in
      CPU)  arq="${AGENTE_BIN}/monitor_cpu.sh" ;;
      MEM)  arq="${AGENTE_BIN}/monitor_memory.sh" ;;
      DISK) arq="${AGENTE_BIN}/monitor_disk.sh" ;;
    esac
    if [[ -f "$arq" ]]; then
      local do_disco
      do_disco="$(grep -m1 "^${qual}_THRESHOLD=" "$arq" 2>/dev/null | cut -d= -f2 | tr -cd '0-9')"
      [[ -n "$do_disco" ]] && v="$do_disco"
    fi
  fi
  [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 1 ]] && [[ "$v" -le 100 ]] || v=90
  printf '%s' "$v"
}

# Os destinatarios de e-mail vivem dentro dos scripts no modelo antigo. Depois
# da migracao passam a viver no email.conf, que e lugar de configuracao.
preserva_destinatarios() {
  local atual="${RECIPIENTS:-}" arq
  [[ "$atual" == *PLACEHOLDER* ]] && atual=""
  if [[ -z "$atual" ]]; then
    for arq in "${AGENTE_BIN}/monitor_cpu.sh" "${AGENTE_BIN}/monitor_memory.sh" "${AGENTE_BIN}/monitor_disk.sh"; do
      [[ -f "$arq" ]] || continue
      atual="$(grep -m1 '^RECIPIENTS=' "$arq" 2>/dev/null | sed 's/^RECIPIENTS="\{0,1\}//; s/"\{0,1\}$//')"
      [[ -n "$atual" && "$atual" != *PLACEHOLDER* ]] && break
      atual=""
    done
  fi
  [[ -z "$atual" ]] && return 0

  mkdir -p "$AGENTE_RAIZ" 2>/dev/null || true
  if [[ -f "${AGENTE_RAIZ}/email.conf" ]]; then
    if grep -q '^RECIPIENTS=' "${AGENTE_RAIZ}/email.conf" 2>/dev/null; then
      sed -i "s|^RECIPIENTS=.*|RECIPIENTS=\"${atual}\"|" "${AGENTE_RAIZ}/email.conf" 2>/dev/null || true
    else
      printf 'RECIPIENTS="%s"\n' "$atual" >>"${AGENTE_RAIZ}/email.conf" 2>/dev/null || true
    fi
  else
    printf 'RECIPIENTS="%s"\n' "$atual" | escreve_atomico "${AGENTE_RAIZ}/email.conf"
    chmod 640 "${AGENTE_RAIZ}/email.conf" 2>/dev/null || true
  fi
  log_info "destinatarios preservados em email.conf"
}

# Quatro execucoes por minuto viram uma. O cron antigo rodava monitor_cpu,
# monitor_memory, monitor_disk e dashboard_fetch_updates a cada minuto, cada um
# chamando top e ps aux duas vezes.
instala_cron() {
  command -v crontab >/dev/null 2>&1 || { log_erro "crontab nao encontrado; cron nao migrado"; return 1; }

  local atual novo
  atual="$(crontab -l 2>/dev/null || true)"

  # Filtra por conteudo, sem flag de "estou dentro do bloco". A versao com
  # flag se perdia: a linha do ClamAV no meio do bloco nao casava com nenhuma
  # regra de descarte, desligava o modo, e o dashboard_fetch_updates logo
  # abaixo sobrevivia. O resultado seria o canal antigo reescrevendo os
  # scripts por baixo do agente novo, a cada minuto, para sempre.
  #
  # Tudo que nao e do monitoramento fica, inclusive o ClamAV e o que o dono
  # do servidor agendou.
  novo="$(printf '%s\n' "$atual" | awk -v m1="$CRON_MARCA_V1" -v m2="$CRON_MARCA_V2" '
    $0 == m1 || $0 == m2 { next }
    /monitor_cpu\.sh|monitor_memory\.sh|monitor_disk\.sh/ { next }
    /dashboard_fetch_updates\.sh/ { next }
    /monitoring-agent\.sh/ { next }
    /^#[[:space:]]*Monitoramento (CPU|Memoria|Mem.ria|Disco)/ { next }
    /^#[[:space:]]*Consulta ao Dashboard/ { next }
    /^#[[:space:]]*Agente de monitoramento/ { next }
    { print }
  ' | awk 'BEGIN{vazias=0}
    /^[[:space:]]*$/ { vazias++; next }
    { while (vazias-- > 0 && NR > 1) print ""; vazias=0; print }
  ')"

  novo="$(printf '%s\n%s\n%s\n' "$novo" "$CRON_MARCA_V2" "* * * * * ${AGENTE_BIN}/monitoring-agent.sh rodada >/dev/null 2>&1")"

  printf '%s\n' "$novo" | crontab - 2>/dev/null || { log_erro "nao consegui escrever o crontab"; return 1; }
  log_info "cron migrado para uma linha unica"
  return 0
}

# Instala este mesmo arquivo como o agente, e deixa os tres nomes antigos
# apontando para ele. Quem tiver script ou runbook chamando monitor_cpu.sh
# continua funcionando.
instala_binarios() {
  local eu
  if ! eu="$(meu_caminho)"; then
    log_erro "rodando sem arquivo (pipe); instalacao do binario pulada"
    return 1
  fi

  mkdir -p "$AGENTE_BIN" "$AGENTE_RAIZ" "$AGENTE_ESTADO" 2>/dev/null || true

  local staging
  staging="$(mktemp "${AGENTE_BIN}/.agent.XXXXXX" 2>/dev/null)" || return 1
  cat "$eu" >"$staging" 2>/dev/null || { rm -f "$staging"; return 1; }
  if ! bash -n "$staging" 2>/dev/null; then
    log_erro "o proprio bundle nao passa em bash -n; instalacao abortada"
    rm -f "$staging"; return 1
  fi
  chmod 755 "$staging" 2>/dev/null || true
  mv -f "$staging" "${AGENTE_BIN}/monitoring-agent.sh" || { rm -f "$staging"; return 1; }

  printf '%s' "$AGENTE_VERSAO" | escreve_atomico "${AGENTE_RAIZ}/VERSION" 2>/dev/null || true
  log_info "monitoring-agent.sh ${AGENTE_VERSAO} instalado"
  return 0
}

roda_bootstrap() {
  if ! sou_root; then
    log_erro "bootstrap precisa de root; seguindo apenas com a rodada de medicao"
    return 1
  fi
  log_info "iniciando migracao para a versao ${AGENTE_VERSAO}"
  preserva_destinatarios
  escreve_config_inicial
  instala_binarios || return 1
  instala_cron || log_erro "cron nao migrado; os scripts antigos seguem chamando o agente novo"
  log_info "migracao concluida"
  return 0
}
