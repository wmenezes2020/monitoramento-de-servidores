
# ---------------------------------------------------------------------------
# Configuracao
# ---------------------------------------------------------------------------
#
# Precedencia, do mais fraco para o mais forte:
#   padrao embutido  <  /opt/monitoring/agent.conf  <  variavel de ambiente
#
# Os limiares tambem chegam do painel, pelo dashboard_fetch_updates.sh, que
# escreve no agent.conf. Assim existe um lugar so com a verdade, em vez do
# "sed no meio do script" que o agente antigo fazia.

carrega_config() {
  # --- Limiares por metrica: atencao e critico sao coisas diferentes ---
  CPU_ATENCAO="${CPU_ATENCAO:-85}"
  CPU_CRITICO="${CPU_CRITICO:-95}"
  MEM_ATENCAO="${MEM_ATENCAO:-85}"
  MEM_CRITICO="${MEM_CRITICO:-95}"
  DISCO_ATENCAO="${DISCO_ATENCAO:-85}"
  DISCO_CRITICO="${DISCO_CRITICO:-93}"
  SWAP_ATENCAO="${SWAP_ATENCAO:-50}"
  SWAP_CRITICO="${SWAP_CRITICO:-80}"
  INODE_ATENCAO="${INODE_ATENCAO:-85}"
  INODE_CRITICO="${INODE_CRITICO:-93}"
  # Load normalizado por nucleo. 1.0 = todos os nucleos ocupados sem fila.
  LOAD_ATENCAO="${LOAD_ATENCAO:-1.5}"
  LOAD_CRITICO="${LOAD_CRITICO:-3.0}"
  # Steal alto em instancia burstable (EC2 t2/t3/t3a) significa credito de CPU
  # esgotado: o limite e do provedor, nao do servidor.
  STEAL_ATENCAO="${STEAL_ATENCAO:-10}"
  STEAL_CRITICO="${STEAL_CRITICO:-25}"

  # --- Histerese: o coracao do "parar de alertar a toa" ---
  CICLOS_CONFIRMACAO="${CICLOS_CONFIRMACAO:-3}"
  CICLOS_RECUPERACAO="${CICLOS_RECUPERACAO:-3}"
  BANDA_SAIDA="${BANDA_SAIDA:-8}"
  RENOTIFICAR_MIN="${RENOTIFICAR_MIN:-60}"
  MAX_ALERTAS_HORA="${MAX_ALERTAS_HORA:-12}"
  ALERTA_RECUPERACAO="${ALERTA_RECUPERACAO:-1}"

  # --- Quais metricas vigiar ---
  VIGIAR_CPU="${VIGIAR_CPU:-1}"
  VIGIAR_MEMORIA="${VIGIAR_MEMORIA:-1}"
  VIGIAR_DISCO="${VIGIAR_DISCO:-1}"
  VIGIAR_SWAP="${VIGIAR_SWAP:-1}"
  VIGIAR_LOAD="${VIGIAR_LOAD:-1}"
  VIGIAR_INODE="${VIGIAR_INODE:-1}"
  VIGIAR_STEAL="${VIGIAR_STEAL:-1}"

  # Pontos de montagem a ignorar, separados por espaco. Volume de container e
  # snap aparecem no df e nao sao problema de ninguem. /dev/shm e memoria
  # compartilhada: cheia e o funcionamento normal, nao falta de disco.
  # O df ja filtra por tipo com -x, mas a lista vale como segunda linha para
  # versao antiga de df que ignore o -x.
  DISCO_IGNORAR="${DISCO_IGNORAR:-/var/lib/docker/* /snap/* /run/* /dev/shm /dev/* }"

  # --- Canais ---
  CANAL_EMAIL="${CANAL_EMAIL:-1}"
  CANAL_TELEGRAM="${CANAL_TELEGRAM:-1}"
  CANAL_DASHBOARD="${CANAL_DASHBOARD:-1}"
  # Recuperacao e informacao, nao urgencia: por padrao nao acorda ninguem no
  # Telegram, so registra por e-mail e no painel.
  RECUPERACAO_TELEGRAM="${RECUPERACAO_TELEGRAM:-0}"

  # --- Auto-atualizacao ---
  AUTO_UPDATE="${AUTO_UPDATE:-1}"
  UPDATE_CANAL="${UPDATE_CANAL:-main}"
  UPDATE_BASE_URL="${UPDATE_BASE_URL:-https://raw.githubusercontent.com/wmenezes2020/monitoramento-de-servidores}"

  # Arquivo do usuario por cima dos padroes
  if [[ -f "${AGENTE_RAIZ}/agent.conf" ]]; then
    # shellcheck disable=SC1090
    source "${AGENTE_RAIZ}/agent.conf" 2>/dev/null || log_erro "agent.conf ilegivel, seguindo com os padroes"
  fi

  # Os destinatarios podem vir de tres lugares: a linha RECIPIENTS= no topo
  # deste arquivo (que o canal antigo edita com sed), o email.conf, ou o
  # painel. O email.conf vence, porque e configuracao de verdade; a linha do
  # topo serve de ponte para servidor que ainda nao migrou.
  local recip_do_script="${RECIPIENTS:-}"
  [[ "$recip_do_script" == *PLACEHOLDER* ]] && recip_do_script=""
  RECIPIENTS=""

  # Configuracoes herdadas do instalador antigo
  [[ -f "${AGENTE_RAIZ}/email.conf" ]] && { source "${AGENTE_RAIZ}/email.conf" 2>/dev/null || true; }
  [[ -f "${AGENTE_RAIZ}/dashboard.conf" ]] && { source "${AGENTE_RAIZ}/dashboard.conf" 2>/dev/null || true; }

  SERVER_ID="${SERVER_ID:-$(hostname 2>/dev/null || echo desconhecido)}"
  [[ -z "${RECIPIENTS:-}" ]] && RECIPIENTS="$recip_do_script"
  [[ "${RECIPIENTS:-}" == *PLACEHOLDER* ]] && RECIPIENTS=""
  DASHBOARD_ENABLED="${DASHBOARD_ENABLED:-0}"
  DASHBOARD_SERVER_UUID="${DASHBOARD_SERVER_UUID:-}"
  DASHBOARD_API_URL="${DASHBOARD_API_URL:-https://api-observabilidade.edeniva.com.br/v1}"

  valida_config
}

