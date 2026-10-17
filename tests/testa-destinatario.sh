#!/usr/bin/env bash
#
# Bateria do destinatario e do remetente de e-mail.
#
#   ./tests/testa-destinatario.sh
#
# Por que esta bateria existe, com data e sintoma:
#
# Em 17/10/2026 dois servidores reinstalados passaram a mandar alerta pelo
# Telegram e nenhum por e-mail. Nada no painel, nada no registro, nenhum erro.
# Eram tres defeitos no mesmo caminho, e todos calados:
#
#   1. A reinstalacao reescrevia o email.conf do zero e levava embora a linha
#      RECIPIENTS. Quem recebia alerta parava de receber.
#   2. Com a conta de e-mail vinda do painel, a instalacao nem perguntava o
#      destinatario: so o pegava se o painel tivesse um cadastrado.
#   3. Sem destinatario, o agente nao chamava o enviador e nao registrava
#      nada. O canal ficava ligado na tela e mudo na pratica.
#
# E um quarto, no mesmo arquivo: a parte de troca do sed que le o remetente
# estava vazia (`.*//p` em vez de `.*/\1/p`), entao o remetente escolhido na
# tela do servidor nunca saia do painel.
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
igual()  { [[ "$2" == "$3" ]] && ok "$1" || falha "$1" "$2" "$3"; }
contem() { [[ "$3" == *"$2"* ]] && ok "$1" || falha "$1" "contendo: $2" "$3"; }
nao_contem() { [[ "$3" != *"$2"* ]] && ok "$1" || falha "$1" "sem: $2" "$3"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

INSTALADOR="${RAIZ}/install-monitoring.sh"

# =========================================================================
grupo "Nenhum byte de controle no codigo que vai para a frota"
# =========================================================================
#
# O `\1` do sed que le o remetente chegou a virar um byte 0x01 literal no
# arquivo, gravado por um script de edicao. O shell nao reclama, o sed nao
# reclama, e a substituicao passa a devolver um caractere de controle onde
# deveria vir o endereco. Nada disso aparece lendo o codigo na tela.
#
# ESC (0x1b) fica de fora da varredura porque e o que desenha cor no terminal,
# e as baterias usam.
CONTROLE="$(grep -rlP '[\x00-\x08\x0b\x0c\x0e-\x1a\x1c-\x1f]' src/ ./*.sh 2>/dev/null | tr '\n' ' ')"
igual "fontes e artefatos livres de byte de controle" "" "${CONTROLE% }"

# =========================================================================
grupo "O remetente escolhido no painel chega ao servidor"
# =========================================================================

export AGENTE_RAIZ="${SANDBOX}/opt" AGENTE_ESTADO="${SANDBOX}/state"
export AGENTE_LOG="${SANDBOX}/agente.log" AGENTE_BIN="${SANDBOX}/bin"
export AGENTE_SO_CARREGAR=1
mkdir -p "$AGENTE_RAIZ" "$AGENTE_ESTADO" "$AGENTE_BIN" "${SANDBOX}/falso"

[[ -f "${RAIZ}/monitoring-agent.sh" ]] || { echo "rode ./scripts/build.sh primeiro" >&2; exit 1; }
# shellcheck disable=SC1091
source "${RAIZ}/monitoring-agent.sh"
carrega_config

# O Postfix do sandbox: um mapa de verdade e um postmap que so diz que deu
# certo. Sem isso aplica_remetente desfaz a troca, e com razao.
export POSTFIX_GENERIC="${SANDBOX}/generic"
printf '@exemplo.com    antigo@exemplo.com\n' >"$POSTFIX_GENERIC"
cat >"${SANDBOX}/falso/postmap" <<'FALSO'
#!/usr/bin/env bash
exit 0
FALSO
cat >"${SANDBOX}/falso/curl" <<'FALSO'
#!/usr/bin/env bash
cat "$RESPOSTA_DO_PAINEL"
exit 0
FALSO
cat >"${SANDBOX}/falso/hostname" <<'FALSO'
#!/usr/bin/env bash
printf 'exemplo.com\n'
FALSO
chmod +x "${SANDBOX}/falso/postmap" "${SANDBOX}/falso/curl" "${SANDBOX}/falso/hostname"

printf 'SENDER_EMAIL="antigo@exemplo.com"\nSERVER_ID="teste"\nRECIPIENTS="quem@exemplo.com"\n' \
  >"${AGENTE_RAIZ}/email.conf"

cat >"${SANDBOX}/resposta.json" <<'JSON'
{"has_updates":true,"server_name":"servidor de teste",
"sender_email":"alertas@exemplo.com","sender_name":"Monitoramento",
"cpu_warning":80,"recipients":{"emails":["quem@exemplo.com"]}}
JSON

export DASHBOARD_ENABLED=1 DASHBOARD_SERVER_UUID="uuid-de-teste"
export DASHBOARD_API_URL="http://painel-de-mentira"
export RESPOSTA_DO_PAINEL="${SANDBOX}/resposta.json"
PATH="${SANDBOX}/falso:${PATH}" sincroniza_config >/dev/null 2>&1

do_email_conf() {
  grep -m1 "^${1}=" "${AGENTE_RAIZ}/email.conf" 2>/dev/null | sed 's/^[^=]*=//; s/^"//; s/"$//'
}

igual "o remetente do painel foi gravado"  "alertas@exemplo.com" "$(do_email_conf SENDER_EMAIL)"
igual "o nome do remetente tambem"         "Monitoramento"       "$(do_email_conf SENDER_NAME)"
contem "o mapa do Postfix aponta para ele" "alertas@exemplo.com" "$(cat "$POSTFIX_GENERIC")"
igual "o destinatario que ja estava ficou" "quem@exemplo.com"    "$(do_email_conf RECIPIENTS)"

# Campo ausente nao apaga: servidor ja instalado tem um remetente que
# funciona, e uma tela aberta so para olhar nao pode deixa-lo sem enviar.
printf '{"has_updates":true,"cpu_warning":81}\n' >"${SANDBOX}/resposta.json"
PATH="${SANDBOX}/falso:${PATH}" sincroniza_config >/dev/null 2>&1
igual "sem remetente na resposta, o atual fica" "alertas@exemplo.com" "$(do_email_conf SENDER_EMAIL)"

# =========================================================================
grupo "Alerta sem destinatario vira registro, nao silencio"
# =========================================================================

cat >"${AGENTE_BIN}/send_html_alert.sh" <<FALSO
#!/usr/bin/env bash
printf '%s\n' "\$2" >"${SANDBOX}/enviou-para.txt"
exit 0
FALSO
chmod +x "${AGENTE_BIN}/send_html_alert.sh"

export DASHBOARD_ENABLED=0
: >"$AGENTE_LOG"
rm -f "${SANDBOX}/enviou-para.txt"
RECIPIENTS="" CANAL_EMAIL=1 CANAL_TELEGRAM=0 \
  envia_alerta cpu cpu 97 90 abrir 300 97 "" "" critico >/dev/null 2>&1

[[ -f "${SANDBOX}/enviou-para.txt" ]] \
  && falha "sem destinatario o enviador nao e chamado" "nenhuma chamada" "chamou" \
  || ok "sem destinatario o enviador nao e chamado"
contem "e a falta de destinatario fica no registro" "nenhum destinatario" "$(cat "$AGENTE_LOG")"

: >"$AGENTE_LOG"
rm -f "${SANDBOX}/enviou-para.txt"
RECIPIENTS="quem@exemplo.com" CANAL_EMAIL=1 CANAL_TELEGRAM=0 \
  envia_alerta cpu cpu 97 90 abrir 300 97 "" "" critico >/dev/null 2>&1
igual "com destinatario o enviador recebe a lista" "quem@exemplo.com" \
  "$(cat "${SANDBOX}/enviou-para.txt" 2>/dev/null)"
nao_contem "e nao sobra aviso de falta" "nenhum destinatario" "$(cat "$AGENTE_LOG")"

# =========================================================================
grupo "O instalador nao perde o destinatario que ja esta na maquina"
# =========================================================================
#
# A funcao e extraida do instalador e executada de verdade. A leitura do
# teclado sai de /dev/tty no instalador e e trocada por /dev/null aqui: o que
# esta sob teste e a ORDEM da procura e a recusa de concluir sem destinatario,
# nao a leitura em si.
cat >"${SANDBOX}/funcao.sh" <<'CAB'
log_info() { printf 'info: %s\n' "$1"; }
log_ok()   { printf 'ok: %s\n' "$1"; }
log_warn() { printf 'warn: %s\n' "$1"; }
log_err()  { printf 'err: %s\n' "$1"; }
CAB
sed -n '/^garante_destinatarios()/,/^}/p' "$INSTALADOR" \
  | sed 's|</dev/tty|</dev/null|' >>"${SANDBOX}/funcao.sh"
printf '\ngarante_destinatarios\nprintf "FINAL=%%s\\n" "$RECIPIENTS"\n' >>"${SANDBOX}/funcao.sh"

roda_funcao() {
  RECIPIENTS="$1" RECIPIENTS_NO_SERVIDOR="$2" bash "${SANDBOX}/funcao.sh" 2>&1
}

saida="$(roda_funcao "do-painel@exemplo.com" "")"
contem "o que vem do painel vale"       "FINAL=do-painel@exemplo.com" "$saida"

saida="$(roda_funcao "" "da-maquina@exemplo.com")"
contem "sem painel, o da maquina fica"  "FINAL=da-maquina@exemplo.com" "$saida"
contem "e o aproveitamento e dito"      "preservados desta maquina"    "$saida"

saida="$(roda_funcao "" "" || true)"
nao_contem "sem nenhum dos dois, nao conclui calado" "FINAL=" "$saida"
contem "e diz o que falta"              "obrigatorio"               "$saida"

# =========================================================================
grupo "O email.conf nasce com a linha do destinatario"
# =========================================================================

linha_printf="$(grep -n 'printf .SENDER_EMAIL=' "$INSTALADOR" | head -1 | cut -d: -f1)"
linha_leitura="$(grep -n 'RECIPIENTS_NO_SERVIDOR="\$(grep' "$INSTALADOR" | head -1 | cut -d: -f1)"

if [[ -n "$linha_printf" && -n "$linha_leitura" && "$linha_leitura" -lt "$linha_printf" ]]; then
  ok "o que esta na maquina e lido antes da primeira escrita"
else
  falha "o que esta na maquina e lido antes da primeira escrita" \
    "leitura antes da linha ${linha_printf:-?}" "leitura na linha ${linha_leitura:-nenhuma}"
fi

contem "o printf do email.conf grava RECIPIENTS" 'RECIPIENTS="%s"' \
  "$(sed -n "${linha_printf}p" "$INSTALADOR")"

igual "garante_destinatarios e chamada nos dois caminhos de coleta" "2" \
  "$(grep -c '^  garante_destinatarios$' "$INSTALADOR")"

# =========================================================================

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32m%s verificacoes de destinatario, todas verdes.\033[0m\n' "$TOTAL"; exit 0
fi
printf '\033[31m%s verificacoes de destinatario, %s falha(s).\033[0m\n' "$TOTAL" "$FALHAS"
exit 1
