# Instalação Completa do ClamAV + Monitoramento com Alertas

Guia completo para instalar e configurar o ClamAV no Linux com varredura automática diária e alertas por e-mail em HTML quando malware for detectado.

**Tempo estimado:** ~15 minutos  
**Pré-requisito:** Postfix configurado com SMTP2GO (ou outro relay SMTP funcional)

---

## 1. Instalar o ClamAV

```bash
sudo apt update
sudo apt install -y clamav clamav-daemon
```

## 2. Atualizar Base de Assinaturas

```bash
sudo systemctl stop clamav-freshclam
sudo freshclam
sudo systemctl start clamav-freshclam
sudo systemctl enable clamav-freshclam
```

## 3. Criar Diretório de Quarentena

```bash
sudo mkdir -p /var/virus-quarantine
sudo chown -R clamav:clamav /var/virus-quarantine
sudo chmod 755 /var/virus-quarantine
```

## 4. Criar Diretório de Logs

```bash
sudo mkdir -p /var/log/clamav
sudo chown -R clamav:clamav /var/log/clamav
```

## 5. Ativar e Iniciar o Daemon ClamAV

```bash
sudo systemctl start clamav-daemon
sudo systemctl enable clamav-daemon
sudo systemctl status clamav-daemon
```

Se falhar, verifique os logs:

```bash
sudo journalctl -u clamav-daemon -xe
```

## 6. Testar o ClamAV

Teste rápido (apenas /home para não demorar):

```bash
sudo clamscan --infected --move=/var/virus-quarantine --exclude-dir="^/tmp" /home
```

---

## Configuração dos Alertas por E-mail

### 7. Instalar Dependência para Templates HTML

```bash
sudo apt install -y gettext-base
```

### 8. Criar Template HTML do Alerta

Crie a estrutura de diretórios e o arquivo de template:

```bash
sudo mkdir -p /opt/alerts/templates
sudo nano /opt/alerts/templates/alert.html
```

Adicione o conteúdo do template:

```html
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="pt-BR">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <meta name="x-apple-disable-message-reformatting" />
  <title>${TITLE}</title>
  <!--[if mso]>
  <noscript>
    <xml>
      <o:OfficeDocumentSettings>
        <o:PixelsPerInch>96</o:PixelsPerInch>
      </o:OfficeDocumentSettings>
    </xml>
  </noscript>
  <![endif]-->
  <style type="text/css">
    table, td { border-collapse: collapse; mso-table-lspace: 0pt; mso-table-rspace: 0pt; }
    img { border: 0; height: auto; line-height: 100%; outline: none; text-decoration: none; -ms-interpolation-mode: bicubic; }
    body { margin: 0; padding: 0; width: 100% !important; -webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; background-color: #f4f4f7; }
    @media only screen and (max-width: 620px) {
      .wrapper { width: 100% !important; max-width: 100% !important; }
      .content-padding { padding: 20px !important; }
      .mobile-font { font-size: 16px !important; }
    }
  </style>
</head>
<body style="margin: 0; padding: 0; background-color: #f4f4f7; font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;">
  <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" bgcolor="#f4f4f7">
    <tr>
      <td align="center" style="padding: 40px 10px;">
        <!--[if (gte mso 9)|(IE)]>
        <table role="presentation" align="center" border="0" cellspacing="0" cellpadding="0" width="600">
        <tr>
        <td align="center" valign="top" width="600">
        <![endif]-->
        <table role="presentation" class="wrapper" border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px; background-color: #ffffff; border-radius: 8px; border: 1px solid #eaeaec; box-shadow: 0 2px 4px rgba(0,0,0,0.05);">
          <tr>
            <td class="content-padding" style="padding: 30px 40px 20px 40px; border-bottom: 3px solid #dc2626;">
              <h1 style="margin: 0; font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 24px; font-weight: bold; color: #1f2937; line-height: 1.4;">
                ${TITLE}
              </h1>
              <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="margin-top: 10px;">
                <tr>
                  <td style="color: #6b7280; font-size: 13px; font-family: sans-serif;">
                    <strong>Data:</strong> ${DATE} &nbsp;|&nbsp; <strong>Servidor:</strong> ${HOST}
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td class="content-padding" style="padding: 30px 40px; background-color: #ffffff;">
              <div style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 16px; line-height: 1.6; color: #374151; white-space: pre-line;">
                ${MESSAGE}
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding: 20px 40px; background-color: #f9fafb; border-bottom-left-radius: 8px; border-bottom-right-radius: 8px; border-top: 1px solid #e5e7eb;">
              <p style="margin: 0; font-family: sans-serif; font-size: 12px; line-height: 1.5; color: #9ca3af; text-align: center;">
                Este é um alerta automático gerado pelo sistema.<br>
                Por favor, não responda a este e-mail.
              </p>
            </td>
          </tr>
        </table>
        <!--[if (gte mso 9)|(IE)]>
        </td>
        </tr>
        </table>
        <![endif]-->
        <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px;">
          <tr>
            <td align="center" style="padding-top: 20px; color: #9ca3af; font-size: 12px; font-family: sans-serif;">
              &copy; Monitoramento de Sistemas - ClamAV
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
```

Salve com `Ctrl+O`, `Enter`, `Ctrl+X`.

