# SDD: agente de monitoramento v2, alertas que valem a pena ler

Data: 2026-10-09
Autor: Wesley Menezes

## Problema

O agente instalado hoje manda alerta demais e informação de menos. Quem recebe
aprende a ignorar, e aí o alerta que importava passa junto com o resto.

Três causas, encontradas no código, não supostas.

### Causa 1: a conta de memória está errada

`monitor_memory.sh`, linha 9:

```bash
USED_MEM=$(echo $MEM_INFO | awk '{print $3 + $6}')
```

No `free`, a coluna 3 é `used` e a coluna 6 é `buff/cache`. O script soma o
cache de disco como memória ocupada. Cache não é memória ocupada: o kernel
devolve no instante em que algum processo precisa.

Medição em servidor real (EC2 t3a.xlarge, 16 GB):

| Conta | Fórmula | Resultado |
| --- | --- | --- |
| O que o script faz | (7,0 + 7,5) / 15 | 96,7 % |
| O correto | (15 − 8,4) / 15 | 44 % |

Com o limiar em 90 %, esse servidor dispara alerta de RAM em toda execução,
indefinidamente, tendo 8,4 GB livres. O mesmo cálculo alimenta o bloco de
métricas enviado ao dashboard, então o gráfico do painel mostra 96 % onde o
servidor está em 44 %.

### Causa 2: nenhum alerta tem memória do anterior

Os três monitores decidem olhando só o instante atual:

- sem histerese: um pico de 2 segundos vira alerta;
- sem cooldown: o mesmo problema alerta de novo a cada ciclo;
- sem recuperação: ninguém é avisado quando normaliza;
- sem severidade: 85 % e 99 % geram a mesma mensagem.

O cron está em `* * * * *` (a cada minuto), apesar do comentário no instalador
dizer "a cada 5 min". Um build de três minutos gera três alertas idênticos.

### Causa 3: a medição de CPU olha uma janela curta demais

`mpstat 1 2` mede dois segundos e reporta como se fosse o estado do servidor.
Qualquer rajada passa do limiar. Além disso, `mpstat` vem do pacote `sysstat`,
que pode não estar instalado, e `bc`, usado em toda comparação, pode faltar em
servidor mínimo. Com `set -euo pipefail` no topo, a falta de qualquer um dos
dois mata o script em silêncio: nenhum alerta sai, e ninguém percebe.

## Causa raiz

O agente responde "o valor passou do limiar agora?" quando a pergunta útil é
"existe um problema que continua acontecendo e precisa de alguém?".

## Objetivo

Alerta que chega quando há problema de verdade, não chega quando não há, diz o
que fazer, e avisa quando acabou. E a frota já instalada recebe isso sozinha,
sem ninguém entrar em servidor nenhum.

### Critério de conclusão

1. A conta de memória usa `MemAvailable` e bate com `free -h` do servidor.
2. CPU é a média do intervalo inteiro entre execuções, não de 2 segundos.
3. Um pico isolado não gera alerta. Problema sustentado gera, uma vez.
4. Normalização gera aviso de recuperação.
5. `bc` e `mpstat` deixam de ser obrigatórios.
6. Falha do agente é visível em vez de silenciosa.
7. Servidor já instalado migra sozinho em até 1 minuto, sem intervenção.
8. Bateria de testes verde antes do push, com fixtures de servidor real.

## Solução

### Medição: ler `/proc`, não chamar binário

| Métrica | Fonte | Observação |
| --- | --- | --- |
| CPU | delta de `/proc/stat` entre execuções | média do intervalo real |
| iowait | `/proc/stat` | separado da CPU: disco lento não é CPU ocupada |
| steal | `/proc/stat` | em EC2 burstable indica crédito esgotado |
| Memória | `MemAvailable` de `/proc/meminfo` | com fallback para `MemFree + Buffers + Cached` |
| Swap | `/proc/meminfo` | ignorado quando `SwapTotal` é 0 |
| Load | `/proc/loadavg` | normalizado pelo número de núcleos |
| Disco | `df -P` | mais inodes, que `df` sem `-i` não mostra |

Toda fonte é injetável por variável (`PROC_STAT`, `PROC_MEMINFO`, ...), o que
permite testar com fixtures em qualquer máquina, inclusive Windows.

Aritmética em `awk`, que é POSIX e está em qualquer servidor. `bc` sai.

### Decisão: máquina de estado com histerese

Estado por métrica, guardado em `/var/lib/monitoring/state/`:

```
OK ──── N ciclos acima do limiar de atenção ────▶ ATENCAO  (alerta)
ATENCAO ─ N ciclos acima do limiar crítico ────▶ CRITICO  (alerta, escalado)
CRITICO/ATENCAO ─ M ciclos abaixo da banda ────▶ OK       (alerta de recuperação)
```

