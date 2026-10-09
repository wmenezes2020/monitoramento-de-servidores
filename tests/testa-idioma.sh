#!/usr/bin/env bash
#
# Bateria dos tres idiomas.
#
#   ./tests/testa-idioma.sh
#
# Separada da bateria principal porque exercita outra coisa: a principal
# verifica se o agente mede e decide certo, esta verifica se ele fala certo.
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
# O texto vai por argumento, nunca interpolado dentro de um "bash -c": os
# diagnosticos tem acento, barra e parentese, e qualquer um quebrava a linha.
contem()     { case "$2" in *"$3"*) ok "$1" ;; *) falha "$1" "conter \"$3\"" "$2" ;; esac; }
nao_contem() { case "$2" in *"$3"*) falha "$1" "nao conter \"$3\"" "$2" ;; *) ok "$1" ;; esac; }
casa()       { if [[ "$2" =~ $3 ]]; then ok "$1"; else falha "$1" "casar com $3" "$2"; fi; }
verdade()    { local d="$1"; shift; if "$@"; then ok "$d"; else falha "$d"; fi; }
mentira()    { local d="$1"; shift; if "$@"; then falha "$d"; else ok "$d"; fi; }

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

# =========================================================================
grupo "Qual idioma vale"
# =========================================================================

IDIOMA="pt-BR"; igual "pt-BR"            "pt" "$(idioma_normalizado)"
IDIOMA="en-US"; igual "en-US"            "en" "$(idioma_normalizado)"
IDIOMA="es-CO"; igual "es-CO"            "es" "$(idioma_normalizado)"
IDIOMA="PT-br"; igual "caixa nao importa" "pt" "$(idioma_normalizado)"
IDIOMA="pt";    igual "so o prefixo basta" "pt" "$(idioma_normalizado)"
# Espanhol e o padrao do produto: servidor sem painel nao tem de quem herdar.
IDIOMA="xx-YY"; igual "idioma desconhecido cai no espanhol" "es" "$(idioma_normalizado)"
IDIOMA="";      igual "idioma vazio cai no espanhol"        "es" "$(idioma_normalizado)"

# =========================================================================
grupo "Catalogo: a mesma chave em cada idioma"
# =========================================================================

IDIOMA="pt-BR"
igual "severidade em pt" "ATENÇÃO"  "$(t sev_atencao)"
igual "memoria em pt"    "Memória"  "$(t rotulo_memoria)"
igual "rodape em pt"     "Alerta automático. Não responda." "$(t tpl_rodape)"
IDIOMA="en-US"
igual "severidade em en" "WARNING"  "$(t sev_atencao)"
igual "memoria em en"    "Memory"   "$(t rotulo_memoria)"
igual "rodape em en"     "Automated alert. Do not reply."   "$(t tpl_rodape)"
IDIOMA="es-CO"
igual "severidade em es" "ATENCIÓN" "$(t sev_atencao)"
igual "memoria em es"    "Memoria"  "$(t rotulo_memoria)"
igual "rodape em es"     "Alerta automática. No responda."  "$(t tpl_rodape)"

# Chave sem traducao nao pode sumir no meio de um alerta.
igual "chave inexistente devolve a propria chave" "chave_que_nao_existe" "$(t chave_que_nao_existe)"

# =========================================================================
grupo "Nome de metrica nao se traduz"
# =========================================================================
#
# CPU Steal, Load average, Swap e Inodes sao o que aparece no top, no vmstat,
# no CloudWatch e no Grafana. E por esse nome que quem recebe o alerta
# pesquisa. "CPU roubada" era traducao literal e nao existe em ferramenta
# nenhuma; chegou a sair em e-mail de producao em 09/10/2026.

