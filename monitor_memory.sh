#!/usr/bin/env bash
#
# Agente de monitoramento de servidores.
# Repositorio: https://github.com/wmenezes2020/monitoramento-de-servidores
#
# Este arquivo e gerado por scripts/build.sh a partir de src/agent/*.sh.
# Nao editar direto: a proxima atualizacao sobrescreve.
#
# Sem "set -e" de proposito. Um comando auxiliar que falha (curl, du, ps) nao
# pode derrubar a rodada inteira de monitoramento: o resultado seria um servidor
# sem vigilancia nenhuma e ninguem sabendo. Cada passo trata o proprio erro e
# registra em /var/log/monitoring-agent.log.
set -uo pipefail

# A versao e o unico carimbo. Carimbar o commit tornaria o bundle diferente a
# cada commit mesmo sem mudanca em src/, o checksum do manifesto mudaria
# sozinho, e o "build --check" do CI reprovaria sempre.
AGENTE_VERSAO="2.1.0"


# ---------------------------------------------------------------------------
# Utilitarios
# ---------------------------------------------------------------------------

# Caminhos. Todos sobrescrituveis por variavel de ambiente, que e o que permite
# rodar a bateria de testes sem root e sem /proc de verdade.
AGENTE_RAIZ="${AGENTE_RAIZ:-/opt/monitoring}"
AGENTE_ESTADO="${AGENTE_ESTADO:-/var/lib/monitoring/state}"
AGENTE_LOG="${AGENTE_LOG:-/var/log/monitoring-agent.log}"
AGENTE_BIN="${AGENTE_BIN:-/usr/local/bin}"
PROC_STAT="${PROC_STAT:-/proc/stat}"
PROC_MEMINFO="${PROC_MEMINFO:-/proc/meminfo}"
PROC_LOADAVG="${PROC_LOADAVG:-/proc/loadavg}"

# Tamanho maximo do log antes de rotacionar. Monitoramento que enche o disco
# que ele deveria vigiar ja aconteceu em servidor de gente seria.
LOG_MAX_BYTES="${LOG_MAX_BYTES:-2097152}"

log() {
  local nivel="$1"; shift
  local linha
  linha="$(date '+%Y-%m-%d %H:%M:%S') [$nivel] $*"
  if [[ -w "$(dirname "$AGENTE_LOG")" ]] || [[ -w "$AGENTE_LOG" ]]; then
    if [[ -f "$AGENTE_LOG" ]]; then
      local tam
      tam=$(wc -c <"$AGENTE_LOG" 2>/dev/null || echo 0)
      if [[ "${tam:-0}" -gt "$LOG_MAX_BYTES" ]]; then
        mv -f "$AGENTE_LOG" "${AGENTE_LOG}.1" 2>/dev/null || true
      fi
    fi
    printf '%s\n' "$linha" >>"$AGENTE_LOG" 2>/dev/null || true
  fi
  [[ "${AGENTE_VERBOSO:-0}" == "1" ]] && printf '%s\n' "$linha" >&2
  return 0
}

log_erro() { log ERRO "$@"; }
log_info() { log INFO "$@"; }

# Aritmetica em awk. "bc" nao esta em todo servidor, e com "set -e" no script
# antigo a falta dele matava o monitor em silencio.
num() { awk -v v="${1:-0}" -v d="${2:-1}" 'BEGIN{printf "%.*f", d, v+0}'; }

# maior A B -> sucesso (0) quando A > B
maior() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a+0 > b+0)}'; }

# menor A B -> sucesso (0) quando A < B
menor() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a+0 < b+0)}'; }

# pct PARTE TOTAL -> percentual com uma casa; total zero devolve 0.0
pct() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{
    if (b+0 == 0) { printf "0.0"; exit }
    printf "%.1f", (a/b)*100
  }'
}

# subtrai A B, nunca negativo (contador de /proc pode zerar no reboot)
delta() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{d=a-b; if (d<0) d=0; printf "%.0f", d}'; }

agora() { date +%s; }

# Escrita atomica: grava num temporario no MESMO diretorio e move por cima.
# mv entre filesystems diferentes nao e atomico, e era assim que o atualizador
# antigo instalava script vindo de /tmp.
escreve_atomico() {
  local destino="$1"
  local dir tmp
  dir="$(dirname "$destino")"
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$(mktemp "${dir}/.tmp.XXXXXX" 2>/dev/null)" || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod --reference="$destino" "$tmp" 2>/dev/null || chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$destino" || { rm -f "$tmp"; return 1; }
  return 0
}

# Escapa para HTML
escapa_html() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# Escapa para campo string de JSON
escapa_json() {
  awk 'BEGIN{ORS=""} {
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"")
    print $0 "\\n"
  }'
}

# Trava por arquivo: duas rodadas do agente ao mesmo tempo corromperiam o
# estado da histerese. Usa mkdir, que e atomico em qualquer filesystem POSIX.
TRAVA_DIR=""
pega_trava() {
  local nome="${1:-agente}"
  TRAVA_DIR="${AGENTE_ESTADO}/.lock-${nome}"
  mkdir -p "$AGENTE_ESTADO" 2>/dev/null || true
  if mkdir "$TRAVA_DIR" 2>/dev/null; then
    printf '%s' "$$" >"${TRAVA_DIR}/pid" 2>/dev/null || true
    trap 'solta_trava' EXIT INT TERM
    return 0
  fi
  # Trava presa por processo que ja morreu (OOM kill, reboot) e liberada.
  local pid_antigo idade
  pid_antigo="$(cat "${TRAVA_DIR}/pid" 2>/dev/null || echo "")"
  if [[ -n "$pid_antigo" ]] && ! kill -0 "$pid_antigo" 2>/dev/null; then
    rm -rf "$TRAVA_DIR" 2>/dev/null || true
    mkdir "$TRAVA_DIR" 2>/dev/null || return 1
    printf '%s' "$$" >"${TRAVA_DIR}/pid" 2>/dev/null || true
    trap 'solta_trava' EXIT INT TERM
    log_info "trava orfa do pid ${pid_antigo} liberada"
    return 0
  fi
  idade=$(( $(agora) - $(stat -c %Y "$TRAVA_DIR" 2>/dev/null || echo 0) ))
  if [[ "$idade" -gt 900 ]]; then
    rm -rf "$TRAVA_DIR" 2>/dev/null || true
    log_erro "trava com ${idade}s liberada por tempo"
    return 1
  fi
  return 1
}

solta_trava() {
  [[ -n "$TRAVA_DIR" ]] && rm -rf "$TRAVA_DIR" 2>/dev/null || true
  return 0
}

# Numero de nucleos, com os dois caminhos que existem num container
nucleos() {
  local n
  n="$(nproc 2>/dev/null || true)"
  [[ -z "$n" ]] && n="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
  [[ -z "$n" || "$n" -lt 1 ]] && n=1
  printf '%s' "$n"
}

# Converte "15m", "2h", "90s", "30" (segundos) em segundos
para_segundos() {
  local v="${1:-0}"
  case "$v" in
    *s) printf '%s' "${v%s}" ;;
    *m) awk -v n="${v%m}" 'BEGIN{printf "%d", n*60}' ;;
    *h) awk -v n="${v%h}" 'BEGIN{printf "%d", n*3600}' ;;
    *d) awk -v n="${v%d}" 'BEGIN{printf "%d", n*86400}' ;;
    *)  printf '%s' "$v" ;;
  esac
}

