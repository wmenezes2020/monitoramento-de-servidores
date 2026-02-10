#!/usr/bin/env bash
#
# Instalador completo: E-mail (SMTP2Go), Telegram, ClamAV, Monitoramento CPU/RAM/Disco
# Repo: https://github.com/wmenezes2020/monitoramento-de-servidores
#
# Uso local:  sudo ./install-monitoring.sh
# Via curl:   curl -fsSL https://raw.githubusercontent.com/wmenezes2020/monitoramento-de-servidores/main/install-monitoring.sh | sudo bash
#
set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[AVISO]${NC} $*"; }
log_err()   { echo -e "${RED}[ERRO]${NC} $*"; }

# Verificar execução como root
if [[ $EUID -ne 0 ]]; then
  log_err "Execute este script como root: sudo bash $0"
  exit 1
fi

# Banner
echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Instalador de Monitoramento e Alertas     ${NC}"
echo -e "${BLUE}  E-mail + Telegram + ClamAV + CPU/RAM/Disco ${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Coleta de dados
log_info "Informe os dados solicitados (Enter para usar valor padrão quando indicado)."
echo ""

read -p "Porta do servidor SMTP (ex: 587 ou 2525) [587]: " SMTP_PORT
SMTP_PORT="${SMTP_PORT:-587}"

read -p "Dominio ou nome do servidor (ex: meuservidor.com) [$(hostname)]: " SMTP_DOMAIN
SMTP_DOMAIN="${SMTP_DOMAIN:-$(hostname)}"

read -p "Usuario SMTP (e-mail ou usuario SMTP2Go): " SMTP_USER
[[ -z "$SMTP_USER" ]] && { log_err "Usuario SMTP e obrigatorio."; exit 1; }

read -s -p "Senha SMTP: " SMTP_PASS
echo ""
[[ -z "$SMTP_PASS" ]] && { log_err "Senha SMTP e obrigatoria."; exit 1; }

read -p "E-mail remetente (verificado no SMTP2Go, ex: alertas@seudominio.com): " SENDER_EMAIL
[[ -z "$SENDER_EMAIL" ]] && { log_err "E-mail remetente e obrigatorio."; exit 1; }

read -p "E-mail(s) de destino para alertas (separados por virgula): " RECIPIENTS
[[ -z "$RECIPIENTS" ]] && { log_err "Pelo menos um e-mail de destino e obrigatorio."; exit 1; }

# Remove espaços extras dos destinatários
RECIPIENTS=$(echo "$RECIPIENTS" | tr -d ' ')

echo ""
read -p "Token do Bot do Telegram (deixe vazio para nao usar notificacoes Telegram): " TELEGRAM_BOT_TOKEN
TELEGRAM_BOT_TOKEN=$(echo "$TELEGRAM_BOT_TOKEN" | tr -d ' ')
TELEGRAM_CHAT_ID=""
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  echo ""
  log_info "Para receber alertas no Telegram: abra o app Telegram, procure seu bot e envie o comando /start"
  read -p "Pressione Enter apos ter enviado /start ao bot... " _dummy
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

echo ""
log_info "Iniciando instalacao..."
echo ""

# --- 1. Pacotes do sistema ---
log_info "Instalando pacotes (postfix, mailutils, clamav, sysstat, bc, gettext-base)..."
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "postfix postfix/mailname string $SMTP_DOMAIN"
debconf-set-selections <<< "postfix postfix/main_mailer_type select Internet Site"
apt-get update -qq
apt-get install -y -qq postfix libsasl2-modules mailutils gettext-base clamav clamav-daemon sysstat bc >/dev/null 2>&1
log_ok "Pacotes instalados."

# --- 2. Configuração Postfix ---
log_info "Configurando Postfix (SMTP2Go)..."
SMTP_HOST="mail.smtp2go.com"
MAIN_CF_EXTRA="
relayhost = [${SMTP_HOST}]:${SMTP_PORT}
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_tls_wrappermode = no
header_size_limit = 4096000
smtp_generic_maps = hash:/etc/postfix/generic
"
echo "$MAIN_CF_EXTRA" >> /etc/postfix/main.cf

