# Configurar Monitoramento de CPU, Memória e Disco

Guia completo para configurar monitoramento de CPU, Memória e **espaço em disco por partição** no Linux com alertas por e-mail em HTML quando o uso ultrapassar 80%.[^1]

**Tempo estimado:** ~20 minutos
**Pré-requisitos:**

- Postfix configurado com SMTP2GO (ou outro relay SMTP funcional)[^1]
- Script `send_html_alert.sh` já configurado (veja o guia de instalação do ClamAV)[^1]

***

## 1. Instalar Dependências

```bash
sudo apt update
sudo apt install -y sysstat bc
```

O `sysstat` inclui o `mpstat` para medição precisa de CPU.[^1]

***

## 2. Criar Templates HTML

### Template para Alertas de CPU

```bash
sudo mkdir -p /opt/alerts/templates
sudo nano /opt/alerts/templates/cpu-alert.html
```

Adicione o conteúdo:

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

Salve com `Ctrl+O`, `Enter`, `Ctrl+X`.[^1]

### Template para Alertas de Memória

```bash
sudo nano /opt/alerts/templates/memory-alert.html
```

Adicione o conteúdo:

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

Salve com `Ctrl+O`, `Enter`, `Ctrl+X`.[^1]

***

## Monitoramento de CPU

### 3. Criar Script de Monitoramento de CPU

```bash
sudo nano /usr/local/bin/monitor_cpu.sh
```

Adicione o conteúdo:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_PATH="/opt/alerts/templates/cpu-alert.html"
RECIPIENTS="seu@email.com"
CPU_THRESHOLD=80

# CPU % médio (mpstat 1s, 2 amostras)
CPU_USAGE=$(timeout 3 mpstat 1 2 2>/dev/null | awk '/Average/ {print 100 - $NF}')

if [[ $(echo "$CPU_USAGE > $CPU_THRESHOLD" | bc -l) == 1 ]]; then
  TOP_PROCS=$(ps aux --sort=-%cpu | head -6 | tail -5 | awk '{printf "%-12s %4s%% %s\n", $11, $3, $2}')
  
  /usr/local/bin/send_html_alert.sh \
    "$TEMPLATE_PATH" \
    "$RECIPIENTS" \
    "ALERTA CPU ${CPU_USAGE}% - $(hostname)" \
    "CPU em ${CPU_USAGE}% (CRITICO)" \
    "Uso medio CPU: <strong>${CPU_USAGE}%</strong> (threshold: ${CPU_THRESHOLD}%)<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Top 5 Processos:</strong><br/><pre>${TOP_PROCS}</pre>"
fi
```

Substitua `seu@email.com` pelo seu e-mail real.

Para múltiplos destinatários, use vírgula: `email1@gmail.com,email2@gmail.com`.[^1]

Salve e torne executável:

```bash
sudo chmod +x /usr/local/bin/monitor_cpu.sh
```


### 4. Testar Script de CPU

```bash
sudo /usr/local/bin/monitor_cpu.sh
```

Para forçar um teste (mesmo sem CPU alta), edite temporariamente o `CPU_THRESHOLD=0`.[^1]

***

## Monitoramento de Memória

### 5. Criar Script de Monitoramento de Memória

```bash
sudo nano /usr/local/bin/monitor_memory.sh
```

Adicione o conteúdo:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_PATH="/opt/alerts/templates/memory-alert.html"
RECIPIENTS="seu@email.com"
MEM_THRESHOLD=80

# Mem % usada (used + buff/cache)
MEM_INFO=$(free | grep Mem)
TOTAL_MEM=$(echo $MEM_INFO | awk '{print $2}')
USED_MEM=$(echo $MEM_INFO | awk '{print $3 + $6}')
MEM_USAGE=$(echo "scale=1; ($USED_MEM / $TOTAL_MEM) * 100" | bc -l)

if [[ $(echo "$MEM_USAGE > $MEM_THRESHOLD" | bc -l) == 1 ]]; then
  TOP_MEM=$(ps aux --sort=-%mem | head -6 | tail -5 | awk '{printf "%-12s %4s%% %s\n", $11, $4, $2}')
  TOTAL_MB=$(echo "scale=0; $TOTAL_MEM / 1024" | bc)
  USED_MB=$(echo "scale=0; $USED_MEM / 1024" | bc)
  
  /usr/local/bin/send_html_alert.sh \
    "$TEMPLATE_PATH" \
    "$RECIPIENTS" \
    "ALERTA RAM ${MEM_USAGE}% - $(hostname)" \
    "Memoria em ${MEM_USAGE}% (CRITICO)" \
    "Uso RAM: <strong>${MEM_USAGE}%</strong> (threshold: ${MEM_THRESHOLD}%)<br/>Total: ${TOTAL_MB}MB | Usado: ${USED_MB}MB<br/><br/>Data/Hora: <strong>$(date)</strong><br/><br/><strong>Top 5 Processos por RAM:</strong><br/><pre>${TOP_MEM}</pre>"
fi
```

