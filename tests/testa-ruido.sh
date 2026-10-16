#!/usr/bin/env bash
#
# Bateria do que NAO deve virar alerta, e de como o alerta que sai e escrito.
#
#   ./tests/testa-ruido.sh
#
# Nasceu de um e-mail real recebido em 15/10/2026:
#
#   [CONTINUA] Load average 1.56 - <servidor>
#   Load average en 1.56 en <servidor>
#   Asi desde hace 6d4h, pico de 2.29. Confirmado en 3 lecturas seguidas.
#
# O servidor tinha 8 nucleos, CPU em 67.9%, iowait em 1.0%, 18.6 GB de memoria
# livre. Estava trabalhando, nao sofrendo. E aquilo renotificava de hora em
# hora havia seis dias: perto de 148 e-mails iguais.
#
# Tres coisas estavam erradas ao mesmo tempo: o load virava incidente sozinho,
# a renotificacao tinha intervalo fixo, e o texto era jargao em vez de aviso.
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
igual()      { [[ "$2" == "$3" ]] && ok "$1" || falha "$1" "$2" "$3"; }
contem()     { case "$2" in *"$3"*) ok "$1" ;; *) falha "$1" "conter \"$3\"" "$2" ;; esac; }
nao_contem() { case "$2" in *"$3"*) falha "$1" "nao conter \"$3\"" "$2" ;; *) ok "$1" ;; esac; }
verdade()    { local d="$1"; shift; if "$@"; then ok "$d"; else falha "$d"; fi; }
mentira()    { local d="$1"; shift; if "$@"; then falha "$d"; else ok "$d"; fi; }
antes_de()   { # descricao texto primeiro segundo
  local t="$2" a="$3" b="$4" pa pb
  pa="${t%%"$a"*}"; pb="${t%%"$b"*}"
  if [[ "$t" == *"$a"* && "$t" == *"$b"* && "${#pa}" -lt "${#pb}" ]]; then
    ok "$1"
  else
    falha "$1" "\"$a\" antes de \"$b\""
  fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export AGENTE_RAIZ="${SANDBOX}/opt" AGENTE_ESTADO="${SANDBOX}/state"
export AGENTE_LOG="${SANDBOX}/log" AGENTE_BIN="${SANDBOX}/bin"
export AGENTE_SO_CARREGAR=1
mkdir -p "$AGENTE_RAIZ" "$AGENTE_ESTADO" "$AGENTE_BIN"

[[ -f "${RAIZ}/monitoring-agent.sh" ]] || { echo "rode ./scripts/build.sh primeiro" >&2; exit 1; }
# shellcheck disable=SC1091
source "${RAIZ}/monitoring-agent.sh"
carrega_config
SERVER_ID="Servidor de teste"

# =========================================================================
grupo "O e-mail que motivou isto nao sai mais"
# =========================================================================
#
# Os numeros sao os medidos no servidor real, nao inventados para o teste.

MEDIDA_LOAD="1.56"; MEDIDA_CPU="67.9"; MEDIDA_IOWAIT="1.0"
mentira "load 1.56 com CPU 67.9% e iowait 1.0% nao alerta" load_vira_alerta

# A fila so importa quando ha sintoma junto, e aí ela ajuda a explicar.
MEDIDA_CPU="91.0"
verdade "a mesma fila com a CPU em 91% alerta" load_vira_alerta

MEDIDA_CPU="30.0"; MEDIDA_IOWAIT="42.0"
verdade "fila com iowait em 42% alerta: e espera de disco" load_vira_alerta

MEDIDA_IOWAIT="1.0"; MEDIDA_LOAD=""
mentira "sem medida de load nao ha o que avaliar" load_vira_alerta

# O limiar de fabrica deixou de transformar servidor que trabalha em alerta.
MEDIDA_LOAD="1.56"
read -r LIM_AT LIM_CR <<<"$(limiar_de load)"
verdade "limiar de atencao acima do caso real" maior "$LIM_AT" "1.56"
igual   "limiar de atencao de fabrica" "2.5" "$LIM_AT"
igual   "limiar critico de fabrica"    "4.0" "$LIM_CR"

# =========================================================================
grupo "Incidente longo avisa cada vez menos"
# =========================================================================
#
# Intervalo fixo de uma hora e o que transforma seis dias de incidente em
# perto de 148 e-mails identicos. A espera dobra ate o teto de um dia.

RENOTIFICAR_MIN=60; RENOTIFICAR_MAX_MIN=1440
igual "1a repeticao: 1h"  "3600"  "$(espera_renotificacao 0)"
igual "2a repeticao: 2h"  "7200"  "$(espera_renotificacao 1)"
igual "3a repeticao: 4h"  "14400" "$(espera_renotificacao 2)"
igual "4a repeticao: 8h"  "28800" "$(espera_renotificacao 3)"
igual "5a repeticao: 16h" "57600" "$(espera_renotificacao 4)"
igual "6a repeticao: 1 dia, que e o teto" "86400" "$(espera_renotificacao 5)"
igual "e daí em diante continua 1 dia"    "86400" "$(espera_renotificacao 9)"
igual "mesmo depois de uma semana"        "86400" "$(espera_renotificacao 40)"

# Em seis dias: 1+2+4+8+16 = 31h nas cinco primeiras, e uma por dia depois.
# Dez avisos, contra os 148 do intervalo fixo.
SOMA=0; REP=0
while [[ "$SOMA" -lt $(( 6 * 86400 )) ]]; do
  SOMA=$(( SOMA + $(espera_renotificacao "$REP") )); REP=$(( REP + 1 ))
done
verdade "seis dias de incidente cabem em menos de 12 avisos" test "$REP" -lt 12

RENOTIFICAR_MIN=0
igual "zero continua desligando a renotificacao" "0" "$(espera_renotificacao 3)"
RENOTIFICAR_MIN=60

RENOTIFICAR_MAX_MIN=30
igual "teto menor que o minimo nao inverte a conta" "3600" "$(espera_renotificacao 5)"
RENOTIFICAR_MAX_MIN=1440

# --- o mesmo pela maquina de estado, que e quem decide de verdade ---------

CICLOS_CONFIRMACAO=1; CICLOS_RECUPERACAO=1; BANDA_SAIDA=8
CHAVE="ruido:cpu"
rm -f "$(caminho_estado "$CHAVE")"

avalia "$CHAVE" 95 85 97
igual "primeira confirmacao abre o incidente" "abrir" "$AV_ACAO"

avalia "$CHAVE" 95 85 97
igual "logo em seguida nao repete" "nada" "$AV_ACAO"

# Uma hora depois, a primeira repeticao sai.
envelhece() {  # segundos
  local arq; arq="$(caminho_estado "$CHAVE")"
  local atual; atual="$(awk -F= '/^ULTIMO_ALERTA=/{print $2}' "$arq")"
  sed -i "s/^ULTIMO_ALERTA=.*/ULTIMO_ALERTA=$(( atual - $1 ))/" "$arq"
}
envelhece 3700
avalia "$CHAVE" 95 85 97
igual "uma hora depois, repete" "repetir" "$AV_ACAO"

# Agora a espera dobrou: uma hora ja nao basta.
envelhece 3700
avalia "$CHAVE" 95 85 97
igual "uma hora depois da repeticao, ainda nao" "nada" "$AV_ACAO"

envelhece 7300
avalia "$CHAVE" 95 85 97
igual "duas horas depois, repete de novo" "repetir" "$AV_ACAO"

# Piorar de verdade zera a conta: interromper alguem de novo vale a pena.
avalia "$CHAVE" 99 85 97
igual "escalada sai na hora, sem esperar" "escalar" "$AV_ACAO"
igual "e zera o contador de repeticoes" "0" \
  "$(awk -F= '/^REPETICOES=/{print $2}' "$(caminho_estado "$CHAVE")")"

envelhece 3700
avalia "$CHAVE" 99 85 97
igual "depois de escalar, a espera volta a uma hora" "repetir" "$AV_ACAO"

# Recuperar limpa tudo, para o proximo incidente nao herdar a espera longa.
avalia "$CHAVE" 10 85 97
igual "recuperou" "resolver" "$AV_ACAO"
igual "e o contador foi zerado" "0" \
  "$(awk -F= '/^REPETICOES=/{print $2}' "$(caminho_estado "$CHAVE")")"

# =========================================================================
grupo "Incidente de load consegue se fechar"
# =========================================================================
#
# Este era o motivo mais grave do e-mail de seis dias, e nao aparecia olhando
# so para os limiares. A banda de saida vinha em pontos percentuais para todas
# as metricas: 8 pontos descontados de um limiar de 2.5 dao numero negativo,
# que fica preso em zero, e aí o incidente so se fecharia com o load
# EXATAMENTE zero. Load zero nao existe em servidor ligado.

igual "a banda do load e em fila por nucleo" "0.3" "$(banda_de load)"
igual "a das demais continua em pontos percentuais" "8" "$(banda_de cpu)"
igual "inclusive para o steal" "8" "$(banda_de steal)"

CICLOS_CONFIRMACAO=1; CICLOS_RECUPERACAO=1
CHAVE="ruido:load"
rm -f "$(caminho_estado "$CHAVE")"

avalia "$CHAVE" 3.0 2.5 4.0 "$(banda_de load)"
igual "fila alta abre o incidente" "abrir" "$AV_ACAO"

avalia "$CHAVE" 2.3 2.5 4.0 "$(banda_de load)"
igual "logo abaixo do limiar ainda nao fecha" "nada" "$AV_ACAO"

avalia "$CHAVE" 1.2 2.5 4.0 "$(banda_de load)"
igual "fila normal fecha o incidente" "resolver" "$AV_ACAO"

# Quando a 2.4.0 chega num servidor com incidente de load aberto, ele e
# fechado porque o criterio mudou. O aviso de recuperacao sai com a fila real,
# nao com um zero inventado: toda a frota recebe esse e-mail uma vez.
LOAD_ATENCAO=2.5; MEDIDA_LOAD="1.56"
igual "fecha com a fila de verdade" "1.56" "$(valor_para_fechar_load)"
MEDIDA_LOAD="3.4"
igual "fila ainda alta forca o fechamento com zero" "0" "$(valor_para_fechar_load)"
MEDIDA_LOAD=""
igual "sem medida, zero" "0" "$(valor_para_fechar_load)"
MEDIDA_LOAD="1.56"

# Com a banda das metricas percentuais, o mesmo caminho nao fecharia nunca.
rm -f "$(caminho_estado "$CHAVE")"
avalia "$CHAVE" 3.0 2.5 4.0 8
avalia "$CHAVE" 0.1 2.5 4.0 8
igual "a banda errada deixava o incidente preso" "nada" "$AV_ACAO"
rm -f "$(caminho_estado "$CHAVE")"

# =========================================================================
grupo "Bater o olho e saber do que se trata"
# =========================================================================

IDIOMA="pt-BR"
MEDIDA_CPU="97.0"; MEDIDA_MEM="98"; MEDIDA_LOAD="1.56"; MEDIDA_IOWAIT="1.0"
MEDIDA_STEAL="2.8"; MEDIDA_SWAP_TOTAL_KB=0; MEDIDA_MEM_DISP_KB=204800
MEDIDA_LOAD_BRUTO="12.49"; MEDIDA_NUCLEOS=8; CICLOS_CONFIRMACAO=3

F="$(frase_problema memoria "98%")"
igual "a frase diz o que houve, nao o nome da metrica" "Memória quase cheia (98%)" "$F"
igual "disco leva o ponto de montagem" "Disco quase cheio em /var (91%)" \
  "$(frase_problema disco "91%" "disco:/var")"
igual "a fila de processos em palavras" "Fila de processos esperando CPU" \
  "$(frase_problema load "1.56")"
nao_contem "e a frase do load nao joga o numero na cara" "$(frase_problema load "1.56")" "1.56"

igual "recuperacao tambem e uma frase" "A memória voltou ao normal (44%)" \
  "$(frase_recuperacao memoria "44%")"

# A urgencia e dita sem numero: e ela que decide se alguem levanta agora.
igual "critico chama alguem"      "Precisa de alguém agora." "$(urgencia abrir critico)"
contem "atencao nao e emergencia" "$(urgencia abrir atencao)" "Não é emergência"
contem "resolvido nao pede nada"  "$(urgencia resolver atencao)" "Nada a fazer"

# --- o corpo inteiro, na ordem em que a pessoa pergunta -------------------

CORPO="$(monta_corpo memoria memoria 98 90 abrir critico 3600 98.4 "<p>processos</p>")"
contem   "o corpo abre dizendo o que isso causa" "$CORPO" "o servidor derruba processos sem avisar"
contem   "diz se precisa de alguem agora"        "$CORPO" "Precisa de alguém agora."
contem   "diz ha quanto tempo esta assim"        "$CORPO" "Está assim há 1h00min."
contem   "tem o que fazer"                       "$CORPO" "O que fazer"
contem   "e o numero continua la"                "$CORPO" "98"
contem   "com a tabela de contexto"              "$CORPO" "iowait"
contem   "e o extra recebido"                    "$CORPO" "<p>processos</p>"

antes_de "o impacto vem antes da urgencia" "$CORPO" "derruba processos" "Precisa de alguém"
antes_de "a urgencia vem antes do que fazer" "$CORPO" "Precisa de alguém" "O que fazer"
antes_de "e o numero fica por ultimo" "$CORPO" "O que fazer" "Detalhes técnicos"

# Recuperacao nao tem "o que fazer": nao ha o que fazer.
CORPO_OK="$(monta_corpo memoria memoria 44 90 resolver atencao 7200 98.4)"
contem     "recuperacao diz que normalizou" "$CORPO_OK" "normalizou"
contem     "e que nao ha nada a fazer"      "$CORPO_OK" "Nada a fazer"
nao_contem "sem bloco de o que fazer"       "$CORPO_OK" "O que fazer"

# --- o mesmo nos outros dois idiomas --------------------------------------

IDIOMA="es-CO"
contem "em espanhol a frase tambem e humana" "$(frase_problema memoria "98%")" "Memoria casi llena"
contem "urgencia em espanhol" "$(urgencia abrir critico)" "ahora"
nao_contem "sem portugues no meio do espanhol" "$(monta_corpo memoria memoria 98 90 abrir critico 60 98.4)" "Precisa de"

IDIOMA="en-US"
contem "em ingles tambem" "$(frase_problema memoria "98%")" "Memory almost full"
contem "urgencia em ingles" "$(urgencia abrir critico)" "now"
IDIOMA="pt-BR"

# =========================================================================
grupo "O que fazer fala do problema, nao de outra metrica"
# =========================================================================
#
# O bloco "o que fazer" escolhe o texto pelo que explica o numero. Os limiares
# dessa escolha estavam cravados, com 1.5 para load e 10 para steal, e ficaram
# para tras quando os de verdade subiram: um alerta de CPU em 97% abria
# falando de load average, que e exatamente o jargao que ninguem precisa ler
# primeiro.

IDIOMA="pt-BR"
MEDIDA_STEAL="2.8"; MEDIDA_IOWAIT="1.0"; MEDIDA_LOAD="1.56"
contem     "CPU alta com fila normal fala de CPU" "$(diagnostico cpu 97)" "Uso sustentado de CPU"
nao_contem "e nao fala de load average"           "$(diagnostico cpu 97)" "Load average"

MEDIDA_LOAD="3.2"
contem "fila de verdade volta a aparecer" "$(diagnostico cpu 97)" "Load average"

MEDIDA_LOAD="1.56"; MEDIDA_STEAL="30"
contem "steal acima do limiar aponta o provedor" "$(diagnostico cpu 97)" "provedor"

MEDIDA_STEAL="2.8"; MEDIDA_IOWAIT="40"
contem "iowait alto aponta disco" "$(diagnostico cpu 97)" "esperando disco"
MEDIDA_IOWAIT="1.0"

# =========================================================================
grupo "A lista de processos nao acusa o proprio medidor"
# =========================================================================
#
# No e-mail real o primeiro lugar era do proprio comando de medicao, com 400%,
# e o agente vinha logo abaixo. Quem lia concluia que o monitoramento era o
# que estava consumindo o servidor.

mkdir -p "${SANDBOX}/falso"
cat >"${SANDBOX}/falso/ps" <<'PSFALSO'
#!/usr/bin/env bash
cat <<'SAIDA'
1737724 root      400.0   0.0 ps              ps -eo pid,user,pcpu,pmem,comm,args --sort=-%cpu
1737546 www        95.0   0.2 php             /usr/local/bin/php artisan schedule:run
1723456 root       63.4   1.7 node            node /var/lib/agent-workspaces/pws-b9f756
1737609 root       16.3   0.0 bash            /usr/local/bin/monitoring-agent.sh rodada
2466    mysql      24.0   2.1 mariadbd        mariadbd
SAIDA
PSFALSO
chmod +x "${SANDBOX}/falso/ps"
# O PATH e trocado DENTRO do subshell: prefixar a atribuicao nao adianta,
# porque a substituicao de comando roda antes de o prefixo valer.
LISTA="$(PATH="${SANDBOX}/falso:${PATH}"; top_processos cpu 12)"

nao_contem "o proprio ps ficou de fora"     "$LISTA" "400.0"
nao_contem "o agente tambem"                "$LISTA" "monitoring-agent.sh"
contem     "e o que importa continua la"    "$LISTA" "artisan schedule:run"
contem     "com o banco junto"              "$LISTA" "mariadbd"

# =========================================================================
grupo "O assunto diz servidor, gravidade e problema"
# =========================================================================

IDIOMA="pt-BR"
ASSUNTO="$(prefixo_assunto abrir) ${SERVER_ID}: $(frase_problema cpu "97%")"
contem "tem a gravidade"  "$ASSUNTO" "[ATENÇÃO]"
contem "tem o servidor"   "$ASSUNTO" "Servidor de teste"
contem "e o que houve"    "$ASSUNTO" "CPU no limite (97%)"

TITULO="$(t titulo_frase "$(frase_problema cpu "97%")" "$SERVER_ID")"
igual "o titulo e a mesma frase com o servidor" "CPU no limite (97%) em Servidor de teste" "$TITULO"

# =========================================================================

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32m%s verificacoes de ruido, todas verdes.\033[0m\n' "$TOTAL"; exit 0
fi
printf '\033[31m%s verificacoes de ruido, %s falha(s).\033[0m\n' "$TOTAL" "$FALHAS"
exit 1
