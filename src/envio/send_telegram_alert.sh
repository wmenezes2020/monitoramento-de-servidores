#!/usr/bin/env bash
#
# Envia uma mensagem para o Telegram.
#
#   send_telegram_alert.sh "Texto da mensagem"
#
# Entra no manifesto de atualizacao: chega na frota pelo canal do agente.
# Config em /opt/monitoring/telegram.conf.
set -uo pipefail

CONF="/opt/monitoring/telegram.conf"
[[ -f "$CONF" ]] || exit 0
# shellcheck disable=SC1090
source "$CONF" 2>/dev/null || true

[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || exit 0
[[ -n "${TELEGRAM_CHAT_ID:-}" ]] || exit 0

MSG="${1:-}"
[[ -n "$MSG" ]] || exit 0

# O Telegram corta mensagem acima de 4096 caracteres e devolve erro. Uma lista
# longa de processos passa disso com facilidade, e o alerta sumia inteiro em
# vez de chegar cortado.
LIMITE=3900
if [[ "${#MSG}" -gt "$LIMITE" ]]; then
  MSG="${MSG:0:$LIMITE}"$'\n\n[...]'
fi

resposta="$(curl -s --max-time 20 -X POST \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  -d "disable_web_page_preview=true" 2>/dev/null)" || exit 1

# Falha do Telegram ia para /dev/null, entao um token trocado ou um chat id
# errado deixava o canal mudo sem deixar rastro em lugar nenhum.
case "$resposta" in
  *'"ok":true'*) exit 0 ;;
  '') printf 'telegram: sem resposta da API\n' >&2; exit 1 ;;
  *) printf 'telegram: %s\n' "$resposta" >&2; exit 1 ;;
esac
