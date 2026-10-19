#!/usr/bin/env bash
#
# Bateria dos servicos de notificacao vindos do painel.
#
#   ./tests/testa-servicos.sh
#
# A pergunta que esta bateria responde, feita em 16/10/2026:
#
#   "o script antes de instalar o servico de e-mail valida se ja existe
#    registrado, para nao sobrescrever e usar funcionalidades alternativas
#    para que funcione sem afetar o que ja existe?"
#
# A resposta tinha duas metades. O instalador JA detectava Postfix, Exim,
# Sendmail e cPanel e, achando qualquer um, desistia de configurar o e-mail
# para nao brigar com eles. Protegia o servidor e deixava o monitoramento
# mudo: servidor com painel de hospedagem nunca recebeu alerta por e-mail.
#
# A outra metade e o que esta bateria cobre: com a conta de envio vinda do
# painel, o agente fala DIRETO com o SMTP e nao toca em nada do que ja existe
# na maquina.
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

PULADOS=0
pulado()     { PULADOS=$((PULADOS+1)); printf '  [33mpulado[0m %s
' "$1"; }

# O chmod nao tem efeito em todo sistema de arquivos: no Git Bash sobre NTFS
# ele e aceito e ignorado. Marcar verde ali seria dizer que a permissao foi
# conferida quando nao foi, e marcar falha reprovaria o agente por um limite
# da maquina de teste. Entao o teste descobre e diz qual dos dois e.
chmod_funciona() {
  local alvo="${SANDBOX}/.prova-chmod"
  : >"$alvo" 2>/dev/null || return 1
  chmod 600 "$alvo" 2>/dev/null || return 1
  local modo
  modo="$(stat -c '%a' "$alvo" 2>/dev/null || stat -f '%OLp' "$alvo" 2>/dev/null)"
  rm -f "$alvo"
  [[ "$modo" == "600" ]]
}

permissao_600() {
  if ! chmod_funciona; then
    pulado "$1 (este sistema de arquivos ignora chmod)"
    return 0
  fi
  igual "$1" "600" "$(stat -c '%a' "$2" 2>/dev/null || stat -f '%OLp' "$2" 2>/dev/null)"
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export AGENTE_RAIZ="${SANDBOX}/opt" AGENTE_ESTADO="${SANDBOX}/state"
export AGENTE_LOG="${SANDBOX}/log" AGENTE_BIN="${SANDBOX}/bin"
export AGENTE_SO_CARREGAR=1
mkdir -p "$AGENTE_RAIZ" "$AGENTE_ESTADO" "$AGENTE_BIN" "${SANDBOX}/falso" "${SANDBOX}/templates"

[[ -f "${RAIZ}/monitoring-agent.sh" ]] || { echo "rode ./scripts/build.sh primeiro" >&2; exit 1; }
# shellcheck disable=SC1091
source "${RAIZ}/monitoring-agent.sh"
carrega_config

# =========================================================================
grupo "O que chega do painel vira configuracao no servidor"
# =========================================================================

RESP='{"has_updates":true,"locale":"pt-BR","email_service":{"kind":"gmail","host":"smtp.gmail.com","port":587,"secure":false,"username":"avisos@empresa.com","password":"abcd efgh ijkl mnop","sender_email":"avisos@empresa.com","sender_name":"Monitoramento"},"telegram_service":{"bot_token":"123:ABC","chat_id":"-100999"}}'

aplica_servicos_do_painel "$RESP"

verdade "o arquivo de SMTP foi criado" test -f "${AGENTE_RAIZ}/smtp.conf"
igual "guardou o servidor"  "smtp.gmail.com"        "$(le_do_arquivo SMTP_HOST "${AGENTE_RAIZ}/smtp.conf")"
igual "guardou a porta"     "587"                   "$(le_do_arquivo SMTP_PORTA "${AGENTE_RAIZ}/smtp.conf")"
igual "guardou o usuario"   "avisos@empresa.com"    "$(le_do_arquivo SMTP_USUARIO "${AGENTE_RAIZ}/smtp.conf")"
igual "guardou a senha de app com espacos" "abcd efgh ijkl mnop" \
  "$(le_do_arquivo SMTP_SENHA "${AGENTE_RAIZ}/smtp.conf")"

# Senha legivel por qualquer usuario da maquina e vazamento local.
permissao_600 "o arquivo de SMTP e 600" "${AGENTE_RAIZ}/smtp.conf"

verdade "o arquivo do Telegram foi criado" test -f "${AGENTE_RAIZ}/telegram.conf"
igual "guardou o token" "123:ABC"  "$(le_do_arquivo TELEGRAM_BOT_TOKEN "${AGENTE_RAIZ}/telegram.conf")"
igual "guardou o chat"  "-100999" "$(le_do_arquivo TELEGRAM_CHAT_ID "${AGENTE_RAIZ}/telegram.conf")"
permissao_600 "o arquivo do Telegram tambem e 600" "${AGENTE_RAIZ}/telegram.conf"

# O remetente vai para o email.conf, que e de onde o enviador le: dois lugares
# guardando a mesma coisa dariam duas verdades sobre quem envia.
igual "o remetente foi para o email.conf" "avisos@empresa.com" \
  "$(le_do_email_conf SENDER_EMAIL)"

# =========================================================================
grupo "Sem bloco no painel, nada e apagado"
# =========================================================================
#
# Ausencia quer dizer "nada escolhido", e nao "apague o que existe". Quem
# nunca abriu a tela de servicos nao pode perder o envio que ja funcionava.

aplica_servicos_do_painel '{"has_updates":true,"locale":"pt-BR"}'
igual "o SMTP continua la"      "smtp.gmail.com" "$(le_do_arquivo SMTP_HOST "${AGENTE_RAIZ}/smtp.conf")"
igual "o Telegram continua la"  "123:ABC"        "$(le_do_arquivo TELEGRAM_BOT_TOKEN "${AGENTE_RAIZ}/telegram.conf")"

# =========================================================================
grupo "Dado incompleto nao substitui o que funciona"
# =========================================================================

mentira "sem senha, recusa" aplica_servico_email "smtp.outro.com" 587 0 "user" "" "a@b.com" "N"
igual "e o que estava la ficou" "smtp.gmail.com" "$(le_do_arquivo SMTP_HOST "${AGENTE_RAIZ}/smtp.conf")"

mentira "remetente invalido, recusa" aplica_servico_email "smtp.outro.com" 587 0 "user" "senha" "nao-e-email" "N"
igual "e o que estava la ficou de novo" "smtp.gmail.com" "$(le_do_arquivo SMTP_HOST "${AGENTE_RAIZ}/smtp.conf")"

mentira "Telegram sem chat, recusa" aplica_servico_telegram "999:XYZ" ""
igual "o token antigo ficou" "123:ABC" "$(le_do_arquivo TELEGRAM_BOT_TOKEN "${AGENTE_RAIZ}/telegram.conf")"

# =========================================================================
grupo "Trocar de conta no painel troca no servidor"
# =========================================================================

aplica_servicos_do_painel '{"email_service":{"kind":"smtp","host":"smtp.outroprovedor.com","port":465,"secure":true,"username":"u2","password":"s2","sender_email":"novo@empresa.com","sender_name":"Avisos"}}'
igual "servidor novo"  "smtp.outroprovedor.com" "$(le_do_arquivo SMTP_HOST "${AGENTE_RAIZ}/smtp.conf")"
igual "porta nova"     "465"                    "$(le_do_arquivo SMTP_PORTA "${AGENTE_RAIZ}/smtp.conf")"
igual "conexao direta" "1"                      "$(le_do_arquivo SMTP_SEGURO "${AGENTE_RAIZ}/smtp.conf")"
igual "remetente novo" "novo@empresa.com"       "$(le_do_email_conf SENDER_EMAIL)"

# =========================================================================
grupo "O envio direto nao toca no servico de e-mail da maquina"
# =========================================================================
#
# Esta e a garantia pedida. O teste monta um servidor que JA TEM Postfix com
# configuracao propria e confere, depois do envio, que nada dela mudou.

mkdir -p "${SANDBOX}/etc/postfix"
printf 'relayhost = [smtp.doutro.com]:587\nmyhostname = loja.exemplo\n' >"${SANDBOX}/etc/postfix/main.cf"
printf '[smtp.doutro.com]:587 outro:segredo\n' >"${SANDBOX}/etc/postfix/sasl_passwd"
printf '@loja.exemplo  dono@loja.exemplo\n' >"${SANDBOX}/etc/postfix/generic"
ANTES_MAIN="$(cat "${SANDBOX}/etc/postfix/main.cf")"
ANTES_SASL="$(cat "${SANDBOX}/etc/postfix/sasl_passwd")"
ANTES_GENERIC="$(cat "${SANDBOX}/etc/postfix/generic")"

# curl de mentira: grava o que recebeu e nao sai da maquina. "mail" e
# "sendmail" NAO existem no PATH deste teste, como num servidor cujo MTA e o
# Exim de um painel de hospedagem.
CHAMADAS="${SANDBOX}/curl.log"
cat >"${SANDBOX}/falso/curl" <<'FALSO'
#!/usr/bin/env bash
url=""; de=""; para=""; arquivo=""; cfg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) url="$2"; shift 2 ;;
    --mail-from) de="$2"; shift 2 ;;
    --mail-rcpt) para="$2"; shift 2 ;;
    --upload-file) arquivo="$2"; shift 2 ;;
    --config) cfg="$2"; shift 2 ;;
    *) shift ;;
  esac
