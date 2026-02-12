#!/usr/bin/env bash
#
# Instalador completo: E-mail (SMTP2Go), Telegram, ClamAV, Monitoramento CPU/RAM/Disco
# Repo: https://github.com/wmenezes2020/monitoramento-de-servidores
#
# Uso local:  sudo ./install-monitoring.sh
# Via curl:   curl -fsSL https://raw.githubusercontent.com/wmenezes2020/monitoramento-de-servidores/main/install-monitoring.sh | sudo bash
#
# Pipe (curl|bash): stdin e o proprio script. NAO fazer exec 0</dev/tty — o bash leria
# o resto do script do teclado e travaria. Todas as perguntas usam "read ... </dev/tty".
# Saida do instalador vai para stderr (> &2) para aparecer imediatamente no pipe.
#
printf 'Carregando instalador...\n' >&2
set -uo pipefail
# Sem set -e: erros sao tratados por run_cmd e auto-correcao

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Controle de progresso e erros
TOTAL_STEPS=9
CURRENT_STEP=0
INSTALL_ERRORS=()
INSTALL_WARNINGS=()
POSTFIX_MARKER="# --- Sistema de Monitoramento de Servidores ---"
CRON_MARKER="# --- Monitoramento de CPU, Memoria, Disco e Antivirus ---"

# Mensagens em stderr para aparecer imediatamente com "curl | bash" (stdout fica em buffer no pipe)
log_info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*" >&2; }
log_err()   { echo -e "${RED}[ERRO]${NC} $*" >&2; }
log_step()  {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo "" >&2
  echo -e "${CYAN}[Passo $CURRENT_STEP/$TOTAL_STEPS]${NC} $*" >&2
}

# Executa comando; em falha registra e opcionalmente retorna em vez de sair
run_cmd() {
  local msg="${1:-}"
  shift
  if [[ -n "$msg" ]]; then
    log_info "$msg"
  fi
  if "$@" 2>/dev/null; then
    return 0
  fi
  local ret=$?
  INSTALL_ERRORS+=("Falha ao executar: $* (exit $ret)")
  return $ret
}

run_cmd_soft() {
  if "$@" 2>/dev/null; then
    return 0
  fi
  INSTALL_WARNINGS+=("Comando ignorado (nao critico): $*")
  return 0
}

# apt-get com retry e tratamento de erro
run_apt() {
  local max_tries=2
  local try=1
  while true; do
    if apt-get update -qq 2>/dev/null && apt-get install -y -qq "$@" 2>/dev/null; then
      return 0
    fi
    INSTALL_WARNINGS+=("apt-get falhou (tentativa $try/$max_tries)")
    try=$((try + 1))
    if [[ $try -gt $max_tries ]]; then
      log_err "Instalacao de pacotes falhou. Verifique: sudo apt-get update && sudo apt-get install -y $*"
      return 1
    fi
    sleep 3
  done
}

# Testa conectividade na porta (1 = aberta)
test_port() {
  local host="${1:-mail.smtp2go.com}"
  local port="${2:-587}"
  (echo >/dev/tcp/"$host"/"$port") 2>/dev/null && return 0 || return 1
}

# Detecta servico de e-mail ja instalado (Postfix, Exim, cPanel, Sendmail).
# Retorno: 0 = conflito detectado (nao instalar), 1 = nenhum conflito
detect_mail_conflict() {
  if dpkg -l postfix 2>/dev/null | grep -q '^ii'; then
    echo "Postfix"
    return 0
  fi
  if dpkg -l exim4 2>/dev/null | grep -q '^ii'; then
    echo "Exim4"
    return 0
  fi
  if dpkg -l exim 2>/dev/null | grep -q '^ii'; then
    echo "Exim"
    return 0
  fi
  if dpkg -l sendmail 2>/dev/null | grep -q '^ii'; then
    echo "Sendmail"
    return 0
  fi
  if [[ -d /usr/local/cpanel ]]; then
    echo "cPanel (gerenciador de e-mail)"
    return 0
  fi
  if systemctl is-active exim 2>/dev/null | grep -q 'active'; then
    echo "Exim (servico ativo)"
    return 0
  fi
  if systemctl is-active exim4 2>/dev/null | grep -q 'active'; then
    echo "Exim4 (servico ativo)"
    return 0
  fi
  if [[ -x /usr/sbin/exim ]] && [[ -f /etc/exim/exim.conf || -f /etc/exim4/exim4.conf ]]; then
    echo "Exim (binario e config presentes)"
    return 0
  fi
  return 1
}

