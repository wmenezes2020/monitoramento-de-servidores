#!/usr/bin/env bash
#
# Bateria do agente de monitoramento.
#
#   ./tests/roda-testes.sh
#
# Roda em qualquer maquina com bash e awk, inclusive Windows com Git Bash,
# porque toda fonte de dado do agente e injetavel por variavel. Nada aqui toca
# /proc de verdade, nem manda e-mail, nem fala com o painel.
set -uo pipefail

cd "$(dirname "$0")/.."
RAIZ="$PWD"
FIX="${RAIZ}/tests/fixtures"

TOTAL=0
FALHAS=0
GRUPO=""

grupo() { GRUPO="$1"; printf '\n%s\n' "$1"; }

ok() {
  TOTAL=$(( TOTAL + 1 ))
  printf '  \033[32mok\033[0m    %s\n' "$1"
}

falha() {
  TOTAL=$(( TOTAL + 1 )); FALHAS=$(( FALHAS + 1 ))
  printf '  \033[31mFALHA\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '        esperado: %s\n' "$2"
  [[ -n "${3:-}" ]] && printf '        obtido:   %s\n' "$3"
}

igual() {
  local desc="$1" esperado="$2" obtido="$3"
  [[ "$esperado" == "$obtido" ]] && ok "$desc" || falha "$desc" "$esperado" "$obtido"
}

verdade() {
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else falha "$desc" "comando verdadeiro" "comando falso"; fi
}

mentira() {
  local desc="$1"; shift
  if "$@"; then falha "$desc" "comando falso" "comando verdadeiro"; else ok "$desc"; fi
}

# --- ambiente isolado -----------------------------------------------------

SANDBOX="$(mktemp -d)"
limpa() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap limpa EXIT

export AGENTE_RAIZ="${SANDBOX}/opt"
export AGENTE_ESTADO="${SANDBOX}/state"
export AGENTE_LOG="${SANDBOX}/agente.log"
export AGENTE_BIN="${SANDBOX}/bin"
export AGENTE_SO_CARREGAR=1
mkdir -p "$AGENTE_RAIZ" "$AGENTE_ESTADO" "$AGENTE_BIN"

if [[ ! -f "${RAIZ}/monitoring-agent.sh" ]]; then
  echo "monitoring-agent.sh nao existe. Rode ./scripts/build.sh primeiro." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${RAIZ}/monitoring-agent.sh"
carrega_config