done
{
  printf 'URL=%s|DE=%s|PARA=%s\n' "$url" "$de" "$para"
  printf 'CONFIG=%s\n' "$(cat "$cfg" 2>/dev/null | tr -d '\n')"
  printf 'MIME<<\n'; cat "$arquivo" 2>/dev/null; printf '\n>>MIME\n'
} >>"$CURL_LOG"
exit 0
FALSO
chmod +x "${SANDBOX}/falso/curl"

mkdir -p "${SANDBOX}/envio"
printf '<html><body>${TITLE} ${MESSAGE} ${DATE} ${HOST}</body></html>\n' >"${SANDBOX}/templates/alert.html"
printf 'SENDER_EMAIL="avisos@empresa.com"\nSENDER_NAME="Monitoramento"\n' >"${SANDBOX}/envio/email.conf"
printf 'SMTP_HOST="smtp.gmail.com"\nSMTP_PORTA="587"\nSMTP_SEGURO="0"\nSMTP_USUARIO="avisos@empresa.com"\nSMTP_SENHA="abcd efgh"\n' >"${SANDBOX}/envio/smtp.conf"

# O enviador le os arquivos de configuracao de AGENTE_RAIZ, que aqui aponta
# para a caixa de areia. A bateria testa o arquivo que vai para o servidor, e
# nao uma copia com os caminhos reescritos: copia e outro arquivo, e outro
# arquivo e outro comportamento no dia em que os dois divergirem.
ENVIA_REAL="${RAIZ}/send_html_alert.sh"