# duracao_humana vive em 25-idioma.sh: a unidade muda com o idioma.


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
  # Steal sozinho NAO e incidente. Em instancia burstable (EC2 t2/t3/t3a) ele
  # aparece toda vez que a maquina usa burst acima do baseline: e o mecanismo
  # funcionando. Medicao real de 09/10/2026 num t3a.xlarge: steal de 16,6% com
  # a CPU em 29,5% e load de 0,41 por nucleo, ou seja, servidor tranquilo. Com
  # o limiar antigo de 10 isso virou e-mail, que e exatamente o alerta que
  # ensina a pessoa a ignorar os outros.
  #
  # Steal so vira problema quando o servidor QUER CPU e o provedor nao da.
  # Por isso o limiar subiu e a avaliacao passou a exigir CPU alta junto
  # (ver VIGIAR_STEAL em 90-main.sh).
  STEAL_ATENCAO="${STEAL_ATENCAO:-25}"
  STEAL_CRITICO="${STEAL_CRITICO:-40}"

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

  # --- Idioma ---
  # pt-BR, en-US ou es-CO. Chega do painel junto com os limiares. O padrao e
  # es-CO porque servidor instalado sem conectar ao painel nao tem de quem
  # herdar idioma, e essa foi a decisao do dono do produto.
  IDIOMA="${IDIOMA:-es-CO}"

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


# ---------------------------------------------------------------------------
# Idioma
# ---------------------------------------------------------------------------
#
# Tres idiomas: pt-BR, en-US e es-CO. O idioma chega do painel, junto com os
# limiares, e vale para e-mail, Telegram e para os templates HTML em disco.
#
# O padrao e es-CO de proposito: servidor instalado sem conectar ao painel nao
# tem de quem herdar idioma, e a decisao do dono foi essa.
#
# Nome de metrica: Swap, Inodes e Load average ficam como estao, porque e
# assim que aparecem no top, no vmstat, no CloudWatch e no Grafana.
#
# "steal" e o caso que precisou de cuidado. "CPU roubada" era traducao literal,
# nao existe em ferramenta nenhuma e assusta quem le: roubo sugere invasao,
# quando o fenomeno e o provedor limitando a fatia contratada. O rotulo passou
# a ser "Contencao de CPU" (CPU contention, termo usado em VMware, Nutanix e
# Kubernetes), e a palavra "steal" continua na linha tecnica da tabela de
# contexto, que e onde ela serve: para a pessoa pesquisar.

idioma_normalizado() {
  case "$(printf '%s' "${IDIOMA:-es-CO}" | tr '[:upper:]' '[:lower:]')" in
    pt*) printf 'pt' ;;
    en*) printf 'en' ;;
    *)   printf 'es' ;;
  esac
}

# t CHAVE [args...] -> texto no idioma vigente, com printf aplicado.
# Chave sem traducao no idioma cai no espanhol, que e o padrao do produto, em
# vez de sumir e deixar um alerta com buraco no meio.
t() {
  local chave="$1"; shift
  local modelo
  case "$(idioma_normalizado)" in
    pt) modelo="$(msg_pt "$chave")" ;;
    en) modelo="$(msg_en "$chave")" ;;
    *)  modelo="$(msg_es "$chave")" ;;
  esac
  [[ -z "$modelo" ]] && modelo="$(msg_es "$chave")"
  [[ -z "$modelo" ]] && modelo="$chave"
  # shellcheck disable=SC2059
  printf "$modelo" "$@"
}

# Nomes que NAO se traduzem, em nenhum idioma.
rotulo_metrica() {
  case "$1" in
    cpu)          printf 'CPU' ;;
    memoria)      printf '%s' "$(t rotulo_memoria)" ;;
    disco)        printf '%s' "$(t rotulo_disco)" ;;
    inode)        printf 'Inodes' ;;
    swap)         printf 'Swap' ;;
    load)         printf '%s' "$(t rotulo_load)" ;;
    steal)        printf '%s' "$(t rotulo_steal)" ;;
    agent_update) printf '%s' "$(t rotulo_agente)" ;;
    *)            printf '%s' "$1" ;;
  esac
}

unidade_metrica() {
  case "$1" in
    load) printf '' ;;
    *) printf '%%' ;;
  esac
}

prefixo_assunto() {
  case "$1" in
    abrir)    printf '[%s]' "$(t sev_atencao)" ;;
    escalar)  printf '[%s]' "$(t sev_critico)" ;;
    repetir)  printf '[%s]' "$(t sev_segue)" ;;
    resolver) printf '[%s]' "$(t sev_ok)" ;;
    *)        printf '[%s]' "$(t sev_aviso)" ;;
  esac
}

# Data no formato que cada lugar le sem precisar pensar.
data_local() {
  case "$(idioma_normalizado)" in
    en) date '+%Y-%m-%d %H:%M:%S %Z' ;;
    *)  date '+%d/%m/%Y %H:%M:%S %Z' ;;
  esac
}

duracao_humana() {
  local s="${1:-0}"
  awk -v s="$s" -v u_s="$(t dur_segundos)" -v u_m="$(t dur_minutos)" \
      -v u_h="$(t dur_horas)" -v u_d="$(t dur_dias)" 'BEGIN{
    s = int(s)
    if (s < 60)    { printf "%d%s", s, u_s; exit }
    if (s < 3600)  { printf "%d%s", int(s/60), u_m; exit }
    if (s < 86400) { printf "%d%s%02d%s", int(s/3600), u_h, int((s%3600)/60), u_m; exit }
    printf "%dd%d%s", int(s/86400), int((s%86400)/3600), u_h
  }'
}

# --- Catalogos ------------------------------------------------------------
#
# Um "case" por idioma. Bash associativo com "set -u" explode em chave que nao
# existe, e aqui chave faltando precisa cair no padrao, nao derrubar a rodada.
#
# As strings passam por printf: "%" literal precisa vir como "%%".

