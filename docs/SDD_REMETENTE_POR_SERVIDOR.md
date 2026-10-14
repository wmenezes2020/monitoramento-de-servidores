# SDD: remetente de e-mail configurável pelo painel

Data: 2026-10-14
Autor: Wesley Menezes

## Problema

O remetente dos alertas é escolhido uma vez, durante a instalação, e fica
cravado no servidor. Para trocar, alguém precisa entrar por SSH e rodar o
instalador de novo. Os destinatários já são editáveis pelo painel; o remetente
não.

## Objetivo

Cada servidor tem um campo de remetente no cadastro, editável pelo painel. O
agente recebe a mudança na sincronia seguinte e os próximos e-mails saem com
o endereço novo.

### Critério de conclusão

1. Campo de remetente na criação e na edição de servidor.
2. O agente aplica o remetente novo e os e-mails seguintes chegam com ele.
3. Nada quebra em servidor que não configurou remetente no painel.
4. Quem usa o painel entende por que o e-mail pode parar de chegar se o
   domínio não estiver verificado no provedor de envio.

## O que torna isso menos simples do que parece

**O Postfix reescreve o remetente, e ele não lê o `email.conf`.**

Durante a instalação o script grava `/etc/postfix/generic`:

```
root@<dominio>    <remetente>
@<dominio>        <remetente>
```

e liga isso no `main.cf` por `smtp_generic_maps`. O Postfix reescreve o
endereço de origem na saída usando esse mapa, depois que o `send_html_alert.sh`
já montou o cabeçalho `From:`.

Então trocar só o `SENDER_EMAIL` no `/opt/monitoring/email.conf` faria o painel
mostrar o remetente novo, o arquivo ter o valor novo, e **o e-mail chegar com o
antigo**. A funcionalidade pareceria pronta e estaria quebrada.

Para funcionar de verdade, o agente precisa, na ordem:

1. gravar `SENDER_EMAIL` e `SENDER_NAME` no `email.conf`;
2. reescrever `/etc/postfix/generic` com o endereço novo;
3. rodar `postmap /etc/postfix/generic`;
4. recarregar o Postfix.

Se os passos 2 a 4 falharem, o `email.conf` volta ao valor anterior: é melhor
continuar enviando pelo remetente antigo, que funciona, do que ficar num estado
em que o cabeçalho diz uma coisa e o envelope diz outra.

## O limite que a tela precisa dizer

Provedor de envio (SMTP2Go e equivalentes) só aceita remetente de domínio
verificado na conta. Um endereço de domínio não verificado é recusado no
envio, ou entregue direto no spam por falta de SPF e DKIM.

Isso é decisivo: trocar o remetente para um domínio qualquer faz os alertas
pararem de chegar, e o sintoma aparece só no próximo incidente, que é o pior
momento possível. O "Saiba mais" do campo diz isso com todas as letras.

## Solução

### Onde o valor mora

Colunas `sender_email` e `sender_name` em `servers`, e não dentro do JSON
`recipients`. Remetente tem formato validável e é um conceito diferente de
destinatário; misturar os dois no mesmo JSON deixaria a validação implícita.

**Por servidor, não por empresa.** Foi o que o dono pediu, e faz sentido: uma
empresa pode ter servidores de clientes diferentes, cada um alertando com o
endereço da marca certa.

### Vazio significa "mantém o que está no servidor"

Servidor que já estava instalado tem remetente configurado localmente. Campo
vazio no painel não apaga esse valor: ele apenas não manda nada. Apagar o
remetente local a partir de um campo em branco deixaria o servidor sem
conseguir enviar, por uma tela que a pessoa só abriu para olhar.

### Como o agente aplica

Mesmo caminho dos destinatários: `/agent/updates` devolve o valor, o
`sincroniza_config` grava, e vale a partir do alerta seguinte. A sincronia
roda a cada cinco minutos.

## Não objetivos

- Verificar o domínio no provedor de envio a partir do painel. Isso exige
  credencial da conta do provedor e é entrega própria.
- Trocar o servidor SMTP pelo painel. Senha de SMTP em banco é outro problema,
  com outro nível de cuidado.
- Remetente por tipo de alerta.

## Validação

1. Bateria do agente verde, com teste do caminho completo: valor novo chega,
   `email.conf` é gravado, `generic` é reescrito e o `postmap` roda.
2. Teste do caso em que o `postmap` falha: o `email.conf` volta ao anterior.
3. Campo vazio não apaga o remetente local.
4. `tsc --noEmit` e build verdes no backend e no painel.
5. Portões de i18n verdes: o campo novo e o "Saiba mais" nos três idiomas.