# Limiar invertido (critico abaixo do atencao) nunca escala, e limiar fora de
# 1-100 nunca dispara. Os dois casos passariam despercebidos para sempre.
valida_config() {
  local m
  for m in CPU MEM DISCO SWAP INODE STEAL; do
    local at cr
    at="$(eval "printf '%s' \"\${${m}_ATENCAO}\"")"
    cr="$(eval "printf '%s' \"\${${m}_CRITICO}\"")"
    if ! [[ "$at" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! [[ "$cr" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      log_erro "limiar de ${m} nao e numero (atencao=${at} critico=${cr}); metrica desligada"
      eval "VIGIAR_$(mapeia_vigiar "$m")=0"
      continue
    fi
    if maior "$at" "$cr"; then
      log_erro "limiar de ${m}: atencao (${at}) acima do critico (${cr}); invertendo"
      eval "${m}_ATENCAO=${cr}"
      eval "${m}_CRITICO=${at}"
    fi
  done
  for v in CICLOS_CONFIRMACAO CICLOS_RECUPERACAO; do
    local atual
    atual="$(eval "printf '%s' \"\${$v}\"")"
    if ! [[ "$atual" =~ ^[0-9]+$ ]] || [[ "$atual" -lt 1 ]]; then
      log_erro "${v}=${atual} invalido; usando 3"
      eval "${v}=3"
    fi
  done
}

mapeia_vigiar() {
  case "$1" in
    CPU) printf 'CPU' ;;
    MEM) printf 'MEMORIA' ;;
    DISCO) printf 'DISCO' ;;
    SWAP) printf 'SWAP' ;;
    INODE) printf 'INODE' ;;
    STEAL) printf 'STEAL' ;;
    *) printf 'NADA' ;;
  esac
}

# Limiares de uma metrica, pelo nome curto usado na avaliacao
limiar_de() {
  case "$1" in
    cpu)    printf '%s %s' "$CPU_ATENCAO" "$CPU_CRITICO" ;;
    memoria)printf '%s %s' "$MEM_ATENCAO" "$MEM_CRITICO" ;;
    disco)  printf '%s %s' "$DISCO_ATENCAO" "$DISCO_CRITICO" ;;
    inode)  printf '%s %s' "$INODE_ATENCAO" "$INODE_CRITICO" ;;
    swap)   printf '%s %s' "$SWAP_ATENCAO" "$SWAP_CRITICO" ;;
    load)   printf '%s %s' "$LOAD_ATENCAO" "$LOAD_CRITICO" ;;
    steal)  printf '%s %s' "$STEAL_ATENCAO" "$STEAL_CRITICO" ;;
    *)      printf '90 95' ;;
  esac
}
