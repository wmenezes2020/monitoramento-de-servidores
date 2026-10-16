# PRD: agente de monitoramento de servidores

Autor: Wesley Menezes
Última atualização: 2026-10-09 (versão 2.0.0 do agente)

## O que é

Um agente de arquivo único que vigia um servidor Linux e avisa quem cuida dele
quando há problema. Instala com um comando, não pede banco de dados, não abre
porta e não precisa de agente externo.

## Para quem

Quem administra poucos servidores e precisa saber que algo está errado antes
do cliente ligar, sem montar uma stack de observabilidade inteira para isso.

## O problema que ele resolve

Monitoramento que alerta demais ensina a pessoa a ignorar o alerta. Quando o
problema de verdade chega, a mensagem passa junto com as outras trinta.

## O que ele faz

### Mede

| Métrica | Fonte | Observação |
| --- | --- | --- |
| CPU | delta de `/proc/stat` | média do intervalo entre execuções |
| iowait | `/proc/stat` | separado: disco lento não é CPU ocupada |
| steal | `/proc/stat` | CPU tirada pelo provedor; em instância burstable indica crédito esgotado |
| Memória | `MemAvailable` de `/proc/meminfo` | cache de disco não conta como ocupado |
| Swap | `/proc/meminfo` | ignorado onde não há swap configurado |
| Load | `/proc/loadavg` | normalizado por núcleo |
| Disco | `df -P` | por ponto de montagem |
| Inodes | `df -Pi` | disco cheio de inode aceita bytes e recusa arquivo novo |

Uma execução por minuto. Sem `mpstat`, sem `bc`, sem dependência que possa
faltar em servidor mínimo.

### Avisa cada vez menos do mesmo

A renotificação de um incidente que continua aberto dobra a cada repetição,
de uma hora até um dia. Seis dias de problema rendem dez avisos, não cento e
quarenta e oito. Piorar de atenção para crítico zera a conta, porque isso vale
interromper alguém de novo.

### Decide

Máquina de estado com histerese por métrica:

- três leituras seguidas acima do limiar de atenção abrem o incidente;
- três leituras seguidas acima do limiar crítico escalam;
- três leituras seguidas abaixo da banda de saída resolvem;
- um incidente aberto é lembrado no máximo de hora em hora;
- acima de doze alertas por hora, as mensagens viram um resumo só.

Um pico isolado nunca vira mensagem.

### Avisa

Por e-mail (SMTP2Go via Postfix), Telegram e o painel de observabilidade.

O aviso é escrito para ser entendido de olho batido, na ordem das perguntas de
quem abre: o que houve, o que isso causa para quem usa o servidor, se precisa
de alguém agora, o que fazer, e só então o número. O assunto já diz tudo isso
em uma linha, por exemplo `[ATENÇÃO] loja-01: Memória quase cheia (98%)`.

O valor, o limiar, o pico, há quanto tempo está assim, a tabela do servidor e
os maiores processos continuam todos no e-mail, embaixo, para quem for
investigar. Incidente resolvido gera aviso de recuperação com a duração e o
pico.

O e-mail sai pelo remetente cadastrado para aquele servidor no painel, e cada
endereço da lista de destinatários recebe seu próprio envio: um endereço com
erro de digitação no meio da lista não cala o alerta para o resto do time.

### Silencia quando faz sentido

`monitoring-agent.sh silenciar 20m "deploy da api"` suprime alertas sem parar
a coleta, com teto de 24 horas. É a alternativa a baixar o limiar e perder o
alerta para o resto do tempo.

### Se atualiza sozinho

Confere o manifesto a cada cinco minutos, valida SHA-256 e sintaxe antes de
instalar, roda autoteste depois, e volta para a versão anterior se o autoteste
falhar.

## Requisitos funcionais

| ID | Requisito |
| --- | --- |
| RF-01 | Instalar com um comando, perguntando o mínimo |
| RF-02 | Medir CPU, memória, disco, swap, load, inodes, iowait e steal |
| RF-03 | Confirmar o problema em N leituras antes de notificar |
| RF-04 | Separar atenção de crítico, com escalada confirmada |
| RF-05 | Notificar a recuperação de todo incidente que foi notificado |
| RF-06 | Não repetir o mesmo incidente antes do intervalo configurado |
| RF-07 | Agregar em um resumo acima do teto de alertas por hora |
| RF-08 | Suprimir alertas por janela de silêncio, sem parar a coleta |
| RF-09 | Enviar métricas ao painel em toda execução, haja alerta ou não |
| RF-10 | Receber limiares e destinatários do painel |
| RF-11 | Atualizar-se sozinho, com checksum, autoteste e rollback |
| RF-12 | Migrar sozinho uma instalação da versão 1, preservando configuração |
| RF-13 | Responder `status`, `autoteste`, `silenciar`, `falar`, `versao` |
| RF-14 | Varrer com ClamAV diariamente e alertar sobre arquivo infectado |
| RF-15 | Aplicar o remetente de e-mail definido no painel, inclusive no Postfix |
| RF-16 | Entregar o alerta a todos os destinatários da lista, um envio por endereço |
| RF-17 | Dizer em uma frase o que houve, o que causa e se precisa de alguém agora |
| RF-18 | Espaçar a renotificação de incidente longo, dobrando até o teto de um dia |
| RF-19 | Só alertar por fila (load) ou contenção (steal) com sintoma medido junto |