msg_pt() {
  case "$1" in
    rotulo_memoria) printf 'Memória' ;;
    rotulo_steal)   printf 'Contenção de CPU' ;;
    rotulo_load)    printf 'Load average' ;;
    tabela_steal)   printf 'Contenção (steal)' ;;
    rotulo_disco)   printf 'Disco' ;;
    rotulo_agente)  printf 'Agente' ;;

    sev_atencao) printf 'ATENÇÃO' ;;
    sev_critico) printf 'CRÍTICO' ;;
    sev_segue)   printf 'SEGUE' ;;
    sev_ok)      printf 'OK' ;;
    sev_aviso)   printf 'AVISO' ;;
    nivel_atencao) printf 'atenção' ;;
    nivel_critico) printf 'crítico' ;;

    dur_segundos) printf 's' ;;
    dur_minutos)  printf 'min' ;;
    dur_horas)    printf 'h' ;;
    dur_dias)     printf 'd' ;;

    titulo_normalizou) printf '%%s normalizou em %%s' ;;
    titulo_alerta)     printf '%%s em %%s%%s no %%s' ;;
    corpo_normalizou)  printf '<strong>%%s normalizou.</strong> Valor atual: %%s%%s. O problema durou %%s e chegou a %%s%%s.' ;;
    corpo_valor)       printf '<strong>%%s: %%s%%s</strong> (limiar %%s%%s)' ;;
    corpo_desde)       printf 'Assim há %%s, pico de %%s%%s. Confirmado em %%s leituras seguidas.' ;;
    corpo_estado)      printf 'Estado do servidor agora' ;;
    corpo_comecar)     printf 'Por onde começar' ;;
    corpo_proc_cpu)    printf 'Processos por CPU' ;;
    corpo_proc_mem)    printf 'Processos por memória' ;;
    corpo_dirs)        printf 'Maiores diretórios em %%s' ;;
    corpo_media_de)    printf 'média de %%s' ;;
    corpo_sem_swap)    printf 'sem swap configurado' ;;
    corpo_disponiveis) printf '%%s GB disponíveis' ;;
    corpo_por_nucleo)  printf '%%s por núcleo, %%s núcleos' ;;

    tg_normalizou) printf '%%s %%s normalizou em %%s\n\nAtual: %%s%%s | durou %%s | pico %%s%%s' ;;
    tg_alerta)     printf '%%s %%s em %%s%%s - %%s\n\nAssim há %%s (pico %%s%%s, limiar %%s%%s)\n\n%%s' ;;

    resumo_assunto) printf '%%s alertas na última hora' ;;
    resumo_titulo)  printf 'Várias métricas fora do normal' ;;
    resumo_corpo)   printf 'O servidor passou do limite de %%s alertas por hora. Em vez de uma mensagem por ocorrência, segue o agrupamento:' ;;
    resumo_tg)      printf '[RESUMO] %%s - %%s alertas na última hora\n\nO limite de %%s por hora foi atingido e as mensagens individuais foram agrupadas.\n\n%%s' ;;

    diag_steal)   printf 'Contenção de CPU em %%s%%%% (steal): o limite está no provedor, não no servidor. Em instância burstable (EC2 t2/t3/t3a) isso é crédito de CPU esgotado. Conferir CPUCreditBalance no painel do provedor.' ;;
    diag_iowait)  printf 'iowait em %%s%%%%: a CPU está esperando disco, não calculando. O gargalo é de I/O. Conferir com: iostat -x 1 5' ;;
    diag_load)    printf 'Load average em %%s por núcleo: há processo na fila esperando CPU, não só usando. Conferir os processos abaixo.' ;;
    diag_cpu)     printf 'Uso sustentado de CPU. Conferir os processos abaixo e se há build, cron ou importação rodando.' ;;
    diag_mem_sem_swap) printf 'Restam %%s MB disponíveis e este servidor não tem swap: estourar significa OOM kill, processo morto sem erro no log da aplicação. Conferir os processos abaixo.' ;;
    diag_mem)     printf 'Restam %%s MB disponíveis. Conferir os processos abaixo e, se for aplicação Node, se há limite de heap configurado.' ;;
    diag_disco)   printf 'Conferir os maiores diretórios abaixo. Suspeitos frequentes: /var/log, /var/lib/docker e dump de banco esquecido.' ;;
    diag_inode)   printf 'Inodes esgotados: o disco aceita bytes mas não aceita arquivo novo, e o df comum não mostra isso. Procurar diretório com muitos arquivos pequenos (cache de sessão, fila de e-mail).' ;;
    diag_swap)    printf 'Swap em uso alto deixa a aplicação lenta sem derrubar nada, então chega como reclamação de lentidão. Páginas em swap não voltam sozinhas.' ;;
    diag_load_m)  printf 'Load average em %%s por núcleo: há processo esperando a vez. Load alto com CPU baixa costuma ser espera de disco ou de rede.' ;;
    diag_steal_m) printf 'A instância está pedindo mais CPU do que o provedor entrega neste momento. Em EC2 burstable, isso é crédito esgotado. Trocar de família ou ligar o modo unlimited resolve; ajuste dentro do servidor não.' ;;
    diag_padrao)  printf 'Conferir os processos abaixo.' ;;

    tpl_data)     printf 'Data' ;;
    tpl_servidor) printf 'Servidor' ;;
    tpl_rodape)   printf 'Alerta automático. Não responda.' ;;
    *) printf '' ;;
  esac
}

msg_en() {
  case "$1" in
    rotulo_memoria) printf 'Memory' ;;
    rotulo_steal)   printf 'CPU contention' ;;
    rotulo_load)    printf 'Load average' ;;
    tabela_steal)   printf 'Contention (steal)' ;;
    rotulo_disco)   printf 'Disk' ;;
    rotulo_agente)  printf 'Agent' ;;

    sev_atencao) printf 'WARNING' ;;
    sev_critico) printf 'CRITICAL' ;;
    sev_segue)   printf 'ONGOING' ;;
    sev_ok)      printf 'RESOLVED' ;;
    sev_aviso)   printf 'NOTICE' ;;
    nivel_atencao) printf 'warning' ;;
    nivel_critico) printf 'critical' ;;

    dur_segundos) printf 's' ;;
    dur_minutos)  printf 'min' ;;
    dur_horas)    printf 'h' ;;
    dur_dias)     printf 'd' ;;

    titulo_normalizou) printf '%%s back to normal on %%s' ;;
    titulo_alerta)     printf '%%s at %%s%%s on %%s' ;;
    corpo_normalizou)  printf '<strong>%%s is back to normal.</strong> Current value: %%s%%s. It lasted %%s and peaked at %%s%%s.' ;;
    corpo_valor)       printf '<strong>%%s: %%s%%s</strong> (threshold %%s%%s)' ;;
    corpo_desde)       printf 'Like this for %%s, peaked at %%s%%s. Confirmed over %%s consecutive readings.' ;;
    corpo_estado)      printf 'Server state right now' ;;
    corpo_comecar)     printf 'Where to start' ;;
    corpo_proc_cpu)    printf 'Top processes by CPU' ;;
    corpo_proc_mem)    printf 'Top processes by memory' ;;
    corpo_dirs)        printf 'Largest directories in %%s' ;;
    corpo_media_de)    printf '%%s average' ;;
    corpo_sem_swap)    printf 'no swap configured' ;;
    corpo_disponiveis) printf '%%s GB available' ;;
    corpo_por_nucleo)  printf '%%s per core, %%s cores' ;;

    tg_normalizou) printf '%%s %%s back to normal on %%s\n\nCurrent: %%s%%s | lasted %%s | peak %%s%%s' ;;
    tg_alerta)     printf '%%s %%s at %%s%%s - %%s\n\nLike this for %%s (peak %%s%%s, threshold %%s%%s)\n\n%%s' ;;

    resumo_assunto) printf '%%s alerts in the last hour' ;;
    resumo_titulo)  printf 'Several metrics out of range' ;;
    resumo_corpo)   printf 'This server went over the limit of %%s alerts per hour. Instead of one message per event, here is the grouped summary:' ;;
    resumo_tg)      printf '[SUMMARY] %%s - %%s alerts in the last hour\n\nThe limit of %%s per hour was reached and individual messages were grouped.\n\n%%s' ;;

    diag_steal)   printf 'CPU contention at %%s%%%% (steal): the limit is on the provider side, not on the server. On a burstable instance (EC2 t2/t3/t3a) this means CPU credits ran out. Check CPUCreditBalance in the provider console.' ;;
    diag_iowait)  printf 'iowait at %%s%%%%: the CPU is waiting on disk, not computing. The bottleneck is I/O. Check with: iostat -x 1 5' ;;
    diag_load)    printf 'Load average at %%s per core: processes are queued waiting for CPU, not just using it. Check the processes below.' ;;
    diag_cpu)     printf 'Sustained CPU usage. Check the processes below and whether a build, cron job or import is running.' ;;
    diag_mem_sem_swap) printf 'Only %%s MB available and this server has no swap: running out means an OOM kill, a process killed with no error in the application log. Check the processes below.' ;;
    diag_mem)     printf 'Only %%s MB available. Check the processes below and, for a Node application, whether a heap limit is configured.' ;;
    diag_disco)   printf 'Check the largest directories below. Usual suspects: /var/log, /var/lib/docker and a forgotten database dump.' ;;
    diag_inode)   printf 'Inodes exhausted: the disk still accepts bytes but refuses new files, and plain df does not show this. Look for a directory with many small files (session cache, mail queue).' ;;
    diag_swap)    printf 'Heavy swap usage makes the application slow without taking anything down, so it arrives as a complaint about slowness. Pages in swap do not come back on their own.' ;;
    diag_load_m)  printf 'Load average at %%s per core: processes are waiting their turn. High load with low CPU usually means waiting on disk or network.' ;;
    diag_steal_m) printf 'This instance is asking for more CPU than the provider is delivering right now. On EC2 burstable, that means credits ran out. Switching instance family or enabling unlimited mode fixes it; tuning inside the server does not.' ;;
    diag_padrao)  printf 'Check the processes below.' ;;

    tpl_data)     printf 'Date' ;;
    tpl_servidor) printf 'Server' ;;
    tpl_rodape)   printf 'Automated alert. Do not reply.' ;;
    *) printf '' ;;
  esac
}