zera_estado() { rm -rf "${AGENTE_ESTADO:?}"/*.state "${AGENTE_ESTADO:?}"/cpu.amostra "${AGENTE_ESTADO:?}"/orcamento 2>/dev/null || true; }

# =========================================================================
grupo "Aritmetica sem bc (bc pode nao existir no servidor)"
# =========================================================================

igual "percentual simples"            "25.0"  "$(pct 50 200)"
igual "percentual com total zero"     "0.0"   "$(pct 10 0)"
igual "delta normal"                  "40"    "$(delta 100 60)"
igual "delta nunca negativo (reboot)" "0"     "$(delta 60 100)"
igual "arredondamento com 1 casa"     "93.3"  "$(num 93.2649 1)"
verdade "maior: 95 > 85"  maior 95 85
mentira "maior: 85 > 95"  maior 95.0 95.1
verdade "menor: 10 < 85"  menor 10 85
igual "duracao em minutos"            "7min"  "$(duracao_humana 437)"
igual "duracao em horas"              "2h05min" "$(duracao_humana 7532)"
igual "15m vira segundos"             "900"   "$(para_segundos 15m)"
igual "2h vira segundos"              "7200"  "$(para_segundos 2h)"

# =========================================================================
grupo "Memoria: o defeito que gerava alerta a cada minuto"
# =========================================================================

export PROC_MEMINFO="${FIX}/meminfo-servidor-real"
mede_memoria

# Servidor real medido: 16,2 GB totais com 8,8 GB disponiveis.
igual "uso real com MemAvailable" "45.7" "$MEDIDA_MEM"

# A conta do agente antigo era used + buff/cache do free. Este teste existe
# para o defeito nao voltar: o valor antigo passa do limiar de 85 e o novo nao.
CONTA_ANTIGA="$(awk '
  /^MemTotal:/      {t=$2}
  /^MemFree:/       {f=$2}
  /^Buffers:/       {b=$2}
  /^Cached:/        {c=$2}
  /^SReclaimable:/  {s=$2}
  END { bc_=b+c+s; used=t-f-bc_; printf "%.1f", ((used+bc_)/t)*100 }
' "$PROC_MEMINFO")"
igual "a conta antiga dava quase 88%" "87.7" "$CONTA_ANTIGA"
verdade "a conta antiga passaria do limiar de 85" maior "$CONTA_ANTIGA" 85
mentira "a conta nova nao passa do limiar de 85"  maior "$MEDIDA_MEM" 85

igual "sem swap configurado, swap fica vazio" "" "$MEDIDA_SWAP"
igual "SwapTotal zero e reportado como zero"  "0" "$MEDIDA_SWAP_TOTAL_KB"

export PROC_MEMINFO="${FIX}/meminfo-critico"
mede_memoria
igual "servidor realmente cheio"    "97.5" "$MEDIDA_MEM"
igual "swap em uso alto"            "90.0" "$MEDIDA_SWAP"

export PROC_MEMINFO="${FIX}/meminfo-sem-memavailable"
mede_memoria
igual "fallback sem MemAvailable (kernel antigo)" "67.4" "$MEDIDA_MEM"
igual "swap pelo fallback"                        "80.0" "$MEDIDA_SWAP"

# =========================================================================
grupo "CPU: media do intervalo, nao de uma janela de 2 segundos"
# =========================================================================

prepara_amostra() {
  # formato: total idle iowait steal timestamp
  printf '9367000 8050000 50000 5000 %s\n' "$(( $(date +%s) - 60 ))" >"${AGENTE_ESTADO}/cpu.amostra"
}

zera_estado; prepara_amostra
export PROC_STAT="${FIX}/stat-t1-ocioso"
mede_cpu
igual "servidor ocioso"            "6.7"  "$MEDIDA_CPU"
igual "iowait baixo"               "0.2"  "$MEDIDA_IOWAIT"
igual "sem steal"                  "0.0"  "$MEDIDA_STEAL"

zera_estado; prepara_amostra
export PROC_STAT="${FIX}/stat-t1-saturado"
mede_cpu
igual "servidor saturado"          "93.3" "$MEDIDA_CPU"

zera_estado; prepara_amostra
export PROC_STAT="${FIX}/stat-t1-steal"
mede_cpu
igual "CPU com steal alto"         "65.8" "$MEDIDA_CPU"
igual "steal medido separado"      "40.5" "$MEDIDA_STEAL"
verdade "steal acima do limiar de atencao" maior "$MEDIDA_STEAL" "$STEAL_ATENCAO"

# Amostra velha (agente parado por horas) nao pode virar media de horas.
zera_estado
printf '9367000 8050000 50000 5000 %s\n' "$(( $(date +%s) - 7200 ))" >"${AGENTE_ESTADO}/cpu.amostra"
export PROC_STAT="${FIX}/stat-t1-saturado"
ANTES="$(date +%s)"
mede_cpu
DEPOIS="$(date +%s)"
mentira "amostra de 2h atras nao e usada como media" test "$MEDIDA_CPU_JANELA" -gt 60
verdade "nesse caso tira amostra curta na hora" test "$(( DEPOIS - ANTES ))" -ge 1

# =========================================================================
grupo "Histerese: o pico isolado morre sem virar mensagem"
# =========================================================================

zera_estado
CICLOS_CONFIRMACAO=3
CICLOS_RECUPERACAO=3
BANDA_SAIDA=8
RENOTIFICAR_MIN=60

avalia teste 99 85 95
igual "ciclo 1 acima do limiar: nao avisa" "nada" "$AV_ACAO"
avalia teste 99 85 95
igual "ciclo 2 acima do limiar: nao avisa" "nada" "$AV_ACAO"
avalia teste 99 85 95
igual "ciclo 3 acima do limiar: avisa"     "abrir" "$AV_ACAO"
igual "e avisa como critico"               "critico" "$AV_NIVEL"
avalia teste 99 85 95
igual "ciclo 4: nao repete dentro do cooldown" "nada" "$AV_ACAO"

zera_estado
avalia teste 99 85 95
avalia teste 10 85 95
avalia teste 99 85 95
avalia teste 99 85 95
igual "pico, normal, pico, pico: ainda nao avisa" "nada" "$AV_ACAO"

# Escalada de atencao para critico interrompe de novo, porque piorou de verdade.
zera_estado
for _ in 1 2 3; do avalia teste 88 85 95; done
igual "tres ciclos em atencao: abre"       "abrir" "$AV_ACAO"
igual "nivel e atencao"                    "atencao" "$AV_NIVEL"
for _ in 1 2 3; do avalia teste 97 85 95; done
igual "piorou para critico: escala"        "escalar" "$AV_ACAO"
igual "nivel agora e critico"              "critico" "$AV_NIVEL"

# =========================================================================
grupo "Recuperacao e banda de saida"
# =========================================================================

zera_estado
for _ in 1 2 3; do avalia teste 99 85 95; done
igual "abriu o incidente" "abrir" "$AV_ACAO"

# 80 esta abaixo do limiar 85 mas dentro da banda de 8 pontos (saida em 77).
for _ in 1 2 3 4; do avalia teste 80 85 95; done
igual "dentro da banda nao conta como recuperado" "nada" "$AV_ACAO"

avalia teste 50 85 95
igual "abaixo da banda, ciclo 1: ainda nao" "nada" "$AV_ACAO"
avalia teste 50 85 95
igual "abaixo da banda, ciclo 2: ainda nao" "nada" "$AV_ACAO"
avalia teste 50 85 95
igual "abaixo da banda, ciclo 3: resolve"   "resolver" "$AV_ACAO"
verdade "a recuperacao reporta o pico" maior "$AV_PICO" 98
verdade "a recuperacao reporta a duracao" test "$AV_DURACAO" -ge 0

avalia teste 50 85 95
igual "depois de resolver, volta ao silencio" "nada" "$AV_ACAO"

# =========================================================================
grupo "Renotificacao: lembra do problema aberto, sem martelar"
# =========================================================================

zera_estado
RENOTIFICAR_MIN=60
for _ in 1 2 3; do avalia teste 99 85 95; done
for _ in 1 2 3 4 5; do avalia teste 99 85 95; done
igual "problema aberto nao repete em 5 ciclos" "nada" "$AV_ACAO"

# Envelhece o registro do ultimo alerta em 61 minutos.
sed -i "s/^ULTIMO_ALERTA=.*/ULTIMO_ALERTA=$(( $(date +%s) - 3700 ))/" "$(caminho_estado teste)"
avalia teste 99 85 95
igual "passada uma hora, repete uma vez" "repetir" "$AV_ACAO"

RENOTIFICAR_MIN=0
zera_estado
for _ in 1 2 3; do avalia teste 99 85 95; done
avalia teste 99 85 95
igual "RENOTIFICAR_MIN=0 desliga a repeticao" "nada" "$AV_ACAO"
RENOTIFICAR_MIN=60

# =========================================================================
grupo "Janela de silencio para deploy e manutencao"
# =========================================================================

mentira "sem arquivo, nao ha silencio" silencio_ativo
inicia_silencio 15m "deploy da api"
verdade "silencio ligado"              silencio_ativo
igual   "motivo preservado"            "deploy da api" "$SILENCIO_MOTIVO"
verdade "resta quase o periodo inteiro" test "$SILENCIO_RESTA" -gt 880
encerra_silencio
mentira "silencio encerrado"           silencio_ativo

inicia_silencio 99d "esquecido ligado"
ATE="$(awk -F= '/^ATE=/{print $2}' "${AGENTE_RAIZ}/silencio")"
verdade "silencio tem teto de 24h" test "$(( ATE - $(date +%s) ))" -le 86401
encerra_silencio

printf 'ATE=%s\nMOTIVO=ja passou\n' "$(( $(date +%s) - 10 ))" >"${AGENTE_RAIZ}/silencio"
mentira "silencio vencido nao vale"    silencio_ativo
mentira "e o arquivo vencido e apagado" test -f "${AGENTE_RAIZ}/silencio"

# =========================================================================
grupo "Orcamento de alertas por hora"
# =========================================================================

rm -f "${AGENTE_ESTADO}/orcamento"
MAX_ALERTAS_HORA=3
verdade "alerta 1 dentro do orcamento" consome_orcamento
verdade "alerta 2 dentro do orcamento" consome_orcamento
verdade "alerta 3 dentro do orcamento" consome_orcamento
mentira "alerta 4 estoura o orcamento" consome_orcamento
verdade "e o estouro fica registrado"  orcamento_estourado
MAX_ALERTAS_HORA=12
rm -f "${AGENTE_ESTADO}/orcamento"

# =========================================================================
grupo "Configuracao invalida nao pode passar despercebida"
# =========================================================================

CPU_ATENCAO=95; CPU_CRITICO=85
valida_config
igual "limiar invertido e corrigido (atencao)" "85" "$CPU_ATENCAO"
igual "limiar invertido e corrigido (critico)" "95" "$CPU_CRITICO"

CICLOS_CONFIRMACAO=0
valida_config
igual "zero ciclos de confirmacao vira 3" "3" "$CICLOS_CONFIRMACAO"

CICLOS_CONFIRMACAO="abc"
valida_config
igual "ciclo nao numerico vira 3" "3" "$CICLOS_CONFIRMACAO"

MEM_ATENCAO="x"; MEM_CRITICO=95
valida_config
igual "limiar nao numerico desliga a metrica" "0" "$VIGIAR_MEMORIA"
MEM_ATENCAO=85; MEM_CRITICO=95; VIGIAR_MEMORIA=1
valida_config

# =========================================================================
grupo "Versao semantica do atualizador"
# =========================================================================

verdade "2.0.0 > 1.9.9"      versao_maior 2.0.0 1.9.9
verdade "2.0.1 > 2.0.0"      versao_maior 2.0.1 2.0.0
verdade "2.1.0 > 2.0.9"      versao_maior 2.1.0 2.0.9
mentira "2.0.0 nao > 2.0.0"  versao_maior 2.0.0 2.0.0
mentira "1.0.0 nao > 2.0.0"  versao_maior 1.0.0 2.0.0
verdade "2.0 > 1.9.9 (campos faltando)" versao_maior 2.0 1.9.9
verdade "qualquer coisa > 0.0.0"        versao_maior 0.0.1 0.0.0

# =========================================================================
grupo "Estado sobrevive entre execucoes"
# =========================================================================

zera_estado
for _ in 1 2 3; do avalia persiste 99 85 95; done
ARQ="$(caminho_estado persiste)"
verdade "arquivo de estado criado"        test -f "$ARQ"
verdade "nivel gravado"                   grep -q '^NIVEL=critico$' "$ARQ"
verdade "momento de inicio gravado"       grep -qE '^DESDE=[0-9]{10}' "$ARQ"
verdade "pico gravado"                    grep -q '^VALOR_PICO=99' "$ARQ"

le_estado persiste
igual "estado relido corretamente" "critico" "$E_NIVEL"

igual "chave com barra vira nome seguro" "disco__var_log" "$(nome_seguro 'disco:/var/log')"

# =========================================================================
grupo "Load e nucleos"
# =========================================================================

export PROC_LOADAVG="${FIX}/loadavg-saturado"
nucleos() { printf '4'; }
mede_load
igual "load bruto"                 "5.41" "$MEDIDA_LOAD_BRUTO"
igual "load normalizado por nucleo" "1.35" "$MEDIDA_LOAD"
verdade "load normalizado nao passa do critico" menor "$MEDIDA_LOAD" "$LOAD_CRITICO"

export PROC_LOADAVG="${FIX}/loadavg-ocioso"
mede_load
igual "servidor ocioso"            "0.12" "$MEDIDA_LOAD"

# =========================================================================
grupo "Disco: o parser precisa aguentar nome de dispositivo com espaco"
# =========================================================================

export FIXTURE_DF="${FIX}/df-com-espaco-no-dispositivo"
export FIXTURE_DF_INODES="${FIX}/df-inodes"
DISCO_IGNORAR="/var/lib/docker/* /snap/* /dev/shm"
mede_disco

campo_disco() { printf '%s' "$MEDIDA_DISCO_LINHAS" | awk -v m="$1" -v c="$2" '$1==m {print $c; exit}'; }

igual "raiz: uso"                      "33"  "$(campo_disco / 2)"
igual "raiz: inodes"                   "13"  "$(campo_disco / 3)"

# Um dispositivo com espaco no nome deslocava todos os campos no parser antigo:
# o agente comparava o ponto de montagem com o percentual e nunca alertava.
igual "dispositivo com espaco: montagem lida" "95" "$(campo_disco /mnt/backup 2)"
igual "sem contagem de inode vira zero"       "0"  "$(campo_disco /mnt/backup 3)"
igual "boot/efi com uso baixo"                "6"  "$(campo_disco /boot/efi 2)"

igual "volume de container ignorado"   ""    "$(campo_disco /var/lib/docker/overlay2/abc 2)"
igual "tmpfs fora da lista"            ""    "$(campo_disco /dev/shm 2)"
igual "tres montagens aproveitadas"    "3"   "$(printf '%s' "$MEDIDA_DISCO_LINHAS" | grep -c .)"

unset FIXTURE_DF FIXTURE_DF_INODES

# =========================================================================
grupo "Diagnostico: a frase que diz por onde comecar"
# =========================================================================

MEDIDA_STEAL=40; MEDIDA_IOWAIT=1; MEDIDA_LOAD=0.5
verdade "steal alto aponta o provedor" bash -c "[[ '$(diagnostico cpu 90)' == *provedor* ]]"
MEDIDA_STEAL=1; MEDIDA_IOWAIT=40
verdade "iowait alto aponta disco"     bash -c "[[ '$(diagnostico cpu 90)' == *disco* ]]"
MEDIDA_STEAL=1; MEDIDA_IOWAIT=1; MEDIDA_LOAD=0.3
verdade "sem sinal especifico, aponta os processos" bash -c "[[ '$(diagnostico cpu 90)' == *processos* ]]"

MEDIDA_SWAP_TOTAL_KB=0; MEDIDA_MEM_DISP_KB=204800
verdade "memoria sem swap avisa do OOM kill" bash -c "[[ '$(diagnostico memoria 95)' == *OOM* ]]"

# =========================================================================
grupo "Escape de texto"
# =========================================================================

igual "html escapado" "&lt;b&gt;x&lt;/b&gt;" "$(printf '<b>x</b>' | escapa_html)"
igual "aspas escapadas para json" 'ele disse \"ok\"\n' "$(printf 'ele disse "ok"' | escapa_json)"

# =========================================================================
grupo "Escrita atomica e trava"
# =========================================================================

printf 'conteudo\n' | escreve_atomico "${SANDBOX}/arquivo.txt"
igual "arquivo escrito"           "conteudo" "$(cat "${SANDBOX}/arquivo.txt")"
mentira "sem temporario sobrando" bash -c "ls '${SANDBOX}'/.tmp.* >/dev/null 2>&1"

verdade "primeira trava e concedida" pega_trava teste_trava
TRAVA_SALVA="$TRAVA_DIR"
TRAVA_DIR=""
mentira "segunda trava e negada"     pega_trava teste_trava
TRAVA_DIR="$TRAVA_SALVA"
solta_trava
verdade "trava liberada"             pega_trava teste_trava
solta_trava

# Trava de processo morto nao pode travar o monitoramento para sempre.
mkdir -p "${AGENTE_ESTADO}/.lock-orfa"
printf '999999' >"${AGENTE_ESTADO}/.lock-orfa/pid"
verdade "trava de processo morto e liberada" pega_trava orfa
solta_trava

# =========================================================================
grupo "Montagens ignoradas"
# =========================================================================

DISCO_IGNORAR="/var/lib/docker/* /snap/* /dev/shm"
verdade "volume de container ignorado" ignorar_montagem "/var/lib/docker/volumes/abc"
verdade "snap ignorado"                ignorar_montagem "/snap/core/1234"
mentira "raiz nao e ignorada"          ignorar_montagem "/"
mentira "/var nao e ignorado"          ignorar_montagem "/var"

# =========================================================================
grupo "Artefatos distribuidos"
# =========================================================================

for nome in monitoring-agent.sh monitor_cpu.sh monitor_memory.sh monitor_disk.sh; do
  verdade "${nome} passa em bash -n" bash -n "${RAIZ}/${nome}"
done

verdade "manifesto existe"          test -f "${RAIZ}/agent.manifest"
verdade "manifesto declara versao"  grep -q '^VERSAO=[0-9]' "${RAIZ}/agent.manifest"
igual   "manifesto lista 4 arquivos" "4" "$(grep -c '^ARQUIVO=' "${RAIZ}/agent.manifest")"

# O canal de atualizacao antigo edita estas linhas com sed. Se o formato
# mudar, a frota instalada para de receber limiar e destinatario do painel.
for nome in monitor_cpu.sh monitor_memory.sh monitor_disk.sh; do
  verdade "${nome} mantem CPU_THRESHOLD= para o canal antigo"  grep -q '^CPU_THRESHOLD=[0-9]' "${RAIZ}/${nome}"
  verdade "${nome} mantem MEM_THRESHOLD= para o canal antigo"  grep -q '^MEM_THRESHOLD=[0-9]' "${RAIZ}/${nome}"
  verdade "${nome} mantem DISK_THRESHOLD= para o canal antigo" grep -q '^DISK_THRESHOLD=[0-9]' "${RAIZ}/${nome}"
  verdade "${nome} mantem RECIPIENTS= para o canal antigo"     grep -q '^RECIPIENTS=' "${RAIZ}/${nome}"
done

# Os checksums do manifesto precisam bater com os arquivos publicados, senao
# o proprio agente recusa a atualizacao e a frota fica parada na versao velha.
sha_de() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
while read -r linha; do
  [[ "$linha" == ARQUIVO=* ]] || continue
  nome="$(printf '%s' "${linha#ARQUIVO=}" | awk '{print $1}')"
  esperado="$(printf '%s' "${linha#ARQUIVO=}" | awk '{print $2}')"
  igual "sha256 de ${nome} confere" "$esperado" "$(sha_de "${RAIZ}/${nome}")"
done <"${RAIZ}/agent.manifest"

verdade "versao do bundle bate com agent.version" \
  grep -q "^AGENTE_VERSAO=\"$(tr -d '[:space:]' <"${RAIZ}/agent.version")\"" "${RAIZ}/monitoring-agent.sh"

# =========================================================================
grupo "Nada de travessao no que a pessoa le"
# =========================================================================

ACHADOS="$(grep -rn $'—\|–\|―' "${RAIZ}/src" "${RAIZ}/docs" 2>/dev/null | head -5 || true)"
igual "sem travessao no codigo e na documentacao" "" "$ACHADOS"

# =========================================================================

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32m%s verificacoes, todas verdes.\033[0m\n' "$TOTAL"
  exit 0
fi
printf '\033[31m%s verificacoes, %s falha(s).\033[0m\n' "$TOTAL" "$FALHAS"
exit 1