### 9. Criar Script de Envio de Alertas HTML

```bash
sudo nano /usr/local/bin/send_html_alert.sh
```

Adicione o conteúdo:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_PATH="${1:-/opt/alerts/templates/alert.html}"
RECIPIENT="${2:?Informe o e-mail de destino}"
SUBJECT="${3:-Alerta do servidor}"
TITLE="${4:-Alerta do servidor}"
MESSAGE="${5:-Mensagem não especificada}"

DATE="$(date '+%Y-%m-%d %H:%M:%S %Z')"
HOST="$(hostname)"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  echo "Template não encontrado: $TEMPLATE_PATH" >&2
  exit 1
fi

export TITLE MESSAGE DATE HOST

RENDERED_FILE="$(mktemp /tmp/alert-email-XXXXXX.html)"
envsubst '${TITLE} ${MESSAGE} ${DATE} ${HOST}' < "$TEMPLATE_PATH" > "$RENDERED_FILE"

cat "$RENDERED_FILE" \
  | mail -a "Content-Type: text/html; charset=UTF-8" \
         -s "$SUBJECT" \
         "$RECIPIENT"

rm -f "$RENDERED_FILE"
```

Salve e torne executável:

```bash
sudo chmod +x /usr/local/bin/send_html_alert.sh
```

### 10. Testar Envio de Alerta

```bash
/usr/local/bin/send_html_alert.sh \
  /opt/alerts/templates/alert.html \
  "seu@email.com" \
  "Teste ClamAV - $(hostname)" \
  "Teste de Alerta ClamAV" \
  "Este é um teste do sistema de alertas do ClamAV."
```

---

## Configuração do Monitoramento Automático

### 11. Configurar Cron para Varredura Diária

Abra o crontab:

```bash
sudo crontab -e
```

Adicione a linha (executa às 02:00 da manhã):

```bash
0 2 * * * /usr/bin/clamscan --infected --move=/var/virus-quarantine --exclude-dir="^/sys|^/proc|^/dev|^/run|^/var/lib/docker|^/boot|^/tmp" / >/var/log/clamav/daily-scan-$(date +\%Y\%m\%d).log 2>&1 && grep -q "Infected files: [1-9]" /var/log/clamav/daily-scan-$(date +\%Y\%m\%d).log && /usr/local/bin/send_html_alert.sh /opt/alerts/templates/alert.html "seu@email.com" "ClamAV ALERTA - $(hostname)" "Malware Detectado!" "Arquivos infectados foram encontrados e movidos para /var/virus-quarantine.<br/><br/>Verifique o log em: /var/log/clamav/daily-scan-$(date +\%Y\%m\%d).log" || true
```

**Substitua `seu@email.com` pelo seu e-mail real.**

Salve com `Ctrl+O`, `Enter`, `Ctrl+X`.

---

## Teste Manual da Varredura Completa

Execute para testar todo o fluxo:

```bash
sudo /usr/bin/clamscan --infected --move=/var/virus-quarantine --exclude-dir="^/sys|^/proc|^/dev|^/run|^/var/lib/docker|^/boot|^/tmp" / >/var/log/clamav/test-scan.log 2>&1
cat /var/log/clamav/test-scan.log
```

**Nota:** A varredura completa pode levar de 10 a 30 minutos dependendo do servidor.

---

## Notas Importantes

| Item | Descrição |
| :-- | :-- |
| **clamscan vs clamdscan** | Use `clamscan` para varreduras agendadas. O `clamdscan` não suporta `--exclude-dir`. |
| **Diretórios excluídos** | `/sys`, `/proc`, `/dev`, `/run`, `/var/lib/docker`, `/boot`, `/tmp` são excluídos para evitar erros e falsos positivos. |
| **Quarentena** | Arquivos infectados são movidos para `/var/virus-quarantine` automaticamente. |
| **Logs** | Logs diários são salvos em `/var/log/clamav/daily-scan-YYYYMMDD.log`. |
| **Alertas** | E-mails HTML são enviados **apenas** quando malware é detectado. |

---

## Troubleshooting

| Problema | Solução |
| :-- | :-- |
| "No such file or directory" no socket | Execute `sudo systemctl restart clamav-daemon` |
| Daemon não inicia | Verifique com `sudo journalctl -u clamav-daemon -xe` |
| E-mail não enviado | Verifique logs do Postfix: `sudo tail -f /var/log/mail.log` |
| Varredura muito lenta | Reduza o escopo ou agende para horários de baixa atividade |
| Permissão negada na quarentena | Execute `sudo chown -R clamav:clamav /var/virus-quarantine` |

---

## Resumo dos Comandos de Verificação

```bash
# Status do ClamAV
sudo systemctl status clamav-daemon
sudo systemctl status clamav-freshclam

# Verificar logs do ClamAV
ls -la /var/log/clamav/

# Verificar quarentena
ls -la /var/virus-quarantine/

# Verificar cron
sudo crontab -l

# Testar envio de e-mail manualmente
/usr/local/bin/send_html_alert.sh /opt/alerts/templates/alert.html "seu@email.com" "Teste" "Título Teste" "Mensagem de teste"
```

---

Pronto! O ClamAV está instalado, configurado para varredura diária automática e enviará alertas profissionais em HTML sempre que detectar malware.