msg_es() {
  case "$1" in
    rotulo_memoria) printf 'Memoria' ;;
    rotulo_steal)   printf 'Contención de CPU' ;;
    rotulo_load)    printf 'Load average' ;;
    tabela_steal)   printf 'Contención (steal)' ;;
    rotulo_disco)   printf 'Disco' ;;
    rotulo_agente)  printf 'Agente' ;;

    sev_atencao) printf 'ATENCIÓN' ;;
    sev_critico) printf 'CRÍTICO' ;;
    sev_segue)   printf 'CONTINÚA' ;;
    sev_ok)      printf 'OK' ;;
    sev_aviso)   printf 'AVISO' ;;
    nivel_atencao) printf 'atención' ;;
    nivel_critico) printf 'crítico' ;;

    dur_segundos) printf 's' ;;
    dur_minutos)  printf 'min' ;;
    dur_horas)    printf 'h' ;;
    dur_dias)     printf 'd' ;;

    titulo_normalizou) printf '%%s se normalizó en %%s' ;;
    titulo_alerta)     printf '%%s en %%s%%s en %%s' ;;
    corpo_normalizou)  printf '<strong>%%s se normalizó.</strong> Valor actual: %%s%%s. El problema duró %%s y llegó a %%s%%s.' ;;
    corpo_valor)       printf '<strong>%%s: %%s%%s</strong> (umbral %%s%%s)' ;;
    corpo_desde)       printf 'Así desde hace %%s, pico de %%s%%s. Confirmado en %%s lecturas seguidas.' ;;
    corpo_estado)      printf 'Estado del servidor ahora' ;;
    corpo_comecar)     printf 'Por dónde empezar' ;;
    corpo_proc_cpu)    printf 'Procesos por CPU' ;;
    corpo_proc_mem)    printf 'Procesos por memoria' ;;
    corpo_dirs)        printf 'Directorios más grandes en %%s' ;;
    corpo_media_de)    printf 'promedio de %%s' ;;
    corpo_sem_swap)    printf 'sin swap configurado' ;;
    corpo_disponiveis) printf '%%s GB disponibles' ;;
    corpo_por_nucleo)  printf '%%s por núcleo, %%s núcleos' ;;

    tg_normalizou) printf '%%s %%s se normalizó en %%s\n\nActual: %%s%%s | duró %%s | pico %%s%%s' ;;
    tg_alerta)     printf '%%s %%s en %%s%%s - %%s\n\nAsí desde hace %%s (pico %%s%%s, umbral %%s%%s)\n\n%%s' ;;

    resumo_assunto) printf '%%s alertas en la última hora' ;;
    resumo_titulo)  printf 'Varias métricas fuera de rango' ;;
    resumo_corpo)   printf 'El servidor superó el límite de %%s alertas por hora. En lugar de un mensaje por evento, este es el resumen agrupado:' ;;
    resumo_tg)      printf '[RESUMEN] %%s - %%s alertas en la última hora\n\nSe alcanzó el límite de %%s por hora y los mensajes individuales fueron agrupados.\n\n%%s' ;;

    diag_steal)   printf 'Contención de CPU en %%s%%%% (steal): el límite está en el proveedor, no en el servidor. En instancia burstable (EC2 t2/t3/t3a) significa que se agotaron los créditos de CPU. Revisar CPUCreditBalance en la consola del proveedor.' ;;
    diag_iowait)  printf 'iowait en %%s%%%%: la CPU está esperando el disco, no calculando. El cuello de botella es de E/S. Revisar con: iostat -x 1 5' ;;
    diag_load)    printf 'Load average en %%s por núcleo: hay procesos en cola esperando CPU, no solo usándola. Revisar los procesos abajo.' ;;
    diag_cpu)     printf 'Uso sostenido de CPU. Revisar los procesos abajo y si hay un build, cron o importación corriendo.' ;;
    diag_mem_sem_swap) printf 'Quedan %%s MB disponibles y este servidor no tiene swap: agotarla significa OOM kill, un proceso terminado sin error en el log de la aplicación. Revisar los procesos abajo.' ;;
    diag_mem)     printf 'Quedan %%s MB disponibles. Revisar los procesos abajo y, si es una aplicación Node, si hay límite de heap configurado.' ;;
    diag_disco)   printf 'Revisar los directorios más grandes abajo. Sospechosos frecuentes: /var/log, /var/lib/docker y un dump de base de datos olvidado.' ;;
    diag_inode)   printf 'Inodos agotados: el disco acepta bytes pero no acepta archivos nuevos, y el df normal no muestra esto. Buscar un directorio con muchos archivos pequeños (caché de sesión, cola de correo).' ;;
    diag_swap)    printf 'El uso alto de swap deja la aplicación lenta sin tumbar nada, así que llega como queja de lentitud. Las páginas en swap no vuelven solas.' ;;
    diag_load_m)  printf 'Load average en %%s por núcleo: hay procesos esperando su turno. Load alto con CPU baja suele ser espera de disco o de red.' ;;
    diag_steal_m) printf 'La instancia está pidiendo más CPU de la que el proveedor entrega en este momento. En EC2 burstable, eso significa que se agotaron los créditos. Cambiar de familia o activar el modo unlimited lo resuelve; ajustar dentro del servidor no.' ;;
    diag_padrao)  printf 'Revisar los procesos abajo.' ;;

    tpl_data)     printf 'Fecha' ;;
    tpl_servidor) printf 'Servidor' ;;
    tpl_rodape)   printf 'Alerta automática. No responda.' ;;
    *) printf '' ;;
  esac
}


