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
Cada alerta traz o valor, há quanto tempo está assim, o pico, o estado geral
do servidor e uma frase dizendo por onde começar a investigação. Incidente
resolvido gera aviso de recuperação com a duração e o pico.

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

## Requisitos não funcionais

| ID | Requisito |
| --- | --- |
| RNF-01 | Uma execução por minuto, sem virar carga no servidor |
| RNF-02 | Nenhuma dependência além de bash, awk, coreutils e curl |
| RNF-03 | Falha do agente visível no registro, nunca silenciosa |
| RNF-04 | Duas execuções simultâneas não corrompem o estado |
| RNF-05 | Troca de arquivo atômica, no mesmo filesystem |
| RNF-06 | Registro rotacionado, para não encher o disco que ele vigia |
| RNF-07 | Texto de alerta em português, sem jargão e sem travessão |
| RNF-08 | Bateria de testes executável em qualquer máquina com bash |

## O que ele não faz

- Não substitui Prometheus ou Zabbix em frota grande. O valor aqui é instalar
  com um comando e ter painel próprio.
- Não coleta por segundo. A granularidade é de um minuto.
- Não reinicia serviço nem toma ação corretiva sozinho.
- Não monitora aplicação (endpoint HTTP, fila, latência). Só o servidor.

## Histórico

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
