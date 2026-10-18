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

# Os caminhos sao os mesmos de sempre, agora por variavel: e o que permite a
# bateria exercitar o envio direto sem root e sem /opt de verdade.
AGENTE_RAIZ="${AGENTE_RAIZ:-/opt/monitoring}"
AGENTE_LOG="${AGENTE_LOG:-/var/log/monitoring-agent.log}"

[[ -f "${AGENTE_RAIZ}/email.conf" ]] && source "${AGENTE_RAIZ}/email.conf" 2>/dev/null
[[ -f "${AGENTE_RAIZ}/agent.conf" ]] && source "${AGENTE_RAIZ}/agent.conf" 2>/dev/null
# Conta de envio escolhida no painel. Existindo, o envio vai direto ao SMTP e
# nao passa pelo servico de e-mail da maquina. Ver o bloco "envio direto".
[[ -f "${AGENTE_RAIZ}/smtp.conf" ]] && source "${AGENTE_RAIZ}/smtp.conf" 2>/dev/null

# Registro no mesmo arquivo do agente, no mesmo formato. Nao rotaciona aqui:
# quem rotaciona e o agente, que escreve no mesmo lugar a cada minuto.
registra() {
  local nivel="$1"; shift
  local linha
  linha="$(date '+%Y-%m-%d %H:%M:%S') [$nivel] send_html_alert: $*"
  if [[ -w "$(dirname "$AGENTE_LOG")" ]] || [[ -w "$AGENTE_LOG" ]]; then
    printf '%s\n' "$linha" >>"$AGENTE_LOG" 2>/dev/null || true
  fi
  return 0
}

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
# Envio direto pelo SMTP, sem passar pelo servico de e-mail da maquina
# ---------------------------------------------------------------------------
#
# Por que este caminho existe, com nome e sobrenome:
#
# O instalador procura Postfix, Exim, Sendmail e cPanel antes de configurar
# qualquer coisa. Achando um deles, ele NAO instala e NAO configura, para nao
# brigar com o que ja esta rodando. A protecao e correta e tem um custo que
# ninguem via: o servidor fica sem alerta por e-mail, calado, para sempre.
#
# Falando direto com o SMTP, o agente nao instala nada, nao edita main.cf, nao
# toca em sasl_passwd nem em generic, e convive com o Exim de um painel de
# hospedagem ou com o Postfix de outra pessoa sem disputar nada.
#
# A senha NAO entra na linha de comando: qualquer usuario da maquina leria no
# "ps". Ela vai num arquivo de configuracao do curl, criado com permissao 600
# antes de receber conteudo e apagado na saida.
tem_smtp_do_painel() {
  [[ -n "${SMTP_HOST:-}" && -n "${SMTP_USUARIO:-}" && -n "${SMTP_SENHA:-}" ]] \
    && command -v curl >/dev/null 2>&1
}

# O Postfix da maquina foi configurado pelo nosso instalador?
#
# Sendo nosso, o envio SAI POR ELE, mesmo com conta vinda do painel: o agente
# ja aplicou a conta no relay (ver aplica_relay_no_postfix), entao passar por
# fora seria abrir um segundo caminho de envio para a mesma conta, com outra
# fila e outro log, sem ganho nenhum.
#
# O envio direto existe para o caso oposto: servidor com Exim de painel de
# hospedagem, com cPanel ou com Postfix de outra pessoa, onde nao se toca em
# nada. E tambem para a maquina sem MTA nenhum, onde nao ha o que usar.
mta_e_nosso() {
  local main_cf="${POSTFIX_MAIN:-/etc/postfix/main.cf}"
  [[ -f "$main_cf" ]] || return 1
  grep -qF '# --- Sistema de Monitoramento de Servidores ---' "$main_cf" 2>/dev/null
}

usa_smtp_direto() {
  tem_smtp_do_painel || return 1
  mta_e_nosso && return 1
  return 0
}

# So as respostas do servidor, nunca o que o agente mandou.
#
# O curl prefixa com "< " o que vem do servidor e com "> " o que ele envia. A
# linha do AUTH esta entre as que ele envia e carrega usuario e senha em
# base64: ela nao pode chegar ao registro de jeito nenhum. Por isso o filtro e
# por lista de permissao, e nao por remocao do que parece perigoso: filtro que
# tira o que conhece deixa passar o que nao conhece, e aqui o que passa e uma
# credencial.
respostas_do_servidor() {
  local transcricao="$1"
  grep '^< ' "$transcricao" 2>/dev/null \
    | sed 's/^< //' \
    | grep -E '^[0-9]{3}' \
    | tail -3 \
    | LC_ALL=C tr -cd '\40-\176\n' \
    | tr '\n' ' ' \
    | cut -c1-300
}

# Preenchidas por envia_direto para quem chama registrar o que houve.
RESPOSTA_SMTP=""
CODIGO_CURL=0