# ---------------------------------------------------------------------------
# Templates de e-mail
# ---------------------------------------------------------------------------
#
# Os templates em /opt/alerts/templates vem do instalador e tem rotulo fixo em
# portugues: "Data:", "Servidor:", "Alerta automatico. Nao responda.". Nem eles
# nem o send_html_alert.sh entram no manifesto de atualizacao, entao nao ha
# como traduzi-los pelo canal normal.
#
# A saida e o agente reescrever os arquivos. O send_html_alert.sh so faz
#   envsubst '${TITLE} ${MESSAGE} ${DATE} ${HOST}'
# ou seja, substitui quatro variaveis e copia o resto literalmente. Entao o
# template pode ir para o disco ja traduzido.
#
# A reescrita acontece quando o idioma muda, nao em toda rodada: gravar cinco
# arquivos por minuto em todo servidor da frota seria desperdicio puro.

TEMPLATES_DIR="${TEMPLATES_DIR:-/opt/alerts/templates}"

# Um arquivo por tipo de alerta, cada um com a cor da borda e o rotulo que o
# instalador original usava.
_templates_lista() {
  printf '%s\n' \
    "alert.html|#64748b" \
    "cpu-alert.html|#f97316" \
    "memory-alert.html|#8b5cf6" \
    "disk-alert.html|#0ea5e9" \
    "clamav-alert.html|#ef4444"
}

escreve_template() {
  local caminho="$1" cor="$2"
  local rot_data rot_servidor rodape
  rot_data="$(t tpl_data)"
  rot_servidor="$(t tpl_servidor)"
  rodape="$(t tpl_rodape)"

  # ${TITLE}, ${MESSAGE}, ${DATE} e ${HOST} ficam literais: quem substitui e o
  # envsubst dentro do send_html_alert.sh, na hora do envio.
  cat <<TEMPLATE | escreve_atomico "$caminho"
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="$(idioma_html)">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>\${TITLE}</title>
  <style type="text/css">
    table, td { border-collapse: collapse; }
    body { margin: 0; padding: 0; width: 100% !important; background-color: #f4f4f7; }
  </style>
</head>
<body style="margin: 0; padding: 0; background-color: #f4f4f7; font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;">
  <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" bgcolor="#f4f4f7">
    <tr><td align="center" style="padding: 40px 10px;">
      <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 640px; background-color: #ffffff; border-radius: 8px; border: 1px solid #eaeaec;">
        <tr>
          <td style="padding: 30px 40px 20px 40px; border-bottom: 4px solid ${cor};">
            <h1 style="margin: 0; font-size: 22px; font-weight: bold; color: #1f2937;">\${TITLE}</h1>
            <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="margin-top: 15px;">
              <tr><td style="color: #6b7280; font-size: 13px;"><strong>${rot_data}:</strong> \${DATE} | <strong>${rot_servidor}:</strong> \${HOST}</td></tr>
            </table>
          </td>
        </tr>
        <tr><td style="padding: 28px 40px; color: #374151; font-size: 14px; line-height: 1.6;">\${MESSAGE}</td></tr>
        <tr>
          <td style="padding: 18px 40px 30px 40px; border-top: 1px solid #eaeaec;">
            <p style="margin: 0; font-size: 12px; color: #9ca3af; text-align: center;">${rodape}</p>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>
TEMPLATE
}

idioma_html() {
  case "$(idioma_normalizado)" in
    pt) printf 'pt-BR' ;;
    en) printf 'en-US' ;;
    *)  printf 'es-CO' ;;
  esac
}

# Reescreve os templates se o idioma gravado em disco nao for o configurado.
# A marca fica num arquivo proprio, e nao dentro do HTML, para nao depender de
# conseguir ler de volta um arquivo que alguem pode ter editado a mao.
sincroniza_templates() {
  local marca="${TEMPLATES_DIR}/.idioma"
  local atual=""
  [[ -f "$marca" ]] && atual="$(tr -d '[:space:]' <"$marca" 2>/dev/null)"

  if [[ "$atual" == "${IDIOMA}" ]] && [[ -f "${TEMPLATES_DIR}/alert.html" ]]; then
    return 0
  fi

  if ! mkdir -p "$TEMPLATES_DIR" 2>/dev/null; then
    log_erro "nao consegui criar ${TEMPLATES_DIR}; templates nao traduzidos"
    return 1
  fi
  if [[ ! -w "$TEMPLATES_DIR" ]]; then
    log_erro "${TEMPLATES_DIR} nao e gravavel; templates seguem no idioma anterior"
    return 1
  fi

  local linha nome cor escritos=0
  while IFS='|' read -r nome cor; do
    [[ -z "$nome" ]] && continue
    if escreve_template "${TEMPLATES_DIR}/${nome}" "$cor"; then
      escritos=$(( escritos + 1 ))
    else
      log_erro "falhei ao escrever ${nome}"
    fi
  done < <(_templates_lista)

  if [[ "$escritos" -gt 0 ]]; then
    printf '%s' "$IDIOMA" | escreve_atomico "$marca" 2>/dev/null || true
    log_info "templates reescritos em ${IDIOMA} (${escritos} arquivos)"
  fi
  return 0
}


# ---------------------------------------------------------------------------
# Medicao
# ---------------------------------------------------------------------------
#
# Tudo sai de /proc. Sem mpstat (pacote sysstat, que pode nao estar instalado)
# e sem bc. O agente antigo dependia dos dois e morria calado quando faltavam.

# --- CPU ------------------------------------------------------------------
#
# A media vem do delta de /proc/stat entre duas execucoes, ou seja, cobre o
# intervalo inteiro do cron. O agente antigo usava "mpstat 1 2", uma janela de
# dois segundos, e por isso qualquer rajada virava alerta.
#
# Preenche: MEDIDA_CPU, MEDIDA_IOWAIT, MEDIDA_STEAL, MEDIDA_CPU_JANELA

le_cpu_bruto() {
  # user nice system idle iowait irq softirq steal
  awk '/^cpu /{
    total=0
    for (i=2; i<=NF; i++) total += $i
    idle = $5 + $6
    steal = (NF >= 9) ? $9 : 0
    printf "%.0f %.0f %.0f %.0f", total, idle, $6, steal
    exit
  }' "$PROC_STAT" 2>/dev/null
}