: >"$CHAMADAS"
PATH="${SANDBOX}/falso:${PATH}" CURL_LOG="$CHAMADAS" \
  AGENTE_RAIZ="${SANDBOX}/envio" bash "$ENVIA_REAL" "${SANDBOX}/templates/alert.html" \
  "um@empresa.com,dois@empresa.com" "[ATENÇÃO] loja: CPU no limite (97%)" "Titulo" "<p>corpo</p>" \
  >/dev/null 2>&1
SAIDA_ENVIO=$?

igual "enviou com sucesso" "0" "$SAIDA_ENVIO"
igual "um envio por destinatario" "2" "$(grep -c '^URL=' "$CHAMADAS")"
contem "falou com o SMTP certo" "$(cat "$CHAMADAS")" "smtp://smtp.gmail.com:587"
contem "primeiro destinatario"  "$(cat "$CHAMADAS")" "PARA=um@empresa.com"
contem "segundo destinatario"   "$(cat "$CHAMADAS")" "PARA=dois@empresa.com"
contem "remetente do painel"    "$(cat "$CHAMADAS")" "DE=avisos@empresa.com"

# A senha vai por arquivo de configuracao, nunca na linha de comando: no "ps"
# ela ficaria visivel para qualquer usuario da maquina.
contem "a senha vai no arquivo de configuracao" "$(cat "$CHAMADAS")" 'user = "avisos@empresa.com:abcd efgh"'

