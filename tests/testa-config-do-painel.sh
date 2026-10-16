#!/usr/bin/env bash
#
# Bateria da configuracao que vem do painel.
#
#   ./tests/testa-config-do-painel.sh
#
# Depois de instalado e conectado, o servidor tem que poder ser inteiramente
# gerido pelo painel. O que nao chega por aqui fica preso no agent.conf da
# maquina, e esse arquivo VENCE o padrao do codigo: um valor velho gravado na
# instalacao vale para sempre.
#
# Foi assim que dois servidores instalados em 16/10/2026 nasceram com
# LOAD_ATENCAO=1.5 e STEAL_ATENCAO=10, desfazendo em silencio a correcao do
# alerta ruidoso que a 2.4 tinha feito.
#
# O defeito irmao, que esta bateria tambem cobre: o parser lia so inteiro
# (`[0-9]+`). A fila por nucleo chega como 2.5, entao o valor do painel era
# descartado sem deixar rastro e o local continuava mandando.
set -uo pipefail

cd "$(dirname "$0")/.."
RAIZ="$PWD"

TOTAL=0; FALHAS=0
grupo() { printf '\n%s\n' "$1"; }
ok()    { TOTAL=$((TOTAL+1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
falha() {
  TOTAL=$((TOTAL+1)); FALHAS=$((FALHAS+1))
  printf '  \033[31mFALHA\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '        esperado: %s\n' "$2"
  [[ -n "${3:-}" ]] && printf '        obtido:   %s\n' "$3"
  return 0
}
igual() { [[ "$2" == "$3" ]] && ok "$1" || falha "$1" "$2" "$3"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export AGENTE_RAIZ="${SANDBOX}/opt" AGENTE_ESTADO="${SANDBOX}/state"
export AGENTE_LOG="${SANDBOX}/log" AGENTE_BIN="${SANDBOX}/bin"
export AGENTE_SO_CARREGAR=1
mkdir -p "$AGENTE_RAIZ" "$AGENTE_ESTADO" "$AGENTE_BIN" "${SANDBOX}/falso"

[[ -f "${RAIZ}/monitoring-agent.sh" ]] || { echo "rode ./scripts/build.sh primeiro" >&2; exit 1; }
# shellcheck disable=SC1091
source "${RAIZ}/monitoring-agent.sh"
carrega_config

# O agent.conf comeca com os valores ANTIGOS, como num servidor instalado
# antes desta entrega. E deles que a sincronia tem que tirar a maquina.
cat >"${AGENTE_RAIZ}/agent.conf" <<'CONF'
CPU_ATENCAO=85
CPU_CRITICO=95
LOAD_ATENCAO=1.5
LOAD_CRITICO=3.0
STEAL_ATENCAO=10
STEAL_CRITICO=25
SWAP_ATENCAO=50
INODE_ATENCAO=85
BANDA_SAIDA=8
RENOTIFICAR_MIN=60
VIGIAR_SWAP=1
CANAL_TELEGRAM=1
CONF

# curl de mentira: devolve a resposta do painel sem sair da maquina.
cat >"${SANDBOX}/falso/curl" <<'FALSO'
#!/usr/bin/env bash
cat "$RESPOSTA_DO_PAINEL"
exit 0
FALSO
chmod +x "${SANDBOX}/falso/curl"

cat >"${SANDBOX}/resposta.json" <<'JSON'
{"has_updates":true,"locale":"pt-BR","server_name":"servidor de teste",
"cpu_warning":80,"cpu_critical":90,
"memory_warning":75,"memory_critical":88,
"disk_warning":80,"disk_critical":90,
"swap_warning":40,"swap_critical":70,
"inode_warning":80,"inode_critical":90,
"load_warning":2.5,"load_critical":4.0,
"steal_warning":25,"steal_critical":40,
"iowait_warning":25,
"confirm_cycles":4,"recover_cycles":2,
"renotify_minutes":90,"renotify_max_minutes":1440,
"max_alerts_hour":10,
"exit_band":8,"exit_band_load":0.3,
"recovery_alert":1,
"watch_cpu":1,"watch_memory":1,"watch_disk":1,"watch_swap":0,
"watch_load":1,"watch_steal":0,"watch_inode":1,
"channel_email":1,"channel_telegram":0,"recovery_telegram":1,
"disk_ignore":"/var/lib/docker/* /meu/volume/*"}
JSON

export DASHBOARD_ENABLED=1 DASHBOARD_SERVER_UUID="uuid-de-teste"
export DASHBOARD_API_URL="http://painel-de-mentira"
export RESPOSTA_DO_PAINEL="${SANDBOX}/resposta.json"
PATH="${SANDBOX}/falso:${PATH}" sincroniza_config >/dev/null 2>&1

valor() { grep -m1 "^${1}=" "${AGENTE_RAIZ}/agent.conf" 2>/dev/null | cut -d= -f2-; }

# =========================================================================
grupo "O decimal chega inteiro, que era o defeito silencioso"
# =========================================================================
#
# O parser lia so "[0-9]+". Com 2.5, ele achava "2" ou nada, e o valor do
# painel nao tinha como valer.

igual "fila de atencao vem do painel"  "2.5" "$(valor LOAD_ATENCAO)"
igual "fila critica tambem"            "4.0" "$(valor LOAD_CRITICO)"
igual "banda de saida do load"         "0.3" "$(valor BANDA_SAIDA_LOAD)"

# =========================================================================
grupo "Os limiares que so existiam na maquina"
# =========================================================================

igual "contencao de CPU, atencao" "25" "$(valor STEAL_ATENCAO)"
igual "contencao de CPU, critico" "40" "$(valor STEAL_CRITICO)"
igual "swap, atencao"             "40" "$(valor SWAP_ATENCAO)"
igual "swap, critico"             "70" "$(valor SWAP_CRITICO)"
igual "inodes, atencao"           "80" "$(valor INODE_ATENCAO)"
igual "inodes, critico"           "90" "$(valor INODE_CRITICO)"
igual "espera de disco"           "25" "$(valor IOWAIT_ATENCAO)"
igual "teto da renotificacao"     "1440" "$(valor RENOTIFICAR_MAX_MIN)"

# =========================================================================
grupo "Os que ja vinham continuam vindo"
# =========================================================================

igual "CPU de atencao"       "80" "$(valor CPU_ATENCAO)"
igual "CPU critica"          "90" "$(valor CPU_CRITICO)"
igual "memoria de atencao"   "75" "$(valor MEM_ATENCAO)"
igual "disco critico"        "90" "$(valor DISCO_CRITICO)"
igual "leituras que confirmam" "4" "$(valor CICLOS_CONFIRMACAO)"
igual "minutos ate lembrar"  "90" "$(valor RENOTIFICAR_MIN)"
igual "teto por hora"        "10" "$(valor MAX_ALERTAS_HORA)"

# =========================================================================
grupo "O que vigiar e por onde avisar"
# =========================================================================
#
# Desligar uma metrica e diferente de por o limiar em 100: o agente para de
# avaliar, e a metrica continua indo para o painel.

igual "swap desligado pelo painel"      "0" "$(valor VIGIAR_SWAP)"
igual "contencao desligada pelo painel" "0" "$(valor VIGIAR_STEAL)"
igual "CPU segue vigiada"               "1" "$(valor VIGIAR_CPU)"
igual "Telegram desligado"              "0" "$(valor CANAL_TELEGRAM)"
igual "e-mail segue ligado"             "1" "$(valor CANAL_EMAIL)"
igual "recuperacao no Telegram ligada"  "1" "$(valor RECUPERACAO_TELEGRAM)"
igual "aviso de recuperacao"            "1" "$(valor ALERTA_RECUPERACAO)"

# =========================================================================
grupo "A lista de montagens ignoradas"
# =========================================================================

igual "a lista veio do painel" "/var/lib/docker/* /meu/volume/*" "$(valor DISCO_IGNORAR)"

# Ausente quer dizer "mantem o que esta no servidor". Mandar vazio apagaria o
# filtro inteiro e faria voltar o alerta de volume de container, que nao e
# problema de ninguem.
printf '{"has_updates":true,"cpu_warning":81}\n' >"${SANDBOX}/resposta.json"
PATH="${SANDBOX}/falso:${PATH}" sincroniza_config >/dev/null 2>&1
igual "sem a lista, a anterior fica"  "/var/lib/docker/* /meu/volume/*" "$(valor DISCO_IGNORAR)"
igual "e o que veio foi aplicado"     "81" "$(valor CPU_ATENCAO)"
igual "o resto nao foi apagado"       "2.5" "$(valor LOAD_ATENCAO)"

# =========================================================================

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32m%s verificacoes de configuracao, todas verdes.\033[0m\n' "$TOTAL"; exit 0
fi
printf '\033[31m%s verificacoes de configuracao, %s falha(s).\033[0m\n' "$TOTAL" "$FALHAS"
exit 1
