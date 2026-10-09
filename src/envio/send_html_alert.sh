#!/usr/bin/env bash
#
# Envia um alerta em HTML por e-mail.
#
#   send_html_alert.sh TEMPLATE DESTINATARIOS ASSUNTO TITULO CORPO_HTML
#
# Este arquivo entra no manifesto de atualizacao, entao ele chega na frota
# pelo mesmo canal do agente. A assinatura nao muda: runbook, cron do ClamAV e
# script antigo que chamam este caminho continuam funcionando.
set -uo pipefail

[[ -f /opt/monitoring/email.conf ]] && source /opt/monitoring/email.conf 2>/dev/null
[[ -f /opt/monitoring/agent.conf ]] && source /opt/monitoring/agent.conf 2>/dev/null

TEMPLATE_PATH="${1:-/opt/alerts/templates/alert.html}"
RECIPIENTS="${2:-}"
SUBJECT="${3:-Alerta}"
TITLE="${4:-Alerta}"
MESSAGE="${5:-}"

[[ -z "$RECIPIENTS" ]] && exit 0
[[ -f "$TEMPLATE_PATH" ]] || TEMPLATE_PATH="/opt/alerts/templates/alert.html"
[[ -f "$TEMPLATE_PATH" ]] || exit 1

# A data sai no formato de cada idioma e no fuso do servidor, nao em ISO com
# UTC cravado. Quem le o alerta quer comparar com o relogio da parede.
case "$(printf '%s' "${IDIOMA:-es-CO}" | tr '[:upper:]' '[:lower:]')" in
  en*) DATE="$(date '+%Y-%m-%d %H:%M:%S %Z')" ;;
  *)   DATE="$(date '+%d/%m/%Y %H:%M:%S %Z')" ;;
esac

HOST="${SERVER_ID:-$(hostname)}"

RENDERED_FILE="$(mktemp /tmp/alerta.XXXXXX.html)" || exit 1
trap 'rm -f "$RENDERED_FILE"' EXIT

export TITLE MESSAGE DATE HOST
envsubst '${TITLE} ${MESSAGE} ${DATE} ${HOST}' <"$TEMPLATE_PATH" >"$RENDERED_FILE" || exit 1

FROM_HEADER="${SENDER_NAME:-Monitoramento de Servidores} <${SENDER_EMAIL:-root@$(hostname)}>"

enviado=0
IFS=',' read -ra LISTA <<<"$RECIPIENTS"
for RECIPIENT in "${LISTA[@]}"; do
  RECIPIENT="$(printf '%s' "$RECIPIENT" | tr -d '[:space:]')"
  [[ -z "$RECIPIENT" ]] && continue
  if command -v mail >/dev/null 2>&1; then
    mail -r "${SENDER_EMAIL:-root@$(hostname)}" \
      -a "From: $FROM_HEADER" \
      -a "Content-Type: text/html; charset=UTF-8" \
      -s "$SUBJECT" "$RECIPIENT" <"$RENDERED_FILE" && enviado=$(( enviado + 1 ))
  elif command -v sendmail >/dev/null 2>&1; then
    {
      printf 'From: %s\n' "$FROM_HEADER"
      printf 'To: %s\n' "$RECIPIENT"
      printf 'Subject: %s\n' "$SUBJECT"
      printf 'MIME-Version: 1.0\nContent-Type: text/html; charset=UTF-8\n\n'
      cat "$RENDERED_FILE"
    } | sendmail -t && enviado=$(( enviado + 1 ))
  fi
done

[[ "$enviado" -gt 0 ]]