# O assunto acentuado continua indo codificado, como no caminho antigo.
contem "assunto acentuado codificado" "$(cat "$CHAMADAS")" "Subject: =?UTF-8?B?"
contem "o corpo vai como HTML"        "$(cat "$CHAMADAS")" "Content-Type: text/html; charset=UTF-8"
contem "com a data no cabecalho"      "$(cat "$CHAMADAS")" "Date: "

# E agora a pergunta que motivou tudo isto.
igual "main.cf intacto"     "$ANTES_MAIN"    "$(cat "${SANDBOX}/etc/postfix/main.cf")"
igual "sasl_passwd intacto" "$ANTES_SASL"    "$(cat "${SANDBOX}/etc/postfix/sasl_passwd")"
igual "generic intacto"     "$ANTES_GENERIC" "$(cat "${SANDBOX}/etc/postfix/generic")"

# =========================================================================
grupo "Postfix nosso: atualiza e envia pela propria maquina"
# =========================================================================

# O mail de mentira registra que o envio saiu pela propria maquina.
cat >"${SANDBOX}/falso/mail" <<'FALSO'
#!/usr/bin/env bash
cat >/dev/null
printf 'MAIL_USADO\n' >>"$CURL_LOG"
exit 0
FALSO
chmod +x "${SANDBOX}/falso/mail"
#
# A regra, na palavra do dono: so usar o envio direto quando JA EXISTIR um MTA
# instalado que NAO e nosso. Sendo nosso, a conta do painel e aplicada nele e o
# envio continua saindo pela maquina, como sempre saiu.
#
# A marca no main.cf e o que separa um caso do outro: e a linha que o nosso
# instalador escreve quando e ele quem configura o Postfix.
#
# Falta uma condicao, e ela custou dois dias em 19/10/2026: "nosso" nao basta,
# o relay dele precisa ser a conta que o painel mandou. Naquele servidor o
# Postfix era nosso com o relay de um provedor antigo e a conta nova estava no
# smtp.conf. Todo alerta era entregue ao Postfix, relayado para o provedor
# velho e recusado com "550 From header sender domain not verified". O `mail`
# aceita na fila e volta com 0, entao a instalacao dizia "enviado" e a recusa
# ia para a caixa local do root.

MARCA='# --- Sistema de Monitoramento de Servidores ---'
printf '%s
relayhost = [smtp.antigo.com]:587
myhostname = loja.exemplo
' "$MARCA"   >"${SANDBOX}/etc/postfix/main.cf"
printf '[smtp.antigo.com]:587 antigo:senha-antiga
[outro.destino.com]:25 terceiro:outra
'   >"${SANDBOX}/etc/postfix/sasl_passwd"

export POSTFIX_MAIN="${SANDBOX}/etc/postfix/main.cf"
export POSTFIX_SASL="${SANDBOX}/etc/postfix/sasl_passwd"

verdade "reconhece o Postfix que nos configuramos" mta_e_nosso

# postmap e postfix de mentira: o teste nao tem Postfix e nao vai ter.
for prog in postmap postfix; do
  printf '#!/usr/bin/env bash
exit 0
' >"${SANDBOX}/falso/${prog}"
  chmod +x "${SANDBOX}/falso/${prog}"
done

PATH="${SANDBOX}/falso:${PATH}" aplica_relay_no_postfix "smtp.novo.com" "2525" "novo@empresa.com" "senha-nova"
SASL="$(cat "${SANDBOX}/etc/postfix/sasl_passwd")"
MAIN="$(cat "${SANDBOX}/etc/postfix/main.cf")"