# Trap: ao sair com ERRO, mostrar erros (avisos ja foram mostrados no fluxo principal)
cleanup_on_exit() {
  local code=$?
  if [[ $code -ne 0 ]] && [[ ${#INSTALL_ERRORS[@]} -gt 0 ]]; then
    echo "" >&2
    log_err "Instalacao encerrada com erros:"
    printf '  - %s\n' "${INSTALL_ERRORS[@]}" >&2
  fi
  # Avisos so no trap se saiu com erro (em sucesso ja foram listados acima)
  if [[ $code -ne 0 ]] && [[ ${#INSTALL_WARNINGS[@]} -gt 0 ]]; then
    echo "" >&2
    log_warn "Avisos durante a instalacao:"
    printf '  - %s\n' "${INSTALL_WARNINGS[@]}" >&2
  fi
}
trap cleanup_on_exit EXIT

# Verificar execução como root
if [[ $EUID -ne 0 ]]; then
  log_err "Execute este script como root: sudo bash $0"
  exit 1
fi

# Detectar ambiente
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "${ID:-unknown}"
    return 0
  fi
  echo "unknown"
  return 1
}
OS_ID=$(detect_os)
if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
  log_warn "Sistema detectado: $OS_ID. Script testado em Ubuntu/Debian. Continuando mesmo assim."
  INSTALL_WARNINGS+=("OS pode nao ser totalmente compativel: $OS_ID")
fi

# IMPORTANTE: Com "curl | sudo bash", o stdin e o PIPE (conteudo do script).
# Nao redirecionar stdin (exec 0</dev/tty) — senao o bash passa a ler o resto do script
# do teclado e trava. Usar apenas "read ... </dev/tty" em cada pergunta.
if [[ ! -t 0 ]]; then
  if [[ ! -r /dev/tty ]]; then
    log_err "Execute a partir de um terminal interativo (ex.: sessao SSH). /dev/tty indisponivel."
    exit 1
  fi
  printf 'Instalador rodando via pipe. Quando cada pergunta aparecer, digite a resposta e Enter.\n' >&2
fi

# Banner (stderr para aparecer logo com "curl | bash")
echo "" >&2
echo -e "${BLUE}============================================${NC}" >&2
echo -e "${BLUE}  Instalador de Monitoramento e Alertas     ${NC}" >&2
echo -e "${BLUE}  E-mail + Telegram + ClamAV + CPU/RAM/Disco ${NC}" >&2
echo -e "${BLUE}============================================${NC}" >&2
echo "" >&2

# --- Ativacao de notificacoes por e-mail ---
EMAIL_ENABLED=0
printf 'Deseja ativar notificacoes por e-mail? (s/N): ' >&2
read -r r </dev/tty || true
r="${r:-n}"
if [[ "${r,,}" == "s" || "${r,,}" == "sim" ]]; then
  conflict=$(detect_mail_conflict) || true
  if [[ -n "$conflict" ]]; then
    echo "" >&2
    log_warn "Foi detectado um servico de e-mail ja instalado neste servidor:"
    printf '   -> %s\n' "$conflict" >&2
    echo "" >&2
    echo "   Instalar o Postfix junto poderia gerar conflitos e afetar o envio e" >&2
    echo "   recebimento de e-mails. Por seguranca, o servico de notificacoes por" >&2
    echo "   e-mail NAO sera instalado/ativado." >&2
    echo "" >&2
    echo "   A instalacao seguira normalmente para os demais itens (Telegram," >&2
    echo "   ClamAV, monitoramento e Dashboard)." >&2
    echo "" >&2
    printf 'Pressione Enter para continuar...' >&2
    read -r </dev/tty || true
    EMAIL_ENABLED=0
  else
    EMAIL_ENABLED=1
  fi
fi
echo "" >&2

# Coleta de dados (prompts em stderr para aparecer com "curl | bash")
log_info "Informe os dados solicitados (Enter para usar valor padrao quando indicado)."
echo "" >&2

# --- Dados SMTP (somente se e-mail ativado) ---
if [[ $EMAIL_ENABLED -eq 1 ]]; then
printf 'Porta do servidor SMTP (ex: 587 ou 2525) [587]: ' >&2
read -r SMTP_PORT </dev/tty || true
SMTP_PORT="${SMTP_PORT:-587}"

DEFAULT_HOST=$(hostname 2>/dev/null) || DEFAULT_HOST="localhost"
printf 'Dominio ou nome do servidor (ex: meuservidor.com) [%s]: ' "$DEFAULT_HOST" >&2
read -r SMTP_DOMAIN </dev/tty || true
SMTP_DOMAIN="${SMTP_DOMAIN:-$DEFAULT_HOST}"

printf 'Usuario SMTP (e-mail ou usuario SMTP2Go): ' >&2
read -r SMTP_USER </dev/tty || true
[[ -z "$SMTP_USER" ]] && { log_err "Usuario SMTP e obrigatorio."; exit 1; }

printf 'Senha SMTP: ' >&2
read -rs SMTP_PASS </dev/tty || true
echo "" >&2
[[ -z "$SMTP_PASS" ]] && { log_err "Senha SMTP e obrigatoria."; exit 1; }

printf 'E-mail remetente (verificado no SMTP2Go, ex: alertas@seudominio.com): ' >&2
read -r SENDER_EMAIL </dev/tty || true
[[ -z "$SENDER_EMAIL" ]] && { log_err "E-mail remetente e obrigatorio."; exit 1; }

printf 'E-mail(s) de destino para alertas (separados por virgula): ' >&2
read -r RECIPIENTS </dev/tty || true
[[ -z "$RECIPIENTS" ]] && { log_err "Pelo menos um e-mail de destino e obrigatorio."; exit 1; }

# Remove espaços extras dos destinatários
RECIPIENTS=$(echo "$RECIPIENTS" | tr -d ' ')
else
  SMTP_PORT="587"
  SMTP_DOMAIN=""
  SMTP_USER=""
  SMTP_PASS=""
  SENDER_EMAIL=""
  RECIPIENTS=""
fi

echo "" >&2
printf 'Token do Bot do Telegram (vazio = nao usar Telegram): ' >&2
read -r TELEGRAM_BOT_TOKEN </dev/tty || true
TELEGRAM_BOT_TOKEN=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d ' ')
TELEGRAM_CHAT_ID=""
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  echo "" >&2
  log_info "Para receber alertas no Telegram: abra o app Telegram, procure seu bot e envie o comando /start"
  printf 'Pressione Enter apos ter enviado /start ao bot... ' >&2
  read -r _dummy </dev/tty || true
  RESP=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?limit=1" 2>/dev/null || true)
  if echo "$RESP" | grep -q '"chat":'; then
    TELEGRAM_CHAT_ID=$(echo "$RESP" | grep -o '"id":[0-9]*' | tail -1 | cut -d: -f2)
  fi
  if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
    log_warn "Chat ID nao encontrado. Apos a instalacao execute: sudo /usr/local/bin/telegram-get-chat-id.sh"
  else
    log_ok "Chat ID do Telegram obtido: $TELEGRAM_CHAT_ID"
  fi
fi

# --- Dashboard de Observabilidade ---
echo "" >&2
printf 'Deseja conectar este servidor ao Dashboard de Observabilidade? (s/N): ' >&2
read -r USE_DASHBOARD </dev/tty || true
USE_DASHBOARD=$(echo "${USE_DASHBOARD:-n}" | tr '[:upper:]' '[:lower:]')

DASHBOARD_ENABLED=0
DASHBOARD_SERVER_UUID=""
DASHBOARD_API_URL="${DASHBOARD_API_URL:-https://api-observabilidade.edeniva.com.br/v1}"

if [[ "$USE_DASHBOARD" == "s" || "$USE_DASHBOARD" == "sim" || "$USE_DASHBOARD" == "y" || "$USE_DASHBOARD" == "yes" ]]; then
  DASHBOARD_ENABLED=1
  printf 'URL da API do Dashboard (ex: https://api-observabilidade.edeniva.com.br/v1): [%s] ' "$DASHBOARD_API_URL" >&2
  read -r DASHBOARD_API_URL_INPUT </dev/tty || true
  [[ -n "$DASHBOARD_API_URL_INPUT" ]] && DASHBOARD_API_URL=$(echo "$DASHBOARD_API_URL_INPUT" | tr -d ' ')
  printf 'UUID do Servidor (gerado no painel ao cadastrar o servidor): ' >&2
  read -r DASHBOARD_SERVER_UUID </dev/tty || true
  DASHBOARD_SERVER_UUID=$(echo "$DASHBOARD_SERVER_UUID" | tr -d ' ')
  if [[ -z "$DASHBOARD_SERVER_UUID" ]]; then
    log_warn "UUID do Dashboard nao informado. Dashboard desabilitado."
    DASHBOARD_ENABLED=0
  elif [[ ! "$DASHBOARD_SERVER_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    log_warn "UUID invalido. Dashboard desabilitado."
    DASHBOARD_ENABLED=0
  else
    log_ok "Dashboard conectado. UUID: $DASHBOARD_SERVER_UUID"
  fi
fi

echo "" >&2
log_info "Iniciando instalacao (ambiente: $OS_ID)..."
# Pre-verificacao rapida
if ! command -v apt-get &>/dev/null; then
  INSTALL_ERRORS+=("apt-get nao encontrado. Este script e para Debian/Ubuntu.")
fi
AVAIL_KB=$(df -P / 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -n "$AVAIL_KB" ]] && [[ "$AVAIL_KB" -lt 500000 ]]; then
  log_warn "Pouco espaco em disco (/ tem menos de ~500MB livre). A instalacao pode falhar."
  INSTALL_WARNINGS+=("Espaco em disco baixo. Libere espaco se encontrar erros.")
fi
echo "" >&2

# --- 1. Pacotes do sistema ---
PACKS="gettext-base clamav clamav-daemon sysstat bc"
[[ $EMAIL_ENABLED -eq 1 ]] && PACKS="postfix libsasl2-modules mailutils $PACKS"
log_step "Pacotes do sistema ($PACKS)"
export DEBIAN_FRONTEND=noninteractive
if [[ $EMAIL_ENABLED -eq 1 ]]; then
  debconf-set-selections <<< "postfix postfix/mailname string $SMTP_DOMAIN" 2>/dev/null || true
  debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site" 2>/dev/null || true
fi
if run_apt $PACKS; then
  log_ok "Pacotes instalados ou ja presentes."
else
  INSTALL_ERRORS+=("Falha ao instalar pacotes. Execute: sudo apt-get update && sudo apt-get install -y $PACKS")
fi

# --- 2. Configuração Postfix (somente se e-mail ativado) ---
if [[ $EMAIL_ENABLED -eq 1 ]]; then
log_step "Postfix (SMTP2Go)"
SMTP_HOST="mail.smtp2go.com"
# Auto-correcao: se porta 587 falhar, tentar 2525
if ! test_port "$SMTP_HOST" "$SMTP_PORT" 2>/dev/null; then
  if [[ "$SMTP_PORT" == "587" ]] && test_port "$SMTP_HOST" 2525 2>/dev/null; then
    log_warn "Porta 587 inacessivel. Usando 2525."
    SMTP_PORT=2525
    INSTALL_WARNINGS+=("SMTP alterado para porta 2525 (587 bloqueada)")
  fi
fi

# So adicionar bloco ao main.cf se ainda nao existe (evita duplicata)
if ! grep -qF "$POSTFIX_MARKER" /etc/postfix/main.cf 2>/dev/null; then
  {
    echo ""
    echo "$POSTFIX_MARKER"
    echo "relayhost = [${SMTP_HOST}]:${SMTP_PORT}"
    echo "smtp_sasl_auth_enable = yes"
    echo "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    echo "smtp_sasl_security_options = noanonymous"
    echo "smtp_tls_security_level = encrypt"
    echo "smtp_tls_wrappermode = no"
    echo "header_size_limit = 4096000"
    echo "smtp_generic_maps = hash:/etc/postfix/generic"
  } >> /etc/postfix/main.cf
  log_info "Bloco de configuracao adicionado ao main.cf"
else
  log_info "Postfix ja configurado por este instalador (main.cf). Atualizando apenas credenciais."
fi

# Credenciais e masquerade sempre atualizados (para permitir reexecucao com novos dados)
printf '%s\n' "[${SMTP_HOST}]:${SMTP_PORT} ${SMTP_USER}:${SMTP_PASS}" > /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd
if ! postmap /etc/postfix/sasl_passwd 2>/dev/null; then
  INSTALL_ERRORS+=("postmap sasl_passwd falhou. Verifique /etc/postfix/sasl_passwd")
fi
chown root:root /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db 2>/dev/null || true

echo "root@${SMTP_DOMAIN}    ${SENDER_EMAIL}
@${SMTP_DOMAIN}    ${SENDER_EMAIL}" > /etc/postfix/generic
postmap /etc/postfix/generic 2>/dev/null || true

if ! postfix check 2>/dev/null; then
  log_warn "postfix check reportou problema. Fazendo backup e reaplicando configuracao..."
  cp -a /etc/postfix/main.cf /etc/postfix/main.cf.bak.monitoramento.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
  # Remove linhas do nosso bloco (do marcador ate smtp_generic_maps)
  awk -v marker="$POSTFIX_MARKER" '
    $0 ~ marker { skip=1 }
    skip && /smtp_generic_maps/ { skip=0; next }
    skip { next }
    { print }
  ' /etc/postfix/main.cf > /etc/postfix/main.cf.tmp 2>/dev/null && mv /etc/postfix/main.cf.tmp /etc/postfix/main.cf
  if ! grep -qF "$POSTFIX_MARKER" /etc/postfix/main.cf 2>/dev/null; then
    {
      echo ""; echo "$POSTFIX_MARKER"
      echo "relayhost = [${SMTP_HOST}]:${SMTP_PORT}"
      echo "smtp_sasl_auth_enable = yes"
      echo "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
      echo "smtp_sasl_security_options = noanonymous"
      echo "smtp_tls_security_level = encrypt"
      echo "smtp_tls_wrappermode = no"
      echo "header_size_limit = 4096000"
      echo "smtp_generic_maps = hash:/etc/postfix/generic"
    } >> /etc/postfix/main.cf
  fi
  if postfix check 2>/dev/null; then
    log_ok "Postfix corrigido."
  else
    INSTALL_ERRORS+=("Postfix: execute 'sudo postfix check' para detalhes. Backup em /etc/postfix/main.cf.bak.monitoramento.*")
  fi
fi
systemctl restart postfix 2>/dev/null || INSTALL_WARNINGS+=("Nao foi possivel reiniciar postfix. Tente: sudo systemctl restart postfix")
systemctl enable postfix 2>/dev/null || true
log_ok "Postfix configurado."
else
  log_ok "E-mail desabilitado. Postfix nao instalado."
fi

# --- 3. ClamAV ---
log_step "ClamAV (antivirus e quarentena)"
mkdir -p /var/virus-quarantine /var/log/clamav
chown -R clamav:clamav /var/virus-quarantine /var/log/clamav 2>/dev/null || true
chmod 755 /var/virus-quarantine

# Atualizar assinaturas (pode falhar por rate-limit; nao critico)
systemctl stop clamav-freshclam 2>/dev/null || true
if freshclam 2>/dev/null; then
  log_ok "Assinaturas ClamAV atualizadas."
else
  log_warn "freshclam falhou (pode ser rate-limit). Assinaturas serao atualizadas em background. Cron usara clamscan."
  INSTALL_WARNINGS+=("freshclam nao atualizou agora. Execute depois: sudo freshclam")
fi
systemctl start clamav-freshclam 2>/dev/null || true
systemctl enable clamav-freshclam 2>/dev/null || true

if systemctl start clamav-daemon 2>/dev/null; then
  systemctl enable clamav-daemon 2>/dev/null || true
  log_ok "ClamAV daemon ativo."
else
  log_warn "clamav-daemon nao iniciou (comum em containers). Cron usara clamscan (standalone)."
  INSTALL_WARNINGS+=("ClamAV daemon inativo. Varredura diaria usara clamscan.")
fi
log_ok "ClamAV configurado."

# --- 4. Diretório de templates e script de envio HTML ---
log_step "Estrutura de alertas (send_html_alert.sh e diretorios)"
mkdir -p /opt/alerts/templates

# send_html_alert.sh (usa From de /opt/monitoring/email.conf = remetente configurado na instalacao)
cat > /usr/local/bin/send_html_alert.sh << 'SENDHTML'
#!/usr/bin/env bash
set -euo pipefail
TEMPLATE_PATH="${1:-/opt/alerts/templates/alert.html}"
RECIPIENT="${2:-}"
[[ -z "$RECIPIENT" ]] && exit 0
SUBJECT="${3:-Alerta do servidor}"
TITLE="${4:-Alerta do servidor}"
MESSAGE="${5:-Mensagem nao especificada}"
DATE="$(date '+%Y-%m-%d %H:%M:%S %Z')"
HOST="$(hostname)"
SENDER_EMAIL=""
SERVER_ID=""
[[ -f /opt/monitoring/email.conf ]] && source /opt/monitoring/email.conf
HOST="${SERVER_ID:-$(hostname)}"
[[ ! -f "$TEMPLATE_PATH" ]] && { echo "Template nao encontrado: $TEMPLATE_PATH" >&2; exit 1; }
export TITLE MESSAGE DATE HOST
RENDERED_FILE="$(mktemp /tmp/alert-email-XXXXXX.html)"
envsubst '${TITLE} ${MESSAGE} ${DATE} ${HOST}' < "$TEMPLATE_PATH" > "$RENDERED_FILE"
if [[ -n "${SENDER_EMAIL:-}" ]]; then
  FROM_HEADER="Monitoramento de Servidores <${SENDER_EMAIL}>"
  cat "$RENDERED_FILE" | mail -r "$SENDER_EMAIL" -a "From: $FROM_HEADER" -a "Content-Type: text/html; charset=UTF-8" -s "$SUBJECT" "$RECIPIENT"
else
  cat "$RENDERED_FILE" | mail -a "Content-Type: text/html; charset=UTF-8" -s "$SUBJECT" "$RECIPIENT"
fi
rm -f "$RENDERED_FILE"
SENDHTML
chmod +x /usr/local/bin/send_html_alert.sh
log_ok "Script send_html_alert.sh criado."

# --- 4b. E-mail: remetente e identificador do servidor (From + nome em todos os alertas) ---
mkdir -p /opt/monitoring
if [[ $EMAIL_ENABLED -eq 1 ]]; then
  printf 'SENDER_EMAIL="%s"\nSERVER_ID="%s"\n' "$SENDER_EMAIL" "$SMTP_DOMAIN" > /opt/monitoring/email.conf
else
  printf 'SENDER_EMAIL=""\nSERVER_ID="%s"\n' "$(hostname 2>/dev/null || echo 'localhost')" > /opt/monitoring/email.conf
fi
chmod 644 /opt/monitoring/email.conf

# --- 4c. Telegram: config e scripts de notificacao ---
log_step "Telegram (send_telegram_alert.sh, telegram-get-chat-id.sh)"
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  cat > /opt/monitoring/telegram.conf << TELEGRAMCONF
# Configuracao do Bot Telegram (gerado pelo install-monitoring.sh)
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAMCONF
  chmod 640 /opt/monitoring/telegram.conf
fi

cat > /usr/local/bin/send_telegram_alert.sh << 'SENDTG'
#!/usr/bin/env bash
# Envia mensagem para o Telegram. Uso: send_telegram_alert.sh "Texto da mensagem"
# Config em /opt/monitoring/telegram.conf
CONF="/opt/monitoring/telegram.conf"
[[ ! -f "$CONF" ]] && exit 0
source "$CONF" 2>/dev/null || true
[[ -z "$TELEGRAM_BOT_TOKEN" ]] && exit 0
[[ -z "$TELEGRAM_CHAT_ID" ]] && exit 0
MSG="${1:-Alerta do servidor}"
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  -d "disable_web_page_preview=true" >/dev/null 2>&1 || true
SENDTG
chmod +x /usr/local/bin/send_telegram_alert.sh

cat > /usr/local/bin/telegram-get-chat-id.sh << 'GETCHATID'
#!/usr/bin/env bash
# Obtem o Chat ID do Telegram apos o usuario enviar /start ao bot.
# Execute: sudo telegram-get-chat-id.sh
CONF="/opt/monitoring/telegram.conf"
[[ ! -f "$CONF" ]] && { echo "Arquivo $CONF nao encontrado."; exit 1; }
source "$CONF" 2>/dev/null || true
[[ -z "$TELEGRAM_BOT_TOKEN" ]] && { echo "TELEGRAM_BOT_TOKEN nao definido em $CONF"; exit 1; }
echo "Envie /start ao seu bot no Telegram e pressione Enter..."
read -r
RESP=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?limit=3")
if echo "$RESP" | grep -q '"chat":'; then
  CHAT_ID=$(echo "$RESP" | grep -o '"id":[0-9]*' | tail -1 | cut -d: -f2)
  sed -i "s/^TELEGRAM_CHAT_ID=.*/TELEGRAM_CHAT_ID=${CHAT_ID}/" "$CONF"
  echo "Chat ID obtido e salvo: $CHAT_ID"
else
  echo "Nenhuma mensagem encontrada. Envie /start ao bot e tente novamente."
  exit 1
fi
GETCHATID
chmod +x /usr/local/bin/telegram-get-chat-id.sh
[[ -n "$TELEGRAM_BOT_TOKEN" ]] && log_ok "Telegram configurado (send_telegram_alert.sh, telegram-get-chat-id.sh)."

# --- 4d. Dashboard: config e script de envio de metricas ---
if [[ $DASHBOARD_ENABLED -eq 1 ]]; then
  mkdir -p /opt/monitoring
  cat > /opt/monitoring/dashboard.conf << DASHCONF
# Configuracao Dashboard (gerado pelo install-monitoring.sh)
DASHBOARD_ENABLED=1
DASHBOARD_SERVER_UUID=${DASHBOARD_SERVER_UUID}
DASHBOARD_API_URL=${DASHBOARD_API_URL}
DASHCONF
  chmod 640 /opt/monitoring/dashboard.conf
  log_info "Dashboard config em /opt/monitoring/dashboard.conf"
fi

cat > /usr/local/bin/send_dashboard_metrics.sh << 'SENDDASH'
#!/usr/bin/env bash
# Envia metricas/incidentes para o Dashboard via API REST.
# Config: /opt/monitoring/dashboard.conf
CONF="/opt/monitoring/dashboard.conf"
[[ ! -f "$CONF" ]] && exit 0
source "$CONF" 2>/dev/null || true
[[ "${DASHBOARD_ENABLED:-0}" != "1" ]] && exit 0
[[ -z "${DASHBOARD_SERVER_UUID:-}" ]] && exit 0
API_URL="${DASHBOARD_API_URL:-https://api.dashboard-exemplo.com/v1}"
SERVER_ID="${SERVER_ID:-$(hostname)}"
MODE="${1:-}"
BODY="${2:-}"
if [[ "$MODE" == "metrics" ]]; then
  ENDPOINT="${API_URL}/ingest/metrics"
elif [[ "$MODE" == "incident" ]]; then
  ENDPOINT="${API_URL}/ingest/incident"
else
  exit 1
fi
if [[ -n "$BODY" && -f "$BODY" ]]; then
  PAYLOAD=$(cat "$BODY")
else
  PAYLOAD=$(cat)
fi
[[ -z "$PAYLOAD" ]] && exit 1
curl -s -X POST "$ENDPOINT" -H "Content-Type: application/json" -H "X-Server-UUID: $DASHBOARD_SERVER_UUID" -d "$PAYLOAD" --max-time 10 >/dev/null 2>&1 || true
SENDDASH
chmod +x /usr/local/bin/send_dashboard_metrics.sh

cat > /usr/local/bin/dashboard_fetch_updates.sh << 'FETCHDASH'
#!/usr/bin/env bash
# Consulta a API do Dashboard por atualizacoes pendentes (thresholds, recipients, scripts).
# Cron: */15 * * * * dashboard_fetch_updates.sh
CONF="/opt/monitoring/dashboard.conf"
[[ ! -f "$CONF" ]] && exit 0
source "$CONF" 2>/dev/null || true
[[ "${DASHBOARD_ENABLED:-0}" != "1" ]] && exit 0
[[ -z "${DASHBOARD_SERVER_UUID:-}" ]] && exit 0
API_URL="${DASHBOARD_API_URL:-https://api.dashboard-exemplo.com/v1}"
RESP=$(curl -s -X GET "${API_URL}/agent/updates" -H "X-Server-UUID: ${DASHBOARD_SERVER_UUID}" --max-time 10 2>/dev/null) || exit 0
[[ -z "$RESP" ]] && exit 0
echo "$RESP" | grep -q '"has_updates":true' || exit 0
# Aplicar thresholds nos scripts
CPU=$(echo "$RESP" | grep -o '"cpu":[0-9]*' | cut -d: -f2)
MEM=$(echo "$RESP" | grep -o '"memory":[0-9]*' | cut -d: -f2)
DISK=$(echo "$RESP" | grep -o '"disk":[0-9]*' | cut -d: -f2)
[[ -n "$CPU" && -f /usr/local/bin/monitor_cpu.sh ]] && sed -i "s/^CPU_THRESHOLD=.*/CPU_THRESHOLD=$CPU/" /usr/local/bin/monitor_cpu.sh 2>/dev/null || true
[[ -n "$MEM" && -f /usr/local/bin/monitor_memory.sh ]] && sed -i "s/^MEM_THRESHOLD=.*/MEM_THRESHOLD=$MEM/" /usr/local/bin/monitor_memory.sh 2>/dev/null || true
[[ -n "$DISK" && -f /usr/local/bin/monitor_disk.sh ]] && sed -i "s/^DISK_THRESHOLD=.*/DISK_THRESHOLD=$DISK/" /usr/local/bin/monitor_disk.sh 2>/dev/null || true
# Aplicar recipients (emails como lista comma-separated, telegram_chat_id em telegram.conf)
EMAILS_RAW=$(echo "$RESP" | sed -n 's/.*"emails":\[\([^]]*\)\].*/\1/p' 2>/dev/null)
if [[ -n "$EMAILS_RAW" ]]; then
  RECIPIENTS_NEW=$(echo "$EMAILS_RAW" | sed 's/","/,/g;s/"//g')
  [[ -n "$RECIPIENTS_NEW" ]] && for script in /usr/local/bin/monitor_cpu.sh /usr/local/bin/monitor_memory.sh /usr/local/bin/monitor_disk.sh; do
    [[ -f "$script" ]] && sed -i "s|^RECIPIENTS=.*|RECIPIENTS=\"$RECIPIENTS_NEW\"|" "$script" 2>/dev/null || true
  done
fi
TG_ID=$(echo "$RESP" | grep -o '"telegram_chat_id":"[^"]*"' | cut -d'"' -f4)
if [[ -n "$TG_ID" && -f /opt/monitoring/telegram.conf ]]; then
  sed -i "s/^TELEGRAM_CHAT_ID=.*/TELEGRAM_CHAT_ID=$TG_ID/" /opt/monitoring/telegram.conf 2>/dev/null || true
fi
# Baixar scripts se URLs presentes (https apenas)
for name in monitor_cpu monitor_memory monitor_disk; do
  URL=$(echo "$RESP" | grep -o "\"${name}\":\"[^\"]*\"" | cut -d'"' -f4)
  if [[ -n "$URL" && "$URL" == https* ]]; then
    curl -s -o "/usr/local/bin/${name}.sh" "$URL" --max-time 15 2>/dev/null && chmod +x "/usr/local/bin/${name}.sh" 2>/dev/null || true
  fi
done
FETCHDASH
chmod +x /usr/local/bin/dashboard_fetch_updates.sh

# --- 5. Templates HTML (variáveis ${TITLE}, ${MESSAGE}, ${DATE}, ${HOST} literais) ---
log_step "Templates HTML (alert, cpu, memory, disk, clamav)"

write_alert_template() {
  local path="$1"
  local border_color="$2"
  local label="$3"
  local subtitle="$4"
  local footer_label="$5"
  cat > "$path" << TEMPLATE_END
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="pt-BR">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>\${TITLE}</title>
  <style type="text/css">
    table, td { border-collapse: collapse; }
    body { margin: 0; padding: 0; width: 100% !important; background-color: #f4f4f7; }
  </style>
</head>
<body style="margin: 0; padding: 0; background-color: #f4f4f7; font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;">
  <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" bgcolor="#f4f4f7">
    <tr><td align="center" style="padding: 40px 10px;">
      <table role="presentation" class="wrapper" border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px; background-color: #ffffff; border-radius: 8px; border: 1px solid #eaeaec;">
        <tr>
          <td style="padding: 30px 40px 20px 40px; border-bottom: 4px solid ${border_color};">
            <h1 style="margin: 0; font-size: 24px; font-weight: bold; color: #1f2937;">\${TITLE}</h1>
            <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="margin-top: 15px;">
              <tr><td style="color: #6b7280; font-size: 13px;"><strong>Data:</strong> \${DATE} | <strong>Servidor:</strong> \${HOST}</td></tr>
            </table>
          </td>
        </tr>
        <tr>
          <td style="padding: 25px 40px; background-color: #f8fafc;">
            <div style="font-size: 24px; font-weight: bold;">${label}</div>
            <div style="font-size: 14px; color: #64748b; margin-top: 5px;">${subtitle}</div>
          </td>
        </tr>
        <tr>
          <td class="content-padding" style="padding: 30px 40px;">
            <div style="font-size: 16px; line-height: 1.6; color: #374151;">\${MESSAGE}</div>
          </td>
        </tr>
        <tr>
          <td style="padding: 20px 40px; background-color: #f9fafb; border-top: 1px solid #e5e7eb;">
            <p style="margin: 0; font-size: 12px; color: #9ca3af; text-align: center;">Alerta automatico. Nao responda.</p>
          </td>
        </tr>
      </table>
      <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px;">
        <tr><td align="center" style="padding-top: 20px; color: #9ca3af; font-size: 12px;">&copy; Monitoramento - ${footer_label}</td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>
TEMPLATE_END
}

write_alert_template "/opt/alerts/templates/alert.html" "#3b82f6" "Alerta" "Notificacao do sistema" "Sistemas"
write_alert_template "/opt/alerts/templates/cpu-alert.html" "#f97316" "CPU" "Uso elevado detectado" "CPU"
write_alert_template "/opt/alerts/templates/memory-alert.html" "#8b5cf6" "RAM" "Uso elevado detectado" "RAM"
write_alert_template "/opt/alerts/templates/disk-alert.html" "#0ea5e9" "DISCO" "Espaco em disco critico" "Disco"
# ClamAV template (vermelho)
write_alert_template "/opt/alerts/templates/clamav-alert.html" "#dc2626" "ClamAV" "Malware detectado" "ClamAV"
log_ok "Templates HTML criados."

# --- 6. Scripts de monitoramento (com RECIPIENTS injetado) ---
log_step "Scripts de monitoramento (CPU, RAM, Disco)"

# monitor_cpu.sh (SERVER_ID = dominio/nome configurado na instalacao)
cat > /usr/local/bin/monitor_cpu.sh << 'MONITORCPU'
#!/usr/bin/env bash
set -euo pipefail
[[ -f /opt/monitoring/email.conf ]] && source /opt/monitoring/email.conf
SERVER_ID="${SERVER_ID:-$(hostname)}"
TEMPLATE_PATH="/opt/alerts/templates/cpu-alert.html"
RECIPIENTS="RECIPIENTS_PLACEHOLDER"
CPU_THRESHOLD=90
CPU_USAGE=$(timeout 3 mpstat 1 2 2>/dev/null | awk '/Average/ {print 100 - $NF}')
if [[ $(echo "$CPU_USAGE > $CPU_THRESHOLD" | bc -l) == 1 ]]; then
  SYS_SNAP=$(top -b -n 1 2>/dev/null | head -35 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "top indisponivel")
  TOP_CPU=$(ps aux --sort=-%cpu | head -26 | tail -25 | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd $i " "; printf "%-8s %-12s %5s %5s %.70s\n", $2, $1, $3, $4, substr(cmd,1,70)}')
  TOP_CPU_ESC=$(echo "$TOP_CPU" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  TOP_MEM=$(ps aux --sort=-%mem | head -26 | tail -25 | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd $i " "; printf "%-8s %-12s %5s %5s %.70s\n", $2, $1, $4, $3, substr(cmd,1,70)}')
  TOP_MEM_ESC=$(echo "$TOP_MEM" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  MSG_HTML="Uso medio CPU: <strong>${CPU_USAGE}%</strong> (threshold: ${CPU_THRESHOLD}%)<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Snapshot do sistema (top):</strong><br/><pre>${SYS_SNAP}</pre><br/><strong>Top 25 processos por CPU (PID USER %CPU %MEM COMANDO):</strong><br/><pre>${TOP_CPU_ESC}</pre><br/><strong>Top 25 processos por RAM:</strong><br/><pre>${TOP_MEM_ESC}</pre>"
  /usr/local/bin/send_html_alert.sh "$TEMPLATE_PATH" "$RECIPIENTS" "ALERTA CPU ${CPU_USAGE}% - ${SERVER_ID}" "CPU em ${CPU_USAGE}% (CRITICO)" "$MSG_HTML"
  TG_TOP=$(ps aux --sort=-%cpu | head -13 | tail -12 | awk '{printf "%-8s %4s %4s %.45s\n", $2, $3"%", $4"%", $11}')
  /usr/local/bin/send_telegram_alert.sh "ALERTA CPU ${CPU_USAGE}% - ${SERVER_ID}\n\nTop processos (PID %CPU %MEM CMD):\n${TG_TOP}" || true
  if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
  if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
    SNAP_ESC=$(echo "$SYS_SNAP" | sed 's/"/\\"/g' | tr '\n' ' ')
    printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","type":"cpu","value":%s,"threshold":%s,"subject":"ALERTA CPU %s%% - %s","snapshot_top":"%s","notifications_sent":{"email":true,"telegram":true}}\n' \
      "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${CPU_USAGE}" "${CPU_THRESHOLD}" "${CPU_USAGE}" "${SERVER_ID}" "${SNAP_ESC}" | /usr/local/bin/send_dashboard_metrics.sh incident 2>/dev/null || true
  fi
fi
if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
  MEM_INFO=$(free | grep Mem 2>/dev/null)
  TOTAL_MEM=$(echo "$MEM_INFO" | awk '{print $2}')
  USED_MEM=$(echo "$MEM_INFO" | awk '{print $3+$6}')
  MEM_PCT=$(echo "scale=1; ($USED_MEM/$TOTAL_MEM)*100" 2>/dev/null | bc -l 2>/dev/null || echo "0")
  DISK_JSON=$(df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2 | while read -r FS SIZE USED AVAIL PCT MNT; do U="${PCT%%%}"; echo -n "{\"mount\":\"$MNT\",\"usage\":$U},"; done | sed 's/,$//')
  printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","metrics":{"cpu":%s,"memory":%s,"disk":[%s]}}\n' \
    "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${CPU_USAGE}" "${MEM_PCT}" "${DISK_JSON:-}" | /usr/local/bin/send_dashboard_metrics.sh metrics 2>/dev/null || true
fi
MONITORCPU
# Injeta RECIPIENTS no script (placeholder)
sed -i "s|RECIPIENTS_PLACEHOLDER|${RECIPIENTS}|g" /usr/local/bin/monitor_cpu.sh
chmod +x /usr/local/bin/monitor_cpu.sh

# monitor_memory.sh (SERVER_ID = dominio/nome configurado na instalacao)
cat > /usr/local/bin/monitor_memory.sh << 'MONITORMEM'
#!/usr/bin/env bash
set -euo pipefail
[[ -f /opt/monitoring/email.conf ]] && source /opt/monitoring/email.conf
SERVER_ID="${SERVER_ID:-$(hostname)}"
TEMPLATE_PATH="/opt/alerts/templates/memory-alert.html"
RECIPIENTS="RECIPIENTS_PLACEHOLDER"
MEM_THRESHOLD=90
MEM_INFO=$(free | grep Mem)
TOTAL_MEM=$(echo $MEM_INFO | awk '{print $2}')
USED_MEM=$(echo $MEM_INFO | awk '{print $3 + $6}')
MEM_USAGE=$(echo "scale=1; ($USED_MEM / $TOTAL_MEM) * 100" | bc -l)
if [[ $(echo "$MEM_USAGE > $MEM_THRESHOLD" | bc -l) == 1 ]]; then
  TOTAL_MB=$(echo "scale=0; $TOTAL_MEM / 1024" | bc)
  USED_MB=$(echo "scale=0; $USED_MEM / 1024" | bc)
  SYS_SNAP=$(top -b -n 1 2>/dev/null | head -35 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "top indisponivel")
  TOP_MEM=$(ps aux --sort=-%mem | head -26 | tail -25 | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd $i " "; printf "%-8s %-12s %5s %5s %.70s\n", $2, $1, $4, $3, substr(cmd,1,70)}')
  TOP_MEM_ESC=$(echo "$TOP_MEM" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  TOP_CPU=$(ps aux --sort=-%cpu | head -26 | tail -25 | awk '{cmd=""; for(i=11;i<=NF;i++) cmd=cmd $i " "; printf "%-8s %-12s %5s %5s %.70s\n", $2, $1, $3, $4, substr(cmd,1,70)}')
  TOP_CPU_ESC=$(echo "$TOP_CPU" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  MSG_HTML="Uso RAM: <strong>${MEM_USAGE}%</strong> (threshold: ${MEM_THRESHOLD}%)<br/>Total: ${TOTAL_MB}MB | Usado: ${USED_MB}MB<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Snapshot do sistema (top):</strong><br/><pre>${SYS_SNAP}</pre><br/><strong>Top 25 processos por RAM (PID USER %MEM %CPU COMANDO):</strong><br/><pre>${TOP_MEM_ESC}</pre><br/><strong>Top 25 processos por CPU:</strong><br/><pre>${TOP_CPU_ESC}</pre>"
  /usr/local/bin/send_html_alert.sh "$TEMPLATE_PATH" "$RECIPIENTS" "ALERTA RAM ${MEM_USAGE}% - ${SERVER_ID}" "Memoria em ${MEM_USAGE}% (CRITICO)" "$MSG_HTML"
  TG_TOP=$(ps aux --sort=-%mem | head -13 | tail -12 | awk '{printf "%-8s %4s %4s %.45s\n", $2, $4"%", $3"%", $11}')
  /usr/local/bin/send_telegram_alert.sh "ALERTA RAM ${MEM_USAGE}% - ${SERVER_ID}\n\nTop processos (PID %MEM %CPU CMD):\n${TG_TOP}" || true
  if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
  if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
    SNAP_ESC=$(echo "$SYS_SNAP" | sed 's/"/\\"/g' | tr '\n' ' ')
    printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","type":"memory","value":%s,"threshold":%s,"subject":"ALERTA RAM %s%% - %s","snapshot_top":"%s","notifications_sent":{"email":true,"telegram":true}}\n' \
      "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${MEM_USAGE}" "${MEM_THRESHOLD}" "${MEM_USAGE}" "${SERVER_ID}" "${SNAP_ESC}" | /usr/local/bin/send_dashboard_metrics.sh incident 2>/dev/null || true
  fi
fi
if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
  CPU_USAGE=$(timeout 3 mpstat 1 2 2>/dev/null | awk '/Average/ {print 100-$NF}' || echo "0")
  DISK_JSON=$(df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2 | while read -r FS SIZE USED AVAIL PCT MNT; do U="${PCT%%%}"; echo -n "{\"mount\":\"$MNT\",\"usage\":$U},"; done | sed 's/,$//')
  printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","metrics":{"cpu":%s,"memory":%s,"disk":[%s]}}\n' \
    "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${CPU_USAGE}" "${MEM_USAGE}" "${DISK_JSON:-}" | /usr/local/bin/send_dashboard_metrics.sh metrics 2>/dev/null || true
fi
MONITORMEM
sed -i "s|RECIPIENTS_PLACEHOLDER|${RECIPIENTS}|g" /usr/local/bin/monitor_memory.sh
chmod +x /usr/local/bin/monitor_memory.sh

# monitor_disk.sh (SERVER_ID = dominio/nome configurado na instalacao)
cat > /usr/local/bin/monitor_disk.sh << 'MONITORDISK'
#!/usr/bin/env bash
set -euo pipefail
[[ -f /opt/monitoring/email.conf ]] && source /opt/monitoring/email.conf
SERVER_ID="${SERVER_ID:-$(hostname)}"
TEMPLATE_PATH="/opt/alerts/templates/disk-alert.html"
RECIPIENTS="RECIPIENTS_PLACEHOLDER"
DISK_THRESHOLD=90
df -P -x tmpfs -x devtmpfs -x squashfs | tail -n +2 | while read -r FS SIZE USED AVAIL PCT MOUNT; do
  USAGE=${PCT%%%}
  if [[ "$USAGE" -gt "$DISK_THRESHOLD" ]]; then
    TOP_DIRS=$(timeout 15 du -h --max-depth=1 "$MOUNT" 2>/dev/null | sort -hr | head -21 | tail -20 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    SYS_SNAP=$(top -b -n 1 2>/dev/null | head -35 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' || echo "top indisponivel")
    MSG_HTML="Particao: <strong>${MOUNT}</strong><br/>Dispositivo: <strong>${FS}</strong><br/>Uso: <strong>${USAGE}%</strong> (threshold: ${DISK_THRESHOLD}%)<br/>Total: ${SIZE}K | Usado: ${USED}K | Livre: ${AVAIL}K<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Top diretorios em ${MOUNT}:</strong><br/><pre>${TOP_DIRS:-N/A}</pre><br/><strong>Snapshot do sistema (top):</strong><br/><pre>${SYS_SNAP}</pre>"
    /usr/local/bin/send_html_alert.sh "$TEMPLATE_PATH" "$RECIPIENTS" "ALERTA DISCO ${USAGE}% - ${SERVER_ID} (${MOUNT})" "Disco em ${USAGE}% (CRITICO) em ${MOUNT}" "$MSG_HTML"
    /usr/local/bin/send_telegram_alert.sh "ALERTA DISCO ${USAGE}% - ${SERVER_ID} ${MOUNT}

Top dirs:
${TOP_DIRS:-N/A}" || true
    if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
    if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
      SNAP_ESC=$(echo "$SYS_SNAP" | sed 's/"/\\"/g' | tr '\n' ' ')
      printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","type":"disk","value":%s,"threshold":%s,"mount":"%s","subject":"ALERTA DISCO %s%% - %s (%s)","snapshot_top":"%s","notifications_sent":{"email":true,"telegram":true}}\n' \
        "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${USAGE}" "${DISK_THRESHOLD}" "${MOUNT}" "${USAGE}" "${SERVER_ID}" "${MOUNT}" "${SNAP_ESC}" | /usr/local/bin/send_dashboard_metrics.sh incident 2>/dev/null || true
    fi
  fi
done
if [[ -f /opt/monitoring/dashboard.conf ]]; then source /opt/monitoring/dashboard.conf 2>/dev/null; fi
if [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]]; then
  MEM_INFO=$(free | grep Mem 2>/dev/null)
  TOTAL_MEM=$(echo "$MEM_INFO" | awk '{print $2}')
  USED_MEM=$(echo "$MEM_INFO" | awk '{print $3+$6}')
  MEM_PCT=$(echo "scale=1; ($USED_MEM/$TOTAL_MEM)*100" 2>/dev/null | bc -l 2>/dev/null || echo "0")
  CPU_USAGE=$(timeout 3 mpstat 1 2 2>/dev/null | awk '/Average/ {print 100-$NF}' || echo "0")
  DISK_JSON=$(df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2 | while read -r FS SIZE USED AVAIL PCT MNT; do
    U="${PCT%%%}"; echo -n "{\"mount\":\"$MNT\",\"usage\":$U},"; done | sed 's/,$//')
  printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","metrics":{"cpu":%s,"memory":%s,"disk":[%s]}}\n' \
    "${DASHBOARD_SERVER_UUID}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERVER_ID}" "${CPU_USAGE}" "${MEM_PCT}" "${DISK_JSON:-}" | /usr/local/bin/send_dashboard_metrics.sh metrics 2>/dev/null || true
fi
MONITORDISK
sed -i "s|RECIPIENTS_PLACEHOLDER|${RECIPIENTS}|g" /usr/local/bin/monitor_disk.sh
chmod +x /usr/local/bin/monitor_disk.sh

log_ok "Scripts de monitoramento criados."

# --- 7. Crontab ---
log_step "Crontab (CPU/RAM/Disco a cada 5 min, ClamAV diario 02:00)"
# Nota: % no crontab deve ser escapado como \%
CRON_LINE_CLAMAV="0 2 * * * . /opt/monitoring/email.conf 2>/dev/null; SERVER_ID=\${SERVER_ID:-\$(hostname)}; /usr/bin/clamscan --infected --move=/var/virus-quarantine --exclude-dir=\"^/sys|^/proc|^/dev|^/run|^/var/lib/docker|^/boot|^/tmp\" / >/var/log/clamav/daily-scan-\$(date +\\\\%Y\\\\%m\\\\%d).log 2>&1 && grep -q \"Infected files: [1-9]\" /var/log/clamav/daily-scan-\$(date +\\\\%Y\\\\%m\\\\%d).log && /usr/local/bin/send_html_alert.sh /opt/alerts/templates/clamav-alert.html \"${RECIPIENTS}\" \"ClamAV ALERTA - \${SERVER_ID}\" \"Malware Detectado\" \"Arquivos infectados movidos para /var/virus-quarantine. Verifique /var/log/clamav/\" && /usr/local/bin/send_telegram_alert.sh \"ClamAV: Malware detectado - \${SERVER_ID}\" || true"

if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
  log_info "Cron do monitoramento ja existe. Nao duplicando."
  INSTALL_WARNINGS+=("Crontab ja configurado. Para reaplicar, remova as linhas com '$CRON_MARKER' e execute o instalador novamente.")
else
  (crontab -l 2>/dev/null
   echo "$CRON_MARKER"
   echo "# Monitoramento CPU a cada 5 min"
   echo "*/5 * * * * /usr/local/bin/monitor_cpu.sh"
   echo "# Monitoramento Memoria a cada 5 min"
   echo "*/5 * * * * /usr/local/bin/monitor_memory.sh"
   echo "# Monitoramento Disco a cada 5 min"
   echo "*/5 * * * * /usr/local/bin/monitor_disk.sh"
   echo "# ClamAV varredura diaria 02:00 e alerta se virus"
   echo "$CRON_LINE_CLAMAV"
   if [[ $DASHBOARD_ENABLED -eq 1 ]]; then
     echo "# Consulta ao Dashboard a cada 15 min"
     echo "*/15 * * * * /usr/local/bin/dashboard_fetch_updates.sh"
   fi
  ) | crontab -
  log_ok "Crontab configurado."
fi

# --- 8. E-mail e Telegram de boas-vindas (confirmar que tudo esta ok) ---
log_step "E-mail e Telegram de boas-vindas"
if [[ $EMAIL_ENABLED -eq 1 ]] && [[ -n "$RECIPIENTS" ]]; then
  WELCOME_SUBJECT="Monitoramento instalado com sucesso - Bem-vindo"
  WELCOME_TITLE="Instalacao concluida com sucesso"
  WELCOME_MSG="Bem-vindo ao sistema de monitoramento. A instalacao e configuracao foram concluidas com exito. Os alertas de CPU, memoria, disco e ClamAV estao ativos. Voce recebera notificacoes neste e-mail e, se configurado, no Telegram.<br/><br/>Servidor: <strong>${SMTP_DOMAIN}</strong><br/>Data: <strong>$(date '+%Y-%m-%d %H:%M:%S')</strong>"
  EMAIL_OK=0
  while IFS=',' read -ra ADDRS; do
    for addr in "${ADDRS[@]}"; do
      addr=$(echo "$addr" | tr -d ' ')
      [[ -z "$addr" ]] && continue
      if /usr/local/bin/send_html_alert.sh /opt/alerts/templates/alert.html "$addr" "$WELCOME_SUBJECT" "$WELCOME_TITLE" "$WELCOME_MSG" 2>/dev/null; then
        EMAIL_OK=1
      fi
    done
  done <<< "$RECIPIENTS"
  if [[ $EMAIL_OK -eq 1 ]]; then
    log_ok "E-mail de boas-vindas enviado para: $RECIPIENTS"
  else
    log_warn "Envio do e-mail de boas-vindas falhou. Verifique: tail -f /var/log/mail.log"
  fi
else
  [[ $EMAIL_ENABLED -eq 0 ]] && log_ok "E-mail desabilitado. Nenhum e-mail de boas-vindas enviado."
fi
if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
  log_info "Enviando mensagem de conexao para o Telegram..."
  if /usr/local/bin/send_telegram_alert.sh "Conexao confirmada. Bem-vindo ao monitoramento de ${SMTP_DOMAIN:-$(hostname)}. Instalacao concluida com sucesso; alertas ativos." 2>/dev/null; then
    log_ok "Telegram: mensagem de boas-vindas enviada ao contato principal do bot."
  else
    log_warn "Telegram: falha no envio. Apos configurar o Chat ID, execute: echo Teste | /usr/local/bin/send_telegram_alert.sh"
  fi
else
  [[ -n "$TELEGRAM_BOT_TOKEN" ]] && log_info "Telegram configurado; execute sudo /usr/local/bin/telegram-get-chat-id.sh e depois teste o envio."
fi

# --- Resumo final ---
echo "" >&2
echo -e "${GREEN}============================================${NC}" >&2
echo -e "${GREEN}  Instalacao concluida com sucesso           ${NC}" >&2
echo -e "${GREEN}============================================${NC}" >&2
echo "" >&2
echo "Resumo:" >&2
if [[ $EMAIL_ENABLED -eq 1 ]]; then
  echo "  - Postfix (SMTP2Go): porta ${SMTP_PORT}, remetente ${SENDER_EMAIL}" >&2
  echo "  - Destinatarios e-mail: ${RECIPIENTS}" >&2
else
  echo "  - E-mail: desabilitado (não instalado)" >&2
fi
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  echo "  - Telegram: config em /opt/monitoring/telegram.conf" >&2
  [[ -z "$TELEGRAM_CHAT_ID" ]] && echo "    (Execute: sudo /usr/local/bin/telegram-get-chat-id.sh para obter o Chat ID)" >&2
fi
echo "  - ClamAV: varredura diaria 02:00, quarentena em /var/virus-quarantine" >&2
echo "  - Monitoramento: CPU, RAM e Disco a cada 5 min (alerta acima de 80%)" >&2
echo "" >&2
echo "Arquivos principais:" >&2
echo "  - /usr/local/bin/send_html_alert.sh" >&2
echo "  - /usr/local/bin/send_telegram_alert.sh" >&2
[[ -n "$TELEGRAM_BOT_TOKEN" ]] && echo "  - /usr/local/bin/telegram-get-chat-id.sh" >&2
echo "  - /usr/local/bin/monitor_cpu.sh" >&2
echo "  - /usr/local/bin/monitor_memory.sh" >&2
echo "  - /usr/local/bin/monitor_disk.sh" >&2
echo "  - /opt/alerts/templates/*.html" >&2
echo "  - /opt/monitoring/email.conf (remetente From dos e-mails)" >&2
echo "  - /opt/monitoring/telegram.conf (Telegram)" >&2
echo "" >&2
echo "Crontab: sudo crontab -l" >&2
echo "Logs: /var/log/mail.log | /var/log/clamav/" >&2
echo "" >&2

# Mostrar avisos no fluxo principal para ficarem visiveis (nao depender do trap)
if [[ ${#INSTALL_WARNINGS[@]} -gt 0 ]]; then
  log_warn "Avisos durante a instalacao:"
  printf '  - %s\n' "${INSTALL_WARNINGS[@]}" >&2
  echo "" >&2
  log_ok "Instalacao concluida com ${#INSTALL_WARNINGS[@]} aviso(s). Tudo funcional; revise os itens acima se desejar."
else
  log_ok "Instalacao concluida sem avisos."
fi

# Encerrar com codigo de erro se houve falhas criticas
if [[ ${#INSTALL_ERRORS[@]} -gt 0 ]]; then
  log_err "Instalacao concluida com ${#INSTALL_ERRORS[@]} erro(s). Revise as mensagens acima."
  exit 1
fi
exit 0