mede_cpu() {
  MEDIDA_CPU="" ; MEDIDA_IOWAIT="0.0" ; MEDIDA_STEAL="0.0" ; MEDIDA_CPU_JANELA="0"

  local amostra ts
  amostra="$(le_cpu_bruto)"
  ts="$(agora)"
  if [[ -z "$amostra" ]]; then
    log_erro "nao consegui ler ${PROC_STAT}"
    return 1
  fi

  local arq="${AGENTE_ESTADO}/cpu.amostra"
  local usar_delta=0 ant_total ant_idle ant_iowait ant_steal ant_ts

  if [[ -f "$arq" ]]; then
    read -r ant_total ant_idle ant_iowait ant_steal ant_ts <"$arq" 2>/dev/null || true
    if [[ -n "${ant_ts:-}" ]]; then
      local idade=$(( ts - ant_ts ))
      # Amostra velha demais (agente parado, servidor reiniciado) daria uma
      # media de horas, que nao representa o agora. Tambem rejeita idade
      # negativa, que acontece quando o relogio e ajustado para tras.
      if [[ "$idade" -ge 20 && "$idade" -le 900 ]]; then
        usar_delta=1
        MEDIDA_CPU_JANELA="$idade"
      fi
    fi
  fi

  # Sem amostra anterior utilizavel: tira uma curta agora, para a primeira
  # execucao depois de instalar nao ficar sem numero.
  if [[ "$usar_delta" -eq 0 ]]; then
    read -r ant_total ant_idle ant_iowait ant_steal <<<"$amostra"
    sleep 1
    amostra="$(le_cpu_bruto)"
    ts="$(agora)"
    MEDIDA_CPU_JANELA="1"
    [[ -z "$amostra" ]] && return 1
  fi

  local cur_total cur_idle cur_iowait cur_steal
  read -r cur_total cur_idle cur_iowait cur_steal <<<"$amostra"

  printf '%s %s %s %s %s\n' "$cur_total" "$cur_idle" "$cur_iowait" "$cur_steal" "$ts" \
    | escreve_atomico "$arq" 2>/dev/null || true

  local d_total d_idle d_iowait d_steal
  d_total="$(delta "$cur_total" "$ant_total")"
  d_idle="$(delta "$cur_idle" "$ant_idle")"
  d_iowait="$(delta "$cur_iowait" "${ant_iowait:-0}")"
  d_steal="$(delta "$cur_steal" "${ant_steal:-0}")"

  # Contador zerado (reboot) ou janela nula: sem numero confiavel nesta rodada.
  if [[ "${d_total:-0}" -le 0 ]]; then
    log_info "delta de /proc/stat nulo; CPU sem medida nesta rodada"
    return 1
  fi

  MEDIDA_CPU="$(pct "$(delta "$d_total" "$d_idle")" "$d_total")"
  MEDIDA_IOWAIT="$(pct "$d_iowait" "$d_total")"
  MEDIDA_STEAL="$(pct "$d_steal" "$d_total")"
  return 0
}

# --- Memoria --------------------------------------------------------------
#
# Aqui estava o defeito que gerava alerta de RAM a cada minuto em servidor
# saudavel: o script antigo somava "used + buff/cache" do free e chamava de
# memoria ocupada. Cache de disco nao e memoria ocupada; o kernel devolve no
# instante em que alguem precisa. Num servidor com 8,4 GB livres de 15 GB a
# conta antiga dava 96,7%, a correta da 44%.
#
# Preenche: MEDIDA_MEM, MEDIDA_MEM_TOTAL_KB, MEDIDA_MEM_DISP_KB,
#           MEDIDA_SWAP, MEDIDA_SWAP_TOTAL_KB

campo_meminfo() {
  awk -v chave="^$1:" '$0 ~ chave { print $2; exit }' "$PROC_MEMINFO" 2>/dev/null
}

mede_memoria() {
  MEDIDA_MEM="" ; MEDIDA_SWAP="" ; MEDIDA_SWAP_TOTAL_KB="0"

  local total disp
  total="$(campo_meminfo MemTotal)"
  if [[ -z "$total" || "$total" -le 0 ]]; then
    log_erro "nao consegui ler MemTotal de ${PROC_MEMINFO}"
    return 1
  fi

  disp="$(campo_meminfo MemAvailable)"
  if [[ -z "$disp" ]]; then
    # Kernel anterior ao 3.14 nao expoe MemAvailable. A aproximacao aceita e
    # free + buffers + cache reclamavel.
    local livre buffers cached sreclaim
    livre="$(campo_meminfo MemFree)"; buffers="$(campo_meminfo Buffers)"
    cached="$(campo_meminfo Cached)"; sreclaim="$(campo_meminfo SReclaimable)"
    disp="$(awk -v a="${livre:-0}" -v b="${buffers:-0}" -v c="${cached:-0}" -v d="${sreclaim:-0}" \
      'BEGIN{printf "%.0f", a+b+c+d}')"
    log_info "MemAvailable ausente; usando MemFree+Buffers+Cached+SReclaimable"
  fi

  MEDIDA_MEM_TOTAL_KB="$total"
  MEDIDA_MEM_DISP_KB="$disp"
  MEDIDA_MEM="$(pct "$(delta "$total" "$disp")" "$total")"

  local swap_total swap_livre
  swap_total="$(campo_meminfo SwapTotal)"
  swap_livre="$(campo_meminfo SwapFree)"
  MEDIDA_SWAP_TOTAL_KB="${swap_total:-0}"
  if [[ -n "$swap_total" && "$swap_total" -gt 0 ]]; then
    MEDIDA_SWAP="$(pct "$(delta "$swap_total" "${swap_livre:-0}")" "$swap_total")"
  else
    # Servidor sem swap: medir "percentual de swap" nao significa nada. Em
    # EC2 isso e o padrao, e o agente nao deve inventar metrica.
    MEDIDA_SWAP=""
  fi
  return 0
}

# --- Load -----------------------------------------------------------------
#
# Normalizado por nucleo: 1.0 quer dizer "todos os nucleos ocupados, sem fila",
# o que torna o numero comparavel entre servidores de tamanhos diferentes.

mede_load() {
  MEDIDA_LOAD="" ; MEDIDA_LOAD_BRUTO=""
  local l1 n
  l1="$(awk '{print $1; exit}' "$PROC_LOADAVG" 2>/dev/null)"
  [[ -z "$l1" ]] && return 1
  n="$(nucleos)"
  MEDIDA_LOAD_BRUTO="$l1"
  MEDIDA_LOAD="$(awk -v l="$l1" -v n="$n" 'BEGIN{printf "%.2f", l/n}')"
  MEDIDA_NUCLEOS="$n"
  return 0
}

# --- Disco ----------------------------------------------------------------
#
# Uma linha por ponto de montagem: "montagem uso_pct inode_pct dispositivo
# tamanho usado disponivel". Ignora o que nao e problema de ninguem (volume de
# container, snap) pela lista DISCO_IGNORAR.

ignorar_montagem() {
  local mnt="$1" padrao
  for padrao in $DISCO_IGNORAR; do
    # shellcheck disable=SC2053
    [[ "$mnt" == $padrao ]] && return 0
  done
  return 1
}

_saida_df()        { if [[ -n "${FIXTURE_DF:-}" ]];        then cat "$FIXTURE_DF";        else df -P  -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null; fi; }
_saida_df_inodes() { if [[ -n "${FIXTURE_DF_INODES:-}" ]]; then cat "$FIXTURE_DF_INODES"; else df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null; fi; }

