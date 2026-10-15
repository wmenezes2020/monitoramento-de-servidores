#!/usr/bin/env bash
#
# Envia um alerta em HTML por e-mail.
#
#   send_html_alert.sh TEMPLATE DESTINATARIOS ASSUNTO TITULO CORPO_HTML
#
# Este arquivo entra no manifesto de atualizacao, entao chega na frota pelo
# mesmo canal do agente. A assinatura nao muda: runbook, cron do ClamAV e
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

# ---------------------------------------------------------------------------
# Cabecalho de e-mail so aceita ASCII (RFC 5322)
# ---------------------------------------------------------------------------
#
# Assunto com acento precisa vir codificado em MIME (RFC 2047), senao o MTA
# recusa a mensagem ou o cliente mostra os bytes crus.
#
# Isto nao e teoria: em 14/10/2026 o alerta de recuperacao chegava e o de
# abertura nao. A diferenca entre os dois era o acento. Em portugues,
# "[ATENCAO]" e "[CRITICO]" viraram "[ATENÇÃO]" e "[CRÍTICO]" quando o
# catalogo de idiomas entrou, e "[OK]" ficou sem acento: so ele passava.
# Em espanhol, "[ATENCIÓN]", "[CRÍTICO]" e "[CONTINÚA]" tinham o mesmo
# problema. Em ingles nenhum assunto tem acento, e por isso la nada quebrava.
codifica_cabecalho() {
  local texto="$1"
  # ASCII puro segue como esta: e mais legivel no log do servidor de e-mail e
  # dispensa decodificacao do outro lado.
  if ! LC_ALL=C grep -q '[^ -~]' <<<"$texto" 2>/dev/null; then
    printf '%s' "$texto"
    return 0
  fi
  if ! command -v base64 >/dev/null 2>&1; then
    # Sem base64, mandar o acento cru seria arriscar a recusa. Tirar o acento
    # entrega um assunto feio, mas entrega.
    printf '%s' "$texto" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null \
      || printf '%s' "$texto" | LC_ALL=C tr -cd ' -~'
    return 0
  fi
  printf '=?UTF-8?B?%s?=' "$(printf '%s' "$texto" | base64 -w 0 2>/dev/null || printf '%s' "$texto" | base64 | tr -d '\n')"
}

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

REMETENTE="${SENDER_EMAIL:-root@$(hostname)}"
NOME_REMETENTE="${SENDER_NAME:-Monitoramento de Servidores}"
# O nome do remetente tambem vai no cabecalho, e tambem pode ter acento.
FROM_HEADER="$(codifica_cabecalho "$NOME_REMETENTE") <${REMETENTE}>"
ASSUNTO="$(codifica_cabecalho "$SUBJECT")"

# ---------------------------------------------------------------------------
# Um envio por destinatario
# ---------------------------------------------------------------------------
#
# A lista vem do painel separada por virgula. O `mail` espera os enderecos
# como argumentos separados, nao uma string com virgula: passar
# "a@x.com,b@y.com" faz ele tratar tudo como um endereco so, e apenas o
# primeiro recebe. Era o que acontecia com o script que o instalador gravava.
#
# Um envio por endereco, e nao todos de uma vez, porque um endereco invalido
# no meio da lista nao pode impedir os outros de receberem o alerta.
enviado=0
recusado=0
IFS=',' read -ra LISTA <<<"$RECIPIENTS"
for BRUTO in "${LISTA[@]}"; do
  RECIPIENT="$(printf '%s' "$BRUTO" | tr -d '[:space:]')"
  [[ -z "$RECIPIENT" ]] && continue

  if command -v mail >/dev/null 2>&1; then
    if mail -r "$REMETENTE" \
      -a "From: $FROM_HEADER" \
      -a "Content-Type: text/html; charset=UTF-8" \
      -a "MIME-Version: 1.0" \
      -s "$ASSUNTO" "$RECIPIENT" <"$RENDERED_FILE" 2>/dev/null
    then
      enviado=$(( enviado + 1 ))
    else
      recusado=$(( recusado + 1 ))
      printf 'send_html_alert: envio para %s falhou\n' "$RECIPIENT" >&2
    fi
  elif command -v sendmail >/dev/null 2>&1; then
    if {
      printf 'From: %s\n' "$FROM_HEADER"
      printf 'To: %s\n' "$RECIPIENT"
      printf 'Subject: %s\n' "$ASSUNTO"
      printf 'MIME-Version: 1.0\nContent-Type: text/html; charset=UTF-8\n\n'
      cat "$RENDERED_FILE"
    } | sendmail -t 2>/dev/null
    then
      enviado=$(( enviado + 1 ))
    else
      recusado=$(( recusado + 1 ))
      printf 'send_html_alert: envio para %s falhou\n' "$RECIPIENT" >&2
    fi
  else
    printf 'send_html_alert: nem mail nem sendmail no servidor\n' >&2
    exit 1
  fi
done

# Falha parcial precisa aparecer: um destinatario que parou de receber sem
# ninguem notar e o mesmo que nao ter alerta para aquela pessoa.
[[ "$recusado" -gt 0 ]] && printf 'send_html_alert: %s enviado(s), %s recusado(s)\n' "$enviado" "$recusado" >&2
[[ "$enviado" -gt 0 ]]