for idi in pt-BR en-US es-CO; do
  IDIOMA="$idi"
  igual "Load average intacto em ${idi}" "Load average" "$(rotulo_metrica load)"
  igual "Swap intacto em ${idi}"         "Swap"         "$(rotulo_metrica swap)"
  igual "Inodes intacto em ${idi}"       "Inodes"       "$(rotulo_metrica inode)"
  igual "CPU intacto em ${idi}"          "CPU"          "$(rotulo_metrica cpu)"

  # "roubada" saiu de vez: era traducao literal, nao existe em ferramenta
  # nenhuma e assusta quem le o alerta. Chegou a sair em e-mail de producao
  # em 09/10/2026, com o servidor tranquilo.
  nao_contem "sem 'roubada' em ${idi}" "$(rotulo_metrica steal)" "roubada"
  nao_contem "sem 'robada' em ${idi}"  "$(rotulo_metrica steal)" "robada"
  nao_contem "sem 'stolen' em ${idi}"  "$(rotulo_metrica steal)" "tolen"

  # O rotulo e calmo; o termo tecnico fica na tabela de contexto, para quem
  # precisa pesquisar.
  contem "rotulo fala em contencao em ${idi}" "$(rotulo_metrica steal)" "onten"
  contem "tabela mantem o termo steal em ${idi}" "$(t tabela_steal)" "steal"
done

IDIOMA="pt-BR"; igual "rotulo em pt" "Contenção de CPU" "$(rotulo_metrica steal)"
IDIOMA="en-US"; igual "rotulo em en" "CPU contention"   "$(rotulo_metrica steal)"
IDIOMA="es-CO"; igual "rotulo em es" "Contención de CPU" "$(rotulo_metrica steal)"

# =========================================================================
grupo "Assunto, titulo e data"
# =========================================================================

IDIOMA="pt-BR"; igual "critico em pt"   "[CRÍTICO]"  "$(prefixo_assunto escalar)"
IDIOMA="en-US"; igual "critico em en"   "[CRITICAL]" "$(prefixo_assunto escalar)"
IDIOMA="es-CO"; igual "critico em es"   "[CRÍTICO]"  "$(prefixo_assunto escalar)"
IDIOMA="en-US"; igual "resolvido em en" "[RESOLVED]" "$(prefixo_assunto resolver)"
IDIOMA="es-CO"; igual "continua em es"  "[CONTINÚA]" "$(prefixo_assunto repetir)"

# O titulo leva o nome do servidor, nao o nivel: o nivel ja esta no assunto,
# entre colchetes, e repetir gastava a linha mais visivel do e-mail.
IDIOMA="pt-BR"
TIT="$(t titulo_alerta "CPU Steal" "16.6" "%" "Efamaa Fronts")"
contem     "titulo tem a metrica"  "$TIT" "CPU Steal"
contem     "titulo tem o servidor" "$TIT" "Efamaa Fronts"
nao_contem "titulo nao repete o nivel" "$TIT" "atenção"

# EN usa ano-mes-dia; PT e ES usam dia/mes/ano.
IDIOMA="en-US"; casa "data em en comeca pelo ano" "$(data_local)" '^[0-9]{4}-'
IDIOMA="pt-BR"; casa "data em pt comeca pelo dia" "$(data_local)" '^[0-9]{2}/'
IDIOMA="es-CO"; casa "data em es comeca pelo dia" "$(data_local)" '^[0-9]{2}/'

IDIOMA="pt-BR"; igual "duracao em pt" "7min" "$(duracao_humana 437)"
IDIOMA="en-US"; igual "duracao em en" "7min" "$(duracao_humana 437)"
IDIOMA="es-CO"; igual "duracao em es" "7min" "$(duracao_humana 437)"
IDIOMA="pt-BR"; igual "duracao longa em pt" "2h05min" "$(duracao_humana 7532)"

# =========================================================================
grupo "Diagnostico traduzido, com o numero certo dentro"
# =========================================================================