contem "a conta nova entrou no mapa"        "$SASL" "[smtp.novo.com]:2525 novo@empresa.com:senha-nova"
nao_contem "e a anterior do mesmo destino saiu" "$SASL" "antigo:senha-antiga"
contem "a linha de terceiro foi preservada" "$SASL" "[outro.destino.com]:25 terceiro:outra"
contem "o relayhost aponta para o novo"     "$MAIN" "relayhost = [smtp.novo.com]:2525"
contem "e a marca do instalador continua la" "$MAIN" "$MARCA"

envia_agora() {
  : >"$CHAMADAS"
  PATH="${SANDBOX}/falso:${PATH}" CURL_LOG="$CHAMADAS" POSTFIX_MAIN="${SANDBOX}/etc/postfix/main.cf" \
    AGENTE_RAIZ="${SANDBOX}/envio" bash "$ENVIA_REAL" "${SANDBOX}/templates/alert.html" \
    "um@empresa.com" "[OK] teste" "T" "<p>c</p>" >/dev/null 2>&1
  cat "$CHAMADAS"
}

conta_do_painel() {
  printf 'SMTP_HOST="%s"\nSMTP_PORTA="%s"\nSMTP_SEGURO="0"\nSMTP_USUARIO="avisos@empresa.com"\nSMTP_SENHA="abcd efgh"\n' \
    "$1" "$2" >"${SANDBOX}/envio/smtp.conf"
}

# 1. Postfix nosso com o relay da conta do painel: sai pela maquina, como o
#    dono quer. O relayhost ficou em [smtp.novo.com]:2525 na troca acima.
conta_do_painel "smtp.novo.com" "2525"
SAIDA="$(envia_agora)"
contem     "relay igual a conta do painel: envia pela maquina" "$SAIDA" "MAIL_USADO"
nao_contem "e nao chama o SMTP por fora"                       "$SAIDA" "URL=smtp"

# 2. O caso de 19/10/2026: Postfix nosso, relay de outro provedor, conta nova
#    no painel. Entregar ao Postfix aqui e entregar ao provedor errado.
conta_do_painel "smtp.gmail.com" "587"
SAIDA="$(envia_agora)"
contem     "relay velho: vai direto pela conta do painel" "$SAIDA" "URL=smtp://smtp.gmail.com:587"
nao_contem "e nao entrega ao Postfix com o relay errado"  "$SAIDA" "MAIL_USADO"

# 3. O main.cf acumula linhas quando o instalador roda mais de uma vez, e o
#    Postfix usa a ULTIMA. Era o que o log do servidor dizia, em "overriding
#    earlier entry: relayhost=". Ler a primeira mandaria pelo caminho errado.
printf '%s
relayhost = [smtp.gmail.com]:587
relayhost = [smtp.outro.com]:587
myhostname = loja.exemplo
' "$MARCA" >"${SANDBOX}/etc/postfix/main.cf"
SAIDA="$(envia_agora)"
contem     "com relayhost repetido, vale o ultimo" "$SAIDA" "URL=smtp://smtp.gmail.com:587"
nao_contem "e o primeiro nao decide"               "$SAIDA" "MAIL_USADO"

printf '%s
relayhost = [smtp.outro.com]:587
relayhost = [smtp.gmail.com]:587
myhostname = loja.exemplo
' "$MARCA" >"${SANDBOX}/etc/postfix/main.cf"
SAIDA="$(envia_agora)"
contem     "o ultimo sendo o do painel, sai pela maquina" "$SAIDA" "MAIL_USADO"
nao_contem "e nao vai por fora"                           "$SAIDA" "URL=smtp"

# Volta ao main.cf da troca de relay para o resto do grupo.
printf '%s
relayhost = [smtp.novo.com]:2525
myhostname = loja.exemplo
' "$MARCA" >"${SANDBOX}/etc/postfix/main.cf"

# Tirando a marca, o mesmo servidor vira "MTA de outra pessoa" e o envio passa
# a ir por fora, sem tocar em nada.
conta_do_painel "smtp.gmail.com" "587"
printf 'relayhost = [smtp.doutro.com]:587
myhostname = loja.exemplo
' >"${SANDBOX}/etc/postfix/main.cf"
mentira "sem a marca, o MTA nao e nosso" mta_e_nosso

