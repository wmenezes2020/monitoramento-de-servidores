# Instalador Unico de Monitoramento e Alertas

Este documento descreve o **script de instalacao completa** `install-monitoring.sh`, que configura em um unico fluxo: servico de e-mail (SMTP2Go), **notificacoes por Telegram**, antivirus (ClamAV), templates de alerta em HTML e monitoramento de CPU, Memoria, Disco e existencia de virus, com alertas por e-mail e Telegram.

---

## O que o instalador faz

1. **Servico de E-mail (Postfix + SMTP2Go)**
   - Instala Postfix, libsasl2-modules, mailutils, gettext-base
   - Configura relay SMTP (porta informada), credenciais e masquerade (remetente)

2. **Notificacoes por Telegram**
   - Pede apenas o **Token do Bot** (obtido em @BotFather no Telegram)
   - Obtem o Chat ID automaticamente apos o usuario enviar `/start` ao bot
   - Cria `send_telegram_alert.sh` e `telegram-get-chat-id.sh` (para obter/atualizar Chat ID depois)
   - Config em `/opt/monitoring/telegram.conf`
   - Todos os alertas (CPU, RAM, Disco, ClamAV) sao enviados tambem para o Telegram quando configurado

3. **Antivirus (ClamAV)**
   - Instala clamav e clamav-daemon
   - Cria diretorio de quarentena e logs
   - Agenda varredura diaria (02:00) e envia alerta HTML e Telegram se encontrar virus

4. **Templates de E-mail HTML**
   - Cria `/opt/alerts/templates/`: `alert.html`, `cpu-alert.html`, `memory-alert.html`, `disk-alert.html`, `clamav-alert.html`

5. **Scripts de monitoramento**
   - `send_html_alert.sh` – envia e-mail HTML a partir de template
   - `send_telegram_alert.sh` – envia mensagem para o Telegram (usa config em `/opt/monitoring/telegram.conf`)
   - `monitor_cpu.sh` – alerta quando CPU > 80% (e-mail + Telegram)
   - `monitor_memory.sh` – alerta quando RAM > 80% (e-mail + Telegram)
   - `monitor_disk.sh` – alerta quando uso de disco > 80% (e-mail + Telegram)

6. **Crontab**
   - CPU, Memoria e Disco: execucao a cada 5 minutos
   - ClamAV: varredura diaria às 02:00 e envio de alerta (e-mail + Telegram) apenas se houver infectados

---

## Dados solicitados durante a instalacao

| Pergunta | Exemplo | Obrigatorio |
|----------|---------|-------------|
| Porta do servidor SMTP | 587 ou 2525 | Nao (padrao 587) |
| Dominio ou nome do servidor | meuservidor.com | Nao (padrao hostname) |
| Usuario SMTP | usuario SMTP2Go | Sim |
| Senha SMTP | *** | Sim |
| E-mail remetente (verificado no SMTP2Go) | alertas@seudominio.com | Sim |
| E-mail(s) de destino para alertas | email1@gmail.com,email2@gmail.com | Sim |
| **Token do Bot do Telegram** | (deixe vazio para nao usar) | Nao |

Os destinatarios de e-mail podem ser varios, separados por **virgula** (sem espacos).

**Telegram:** Se informar o token, o instalador pedira para voce enviar o comando **/start** ao seu bot no app Telegram; em seguida o Chat ID e obtido automaticamente. Se nao aparecer nenhuma mensagem do bot, apos a instalacao execute: `sudo /usr/local/bin/telegram-get-chat-id.sh`.

---

## Pre-requisitos

