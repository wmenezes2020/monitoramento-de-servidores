# SDD: o alerta de abertura não chegava, e só o primeiro destinatário recebia

Versão 2.3.0. Dois defeitos no mesmo arquivo, relatados em 14/10/2026 por quem
recebia os e-mails.

## Problema

Relato, na palavra de quem viu:

> O script está enviando e-mails de pós acontecimento, informando que se
> resolveu, mas o do acontecimento não está chegando pra ninguém. Outro ponto:
> parece que não está sendo enviado para todos os destinatários, está enviando
> para apenas o primeiro da lista separada por vírgula no dashboard.

Os dois juntos têm um efeito pior que a soma: o único e-mail que saía era o de
recuperação, para uma pessoa só. Quem lê recebe "resolvido" de um problema que
nunca foi anunciado, e passa a desconfiar do monitoramento inteiro.

## Causa raiz

### 1. Acento no assunto

Cabeçalho de e-mail só aceita ASCII (RFC 5322). Byte fora dessa faixa precisa
ir como encoded-word da RFC 2047, no formato `=?UTF-8?B?...?=`. Sem isso, o MTA
recusa a mensagem ou entrega o cabeçalho corrompido.

Os prefixos de severidade por idioma, medidos no catálogo:

```
NAO-ASCII  pt-BR abrir    -> [ATENÇÃO]
NAO-ASCII  pt-BR escalar  -> [CRÍTICO]
NAO-ASCII  es-CO abrir    -> [ATENCIÓN]
NAO-ASCII  es-CO escalar  -> [CRÍTICO]
NAO-ASCII  es-CO repetir  -> [CONTINÚA]
ASCII      pt-BR resolver -> [OK]
ASCII      pt-BR seguir   -> [SEGUE]
```

`[OK]` e `[SEGUE]` são ASCII puro. Era por isso que só o aviso de recuperação
chegava: ele é o único cujo assunto não tem acento.

Regressão introduzida na 2.1.0, quando o catálogo de idiomas trocou
`[ATENCAO]` por `[ATENÇÃO]` e `[CRITICO]` por `[CRÍTICO]`. O envio em ASCII
funcionava antes por acidente, não por desenho.

### 2. A lista inteira como um endereço

O `send_html_alert.sh` recebia a lista de destinatários num argumento e a
repassava inteira ao `mail`:

```bash
RECIPIENT="${2:-}"
cat "$RENDERED_FILE" | mail -r "$SENDER_EMAIL" ... -s "$SUBJECT" "$RECIPIENT"
```

O `mail` espera um endereço por argumento. Recebendo `a@x.com,b@y.com` ele
trata tudo como um endereço só, e o resultado depende do MTA: na melhor das
hipóteses entrega ao primeiro e descarta o resto, que é o que foi observado.

## Objetivo

1. Alerta de abertura e de escalada chegam, nos três idiomas.
2. Todo endereço da lista recebe.
3. Endereço ruim no meio da lista não impede os outros de receber.
4. Assunto sem acento continua legível no log do servidor de e-mail.

## Solução

### Codificação só quando precisa

`codifica_cabecalho()` devolve o texto intacto quando ele é ASCII puro, e o
converte em encoded-word quando não é. Codificar tudo também funcionaria, mas
deixaria o log do MTA ilegível e atrapalharia procurar um alerta antigo.

Ela é aplicada ao assunto e ao nome do remetente, que também pode ter acento
desde que o campo de remetente virou editável pelo painel na 2.2.0.

Sem `base64` na máquina, o texto cai para transliteração por `iconv`, e sem
`iconv` para remoção dos bytes fora do ASCII. Assunto sem acento entrega menos
informação que o certo, e muito mais que um e-mail que não sai.

### Um envio por destinatário

A lista é partida na vírgula, cada endereço perde o espaço em volta, e cada um
recebe sua própria chamada ao `mail`. Endereço vazio por vírgula sobrando é
ignorado.

A função devolve sucesso se **ao menos um** envio passou. Um endereço com erro
de digitação na lista não pode calar o alerta para o resto do time, e a falha
de cada endereço vai para o registro com o nome dele.

## Não-objetivos

- Não valida se o endereço existe. Isso só o MTA sabe, no envio.
- Não enfileira para tentar de novo. O agente roda a cada minuto e a histerese
  renotifica; fila própria seria um segundo estado para manter.
- Não mexe no corpo em HTML, que já ia em UTF-8 declarado e nunca foi o problema.

## Validação

`tests/testa-envio-email.sh`, 25 verificações, com um `mail` de mentira que
grava destinatário, assunto e remetente num arquivo em vez de enviar:

- assunto acentuado vira encoded-word nos três idiomas, e **decodifica de volta
  no texto exato**, porque codificar errado trocaria um alerta que não chega
  por um que chega ilegível;
- assunto em ASCII puro não é codificado;
- três endereços geram três envios, na ordem, com espaço em volta da vírgula e
  vírgula sobrando;
- endereço recusado no meio não impede o terceiro de ser tentado;
- falhar em todos é falha, falhar em alguns é sucesso;
- nome de remetente acentuado também é codificado, e o endereço fica legível ao
  lado;
- lista vazia não chama o `mail` nenhuma vez.

Baterias do repositório, todas verdes nesta entrega: 134 de unidade, 112 de
idioma, 31 de migração, 28 de remetente, 25 de envio.

## Alcance da correção na frota

`send_html_alert.sh` só entrou no manifesto de atualização na 2.1.0. Servidor
que ainda esteja em 2.0.0 ou anterior tem a cópia que veio do instalador e
recebe o conserto junto com a atualização do agente, não antes dela.