## Requisitos não funcionais

| ID | Requisito |
| --- | --- |
| RNF-01 | Uma execução por minuto, sem virar carga no servidor |
| RNF-02 | Nenhuma dependência além de bash, awk, coreutils e curl |
| RNF-03 | Falha do agente visível no registro, nunca silenciosa |
| RNF-04 | Duas execuções simultâneas não corrompem o estado |
| RNF-05 | Troca de arquivo atômica, no mesmo filesystem |
| RNF-06 | Registro rotacionado, para não encher o disco que ele vigia |
| RNF-07 | Texto de alerta no idioma da conta, sem jargão e sem travessão |
| RNF-09 | Cabeçalho de e-mail em ASCII, com acento em encoded-word da RFC 2047 |
| RNF-08 | Bateria de testes executável em qualquer máquina com bash |

## O que ele não faz

- Não substitui Prometheus ou Zabbix em frota grande. O valor aqui é instalar
  com um comando e ter painel próprio.
- Não coleta por segundo. A granularidade é de um minuto.
- Não reinicia serviço nem toma ação corretiva sozinho.
- Não monitora aplicação (endpoint HTTP, fila, latência). Só o servidor.

## Histórico

### 2.4.0, 2026-10-15: aviso que se entende de olho batido, e só quando importa

Um e-mail real abriu com `Load average en 1.56 en <servidor>` e a reação de
quem recebeu foi: não dá para saber do que se trata. Ele estava certo, e o
mesmo e-mail trazia cinco defeitos.

**O incidente renotificava de hora em hora havia seis dias.** Perto de 148
e-mails iguais, que é exatamente como se ensina alguém a ignorar o alerta. A
espera passou a dobrar a cada repetição, de uma hora até um dia.

**O load virava incidente sozinho.** O servidor tinha load 1.56 por núcleo,
CPU em 67.9%, iowait em 1.0% e 18.6 GB de memória livre: estava trabalhando,
não sofrendo. Load é medida de fila, e fila só dói acompanhada de CPU saturada
ou de espera de disco. Agora ele exige sintoma medido no mesmo ciclo, como o
steal já exigia desde a 2.1.0, e o limiar de fábrica subiu de 1.5 para 2.5 por
núcleo.

**O texto era jargão.** Um número e uma unidade não são um aviso. O e-mail
passou a abrir pelo que o problema causa, seguido de uma linha que diz se
precisa de alguém agora, depois o que fazer, e só então o número.

**O bloco de processos saía em português dentro do e-mail em espanhol**,
embora as chaves traduzidas existissem desde a 2.1.0.

**E o incidente de load não tinha como se fechar.** Este foi o mais grave, e
só apareceu ao conferir o fechamento. A banda de saída da histerese vinha em
pontos percentuais para toda métrica, e descontar 8 pontos de um limiar 2.5 dá
número negativo, que fica preso em zero: o incidente de load só se fecharia com
o load exatamente zero, o que não acontece em servidor ligado. Ele abria e
ficava aberto, renotificando. A banda passou a vir na unidade da métrica.

**A lista de processos acusava o próprio medidor.** O primeiro lugar era do
comando `ps` com 400%, porque o percentual dele é calculado sobre uma vida de
milissegundos, e o agente vinha logo abaixo. Quem lia concluía que o
monitoramento era o que estava consumindo o servidor.

Detalhe em `docs/SDD_ALERTA_NO_BRAIN.md`.

### 2.3.0, 2026-10-14: o alerta de abertura voltou a chegar

**Dois defeitos que se somavam no pior jeito possível.** O assunto do alerta de
atenção e de crítico tem acento em português e em espanhol, e cabeçalho de
e-mail só aceita ASCII: o MTA recusava a mensagem. `[OK]` e `[SEGUE]` são ASCII
puro, então o único e-mail que saía era o de recuperação. Quem lê recebia
"resolvido" de um problema que nunca foi anunciado. Era regressão da 2.1.0,
quando o catálogo de idiomas trocou `[ATENCAO]` por `[ATENÇÃO]`.

**E só o primeiro destinatário recebia.** A lista do painel ia inteira num
argumento, e o `mail` tratava `a@x.com,b@y.com` como um endereço só.

Agora o assunto acentuado vai como encoded-word da RFC 2047, o que é ASCII puro
segue legível no log do servidor de e-mail, e cada endereço recebe um envio
próprio. Detalhe em `docs/SDD_ENVIO_DE_EMAIL.md`.

### 2.2.0, 2026-10-14: remetente por servidor, definido no painel

O endereço que envia os alertas de cada servidor passou a ser campo do cadastro
no painel, e o agente o aplica no mesmo ciclo em que busca configuração, em até
cinco minutos.