- Sistema Linux (Ubuntu/Debian)
- Acesso root (sudo)
- Credenciais SMTP2Go (ou outro SMTP compativel na mesma configuracao)
- E-mail remetente verificado no SMTP2Go
- Conectividade com a internet para instalar pacotes e enviar e-mail
- **Telegram (opcional):** criar um bot em [@BotFather](https://t.me/BotFather) e copiar o token fornecido

---

## Como executar o instalador

### Opcao 1: Arquivo local

Se voce ja baixou o script para o servidor:

```bash
chmod +x install-monitoring.sh
sudo ./install-monitoring.sh
```

### Opcao 2: Via curl (URL publica)

Recomendado para executar direto a partir de um link. Substitua `URL_DO_SCRIPT` pela URL real do arquivo `install-monitoring.sh` (por exemplo, no GitHub raw ou no seu servidor).

```bash
sudo bash -c "$(curl -sL 'URL_DO_SCRIPT')"
```

**Exemplo com URL ficticia (substitua pela sua):**

```bash
sudo bash -c "$(curl -sL 'https://raw.githubusercontent.com/seu-usuario/seu-repo/main/install-monitoring.sh')"
```

**Exemplo usando arquivo hospedado no seu dominio:**

```bash
sudo bash -c "$(curl -sL 'https://seudominio.com/scripts/install-monitoring.sh')"
```

### Opcao 3: Download e execucao em dois passos

```bash
curl -sL 'URL_DO_SCRIPT' -o install-monitoring.sh
sudo bash install-monitoring.sh
```

---

## Exemplo pratico de uso (curl)

Qualquer pessoa com acesso SSH ao servidor e permissao de root pode rodar o instalador assim:

1. Conectar no servidor:
   ```bash
   ssh usuario@ip-do-servidor
   ```

2. Executar o instalador (substitua a URL pela do seu script):
   ```bash
   sudo bash -c "$(curl -sL 'https://exemplo.com/install-monitoring.sh')"
   ```

3. Responder as perguntas:
   - Porta SMTP: `587` ou `2525`
   - Dominio: Enter para usar o hostname ou informar o dominio
   - Usuario SMTP: o usuario do SMTP2Go
   - Senha SMTP: a senha
   - E-mail remetente: ex. `alertas@seudominio.com`
   - E-mails de destino: `admin@empresa.com,ti@empresa.com`
   - Token do Bot Telegram: cole o token do @BotFather ou Enter para pular
   - Se informou token: enviar **/start** ao bot no Telegram e pressionar Enter no terminal

4. Aguardar o fim da instalacao e conferir o e-mail de teste e, se configurou Telegram, a mensagem de teste no app.

---

## Apos a instalacao

- **Crontab:** `sudo crontab -l` – lista os agendamentos.
- **Logs de e-mail:** `sudo tail -f /var/log/mail.log`
- **Logs ClamAV:** `ls /var/log/clamav/`
- **Quarentena:** `ls /var/virus-quarantine/`
- **Testar envio manual (e-mail):**  
  `echo "Teste" | mail -s "Assunto" seu@email.com`  
  ou  
  `/usr/local/bin/send_html_alert.sh /opt/alerts/templates/alert.html seu@email.com "Assunto" "Titulo" "Mensagem"`

- **Telegram:** Config em `/opt/monitoring/telegram.conf`. Se o Chat ID nao foi obtido na instalacao: `sudo /usr/local/bin/telegram-get-chat-id.sh`. Testar envio: `sudo /usr/local/bin/send_telegram_alert.sh "Mensagem de teste"`

---

## Relacao com a documentacao

O instalador segue as orientacoes dos documentos:

- **Instalar Servico de E-Mail no Servidor.md** – Postfix, SMTP2Go, masquerade, templates e envio HTML.
- **Instalar o ClamV + Monitoramento.md** – ClamAV, quarentena, clamscan, alerta por e-mail.
- **Configurar Monitoramento de CPU e Memoria.md** – CPU/RAM com threshold 80%, templates e cron.
- **Configurar Monitoramento de CPU, Memoria e Disco.md** – inclusao do monitor de disco (80%) e template de disco.

Assim, um unico script reproduz o que seria feito manualmente conforme essa documentacao.