mede_disco() {
  MEDIDA_DISCO_LINHAS=""

  # Os campos sao lidos a partir do FIM da linha, nao do comeco. O nome do
  # dispositivo pode conter espaco (share de rede, caminho montado), e aí um
  # "read fs size used avail pct mnt" desloca tudo e o agente passa a comparar
  # o ponto de montagem com o percentual. O layout do df -P e fixo pela direita:
  #   ... TAMANHO USADO DISPONIVEL USO% MONTAGEM
  local inodes linhas
  inodes="$(_saida_df_inodes | tail -n +2 | awk 'NF >= 2 {print $NF, $(NF-1)}' 2>/dev/null || true)"
  linhas="$(_saida_df | tail -n +2 | awk 'NF >= 6 {
    gsub(/%/, "", $(NF-1))
    printf "%s|%s|%s|%s|%s\n", $NF, $(NF-1), $(NF-4), $(NF-3), $(NF-2)
  }' 2>/dev/null || true)"
  [[ -z "$linhas" ]] && { log_erro "df nao devolveu nada utilizavel"; return 1; }

  local mnt pct_uso size used avail ipct
  while IFS='|' read -r mnt pct_uso size used avail; do
    [[ -z "${mnt:-}" ]] && continue
    [[ "$pct_uso" =~ ^[0-9]+$ ]] || continue
    ignorar_montagem "$mnt" && continue
    ipct="$(printf '%s\n' "$inodes" | awk -v m="$mnt" '$1==m {gsub(/%/,"",$2); print $2; exit}')"
    # Filesystem sem contagem de inode (btrfs, zfs, ntfs) devolve "-". Zero
    # aqui significa "nao se aplica" e nunca dispara alerta.
    [[ "${ipct:-}" =~ ^[0-9]+$ ]] || ipct="0"
    MEDIDA_DISCO_LINHAS+="${mnt} ${pct_uso} ${ipct} ${size} ${used} ${avail}"$'\n'
  done <<<"$linhas"
  [[ -z "$MEDIDA_DISCO_LINHAS" ]] && return 1
  return 0
}

# --- Contexto para o texto do alerta --------------------------------------

top_processos() {
  local por="${1:-cpu}" n="${2:-12}"
  local chave="-%cpu"
  [[ "$por" == "mem" ]] && chave="-%mem"
  ps -eo pid,user,pcpu,pmem,comm,args --sort="$chave" --no-headers 2>/dev/null \
    | head -n "$n" \
    | awk '{
        cmd=""
        for (i=6; i<=NF; i++) cmd = cmd $i " "
        printf "%-7s %-10s %5s%% %5s%% %.60s\n", $1, $2, $3, $4, substr(cmd,1,60)
      }' 2>/dev/null || printf 'ps indisponivel\n'
}

maiores_diretorios() {
  local mnt="$1"
  timeout 20 du -xh --max-depth=1 "$mnt" 2>/dev/null | sort -hr | head -n 12 \
    || printf 'du nao terminou em 20s\n'
}


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


# ---------------------------------------------------------------------------
# Auto-atualizacao
# ---------------------------------------------------------------------------
#
# O mecanismo antigo baixava tres arquivos de main a cada minuto, para sempre,
# sem versao e sem checksum: conferia so HTTP 200 e a primeira linha comecando
# com "#!". Um commit quebrado em main chegava na frota inteira em 60 segundos
# sem caminho de volta, e o mv vinha de /tmp, que costuma ser outro filesystem,
# entao a troca nem atomica era.
#
# Aqui: versao, SHA-256 por arquivo, validacao de sintaxe, troca atomica no
# mesmo filesystem, autoteste e rollback automatico.

sha256_de() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
  else
    printf ''
  fi
}

baixa() {
  local url="$1" destino="$2" codigo
  codigo="$(curl -fsSL -o "$destino" -w '%{http_code}' --max-time 30 --retry 2 --retry-delay 2 "$url" 2>/dev/null)" || return 1
  [[ "$codigo" == "200" ]] || return 1
  [[ -s "$destino" ]] || return 1
  return 0
}

versao_instalada() {
  cat "${AGENTE_RAIZ}/VERSION" 2>/dev/null | tr -d '[:space:]' || printf ''
}

# Compara versoes semanticas: sucesso quando $1 > $2
versao_maior() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    na = split(a, x, "."); nb = split(b, y, ".")
    n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      xi = (i <= na) ? x[i]+0 : 0
      yi = (i <= nb) ? y[i]+0 : 0
      if (xi > yi) { exit 0 }
      if (xi < yi) { exit 1 }
    }
    exit 1
  }'
}