# envia_direto DESTINATARIO ARQUIVO_MIME
envia_direto() {
  local destinatario="$1" arquivo="$2"
  local esquema="smtp" porta="${SMTP_PORTA:-587}" extra=()

  # Porta 465 fala TLS desde o primeiro byte (smtps). As demais sobem para TLS
  # com STARTTLS, e --ssl-reqd recusa seguir em texto claro se o servidor nao
  # oferecer: mandar credencial em claro seria pior que nao mandar o alerta.
  if [[ "${SMTP_SEGURO:-0}" == "1" || "$porta" == "465" ]]; then
    esquema="smtps"
  else
    extra+=(--ssl-reqd)
  fi

  local cfg
  cfg="$(mktemp /tmp/smtp.XXXXXX.conf)" || return 1
  chmod 600 "$cfg" 2>/dev/null || true
  printf 'user = "%s:%s"\n' "$SMTP_USUARIO" "$SMTP_SENHA" >"$cfg"

  # A conversa com o servidor vai para um arquivo nosso, com permissao 600
  # antes de receber qualquer byte: ela contem a linha do AUTH.
  local transcricao
  transcricao="$(mktemp /tmp/smtp.XXXXXX.log)" || { rm -f "$cfg"; return 1; }
  chmod 600 "$transcricao" 2>/dev/null || true

  # --crlf nao e detalhe: o RFC 5322 exige CRLF, e o arquivo que montamos aqui
  # tem LF solto, como todo arquivo de texto no Linux. Sem a conversao, a
  # mensagem sai com LF e o servidor de e-mail responde 250 do mesmo jeito: o
  # envio "da certo" e a mensagem some depois, sem erro em lugar nenhum.
  #
  # Foi isso que aconteceu em 17 e 18/10/2026. O instalador dizia "E-mail de
  # boas-vindas enviado", o curl voltava com 0, e nada chegava na caixa de
  # entrada. Medido contra um servidor SMTP de mentira que grava os bytes
  # crus: sem --crlf chegavam 9 fins de linha LF e 2 CRLF, inclusive na linha
  # em branco que separa cabecalho de corpo; com --crlf, 10 CRLF e nenhum LF.
  #
  # O arquivo precisa chegar aqui com LF puro, senao a conversao dobraria o
  # CR. Por isso monta_mime limpa o CR do conteudo antes de gravar.
  curl --silent --show-error --verbose --crlf --config "$cfg" \
    --url "${esquema}://${SMTP_HOST}:${porta}" \
    --mail-from "$REMETENTE" \
    --mail-rcpt "$destinatario" \
    --upload-file "$arquivo" \
    --connect-timeout 15 --max-time 60 \
    "${extra[@]}" 2>"$transcricao"
  local codigo=$?
  rm -f "$cfg"

  RESPOSTA_SMTP="$(respostas_do_servidor "$transcricao")"
  CODIGO_CURL="$codigo"
  rm -f "$transcricao"
  return "$codigo"
}

# Monta a mensagem inteira, com cabecalhos, do jeito que o SMTP espera receber.
# O `mail` fazia isso por nos no caminho antigo.
monta_mime() {
  local destinatario="$1" saida="$2"
  {
    printf 'From: %s\n' "$FROM_HEADER"
    printf 'To: %s\n' "$destinatario"
    printf 'Subject: %s\n' "$ASSUNTO"
    printf 'Date: %s\n' "$(date -R 2>/dev/null || date)"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/html; charset=UTF-8\n'
    printf 'Content-Transfer-Encoding: 8bit\n'
    printf '\n'
    # Conteudo com LF puro. O CR aqui dentro viraria CRCRLF na conversao do
    # curl, que e a outra forma de entregar uma mensagem malformada.
    tr -d '\r' <"$RENDERED_FILE"
  } >"$saida"
}

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

  if usa_smtp_direto; then
    MIME_FILE="$(mktemp /tmp/alerta.XXXXXX.eml)" || exit 1
    monta_mime "$RECIPIENT" "$MIME_FILE"
    if envia_direto "$RECIPIENT" "$MIME_FILE"; then
      enviado=$(( enviado + 1 ))
      # O que o servidor respondeu fica registrado mesmo no sucesso, e e a
      # parte que faltava: aceitar nao e entregar. Na instalacao de
      # 17/10/2026 o envio deu certo, o alerta nao chegou, e nao havia no
      # servidor nenhuma linha que dissesse para qual mensagem olhar no
      # painel do provedor. A resposta traz o identificador da fila.
      registra INFO "aceito para ${RECIPIENT} por ${SMTP_HOST}:${SMTP_PORTA:-587}: ${RESPOSTA_SMTP:-sem resposta registrada}"
    else
      recusado=$(( recusado + 1 ))
      registra ERRO "envio direto para ${RECIPIENT} falhou (curl ${CODIGO_CURL}) por ${SMTP_HOST}:${SMTP_PORTA:-587}: ${RESPOSTA_SMTP:-sem resposta do servidor}"
      printf 'send_html_alert: envio direto para %s falhou (SMTP %s:%s): %s\n' \
        "$RECIPIENT" "$SMTP_HOST" "${SMTP_PORTA:-587}" "${RESPOSTA_SMTP:-sem resposta}" >&2
    fi
    rm -f "$MIME_FILE"
  elif command -v mail >/dev/null 2>&1; then
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
