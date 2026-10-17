# SDD: instalação silenciosa com o UUID na chamada

Autor: Wesley Menezes
Data: 17/10/2026
Escopo: o instalador e a tela de Servidores. O agente não muda.

## Problema

Instalar o agente hoje é uma conversa de dez perguntas no terminal: conectar ao
painel, endereço da API, UUID, ativar e-mail, porta do SMTP, domínio, usuário,
senha, remetente, destinatários e token do Telegram. Quem cadastrou o servidor
no painel já respondeu quase tudo isso lá, com mais calma e com validação na
tela. Digitar de novo, por SSH, é onde entra o erro de digitação que ninguém
percebe: um UUID com um caractere trocado instala um agente que nunca aparece
no painel.

Pior quando são vinte servidores. A instalação vira trabalho manual repetido,
não dá para pôr num `cloud-init`, numa imagem base nem num Ansible, porque o
script exige um terminal interativo para cada resposta.

## Causa

O instalador foi escrito como diálogo. Toda informação entra por `read`, e a
conexão com o painel é apenas mais uma pergunta no meio das outras, feita
depois que o usuário já escolheu conectar.

Só que a ordem real da informação é a inversa: quando o servidor existe no
painel, o painel sabe o nome, os limiares, os destinatários, a conta de envio
de e-mail e o bot do Telegram. O que falta ao script é apenas saber de quem ele
está falando. Esse "de quem" é o UUID, e o UUID cabe inteiro na linha de
comando.

## Objetivo

Receber o UUID na chamada e, com ele, instalar sem perguntar nada.

```bash
curl -fsSL <raw>/install-monitoring.sh | sudo bash -s -- --uuid=<UUID>
```

Sem o UUID, o instalador continua exatamente como está hoje, pergunta por
pergunta. Nenhum fluxo existente muda de comportamento.

## Solução

### 1. Opções na chamada

O script passa a ler os argumentos antes de qualquer pergunta:

| Opção | Para que serve |
| --- | --- |
| `--uuid=<UUID>` | UUID do servidor no painel. Liga o modo silencioso. |
| `--api=<URL>` | Endereço da API do painel, quando não é o padrão. |
| `--help` | Mostra o uso e sai. |

Também aceita `--uuid <UUID>` separado por espaço, o UUID solto como primeiro
argumento, e a variável de ambiente `SERVER_UUID`, que é o formato que serviço
de inicialização de máquina costuma oferecer.

O UUID é validado no formato antes de qualquer coisa. UUID malformado **para a
instalação com erro**, em vez de cair no fluxo interativo. Quem pediu
instalação silenciosa com um identificador errado precisa saber disso, e não
descobrir meia hora depois que o servidor nunca apareceu no painel.

### 2. O que o modo silencioso faz

1. Busca a configuração em `GET /agent/updates` com o cabeçalho
   `X-Server-UUID`. Se a resposta não trouxer o servidor, encerra com erro: sem
   painel não há o que instalar em silêncio.
2. Aplica o que veio: nome do servidor, idioma, limiares, destinatários de
   e-mail, conta de envio e bot do Telegram.
3. **O que não veio fica de fora, sem pergunta.** Sem conta de envio no painel,
   o e-mail fica desligado e nenhum serviço de e-mail é instalado nesta
   máquina. Sem bot, o Telegram fica de fora. Os dois casos entram no resumo
   final como aviso, com a frase que diz onde resolver.
4. Não exige terminal interativo. O script deixa de pedir `/dev/tty`, então
   roda em `cloud-init`, em Ansible e em pipeline de imagem.

### 3. O que ele preserva da máquina

Reinstalar não pode apagar o que já estava funcionando. Antes de reescrever o
`email.conf`, o instalador lê o que existe e guarda:

- `RECIPIENTS`: já era preservado desde a 2.6.1.
- `SENDER_EMAIL`: passa a ser preservado agora. Sem isso, uma reinstalação
  silenciosa num servidor cuja conta de envio não está no painel gravaria
  remetente vazio, e o e-mail pararia de sair até a próxima sincronia.

### 4. Botão no painel

A tela de Servidores ganha, ao lado de "Copiar UUID", um botão "Copiar
instalador". Ele põe na área de transferência a linha inteira, com o UUID
daquele servidor e o endereço da API do próprio painel. A pessoa cola no SSH e
pronto.

## Não objetivos

- **Não muda a autenticação do agente.** O UUID continua sendo a única
  credencial, e quem o tiver lê do painel a senha do SMTP e o token do bot.
  Essa dívida é anterior a esta entrega e continua aberta. O que muda é que o
  UUID agora também circula na linha de comando, então ele aparece no
  histórico do shell de quem colar o comando.
- **Não instala sem painel.** Modo silencioso sem servidor cadastrado não tem
  de onde tirar configuração, e adivinhar seria pior que falhar.
- **Não altera o agente**, só o instalador e a tela.

## Validação

- `./tests/testa-instalador.sh`: verificações novas do modo silencioso, de que
  nenhuma pergunta sobra num caminho silencioso e de que o fluxo interativo
  continua inteiro.
- `bash -n install-monitoring.sh`.
- Ensaio do leitor de argumentos com UUID válido, UUID inválido, `--api`,
  argumento solto, variável de ambiente e `--help`.