Salve e torne executável:

```bash
sudo chmod +x /usr/local/bin/monitor_memory.sh
```


### 6. Testar Script de Memória

```bash
sudo /usr/local/bin/monitor_memory.sh
```

Para forçar um teste, edite temporariamente o `MEM_THRESHOLD=0`.[^1]

***

## Configurar Monitoramento Automático

### 7. Adicionar Crons

Abra o crontab:

```bash
sudo crontab -e
```

Adicione as linhas (executa a cada 5 minutos):

```bash
# Monitoramento de CPU a cada 5 minutos
*/5 * * * * /usr/local/bin/monitor_cpu.sh

# Monitoramento de Memória a cada 5 minutos
*/5 * * * * /usr/local/bin/monitor_memory.sh
```

Salve com `Ctrl+O`, `Enter`, `Ctrl+X`.[^1]

***

## Entendendo os Thresholds

### CPU (80%)

| Métrica | Descrição |
| :-- | :-- |
| Método | `mpstat` mede uso médio real de todos os cores |
| Threshold | Alerta quando uso médio > 80% |
| Precisão | Calcula média de 2 amostras em 1 segundo cada |

### Memória (80%)

| Métrica | Descrição |
| :-- | :-- |
| Método | `free` mede RAM total e usada |
| Cálculo | (Used + Buff/Cache) / Total * 100 |
| Threshold | Alerta quando uso > 80% |


***

## Ajustar Thresholds (Opcional)

Para alterar os limites de alerta, edite os scripts:

**CPU:**

```bash
sudo nano /usr/local/bin/monitor_cpu.sh
# Altere: CPU_THRESHOLD=80 para o valor desejado
```

**Memória:**

```bash
sudo nano /usr/local/bin/monitor_memory.sh
# Altere: MEM_THRESHOLD=80 para o valor desejado
```


***

## Troubleshooting

| Problema | Solução |
| :-- | :-- |
| `mpstat: command not found` | Execute `sudo apt install -y sysstat` |
| `bc: command not found` | Execute `sudo apt install -y bc` |
| Script não envia e-mail | Verifique se `send_html_alert.sh` está funcionando |
| E-mail não chega | Verifique logs: `sudo tail -f /var/log/mail.log` |
| Threshold incorreto | Verifique o valor de `CPU_THRESHOLD` ou `MEM_THRESHOLD` |


***

## Resumo dos Comandos de Verificação

```bash
# Verificar uso atual de CPU
mpstat 1 2

# Verificar uso atual de Memória
free -h

# Listar crons ativos
sudo crontab -l

# Testar script de CPU manualmente
sudo /usr/local/bin/monitor_cpu.sh

# Testar script de Memória manualmente
sudo /usr/local/bin/monitor_memory.sh

# Ver logs do sistema
sudo tail -f /var/log/syslog

# Ver logs de e-mail
sudo tail -f /var/log/mail.log
```


***

## Por que 5 minutos de intervalo?

- Evita spam de alertas: se a CPU subir momentaneamente, você não receberá dezenas de e-mails.[^1]
- Load average já é uma média, então verificar a cada minuto pode ser redundante.[^1]
- Balanceia resposta vs. ruído: 5 minutos é tempo suficiente para detectar problemas reais sem alertas falsos.[^1]