echo "[${SMTP_HOST}]:${SMTP_PORT} ${SMTP_USER}:${SMTP_PASS}" > /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
chown root:root /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db 2>/dev/null || true

# Masquerade
echo "root@${SMTP_DOMAIN}    ${SENDER_EMAIL}
@${SMTP_DOMAIN}    ${SENDER_EMAIL}" > /etc/postfix/generic
postmap /etc/postfix/generic

postfix check
systemctl restart postfix
systemctl enable postfix
log_ok "Postfix configurado."

# --- 3. ClamAV ---
log_info "Configurando ClamAV..."
mkdir -p /var/virus-quarantine /var/log/clamav
chown -R clamav:clamav /var/virus-quarantine /var/log/clamav
chmod 755 /var/virus-quarantine
systemctl stop clamav-freshclam 2>/dev/null || true
freshclam 2>/dev/null || true
systemctl start clamav-freshclam 2>/dev/null || true
systemctl enable clamav-freshclam 2>/dev/null || true
systemctl start clamav-daemon 2>/dev/null || true
systemctl enable clamav-daemon 2>/dev/null || true
log_ok "ClamAV configurado."

# --- 4. Diretório de templates e script de envio HTML ---
log_info "Criando estrutura de alertas..."
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
log_info "Criando scripts de notificacao Telegram..."
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
log_info "Criando templates HTML..."

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
log_info "Criando scripts de monitoramento..."

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
log_info "Configurando crontab..."
CRON_MARKER="# --- Monitoramento (install-monitoring.sh) ---"
# Nota: % no crontab deve ser escapado como \%
CRON_LINE_CLAMAV="0 2 * * * /usr/bin/clamscan --infected --move=/var/virus-quarantine --exclude-dir=\"^/sys|^/proc|^/dev|^/run|^/var/lib/docker|^/boot|^/tmp\" / >/var/log/clamav/daily-scan-\$(date +\\\\%Y\\\\%m\\\\%d).log 2>&1 && grep -q \"Infected files: [1-9]\" /var/log/clamav/daily-scan-\$(date +\\\\%Y\\\\%m\\\\%d).log && /usr/local/bin/send_html_alert.sh /opt/alerts/templates/clamav-alert.html \"${RECIPIENTS}\" \"ClamAV ALERTA - \$(hostname)\" \"Malware Detectado\" \"Arquivos infectados movidos para /var/virus-quarantine. Verifique /var/log/clamav/\" && /usr/local/bin/send_telegram_alert.sh \"ClamAV: Malware detectado - \$(hostname)\" || true"

if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
  log_warn "Entradas de cron do monitoramento ja existem. Nao duplicando."
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
log_info "Enviando e-mail de teste..."
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
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Instalacao concluida com sucesso           ${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Resumo:"
echo "  - Postfix (SMTP2Go): porta ${SMTP_PORT}, remetente ${SENDER_EMAIL}"
echo "  - Destinatarios e-mail: ${RECIPIENTS}"
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  echo "  - Telegram: config em /opt/monitoring/telegram.conf"
  [[ -z "$TELEGRAM_CHAT_ID" ]] && echo "    (Execute: sudo /usr/local/bin/telegram-get-chat-id.sh para obter o Chat ID)"
fi
echo "  - ClamAV: varredura diaria 02:00, quarentena em /var/virus-quarantine"
echo "  - Monitoramento: CPU, RAM e Disco a cada 5 min (alerta acima de 80%)"
echo ""
echo "Arquivos principais:"
echo "  - /usr/local/bin/send_html_alert.sh"
echo "  - /usr/local/bin/send_telegram_alert.sh"
[[ -n "$TELEGRAM_BOT_TOKEN" ]] && echo "  - /usr/local/bin/telegram-get-chat-id.sh"
echo "  - /usr/local/bin/monitor_cpu.sh"
echo "  - /usr/local/bin/monitor_memory.sh"
echo "  - /usr/local/bin/monitor_disk.sh"
echo "  - /opt/alerts/templates/*.html"
echo "  - /opt/monitoring/telegram.conf (Telegram)"
echo ""
echo "Crontab: sudo crontab -l"
echo "Logs: /var/log/mail.log | /var/log/clamav/"
echo ""