Gravar só o arquivo de configuração seria mentira: o Postfix reescreve o
remetente do envelope pelo `smtp_generic_maps`, então a troca só vale de fato
quando o mapa `/etc/postfix/generic` acompanha. Endereço inválido é recusado
antes de gravar, e falha na aplicação volta o valor anterior, porque um
remetente pela metade deixa o servidor sem conseguir enviar nada. Detalhe em
`docs/SDD_REMETENTE_POR_SERVIDOR.md`.

### 2.1.0, 2026-10-09: três idiomas e contenção de CPU

**Três idiomas:** pt-BR, en-US e es-CO, com `es-CO` como padrão de quem não
está conectado a painel nenhum. O idioma chega do painel e vale para e-mail,
Telegram e para os templates HTML, que o agente reescreve em disco quando o
idioma muda. Nem os templates nem o `send_html_alert.sh` eram atualizáveis
antes; passaram a ser.

**O alerta de steal estava errado.** O limiar era 10% e não olhava mais nada.
Em instância burstable, steal aparece toda vez que a máquina usa burst acima
do baseline: num `t3a.xlarge` medido em 09/10/2026, steal de 16,6% com a CPU
em 29,5% e load de 0,41 por núcleo gerou e-mail, com o servidor tranquilo.
Agora o limiar é 25% e só alerta se a CPU também estiver acima do limiar de
atenção no mesmo ciclo.

**"CPU roubada" virou "contenção de CPU".** Era tradução literal, não existe
em ferramenta nenhuma e assusta quem lê. O termo novo é o usado em VMware,
Nutanix e Kubernetes, e a palavra "steal" continua na linha técnica do corpo
do alerta, que é onde serve para pesquisar.

**Texto do e-mail.** Saiu o subtítulo fixo que não dizia nada sobre a métrica
do alerta, saiu o rodapé vazio, a data passou a sair no formato e no fuso do
servidor em vez de ISO em UTC, e o título passou a levar o nome do servidor
em vez de repetir o nível que já está no assunto.

**O envio ao Telegram deixou de engolir erro.** Token trocado ou chat ID
errado deixava o canal mudo sem deixar rastro; agora aparece no registro. A
mensagem também é cortada em 3900 caracteres, porque acima de 4096 o Telegram
recusa a mensagem inteira.

### 2.0.0, 2026-10-09

Reescrita a partir de três defeitos encontrados no código da versão 1.

**Corrigido o cálculo de memória.** A versão anterior somava `used + buff/cache`
do `free` e chamava de memória ocupada. Cache de disco não é memória ocupada.
Num servidor medido com 16 GB e 8,4 GB disponíveis, a conta antiga dava 96,7%
e a correta dá 44%. Esse servidor disparava alerta de RAM a cada minuto,
indefinidamente, e o painel mostrava o valor errado no gráfico.

**Corrigida a frequência.** O cron estava em `* * * * *`, apesar do comentário
no instalador dizer "a cada 5 min". Eram quatro execuções por minuto, cada uma
chamando `top` e `ps aux` duas vezes. Agora é uma.

**Corrigida a medição de CPU.** `mpstat 1 2` media dois segundos e reportava
como estado do servidor. Agora é o delta de `/proc/stat` sobre o intervalo
inteiro.

**Adicionados:** histerese, cooldown, recuperação, severidade, janela de
silêncio, orçamento de alertas, medição de iowait, steal, load e inodes,
diagnóstico no corpo do alerta, autoteste e comando de status.

**Removidas duas dependências.** `mpstat` (pacote `sysstat`) e `bc`. Com
`set -euo pipefail` no topo do script antigo, a falta de qualquer um dos dois
matava o monitoramento em silêncio.

**Corrigido o canal de atualização.** Baixava três arquivos por minuto, para
sempre, sem versão e sem checksum, conferindo só HTTP 200 e a primeira linha.
Instalava com `mv` vindo de `/tmp`, que costuma ser outro filesystem e por
isso não é atômico. Agora há manifesto versionado, SHA-256, validação de
sintaxe, autoteste e rollback.

**Removida a duplicação de código.** `update_scripts.sh` carregava cópias dos
três monitores escritas dentro dele, que já tinham divergido dos arquivos do
repositório e perdido o bloco de envio de métricas ao painel. Quem rodasse
aquele script desligava o próprio dashboard sem receber aviso. Agora existe
uma fonte só, em `src/agent/`, e a raiz é gerada por `scripts/build.sh`.

**Corrigido o parser do `df`.** Lia os campos da esquerda, e um nome de
dispositivo com espaço (share de rede) deslocava tudo: o agente passava a
comparar o ponto de montagem com o percentual e nunca alertava sobre aquela
partição.

**Higiene do repositório público.** Adicionada licença MIT, `.gitattributes`
com `eol=lf` (sem ele, clone no Windows devolve script com CRLF e o Linux
responde `bad interpreter`), `.gitignore`, e removido do rastreamento um dump
de `getUpdates` do Telegram commitado por acidente, com o chat ID do grupo de
alertas dentro.