# O manifesto e a lista do que compoe uma versao, com o hash de cada arquivo:
#   VERSAO=2.0.0
#   ARQUIVO=monitoring-agent.sh <sha256>
#   ARQUIVO=monitor_cpu.sh <sha256>
atualiza_agente() {
  [[ "${AUTO_UPDATE:-1}" == "1" ]] || { log_info "auto-update desligado"; return 0; }

  local base="${UPDATE_BASE_URL}/${UPDATE_CANAL}"
  local tmpdir
  tmpdir="$(mktemp -d "${AGENTE_RAIZ}/.update.XXXXXX" 2>/dev/null)" || {
    log_erro "nao consegui criar diretorio temporario para a atualizacao"; return 1; }
  # mktemp dentro de AGENTE_RAIZ de proposito: a troca final precisa ser um mv
  # dentro do mesmo filesystem de destino para ser atomica.

  local limpar=1
  _limpa_update() { [[ "$limpar" == "1" ]] && rm -rf "$tmpdir" 2>/dev/null || true; }

  if ! baixa "${base}/agent.manifest" "${tmpdir}/manifest"; then
    log_erro "manifesto indisponivel em ${base}/agent.manifest"
    _limpa_update; return 1
  fi

  local nova
  nova="$(awk -F= '/^VERSAO=/{print $2; exit}' "${tmpdir}/manifest" | tr -d '[:space:]')"
  if [[ -z "$nova" ]]; then
    log_erro "manifesto sem campo VERSAO"
    _limpa_update; return 1
  fi

  local atual
  atual="$(versao_instalada)"
  [[ -z "$atual" ]] && atual="0.0.0"
  if ! versao_maior "$nova" "$atual"; then
    _limpa_update
    return 0
  fi

  log_info "atualizacao disponivel: ${atual} -> ${nova}"

  # 1. Baixar e conferir TUDO antes de instalar qualquer coisa. Instalar
  #    arquivo por arquivo deixaria o servidor com meia versao se o quinto
  #    download falhasse.
  local arquivos=() nome hash_esperado hash_obtido
  while read -r linha; do
    [[ "$linha" == ARQUIVO=* ]] || continue
    nome="$(printf '%s' "${linha#ARQUIVO=}" | awk '{print $1}')"
    hash_esperado="$(printf '%s' "${linha#ARQUIVO=}" | awk '{print $2}')"
    [[ -z "$nome" || -z "$hash_esperado" ]] && continue

    if ! baixa "${base}/${nome}" "${tmpdir}/${nome}"; then
      log_erro "download de ${nome} falhou; atualizacao abortada sem alterar nada"
      _limpa_update; return 1
    fi
    hash_obtido="$(sha256_de "${tmpdir}/${nome}")"
    if [[ -z "$hash_obtido" ]]; then
      log_erro "sem ferramenta de sha256 no servidor; atualizacao abortada por seguranca"
      _limpa_update; return 1
    fi
    if [[ "$hash_obtido" != "$hash_esperado" ]]; then
      log_erro "checksum de ${nome} nao confere (esperado ${hash_esperado}, obtido ${hash_obtido}); atualizacao abortada"
      _limpa_update; return 1
    fi
    if ! bash -n "${tmpdir}/${nome}" 2>/dev/null; then
      log_erro "${nome} nao passa em bash -n; atualizacao abortada"
      _limpa_update; return 1
    fi
    arquivos+=("$nome")
  done <"${tmpdir}/manifest"

  if [[ "${#arquivos[@]}" -eq 0 ]]; then
    log_erro "manifesto sem arquivos"
    _limpa_update; return 1
  fi

  # 2. Guardar a versao atual para poder voltar
  local backup="${AGENTE_RAIZ}/rollback"
  rm -rf "$backup" 2>/dev/null || true
  mkdir -p "$backup" 2>/dev/null || true
  for nome in "${arquivos[@]}"; do
    [[ -f "${AGENTE_BIN}/${nome}" ]] && cp -a "${AGENTE_BIN}/${nome}" "${backup}/${nome}" 2>/dev/null || true
  done
  printf '%s' "$atual" >"${backup}/VERSION" 2>/dev/null || true

  # 3. Instalar. O temporario precisa estar no filesystem do destino.
  local falhou=0 staging
  staging="$(mktemp -d "${AGENTE_BIN}/.staging.XXXXXX" 2>/dev/null)" || {
    log_erro "nao consegui criar staging em ${AGENTE_BIN}"; _limpa_update; return 1; }
  for nome in "${arquivos[@]}"; do
    cp "${tmpdir}/${nome}" "${staging}/${nome}" 2>/dev/null || { falhou=1; break; }
    chmod 755 "${staging}/${nome}" 2>/dev/null || true
  done
  if [[ "$falhou" -eq 0 ]]; then
    for nome in "${arquivos[@]}"; do
      mv -f "${staging}/${nome}" "${AGENTE_BIN}/${nome}" 2>/dev/null || falhou=1
    done
  fi
  rm -rf "$staging" 2>/dev/null || true

  if [[ "$falhou" -ne 0 ]]; then
    log_erro "instalacao falhou no meio; restaurando"
    restaura_rollback
    _limpa_update; return 1
  fi

  printf '%s' "$nova" | escreve_atomico "${AGENTE_RAIZ}/VERSION" 2>/dev/null || true

  # 4. Autoteste. Versao que nao roda nao fica instalada.
  if ! "${AGENTE_BIN}/monitoring-agent.sh" autoteste >/dev/null 2>&1; then
    log_erro "autoteste da versao ${nova} falhou; voltando para ${atual}"
    restaura_rollback
    printf '%s' "$atual" | escreve_atomico "${AGENTE_RAIZ}/VERSION" 2>/dev/null || true
    reporta_falha_update "$nova" "$atual"
    _limpa_update; return 1
  fi

  log_info "atualizado para ${nova} com autoteste verde"
  _limpa_update
  return 0
}

restaura_rollback() {
  local backup="${AGENTE_RAIZ}/rollback" nome
  [[ -d "$backup" ]] || { log_erro "sem backup para restaurar"; return 1; }
  for f in "$backup"/*; do
    nome="$(basename "$f")"
    [[ "$nome" == "VERSION" ]] && continue
    cp -a "$f" "${AGENTE_BIN}/${nome}" 2>/dev/null || true
    chmod 755 "${AGENTE_BIN}/${nome}" 2>/dev/null || true
  done
  log_info "rollback aplicado"
  return 0
}

reporta_falha_update() {
  local tentada="$1" voltou="$2"
  [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]] || return 0
  [[ -x "${AGENTE_BIN}/send_dashboard_metrics.sh" ]] || return 0
  printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","type":"agent_update","value":0,"threshold":0,"severity":"warning","status":"open","subject":"Atualizacao %s revertida em %s","snapshot_top":"O autoteste da versao %s falhou e o agente voltou para %s automaticamente.","agent_version":"%s","notifications_sent":{"email":false,"telegram":false}}\n' \
    "$DASHBOARD_SERVER_UUID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SERVER_ID" \
    "$tentada" "$SERVER_ID" "$tentada" "$voltou" "$voltou" \
    | "${AGENTE_BIN}/send_dashboard_metrics.sh" incident >/dev/null 2>&1 || true
}


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

# Idioma dos alertas: pt-BR, en-US ou es-CO. Vem do painel; es-CO e o padrao
# de quem nao esta conectado a nenhum painel.
IDIOMA=${IDIOMA:-es-CO}

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

  # O idioma e da empresa, nao do servidor: muda no painel e vale para todos
  # os servidores daquela conta. Valor que nao reconhecemos e ignorado, em vez
  # de deixar o agente mudo ou cair num catalogo vazio.
  local idioma_novo
  idioma_novo="$(printf '%s' "$resp" | sed -n 's/.*"locale":"\([^"]*\)".*/\1/p' | head -1)"
  case "$idioma_novo" in
    pt-BR|en-US|es-CO) _grava_conf IDIOMA "$idioma_novo" ;;
    "") : ;;
    *) log_erro "painel mandou idioma desconhecido (${idioma_novo}); mantido ${IDIOMA}" ;;
  esac

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

  if [[ "$mudou" -eq 1 ]]; then
    log_info "configuracao sincronizada com o painel"
    # Rele o arquivo para o valor novo valer ainda nesta rodada: num servidor
    # que acabou de trocar de idioma, o alerta seguinte ja sai traduzido.
    carrega_config
  fi
  sincroniza_templates
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

  # Barato: sai na primeira comparacao quando o idioma nao mudou. Sem isto, o
  # primeiro alerta depois de instalar sairia no template antigo em portugues.
  sincroniza_templates

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

  # Steal so e avaliado quando a CPU tambem esta acima do limiar de atencao.
  # Sem essa condicao, qualquer burst normal de instancia t3/t3a gera alerta
  # com o servidor ocioso: medicao real de 09/10/2026 num t3a.xlarge deu steal
  # de 16,6% com a CPU em 29,5% e load de 0,41 por nucleo, e virou e-mail.
  # Quando a CPU esta baixa, o steal continua aparecendo no corpo do alerta e
  # no diagnostico, que e onde ele serve.
  if [[ "${VIGIAR_STEAL:-1}" == "1" ]] && [[ -n "${MEDIDA_CPU:-}" ]]      && maior "${MEDIDA_CPU:-0}" "${CPU_ATENCAO:-85}"; then
    avalia_e_notifica steal steal "${MEDIDA_STEAL:-}" "$html_cpu" "$proc_cpu"
  elif [[ -f "$(caminho_estado steal)" ]]; then
    # Incidente de steal aberto nao pode ficar pendurado quando a CPU
    # normaliza antes dele: alimenta a maquina de estado com um valor em
    # ordem para que ela feche pelo caminho normal, com aviso de recuperacao.
    avalia_e_notifica steal steal "0"
  fi

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

Idioma: pt-BR, en-US ou es-CO, em IDIOMA no agent.conf. Chega do painel, e
vale para e-mail, Telegram e os templates em /opt/alerts/templates.

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

