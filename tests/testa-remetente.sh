#!/usr/bin/env bash
#
# Bateria do remetente de e-mail.
#
#   ./tests/testa-remetente.sh
#
# O ponto delicado nao e gravar a variavel: e o Postfix reescrever o endereco
# de origem na saida, pelo mapa /etc/postfix/generic, DEPOIS que o
# send_html_alert.sh montou o cabecalho From:. Mudar so o email.conf faria o
# painel mostrar o remetente novo e o e-mail chegar com o antigo.
#
# Os testes usam um "generic" de mentira e um "postmap" de mentira no PATH,
# entao nada toca no Postfix da maquina.
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
igual()   { [[ "$2" == "$3" ]] && ok "$1" || falha "$1" "$2" "$3"; }
contem()  { case "$2" in *"$3"*) ok "$1" ;; *) falha "$1" "conter \"$3\"" "$2" ;; esac; }
verdade() { local d="$1"; shift; if "$@"; then ok "$d"; else falha "$d"; fi; }
mentira() { local d="$1"; shift; if "$@"; then falha "$d"; else ok "$d"; fi; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export AGENTE_RAIZ="${SANDBOX}/opt" AGENTE_ESTADO="${SANDBOX}/state"
export AGENTE_LOG="${SANDBOX}/log" AGENTE_BIN="${SANDBOX}/bin"
export POSTFIX_GENERIC="${SANDBOX}/generic"
export AGENTE_SO_CARREGAR=1
mkdir -p "$AGENTE_RAIZ" "$AGENTE_ESTADO" "$AGENTE_BIN" "${SANDBOX}/falso"

# postmap e postfix de mentira. POSTMAP_FALHA=1 encena a recusa.
cat >"${SANDBOX}/falso/postmap" <<'FALSO'
#!/usr/bin/env bash
[[ "${POSTMAP_FALHA:-0}" == "1" ]] && exit 1
printf '%s\n' "$1" >> "${POSTMAP_LOG:-/dev/null}"
exit 0
FALSO
printf '#!/usr/bin/env bash\nexit 0\n' >"${SANDBOX}/falso/postfix"
chmod +x "${SANDBOX}/falso/postmap" "${SANDBOX}/falso/postfix"
export PATH="${SANDBOX}/falso:${PATH}"
export POSTMAP_LOG="${SANDBOX}/postmap.log"

[[ -f "${RAIZ}/monitoring-agent.sh" ]] || { echo "rode ./scripts/build.sh primeiro" >&2; exit 1; }
# shellcheck disable=SC1091
source "${RAIZ}/monitoring-agent.sh"
carrega_config

# Estado inicial: o que o instalador deixa num servidor novo.
prepara() {
  printf 'SENDER_EMAIL="alertas@antigo.com.br"\nSERVER_ID="servidor-teste"\n' >"${AGENTE_RAIZ}/email.conf"
  printf 'root@antigo.com.br    alertas@antigo.com.br\n@antigo.com.br    alertas@antigo.com.br\n' >"$POSTFIX_GENERIC"
  : >"$POSTMAP_LOG"
  unset POSTMAP_FALHA
}

# =========================================================================
grupo "O endereco precisa ter cara de e-mail"
# =========================================================================

verdade "endereco comum"            email_valido "alertas@empresa.com.br"
verdade "com ponto e sinal de mais" email_valido "nome.sobrenome+alerta@sub.empresa.com"
mentira "sem arroba"                email_valido "alertas.empresa.com.br"
mentira "sem dominio"               email_valido "alertas@"
mentira "sem extensao"              email_valido "alertas@empresa"
mentira "vazio"                     email_valido ""
mentira "com espaco"                email_valido "alertas @empresa.com.br"

# =========================================================================
grupo "Troca que da certo"
# =========================================================================

prepara
verdade "a troca e aceita" aplica_remetente "avisos@novo.com.br" "Monitoramento"

igual   "email.conf tem o endereco novo" "avisos@novo.com.br" "$(le_do_email_conf SENDER_EMAIL)"
igual   "e o nome de exibicao"           "Monitoramento"      "$(le_do_email_conf SENDER_NAME)"
igual   "SERVER_ID nao foi mexido"       "servidor-teste"     "$(le_do_email_conf SERVER_ID)"

# Sem isto o Postfix reescreveria o endereco de volta na saida, e o e-mail
# chegaria com o remetente antigo mesmo com o arquivo certo.
contem  "o mapa do Postfix aponta para o novo" "$(cat "$POSTFIX_GENERIC")" "avisos@novo.com.br"
mentira "e nao sobrou linha com o antigo" grep -q "alertas@antigo.com.br" "$POSTFIX_GENERIC"
contem  "o postmap foi executado no mapa"  "$(cat "$POSTMAP_LOG")" "generic"

igual "o mapa tem duas linhas, root@ e @" "2" "$(grep -c 'avisos@novo.com.br' "$POSTFIX_GENERIC")"

# =========================================================================
grupo "Linha de terceiro no mapa e preservada"
# =========================================================================
#
# Apagar o arquivo inteiro levaria junto regra que alguem somou a mao.

prepara
printf 'outro@dominio.com    mantem@isto.com\n' >>"$POSTFIX_GENERIC"
aplica_remetente "avisos@novo.com.br" >/dev/null
contem "regra de outro dominio continua la" "$(cat "$POSTFIX_GENERIC")" "mantem@isto.com"

# =========================================================================
grupo "Quando o Postfix recusa, volta atras"
# =========================================================================
#
# Deixar o email.conf com o novo e o mapa com o antigo faria o cabecalho From:
# discordar do envelope, que e pior do que nao ter trocado.

prepara
export POSTMAP_FALHA=1
mentira "a troca e recusada"                 aplica_remetente "avisos@novo.com.br" "Novo"
igual   "e o email.conf volta para o antigo" "alertas@antigo.com.br" "$(le_do_email_conf SENDER_EMAIL)"
unset POSTMAP_FALHA

# =========================================================================
grupo "O que nao deve mudar nada"
# =========================================================================

prepara
mentira "endereco invalido e recusado"     aplica_remetente "nao-e-email"
igual   "e o atual continua"               "alertas@antigo.com.br" "$(le_do_email_conf SENDER_EMAIL)"

mentira "vazio nao mexe em nada"           aplica_remetente ""
igual   "e o atual continua"               "alertas@antigo.com.br" "$(le_do_email_conf SENDER_EMAIL)"

prepara
mentira "o mesmo endereco nao reescreve"   aplica_remetente "alertas@antigo.com.br"
igual   "e o postmap nem foi chamado"      "" "$(cat "$POSTMAP_LOG")"

# =========================================================================
grupo "Dominio usado no mapa"
# =========================================================================

prepara
igual "sai do remetente atual" "antigo.com.br" "$(dominio_do_postfix)"

printf 'SENDER_EMAIL=""\n' >"${AGENTE_RAIZ}/email.conf"
verdade "sem remetente anterior, cai no hostname" test -n "$(dominio_do_postfix)"

# =========================================================================
grupo "Leitura do email.conf sem dar source"
# =========================================================================
#
# O arquivo pode ter sido editado a mao. Um source traria junto qualquer
# coisa que estivesse la, inclusive comando.

printf 'SENDER_EMAIL="x@y.com"\nMALICIOSO=$(touch %s/invadiu)\n' "$SANDBOX" >"${AGENTE_RAIZ}/email.conf"
igual   "le o valor certo"            "x@y.com" "$(le_do_email_conf SENDER_EMAIL)"
mentira "e nao executa o que tem la"  test -f "${SANDBOX}/invadiu"

# =========================================================================

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32m%s verificacoes de remetente, todas verdes.\033[0m\n' "$TOTAL"; exit 0
fi
printf '\033[31m%s verificacoes de remetente, %s falha(s).\033[0m\n' "$TOTAL" "$FALHAS"
exit 1