MEDIDA_STEAL=40; MEDIDA_IOWAIT=1; MEDIDA_LOAD=0.5; STEAL_ATENCAO=25
IDIOMA="pt-BR"; D_PT="$(diagnostico cpu 90)"
IDIOMA="en-US"; D_EN="$(diagnostico cpu 90)"
IDIOMA="es-CO"; D_ES="$(diagnostico cpu 90)"
contem "pt fala em provedor"   "$D_PT" "provedor"
contem "pt usa contencao"      "$D_PT" "Contenção de CPU"
contem "pt mantem steal junto" "$D_PT" "steal"
contem "en fala em provider"  "$D_EN" "provider"
contem "es fala em proveedor" "$D_ES" "proveedor"
contem "o valor entra no texto pt" "$D_PT" "40"
contem "o valor entra no texto en" "$D_EN" "40"
contem "o valor entra no texto es" "$D_ES" "40"

# O catalogo escreve %% para o printf devolver um % so. Errar isso deixaria
# "40%%" no corpo do e-mail, ou comeria o numero seguinte.
contem     "percentual sai com um sinal so" "$D_PT" "em 40% (steal)"
nao_contem "sem percentual duplicado"       "$D_PT" "%%"

MEDIDA_SWAP_TOTAL_KB=0; MEDIDA_MEM_DISP_KB=204800
IDIOMA="pt-BR"; contem "OOM kill avisado em pt" "$(diagnostico memoria 95)" "OOM kill"
IDIOMA="en-US"; contem "OOM kill avisado em en" "$(diagnostico memoria 95)" "OOM kill"
IDIOMA="es-CO"; contem "OOM kill avisado em es" "$(diagnostico memoria 95)" "OOM kill"

MEDIDA_STEAL=1; MEDIDA_IOWAIT=40
IDIOMA="pt-BR"; contem "iowait aponta disco em pt" "$(diagnostico cpu 90)" "disco"
IDIOMA="en-US"; contem "iowait aponta disco em en" "$(diagnostico cpu 90)" "disk"

# =========================================================================
grupo "Templates de e-mail reescritos em disco"
# =========================================================================

export TEMPLATES_DIR="${SANDBOX}/templates"

IDIOMA="pt-BR"
sincroniza_templates
verdade "template criado"          test -f "${TEMPLATES_DIR}/alert.html"
igual   "cinco templates"          "5" "$(ls "${TEMPLATES_DIR}"/*.html 2>/dev/null | wc -l)"
verdade "rotulo de data em pt"     grep -q "<strong>Data:</strong>"  "${TEMPLATES_DIR}/alert.html"
verdade "rodape em pt"             grep -q "Alerta automático"       "${TEMPLATES_DIR}/alert.html"
verdade "lang do html em pt"       grep -q 'lang="pt-BR"'            "${TEMPLATES_DIR}/alert.html"
igual   "marca de idioma gravada"  "pt-BR" "$(cat "${TEMPLATES_DIR}/.idioma" 2>/dev/null)"

# As quatro variaveis precisam continuar literais: quem substitui e o envsubst
# dentro do send_html_alert.sh, na hora do envio. Expandi-las aqui mandaria um
# e-mail com o corpo vazio.
verdade 'TITLE literal'   grep -q '${TITLE}'   "${TEMPLATES_DIR}/alert.html"
verdade 'MESSAGE literal' grep -q '${MESSAGE}' "${TEMPLATES_DIR}/alert.html"
verdade 'DATE literal'    grep -q '${DATE}'    "${TEMPLATES_DIR}/alert.html"
verdade 'HOST literal'    grep -q '${HOST}'    "${TEMPLATES_DIR}/alert.html"

# O template do instalador trazia um subtitulo fixo ("Uso elevado detectado")
# que nao dizia nada num alerta de steal, e um rodape "© Monitoramento - CPU".
nao_contem "sem subtitulo fixo" "$(cat "${TEMPLATES_DIR}/cpu-alert.html")" "Uso elevado detectado"
nao_contem "sem rodape vazio"   "$(cat "${TEMPLATES_DIR}/cpu-alert.html")" "© Monitoramento"

