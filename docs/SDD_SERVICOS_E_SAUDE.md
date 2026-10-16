# SDD: conta de envio vinda do painel, e saúde da máquina no histórico

Versão 2.5.0.

## Problema

### 1. Servidor que já tem serviço de e-mail ficava sem alerta por e-mail

O instalador procura Postfix, Exim, Sendmail e cPanel antes de configurar
qualquer coisa (`detect_mail_conflict`). Achando um deles, ele não instala e
não configura, para não brigar com o que já está rodando.

A proteção é correta. O custo não aparecia em lugar nenhum: o servidor ficava
**sem alerta por e-mail, em silêncio**. Quem tem painel de hospedagem, que vem
com Exim, nunca recebeu um e-mail do monitoramento.

### 2. A mesma credencial repetida em cada máquina

Remetente, token do bot e chat ID eram cadastro de cada servidor. Vinte
servidores com a mesma conta de envio tinham a mesma senha digitada vinte
vezes, e trocar a senha era visitar vinte telas.

### 3. A instalação perguntava o que o painel já sabia

Mesmo em servidor que seria conectado ao painel, o instalador pedia porta,
usuário, senha, remetente e destinatários.

### 4. O painel não mostrava se a máquina estava dando conta

Havia CPU, memória e disco. Não havia fila de processos nas três janelas,
quantos programas estavam rodando, nem há quanto tempo a máquina estava
ligada: justamente o que separa "o servidor está lento" de "o servidor está
com trabalho demais".

## Objetivo

1. Servidor com qualquer serviço de e-mail instalado volta a mandar alerta por
   e-mail, sem que nada do que já existe seja tocado.
2. Conta de envio e bot cadastrados uma vez no painel, escolhidos por servidor.
3. Instalação conectada ao painel não pergunta o que o painel já tem.
4. Saúde da máquina guardada na série temporal, navegável pelo filtro de data.

## Solução

### Falar direto com o servidor de e-mail

Havendo conta de envio escolhida no painel, o agente envia por `curl`,
diretamente ao SMTP. Ele não instala Postfix, não edita `main.cf`, não toca em
`sasl_passwd` nem em `generic`.

É isso que o faz conviver com o Exim de um painel de hospedagem, com um cPanel
ou com o Postfix de outra pessoa: não há nada para disputar.

Dois cuidados que não são opcionais:

- **A senha não entra na linha de comando.** Em `--user usuario:senha` ela
  ficaria visível no `ps` para qualquer usuário da máquina. Vai num arquivo de
  configuração do `curl`, criado com permissão 600 antes de receber conteúdo e
  apagado no fim.
- **Conexão em texto claro é recusada.** Fora da porta 465, o envio usa
  `--ssl-reqd`: servidor que não ofereça TLS faz o alerta não sair, em vez de a
  credencial viajar aberta.

O caminho antigo (`mail`, depois `sendmail`) continua inteiro para quem não tem
conta no painel.

### Os arquivos que o agente passa a manter

`smtp.conf` e `telegram.conf`, os dois com permissão 600 desde a criação. São
reescritos só quando o conteúdo muda de verdade: reescrever a cada cinco
minutos encheria o registro e trocaria o arquivo debaixo de um envio.

Bloco ausente na resposta do painel quer dizer "nada escolhido", e **não**
"apague o que existe". Quem nunca abriu a tela de serviços não pode perder o
envio que já funcionava.

### Instalação que não repete pergunta

Vindo conta de envio do painel, o instalador liga o e-mail sozinho, grava o
`smtp.conf`, **não instala Postfix nem mailutils** e pula as perguntas de SMTP.
Vindo bot, grava o `telegram.conf`.

### Saúde da máquina junto das métricas

`/proc/loadavg` já traz, na mesma linha, as três janelas da fila e o par
"rodando/total" de processos. O agente passa a mandar isso, mais as linhas de
execução somadas e o tempo ligado, no mesmo envio das demais métricas.

Vai para a série temporal de propósito: é o que faz o filtro de data do painel
valer para esses números também. Campo que não foi medido vai ausente, não
zero: zero no gráfico parece máquina parada.

## Não-objetivos

- Não valida a credencial contra o servidor de e-mail a cada ciclo. Quem sabe
  se a senha está certa é o SMTP, no envio; testar por minuto, em toda a frota,
  seria uma conexão por minuto para responder o que o primeiro alerta responde.
- Não conserta a sobrescrita de `sasl_passwd` e `generic` no caminho antigo,
  quando somos nós que instalamos o Postfix. Fica anotado, é mudança de risco
  própria.
- Não remove o Postfix de quem já o tem configurado por nós.

## Validação

`tests/testa-servicos.sh`, 44 verificações. A principal monta um servidor que
**já tem Postfix configurado para outro provedor**, com `sasl_passwd` e
`generic` de terceiros, sem `mail` nem `sendmail` no caminho, e compara os três
arquivos byte a byte depois do envio.

Duas verificações de permissão são **puladas com aviso** quando o sistema de
arquivos ignora `chmod`, que é o caso do Git Bash no Windows. Marcar verde ali
seria dizer que a permissão foi conferida quando não foi.

Baterias do repositório nesta entrega: 134 de unidade, 112 de idioma, 77 de
ruído, 44 de serviços, 31 de migração, 28 de remetente e 25 de envio. Todas
verdes.