: >"$CHAMADAS"
PATH="${SANDBOX}/falso:${PATH}" CURL_LOG="$CHAMADAS" POSTFIX_MAIN="${SANDBOX}/etc/postfix/main.cf"   AGENTE_RAIZ="${SANDBOX}/envio" bash "$ENVIA_REAL" "${SANDBOX}/templates/alert.html" "um@empresa.com" "[OK] teste" "T" "<p>c</p>"   >/dev/null 2>&1

contem     "MTA de terceiro: envia direto" "$(cat "$CHAMADAS")" "URL=smtp://smtp.gmail.com:587"
nao_contem "e nao usa o mail da maquina"   "$(cat "$CHAMADAS")" "MAIL_USADO"

# Maquina sem Postfix nenhum: nao ha o que usar, entao vai direto.
rm -f "${SANDBOX}/etc/postfix/main.cf"
mentira "sem main.cf, o MTA nao e nosso" mta_e_nosso
unset POSTFIX_MAIN POSTFIX_SASL

# =========================================================================
grupo "Sem conta no painel, o caminho antigo continua valendo"
# =========================================================================

: >"$CHAMADAS"
: >"${SANDBOX}/envio/smtp.conf"   # sem conta do painel
PATH="${SANDBOX}/falso:${PATH}" CURL_LOG="$CHAMADAS" \
  AGENTE_RAIZ="${SANDBOX}/envio" bash "$ENVIA_REAL" "${SANDBOX}/templates/alert.html" "um@empresa.com" "[OK] teste" "T" "<p>c</p>" \
  >/dev/null 2>&1

contem     "voltou a usar o mail"      "$(cat "$CHAMADAS")" "MAIL_USADO"
nao_contem "e nao chamou o SMTP direto" "$(cat "$CHAMADAS")" "URL=smtp"

# =========================================================================
grupo "Saude da maquina: o que o painel vai guardar"
# =========================================================================

printf '3.78 3.40 3.20 5/265 18420\n' >"${SANDBOX}/loadavg"
printf '648323.45 5123456.78\n'       >"${SANDBOX}/uptime"
printf '1015\n'                       >"${SANDBOX}/threads"
PROC_LOADAVG="${SANDBOX}/loadavg" PROC_UPTIME="${SANDBOX}/uptime" FIXTURE_THREADS="${SANDBOX}/threads" \
  bash -c 'true'   # so para documentar as fontes injetaveis

PROC_LOADAVG="${SANDBOX}/loadavg" mede_load
igual "fila de 1 minuto por nucleo"  "$(awk -v n="$(nucleos)" 'BEGIN{printf "%.2f", 3.78/n}')" "$MEDIDA_LOAD"
igual "fila de 5 minutos"            "$(awk -v n="$(nucleos)" 'BEGIN{printf "%.2f", 3.40/n}')" "$MEDIDA_LOAD5"
igual "fila de 15 minutos"           "$(awk -v n="$(nucleos)" 'BEGIN{printf "%.2f", 3.20/n}')" "$MEDIDA_LOAD15"
igual "programas trabalhando agora"  "5"   "$MEDIDA_PROCS_RODANDO"
igual "programas abertos"            "265" "$MEDIDA_PROCS_TOTAL"
igual "o load bruto segue inteiro"   "3.78" "$MEDIDA_LOAD_BRUTO"

PROC_UPTIME="${SANDBOX}/uptime" mede_uptime
igual "tempo ligado em segundos" "648323" "$MEDIDA_UPTIME"

FIXTURE_THREADS="${SANDBOX}/threads" mede_threads
igual "linhas de execucao" "1015" "$MEDIDA_THREADS"

# =========================================================================

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  if [[ "$PULADOS" -gt 0 ]]; then
    printf '[32m%s verificacoes de servicos, todas verdes[0m [33m(%s pulada(s) neste sistema de arquivos)[0m
' "$TOTAL" "$PULADOS"
  else
    printf '[32m%s verificacoes de servicos, todas verdes.[0m
' "$TOTAL"
  fi
  exit 0
fi
printf '[31m%s verificacoes de servicos, %s falha(s).[0m
' "$TOTAL" "$FALHAS"
exit 1