Para ambientes críticos que precisam de resposta mais rápida, altere `*/5` para `*/2` (a cada 2 minutos) ou `*/1` (a cada minuto).[^1]

***

## Monitoramento de Disco (por partição)

Guia para configurar monitoramento de **espaço em disco por partição**, com alerta por e-mail em HTML quando o uso ultrapassar 80%.[^1]

### 1. Criar Template HTML de Disco

```bash
sudo mkdir -p /opt/alerts/templates
sudo nano /opt/alerts/templates/disk-alert.html
```

Conteúdo do template:

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
            <td class="content-padding" style="padding: 30px 40px 20px 40px; border-bottom: 4px solid #0ea5e9;">
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
            <td style="padding: 25px 40px; background-color: #e0f2fe;">
              <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%">
                <tr>
                  <td align="center">
                    <div style="font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 48px; font-weight: bold; color: #0284c7;">
                      DISCO
                    </div>
                    <div style="font-family: sans-serif; font-size: 14px; color: #075985; margin-top: 5px; text-transform: uppercase; letter-spacing: 1px;">
                      Espaço em Disco Crítico
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
              &copy; Monitoramento de Sistemas - Disco
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
```

Salve com `Ctrl+O`, `Enter`, `Ctrl+X`.[^1]

***

### 2. Criar Script de Monitoramento de Disco

Este script verifica **todas as partições montadas** (exceto sistemas pseudo-filesystem) e dispara um e-mail para cada partição cujo uso ultrapassar 80%.[^1]

```bash
sudo nano /usr/local/bin/monitor_disk.sh
```

Conteúdo:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_PATH="/opt/alerts/templates/disk-alert.html"
RECIPIENTS="seu@email.com"
DISK_THRESHOLD=80

# Ignora tmpfs, devtmpfs, squashfs, etc.
df -P -x tmpfs -x devtmpfs -x squashfs | tail -n +2 | while read -r FS SIZE USED AVAIL PCT MOUNT; do
  # PCT vem no formato "85%" -> remover o '%'
  USAGE=${PCT%%%}

  if [[ "$USAGE" -gt "$DISK_THRESHOLD" ]]; then
    HOSTNAME=$(hostname)
    NOW=$(date)

    MESSAGE="Particao: <strong>${MOUNT}</strong><br/>
Dispositivo: <strong>${FS}</strong><br/>
Uso de disco: <strong>${USAGE}%</strong> (threshold: ${DISK_THRESHOLD}%)<br/>
Espaco total: ${SIZE}K | Usado: ${USED}K | Livre: ${AVAIL}K<br/><br/>
Data/Hora: <strong>${NOW}</strong>"

    /usr/local/bin/send_html_alert.sh \
      "$TEMPLATE_PATH" \
      "$RECIPIENTS" \
      "ALERTA DISCO ${USAGE}% - ${HOSTNAME} (${MOUNT})" \
      "Disco em ${USAGE}% (CRITICO) em ${MOUNT}" \
      "$MESSAGE"
  fi
done
```

Ajuste `DISK_THRESHOLD=80` se quiser outro limite, e edite `RECIPIENTS` com seu e-mail (ou lista separada por vírgulas).[^1]

Torne o script executável:

```bash
sudo chmod +x /usr/local/bin/monitor_disk.sh
```


***

### 3. Testar Script de Disco

```bash
sudo /usr/local/bin/monitor_disk.sh
```

Para forçar um teste em ambiente de lab, altere temporariamente `DISK_THRESHOLD=0`.[^1]

***

### 4. Adicionar Cron de Disco

No mesmo `crontab` onde já estão CPU e Memória:

```bash
sudo crontab -e
```

Adicione:

```bash
# Monitoramento de Disco a cada 5 minutos
*/5 * * * * /usr/local/bin/monitor_disk.sh
```

Assim, CPU, Memória e Disco serão verificados com o mesmo intervalo e política de threshold (80%), cada um com seu template de e-mail dedicado.[^1]