Padrões, todos configuráveis em `/opt/monitoring/agent.conf`:

| Parâmetro | Padrão | Por quê |
| --- | --- | --- |
| `CICLOS_CONFIRMACAO` | 3 | três minutos sustentados, não um pico |
| `CICLOS_RECUPERACAO` | 3 | evita anunciar recuperação cedo demais |
| `BANDA_SAIDA` | 8 pontos | sair em 82 % para um limiar de 90 % evita pingue-pongue na borda |
| `RENOTIFICAR_MIN` | 60 | repete o alerta aberto no máximo de hora em hora |
| `MAX_ALERTAS_HORA` | 12 | acima disso agrega num resumo só |
| CPU atenção / crítico | 85 / 95 | |
| RAM atenção / crítico | 85 / 95 | |
| Disco atenção / crítico | 85 / 93 | |

### Anti-tempestade: janela de silêncio

`/opt/monitoring/silencio` com um timestamp de expiração suprime alertas sem
parar a coleta de métricas. Serve para o deploy chamar antes de subir:

```bash
monitoring-agent.sh silenciar 15m "deploy da api"
```

Build deixa de gerar alerta sem que ninguém precise baixar limiar.

### Conteúdo do alerta: dizer o que fazer

Cada alerta passa a trazer, além do valor: quanto tempo está assim, o que mudou
desde o ciclo anterior, os processos relevantes para aquela métrica, e a
primeira coisa a conferir. Em CPU alta com steal alto, por exemplo, o texto diz
que o limite é do provedor e não do servidor.

### Auto-atualização: versionada, verificada e reversível

`agent.version` no repositório e `manifest.json` com SHA-256 de cada arquivo.
O ciclo de atualização:

1. busca o manifesto e compara com a versão instalada; igual, encerra;
2. baixa cada arquivo para um temporário **no mesmo filesystem** do destino;
3. confere SHA-256; diferente, aborta sem tocar em nada;
4. valida sintaxe com `bash -n`;
5. guarda a versão atual em `/opt/monitoring/rollback/`;
6. instala com `mv` atômico;
7. roda um smoke test (`monitoring-agent.sh autoteste`);
8. se o smoke test falhar, restaura o rollback e reporta o incidente ao painel.

O `has_updates` do backend passa a comparar versão em vez de responder sempre
`true`, o que hoje faz cada servidor baixar três arquivos por minuto para sempre.

### Migração da base instalada

O único canal que alcança quem já está instalado são os três arquivos que o
`dashboard_fetch_updates.sh` baixa hoje. Então cada um deles passa a ser o
**bundle completo do agente**. Ao rodar pela primeira vez, o bundle:

1. instala `/usr/local/bin/monitoring-agent.sh`;
2. cria `/opt/monitoring/agent.conf` com os padrões, preservando limiares já
   configurados no servidor;
3. substitui as quatro linhas antigas do cron por uma só;
4. executa a própria rodada normalmente.

Se qualquer passo falhar, os três scripts continuam funcionando sozinhos,
porque cada um é o bundle inteiro. Não existe estado intermediário quebrado.

### Como o código fica organizado

Módulos em `src/agent/`, testados isoladamente, e um `scripts/build.sh` que
concatena tudo nos artefatos da raiz, que são os que o canal de distribuição
baixa. O repositório deixa de ter a mesma lógica escrita em dois lugares:
hoje `update_scripts.sh` carrega cópias embutidas dos três monitores que já
divergiram do que está na raiz, e rodá-lo desliga o envio de métricas ao
dashboard sem avisar.

## Não objetivos

- Trocar por Prometheus, Zabbix ou agente de terceiro. O valor aqui é o
  instalador de um comando e o painel próprio.
- Coletar métrica por segundo. A granularidade de um minuto resolve o problema.
- Tocar no ClamAV, no Postfix ou no fluxo de e-mail.
- Apagar os scripts antigos. Eles permanecem, delegando para o núcleo novo.

## Validação

1. `bash -n` em todo artefato gerado.
2. `tests/roda-testes.sh`: bateria com fixtures de `/proc` de servidor real,
   cobrindo a conta de memória, a máquina de estado, a janela de silêncio e a
   verificação de checksum do atualizador.
3. Comparação do valor calculado contra o `free -h` do servidor real medido.
4. `npx tsc --noEmit` no backend e no frontend.
5. Migration do Prisma idempotente, aplicada em base limpa e em base existente.

## Risco aceito

A frota inteira atualiza de uma vez, por decisão do dono. A mitigação é o
checksum, o `bash -n`, o smoke test e o rollback automático listados acima,
mais a propriedade de que os três scripts antigos seguem funcionando se o
bootstrap falhar.