IDIOMA="en-US"
sincroniza_templates
verdade    "rotulo trocou para en" grep -q "<strong>Date:</strong>" "${TEMPLATES_DIR}/alert.html"
verdade    "rodape em en"          grep -q "Automated alert"        "${TEMPLATES_DIR}/alert.html"
verdade    "lang do html em en"    grep -q 'lang="en-US"'           "${TEMPLATES_DIR}/alert.html"
nao_contem "nao sobrou rotulo pt"  "$(cat "${TEMPLATES_DIR}/alert.html")" "<strong>Data:</strong>"

IDIOMA="es-CO"
sincroniza_templates
verdade "rotulo em es" grep -q "<strong>Fecha:</strong>" "${TEMPLATES_DIR}/alert.html"
verdade "rodape em es" grep -q "Alerta automática"       "${TEMPLATES_DIR}/alert.html"

# Reescrever cinco arquivos por minuto em toda a frota seria desperdicio puro.
ANTES="$(stat -c %Y "${TEMPLATES_DIR}/alert.html" 2>/dev/null || echo 0)"
sincroniza_templates
igual "idioma igual nao reescreve" "$ANTES" "$(stat -c %Y "${TEMPLATES_DIR}/alert.html" 2>/dev/null || echo 0)"

unset TEMPLATES_DIR

# =========================================================================
grupo "Steal so alerta quando a CPU tambem esta alta"
# =========================================================================
#
# Caso real de 09/10/2026 num t3a.xlarge: steal de 16,6% com a CPU em 29,5% e
# load de 0,41 por nucleo. O servidor estava tranquilo e mesmo assim saiu
# e-mail, porque o limiar de steal era 10 e nao olhava mais nada. Em instancia
# burstable, steal aparece sempre que a maquina usa burst acima do baseline.

CPU_ATENCAO=85; STEAL_ATENCAO=25; STEAL_CRITICO=40
mentira "steal de 16,6 com CPU em 29,5 nao passa do limiar novo" maior "16.6" "$STEAL_ATENCAO"
mentira "e a CPU de 29,5 nao passa do limiar de atencao"         maior "29.5" "$CPU_ATENCAO"
verdade "steal de 45 com CPU em 92 passa nos dois"               maior "45" "$STEAL_ATENCAO"
verdade "e a CPU de 92 passa do limiar de atencao"               maior "92" "$CPU_ATENCAO"

# =========================================================================
grupo "Auxiliares de envio no manifesto"
# =========================================================================
#
# Eles vivem em /usr/local/bin, que e onde o atualizador instala. Sem estarem
# no manifesto, a frota ficava presa na versao que o instalador gravou, com a
# data em UTC e o cabecalho em portugues cravados para sempre.

verdade "send_html_alert no manifesto"     grep -q '^ARQUIVO=send_html_alert.sh'     "${RAIZ}/agent.manifest"
verdade "send_telegram_alert no manifesto" grep -q '^ARQUIVO=send_telegram_alert.sh' "${RAIZ}/agent.manifest"
verdade "send_html_alert publicado"        test -f "${RAIZ}/send_html_alert.sh"
verdade "send_telegram_alert publicado"    test -f "${RAIZ}/send_telegram_alert.sh"
verdade "send_html_alert passa em bash -n"     bash -n "${RAIZ}/send_html_alert.sh"
verdade "send_telegram_alert passa em bash -n" bash -n "${RAIZ}/send_telegram_alert.sh"

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

# =========================================================================

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32m%s verificacoes de idioma, todas verdes.\033[0m\n' "$TOTAL"; exit 0
fi
printf '\033[31m%s verificacoes de idioma, %s falha(s).\033[0m\n' "$TOTAL" "$FALHAS"
exit 1
