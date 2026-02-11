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
TOTAL_STEPS=8
CURRENT_STEP=0
INSTALL_ERRORS=()
INSTALL_WARNINGS=()
POSTFIX_MARKER="# --- monitoramento-de-servidores (install-monitoring.sh) ---"
CRON_MARKER="# --- Monitoramento (install-monitoring.sh) ---"

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

# Trap: ao sair, mostrar resumo de erros/avisos se houver
cleanup_on_exit() {
  local code=$?
  if [[ $code -ne 0 ]] && [[ ${#INSTALL_ERRORS[@]} -gt 0 ]]; then
    echo "" >&2
    log_err "Instalacao encerrada com erros:"
    printf '  - %s\n' "${INSTALL_ERRORS[@]}" >&2
  fi
  if [[ ${#INSTALL_WARNINGS[@]} -gt 0 ]]; then
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

# Coleta de dados (prompts em stderr para aparecer com "curl | bash")
log_info "Informe os dados solicitados (Enter para usar valor padrao quando indicado)."
echo "" >&2
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
log_step "Pacotes do sistema (postfix, mailutils, clamav, sysstat, bc, gettext-base)"
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "postfix postfix/mailname string $SMTP_DOMAIN" 2>/dev/null || true
debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site" 2>/dev/null || true
if run_apt postfix libsasl2-modules mailutils gettext-base clamav clamav-daemon sysstat bc; then
  log_ok "Pacotes instalados ou ja presentes."
else
  INSTALL_ERRORS+=("Falha ao instalar pacotes. Execute: sudo apt-get update && sudo apt-get install -y postfix libsasl2-modules mailutils gettext-base clamav clamav-daemon sysstat bc")
fi

# --- 2. Configuração Postfix ---
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

# send_html_alert.sh
cat > /usr/local/bin/send_html_alert.sh << 'SENDHTML'
#!/usr/bin/env bash
set -euo pipefail
TEMPLATE_PATH="${1:-/opt/alerts/templates/alert.html}"
RECIPIENT="${2:?Informe o e-mail de destino}"
SUBJECT="${3:-Alerta do servidor}"
TITLE="${4:-Alerta do servidor}"
MESSAGE="${5:-Mensagem nao especificada}"
DATE="$(date '+%Y-%m-%d %H:%M:%S %Z')"
HOST="$(hostname)"
[[ ! -f "$TEMPLATE_PATH" ]] && { echo "Template nao encontrado: $TEMPLATE_PATH" >&2; exit 1; }
export TITLE MESSAGE DATE HOST
RENDERED_FILE="$(mktemp /tmp/alert-email-XXXXXX.html)"
envsubst '${TITLE} ${MESSAGE} ${DATE} ${HOST}' < "$TEMPLATE_PATH" > "$RENDERED_FILE"
cat "$RENDERED_FILE" | mail -a "Content-Type: text/html; charset=UTF-8" -s "$SUBJECT" "$RECIPIENT"
rm -f "$RENDERED_FILE"
SENDHTML
chmod +x /usr/local/bin/send_html_alert.sh
log_ok "Script send_html_alert.sh criado."

# --- 4b. Telegram: config e scripts de notificacao ---
log_step "Telegram (send_telegram_alert.sh, telegram-get-chat-id.sh)"
mkdir -p /opt/monitoring
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

# monitor_cpu.sh
cat > /usr/local/bin/monitor_cpu.sh << MONITORCPU
#!/usr/bin/env bash
set -euo pipefail
TEMPLATE_PATH="/opt/alerts/templates/cpu-alert.html"
RECIPIENTS="${RECIPIENTS}"
CPU_THRESHOLD=80
CPU_USAGE=\$(timeout 3 mpstat 1 2 2>/dev/null | awk '/Average/ {print 100 - \$NF}')
if [[ \$(echo "\$CPU_USAGE > \$CPU_THRESHOLD" | bc -l) == 1 ]]; then
  TOP_PROCS=\$(ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "%-12s %4s%% %s\n", \$11, \$3, \$2}')
  /usr/local/bin/send_html_alert.sh "\$TEMPLATE_PATH" "\$RECIPIENTS" "ALERTA CPU \${CPU_USAGE}% - \$(hostname)" "CPU em \${CPU_USAGE}% (CRITICO)" "Uso medio CPU: <strong>\${CPU_USAGE}%</strong> (threshold: \${CPU_THRESHOLD}%)<br/><br/>Data/Hora: <strong>\$(date)</strong><br/><br/><strong>Top 5 Processos:</strong><br/><pre>\${TOP_PROCS}</pre>"
  /usr/local/bin/send_telegram_alert.sh "ALERTA CPU \${CPU_USAGE}% - \$(hostname)" || true
fi
MONITORCPU
chmod +x /usr/local/bin/monitor_cpu.sh

# monitor_memory.sh
cat > /usr/local/bin/monitor_memory.sh << MONITORMEM
#!/usr/bin/env bash
set -euo pipefail
TEMPLATE_PATH="/opt/alerts/templates/memory-alert.html"
RECIPIENTS="${RECIPIENTS}"
MEM_THRESHOLD=80
MEM_INFO=\$(free | grep Mem)
TOTAL_MEM=\$(echo \$MEM_INFO | awk '{print \$2}')
USED_MEM=\$(echo \$MEM_INFO | awk '{print \$3 + \$6}')
MEM_USAGE=\$(echo "scale=1; (\$USED_MEM / \$TOTAL_MEM) * 100" | bc -l)
if [[ \$(echo "\$MEM_USAGE > \$MEM_THRESHOLD" | bc -l) == 1 ]]; then
  TOP_MEM=\$(ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "%-12s %4s%% %s\n", \$11, \$4, \$2}')
  TOTAL_MB=\$(echo "scale=0; \$TOTAL_MEM / 1024" | bc)
  USED_MB=\$(echo "scale=0; \$USED_MEM / 1024" | bc)
  /usr/local/bin/send_html_alert.sh "\$TEMPLATE_PATH" "\$RECIPIENTS" "ALERTA RAM \${MEM_USAGE}% - \$(hostname)" "Memoria em \${MEM_USAGE}% (CRITICO)" "Uso RAM: <strong>\${MEM_USAGE}%</strong> (threshold: \${MEM_THRESHOLD}%)<br/>Total: \${TOTAL_MB}MB | Usado: \${USED_MB}MB<br/><br/>Data/Hora: <strong>\$(date)</strong><br/><br/><strong>Top 5 Processos por RAM:</strong><br/><pre>\${TOP_MEM}</pre>"
  /usr/local/bin/send_telegram_alert.sh "ALERTA RAM \${MEM_USAGE}% - \$(hostname)" || true
fi
MONITORMEM
chmod +x /usr/local/bin/monitor_memory.sh

# monitor_disk.sh
cat > /usr/local/bin/monitor_disk.sh << MONITORDISK
#!/usr/bin/env bash
set -euo pipefail
TEMPLATE_PATH="/opt/alerts/templates/disk-alert.html"
RECIPIENTS="${RECIPIENTS}"
DISK_THRESHOLD=80
df -P -x tmpfs -x devtmpfs -x squashfs | tail -n +2 | while read -r FS SIZE USED AVAIL PCT MOUNT; do
  USAGE=\${PCT%%%}
  if [[ "\$USAGE" -gt "\$DISK_THRESHOLD" ]]; then
    MESSAGE="Particao: <strong>\${MOUNT}</strong><br/>Dispositivo: <strong>\${FS}</strong><br/>Uso: <strong>\${USAGE}%</strong> (threshold: \${DISK_THRESHOLD}%)<br/>Total: \${SIZE}K | Usado: \${USED}K | Livre: \${AVAIL}K<br/><br/>Data/Hora: <strong>\$(date)</strong>"
    /usr/local/bin/send_html_alert.sh "\$TEMPLATE_PATH" "\$RECIPIENTS" "ALERTA DISCO \${USAGE}% - \$(hostname) (\${MOUNT})" "Disco em \${USAGE}% (CRITICO) em \${MOUNT}" "\$MESSAGE"
    /usr/local/bin/send_telegram_alert.sh "ALERTA DISCO \${USAGE}% - \$(hostname) \${MOUNT}" || true
  fi
done
MONITORDISK
chmod +x /usr/local/bin/monitor_disk.sh

log_ok "Scripts de monitoramento criados."

# --- 7. Crontab ---
log_step "Crontab (CPU/RAM/Disco a cada 5 min, ClamAV diario 02:00)"
# Nota: % no crontab deve ser escapado como \%
CRON_LINE_CLAMAV="0 2 * * * /usr/bin/clamscan --infected --move=/var/virus-quarantine --exclude-dir=\"^/sys|^/proc|^/dev|^/run|^/var/lib/docker|^/boot|^/tmp\" / >/var/log/clamav/daily-scan-\$(date +\\\\%Y\\\\%m\\\\%d).log 2>&1 && grep -q \"Infected files: [1-9]\" /var/log/clamav/daily-scan-\$(date +\\\\%Y\\\\%m\\\\%d).log && /usr/local/bin/send_html_alert.sh /opt/alerts/templates/clamav-alert.html \"${RECIPIENTS}\" \"ClamAV ALERTA - \$(hostname)\" \"Malware Detectado\" \"Arquivos infectados movidos para /var/virus-quarantine. Verifique /var/log/clamav/\" && /usr/local/bin/send_telegram_alert.sh \"ClamAV: Malware detectado - \$(hostname)\" || true"

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
  ) | crontab -
  log_ok "Crontab configurado."
fi

# --- 8. Teste de envio ---
log_step "Teste de envio (e-mail e Telegram)"
if echo "Teste de instalacao - $(date)" | mail -s "Monitoramento instalado - $(hostname)" "$RECIPIENTS" 2>/dev/null; then
  log_ok "E-mail de teste enviado para: $RECIPIENTS"
else
  log_warn "Envio de teste falhou. Verifique: tail -f /var/log/mail.log"
fi
if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
  log_info "Enviando teste para o Telegram..."
  /usr/local/bin/send_telegram_alert.sh "Monitoramento instalado - $(hostname). Alertas ativos." && log_ok "Telegram: mensagem de teste enviada." || log_warn "Telegram: falha no envio. Execute telegram-get-chat-id.sh se ainda nao configurou o Chat ID."
fi

# --- Resumo final ---
echo "" >&2
echo -e "${GREEN}============================================${NC}" >&2
echo -e "${GREEN}  Instalacao concluida com sucesso           ${NC}" >&2
echo -e "${GREEN}============================================${NC}" >&2
echo "" >&2
echo "Resumo:" >&2
echo "  - Postfix (SMTP2Go): porta ${SMTP_PORT}, remetente ${SENDER_EMAIL}" >&2
echo "  - Destinatarios e-mail: ${RECIPIENTS}" >&2
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
echo "  - /opt/monitoring/telegram.conf (Telegram)" >&2
echo "" >&2
echo "Crontab: sudo crontab -l" >&2
echo "Logs: /var/log/mail.log | /var/log/clamav/" >&2
echo "" >&2

# Encerrar com codigo de erro se houve falhas criticas
if [[ ${#INSTALL_ERRORS[@]} -gt 0 ]]; then
  log_err "Instalacao concluida com ${#INSTALL_ERRORS[@]} erro(s). Revise as mensagens acima."
  exit 1
fi
if [[ ${#INSTALL_WARNINGS[@]} -gt 0 ]]; then
  log_ok "Instalacao concluida com ${#INSTALL_WARNINGS[@]} aviso(s). Tudo funcional; revise se desejar."
fi
exit 0
