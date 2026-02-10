# Instalar Servico de E-Mail no Servidor Linux

Guia completo para configurar o Postfix como relay SMTP via SMTP2GO no Linux, permitindo envio de alertas por e-mail em texto simples ou HTML profissional.

**Tempo estimado:** ~20 minutos  
**Compatibilidade:** Ubuntu/Debian

> **Instalador automatico:** Para configurar e-mail + ClamAV + monitoramento (CPU, RAM, Disco) em um unico passo, use o script `install-monitoring.sh`. Veja o documento **Atualize essa documentacao com a criacao do script.md** e a secao de execucao via curl.

---

## Indice

1. [Instalacao do Postfix e SMTP2GO](#1-instalacao-do-postfix-e-smtp2go)
2. [Configuracao do Postfix](#2-configuracao-do-postfix)
3. [Credenciais SMTP2GO](#3-credenciais-smtp2go)
4. [Masquerade - Mudanca de Remetente](#4-masquerade---mudanca-de-remetente-recomendado)
5. [Teste de Envio Simples](#5-teste-de-envio-simples-texto-puro)
6. [Configurar Envio de E-mail HTML](#6-configurar-envio-de-e-mail-html)
7. [Templates HTML Disponiveis](#7-templates-html-disponiveis)
8. [Exemplos de Uso](#8-exemplos-de-uso)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Instalacao do Postfix e SMTP2GO

### Instalar pacotes necessarios

```bash
sudo apt update
sudo apt install -y postfix libsasl2-modules mailutils gettext-base
```

Durante a instalacao do Postfix:
- Escolha **"Internet Site"**
- System mail name: digite o nome do seu servidor ou dominio

> Se ja estiver instalado, reconfigure com: `sudo dpkg-reconfigure postfix`

---

## 2. Configuracao do Postfix

Edite o arquivo de configuracao principal:

```bash
sudo nano /etc/postfix/main.cf
```

Adicione no **final** do arquivo:

```
relayhost = [mail.smtp2go.com]:2525
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
smtp_tls_wrappermode = no
header_size_limit = 4096000
```

Salve com `Ctrl+O`, `Enter`, `Ctrl+X`.

---

## 3. Credenciais SMTP2GO

### Criar arquivo de credenciais

```bash
sudo nano /etc/postfix/sasl_passwd
```

Adicione **uma linha** (substitua `USER` e `PASS` pelas suas credenciais do SMTP2GO):

```
[mail.smtp2go.com]:2525 USER:PASS
```

### Proteger e compilar credenciais

```bash
sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd
sudo chown root:root /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
```

### Reiniciar e habilitar Postfix

```bash
sudo systemctl restart postfix
sudo systemctl enable postfix
```

---

## 4. Masquerade - Mudanca de Remetente (RECOMENDADO)

Configure o Postfix para usar um remetente verificado no SMTP2GO, evitando rejeicoes.

### Criar arquivo de masquerade

```bash
sudo nano /etc/postfix/generic
```

Adicione (substitua `alertas@seudominio.com` pelo seu e-mail verificado no SMTP2GO e `seu-servidor` pelo hostname do seu servidor):

```
root@seu-servidor           alertas@seudominio.com
@seu-servidor               alertas@seudominio.com
```

### Compilar e ativar masquerade

```bash
sudo postmap /etc/postfix/generic
sudo nano /etc/postfix/main.cf
```

Adicione no final do `main.cf`:

```
smtp_generic_maps = hash:/etc/postfix/generic
```

### Verificar e reiniciar

```bash
sudo postfix check
sudo systemctl restart postfix
```

---

## 5. Teste de Envio Simples (Texto Puro)

### Teste basico

```bash
echo "Teste de envio - $(date)" | mail -s "Teste SMTP2GO $(hostname)" seu@email.com
```

### Verificar logs

```bash
sudo tail -f /var/log/mail.log
```

O e-mail deve ser enviado em segundos. Procure por `status=sent` nos logs.

### Teste com multiplos destinatarios

```bash
echo "Teste multiplos destinatarios" | mail -s "Teste $(hostname)" email1@gmail.com,email2@gmail.com
```

---

## 6. Configurar Envio de E-mail HTML

### Criar estrutura de diretorios

```bash
sudo mkdir -p /opt/alerts/templates
```

### Criar script de envio HTML

```bash
sudo nano /usr/local/bin/send_html_alert.sh
```

Adicione o conteudo:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_PATH="${1:-/opt/alerts/templates/alert.html}"
RECIPIENT="${2:?Informe o e-mail de destino}"
SUBJECT="${3:-Alerta do servidor}"
TITLE="${4:-Alerta do servidor}"
MESSAGE="${5:-Mensagem nao especificada}"

DATE="$(date '+%Y-%m-%d %H:%M:%S %Z')"
HOST="$(hostname)"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  echo "Template nao encontrado: $TEMPLATE_PATH" >&2
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

### Tornar executavel

```bash
sudo chmod +x /usr/local/bin/send_html_alert.sh
```

---

## 7. Templates HTML Disponiveis

### Template Generico (alert.html)

Crie o template base para alertas gerais:

```bash
sudo nano /opt/alerts/templates/alert.html
```

```html
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="pt-BR">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
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
    body { margin: 0; padding: 0; width: 100% !important; background-color: #f4f4f7; }
    @media only screen and (max-width: 620px) {
      .wrapper { width: 100% !important; max-width: 100% !important; }
      .content-padding { padding: 20px !important; }
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
            <td class="content-padding" style="padding: 30px 40px 20px 40px; border-bottom: 3px solid #3b82f6;">
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
              <div style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 16px; line-height: 1.6; color: #374151;">
                ${MESSAGE}
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding: 20px 40px; background-color: #f9fafb; border-bottom-left-radius: 8px; border-bottom-right-radius: 8px; border-top: 1px solid #e5e7eb;">
              <p style="margin: 0; font-family: sans-serif; font-size: 12px; line-height: 1.5; color: #9ca3af; text-align: center;">
                Este e um alerta automatico gerado pelo sistema.<br>
                Por favor, nao responda a este e-mail.
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
              &copy; Monitoramento de Sistemas
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
```

### Template para CPU (cpu-alert.html)

```bash
sudo nano /opt/alerts/templates/cpu-alert.html
```

```html
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="pt-BR">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
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
    body { margin: 0; padding: 0; width: 100% !important; background-color: #f4f4f7; }
    @media only screen and (max-width: 620px) {
      .wrapper { width: 100% !important; max-width: 100% !important; }
      .content-padding { padding: 20px !important; }
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
            <td class="content-padding" style="padding: 30px 40px 20px 40px; border-bottom: 4px solid #f97316;">
              <h1 style="margin: 0; font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 24px; font-weight: bold; color: #1f2937; line-height: 1.4;">
                ${TITLE}
              </h1>
              <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="margin-top: 15px;">
                <tr>
                  <td style="color: #6b7280; font-size: 13px; font-family: sans-serif;">
                    <strong>Data:</strong> ${DATE} &nbsp;|&nbsp; <strong>Servidor:</strong> ${HOST}
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding: 25px 40px; background-color: #fff7ed;">
              <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%">
                <tr>
                  <td align="center">
                    <div style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 48px; font-weight: bold; color: #ea580c;">
                      CPU
                    </div>
                    <div style="font-family: sans-serif; font-size: 14px; color: #9a3412; margin-top: 5px; text-transform: uppercase; letter-spacing: 1px;">
                      Uso Elevado Detectado
                    </div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td class="content-padding" style="padding: 30px 40px; background-color: #ffffff;">
              <div style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 16px; line-height: 1.6; color: #374151;">
                ${MESSAGE}
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding: 20px 40px; background-color: #f9fafb; border-bottom-left-radius: 8px; border-bottom-right-radius: 8px; border-top: 1px solid #e5e7eb;">
              <p style="margin: 0; font-family: sans-serif; font-size: 12px; line-height: 1.5; color: #9ca3af; text-align: center;">
                Este e um alerta automatico gerado pelo sistema.<br>
                Por favor, nao responda a este e-mail.
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
              &copy; Monitoramento de Sistemas - CPU
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
```

### Template para Memoria (memory-alert.html)

```bash
sudo nano /opt/alerts/templates/memory-alert.html
```

```html
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="pt-BR">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
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
    body { margin: 0; padding: 0; width: 100% !important; background-color: #f4f4f7; }
    @media only screen and (max-width: 620px) {
      .wrapper { width: 100% !important; max-width: 100% !important; }
      .content-padding { padding: 20px !important; }
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
            <td class="content-padding" style="padding: 30px 40px 20px 40px; border-bottom: 4px solid #8b5cf6;">
              <h1 style="margin: 0; font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 24px; font-weight: bold; color: #1f2937; line-height: 1.4;">
                ${TITLE}
              </h1>
              <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="margin-top: 15px;">
                <tr>
                  <td style="color: #6b7280; font-size: 13px; font-family: sans-serif;">
                    <strong>Data:</strong> ${DATE} &nbsp;|&nbsp; <strong>Servidor:</strong> ${HOST}
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding: 25px 40px; background-color: #f5f3ff;">
              <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%">
                <tr>
                  <td align="center">
                    <div style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 48px; font-weight: bold; color: #7c3aed;">
                      RAM
                    </div>
                    <div style="font-family: sans-serif; font-size: 14px; color: #5b21b6; margin-top: 5px; text-transform: uppercase; letter-spacing: 1px;">
                      Uso Elevado Detectado
                    </div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td class="content-padding" style="padding: 30px 40px; background-color: #ffffff;">
              <div style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 16px; line-height: 1.6; color: #374151;">
                ${MESSAGE}
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding: 20px 40px; background-color: #f9fafb; border-bottom-left-radius: 8px; border-bottom-right-radius: 8px; border-top: 1px solid #e5e7eb;">
              <p style="margin: 0; font-family: sans-serif; font-size: 12px; line-height: 1.5; color: #9ca3af; text-align: center;">
                Este e um alerta automatico gerado pelo sistema.<br>
                Por favor, nao responda a este e-mail.
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
              &copy; Monitoramento de Sistemas - RAM
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
```

---

## 8. Exemplos de Uso

### Teste de E-mail em Texto Simples

```bash
echo "Este e um teste de envio simples - $(date)" | mail -s "Teste Simples $(hostname)" seu@email.com
```

### Teste de E-mail HTML com Template Generico

```bash
/usr/local/bin/send_html_alert.sh \
  /opt/alerts/templates/alert.html \
  "seu@email.com" \
  "Teste de Alerta HTML - $(hostname)" \
  "Teste de Alerta" \
  "Este e um teste do sistema de alertas em HTML.<br/><br/>Se voce esta recebendo este e-mail, a configuracao esta funcionando corretamente."
```

### Teste de E-mail HTML com Template de CPU

```bash
/usr/local/bin/send_html_alert.sh \
  /opt/alerts/templates/cpu-alert.html \
  "seu@email.com" \
  "ALERTA CPU - $(hostname)" \
  "CPU em 85% (CRITICO)" \
  "Uso medio CPU: <strong>85%</strong> (threshold: 80%)<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Top 5 Processos:</strong><br/><pre>processo1    25%  1234<br/>processo2    20%  5678<br/>processo3    15%  9012</pre>"
```

### Teste de E-mail HTML com Template de Memoria

```bash
/usr/local/bin/send_html_alert.sh \
  /opt/alerts/templates/memory-alert.html \
  "seu@email.com" \
  "ALERTA RAM - $(hostname)" \
  "Memoria em 90% (CRITICO)" \
  "Uso RAM: <strong>90%</strong> (threshold: 80%)<br/>Total: 8000MB | Usado: 7200MB<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Top 5 Processos por RAM:</strong><br/><pre>processo1    30%  1234<br/>processo2    25%  5678<br/>processo3    20%  9012</pre>"
```

### Envio para Multiplos Destinatarios

```bash
/usr/local/bin/send_html_alert.sh \
  /opt/alerts/templates/alert.html \
  "email1@gmail.com,email2@gmail.com" \
  "Alerta Multiplos Destinatarios" \
  "Alerta de Teste" \
  "Este alerta foi enviado para multiplos destinatarios."
```

---

## 9. Troubleshooting

### Problemas Comuns e Solucoes

| Problema | Solucao |
| :-- | :-- |
| "Relay access denied" | Verifique USER/PASS em `/etc/postfix/sasl_passwd` e execute `sudo postmap /etc/postfix/sasl_passwd` |
| Porta 587 bloqueada | Altere para porta 2525: `[mail.smtp2go.com]:2525` em `main.cf` e `sasl_passwd` |
| E-mail nao enviado | Verifique logs: `sudo tail -f /var/log/mail.log` |
| Logs vazios | Execute `sudo postconf -n` para ver configuracao ativa |
| Template nao encontrado | Verifique se o arquivo existe em `/opt/alerts/templates/` |
| E-mail rejeitado por remetente | Configure o masquerade (secao 4) com e-mail verificado no SMTP2GO |

### Comandos de Verificacao

```bash
# Status do Postfix
sudo systemctl status postfix

# Ver configuracao ativa
sudo postconf -n

# Ver fila de e-mails
mailq

# Forcar envio da fila
sudo postfix flush

# Ver logs em tempo real
sudo tail -f /var/log/mail.log

# Verificar configuracao do Postfix
sudo postfix check

# Listar templates disponiveis
ls -la /opt/alerts/templates/
```

### Testar Conectividade SMTP

```bash
# Testar porta 587
nc -zv mail.smtp2go.com 587

# Testar porta alternativa 2525
nc -zv mail.smtp2go.com 2525
```

---

## Resumo dos Arquivos Criados

| Arquivo | Descricao |
| :-- | :-- |
| `/etc/postfix/main.cf` | Configuracao principal do Postfix |
| `/etc/postfix/sasl_passwd` | Credenciais do SMTP2GO |
| `/etc/postfix/generic` | Mapeamento de remetentes (masquerade) |
| `/usr/local/bin/send_html_alert.sh` | Script para envio de e-mails HTML |
| `/opt/alerts/templates/alert.html` | Template generico (azul) |
| `/opt/alerts/templates/cpu-alert.html` | Template para alertas de CPU (laranja) |
| `/opt/alerts/templates/memory-alert.html` | Template para alertas de memoria (roxo) |

---

## Variaveis Disponiveis nos Templates

| Variavel | Descricao |
| :-- | :-- |
| `${TITLE}` | Titulo do alerta (passado como parametro) |
| `${MESSAGE}` | Mensagem do alerta (passado como parametro, suporta HTML) |
| `${DATE}` | Data/hora do envio (gerado automaticamente) |
| `${HOST}` | Nome do servidor (gerado automaticamente) |

---

Pronto! O servico de e-mail esta configurado e pronto para enviar alertas em texto simples ou HTML profissional via SMTP2GO.
