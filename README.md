# Monitoramento de servidores

Agente de um arquivo que vigia CPU, memória, disco, swap, load e inodes de um
servidor Linux, avisa por e-mail e Telegram quando há problema de verdade, e
manda as métricas para o painel de observabilidade.

Instala com um comando, não precisa de banco, agente externo nem porta aberta.

```bash
curl -fsSL https://raw.githubusercontent.com/wmenezes2020/monitoramento-de-servidores/main/install-monitoring.sh | sudo bash
```

## O que ele faz de diferente

**Só avisa quando há problema.** Um pico de dois segundos durante um deploy não
vira mensagem. O agente exige três leituras seguidas acima do limiar antes de
abrir um alerta, e três abaixo da banda de saída antes de dar por resolvido.

**Avisa quando passou.** Todo incidente aberto recebe o aviso de recuperação,
com quanto tempo durou e qual foi o pico.

**Diz por onde começar.** Em vez de repetir o número, o alerta aponta o
provável caminho: steal alto indica limite do provedor, iowait alto indica
disco, servidor sem swap indica risco de OOM kill.

**Separa atenção de crítico.** 86% e 99% deixam de gerar a mesma mensagem.

**Não vira a carga do servidor.** Uma execução por minuto, lendo `/proc`. Sem
`mpstat`, sem `bc`, e o `du` do disco só roda quando a partição já passou do
limiar de atenção.

## Comandos

```bash
monitoring-agent.sh status
```

Mostra CPU, iowait, steal, memória, swap, load, disco, os limiares em vigor e
quais incidentes estão abertos.

```bash
monitoring-agent.sh silenciar 20m "deploy da api"
```

Suprime os alertas pelo tempo indicado sem parar a coleta. É o que deve ser
chamado antes de um deploy, em vez de baixar o limiar e perder o alerta para
o resto do tempo. O teto é 24 horas, para um silêncio esquecido ligado não
deixar o servidor sem vigilância.

```bash
monitoring-agent.sh falar          # encerra o silêncio agora
monitoring-agent.sh autoteste      # valida a instalação
monitoring-agent.sh atualizar      # força a busca por atualização
monitoring-agent.sh versao
```

## Configuração

Tudo em `/opt/monitoring/agent.conf`. Os valores também chegam do painel de
observabilidade, que sobrescreve o arquivo na sincronia a cada cinco minutos.

| Chave | Padrão | O que faz |
| --- | --- | --- |
| `CPU_ATENCAO` / `CPU_CRITICO` | 85 / 95 | limiares de CPU |
| `MEM_ATENCAO` / `MEM_CRITICO` | 85 / 95 | limiares de memória |
| `DISCO_ATENCAO` / `DISCO_CRITICO` | 85 / 93 | por ponto de montagem |
| `SWAP_ATENCAO` / `SWAP_CRITICO` | 50 / 80 | ignorado onde não há swap |
| `INODE_ATENCAO` / `INODE_CRITICO` | 85 / 93 | disco cheio de inode aceita bytes e recusa arquivo |
| `LOAD_ATENCAO` / `LOAD_CRITICO` | 1.5 / 3.0 | normalizado por núcleo |
| `STEAL_ATENCAO` / `STEAL_CRITICO` | 10 / 25 | CPU tirada pelo provedor |
| `CICLOS_CONFIRMACAO` | 3 | leituras seguidas acima do limiar antes de avisar |
| `CICLOS_RECUPERACAO` | 3 | leituras seguidas abaixo antes de dar por resolvido |
| `BANDA_SAIDA` | 8 | pontos abaixo do limiar para considerar normalizado |
| `RENOTIFICAR_MIN` | 60 | minutos até lembrar de um incidente ainda aberto; 0 desliga |
| `MAX_ALERTAS_HORA` | 12 | acima disso as mensagens viram um resumo |
| `RECUPERACAO_TELEGRAM` | 0 | recuperação por e-mail e painel, sem acordar ninguém |
| `AUTO_UPDATE` | 1 | busca atualização a cada cinco minutos |

Para desligar uma métrica: `VIGIAR_SWAP=0`, `VIGIAR_INODE=0`, e assim por diante.

Para ignorar pontos de montagem: `DISCO_IGNORAR="/var/lib/docker/* /mnt/backup"`.

## Como a atualização chega

O agente confere `agent.manifest` no repositório a cada cinco minutos. Se há
versão nova, ele:

1. baixa cada arquivo para um temporário no mesmo filesystem do destino;
2. confere o SHA-256 contra o manifesto, e aborta sem tocar em nada se diferir;
3. valida a sintaxe com `bash -n`;
4. guarda a versão atual em `/opt/monitoring/rollback/`;
5. instala com `mv` atômico;
6. roda o autoteste;
7. se o autoteste falhar, restaura a versão anterior e reporta ao painel.

Para forçar na hora:

```bash
sudo /usr/local/bin/monitoring-agent.sh atualizar
```

## Desenvolvimento

O agente é montado a partir de módulos. Não edite os arquivos da raiz: eles
são gerados.

```
src/agent/        fonte, um módulo por responsabilidade
scripts/build.sh  monta a raiz e o manifesto
tests/            bateria de unidade e teste de migração
```

```bash
./scripts/build.sh          # monta os artefatos e o manifesto
./scripts/build.sh --check  # confere se a raiz está em dia, para CI
./tests/roda-testes.sh      # 136 verificações de unidade
./tests/testa-migracao.sh   # 31 verificações de migração ponta a ponta
```

As fontes de dados são injetáveis (`PROC_STAT`, `PROC_MEMINFO`, `PROC_LOADAVG`,
`FIXTURE_DF`), então a bateria roda em qualquer máquina com bash e awk,
inclusive Windows com Git Bash, sem tocar em `/proc` de verdade e sem enviar
nada.

Depois de qualquer mudança em `src/`, rode o build antes de commitar. O
`agent.manifest` precisa estar coerente com os arquivos publicados, ou os
agentes da frota recusam a atualização por checksum e ficam na versão anterior.

## Arquivos no servidor

```
/usr/local/bin/monitoring-agent.sh    o agente
/usr/local/bin/monitor_cpu.sh         mesmo arquivo, nome antigo preservado
/opt/monitoring/agent.conf            configuração
/opt/monitoring/VERSION               versão instalada
/opt/monitoring/silencio              janela de silêncio, quando ativa
/var/lib/monitoring/state/            estado da histerese entre execuções
/var/log/monitoring-agent.log         registro, rotacionado em 2 MB
```

## Migração a partir da versão 1

Automática, em até um minuto, sem ninguém entrar no servidor. Ao receber o
bundle novo pelo canal de atualização, o agente instala a si mesmo, converte
os limiares antigos para o par atenção/crítico, move os destinatários de
e-mail de dentro do script para `email.conf`, e troca as quatro linhas por
minuto do cron por uma só, preservando o ClamAV e tudo que o dono do servidor
tiver agendado.

Se qualquer passo falhar, os três scripts antigos continuam funcionando,
porque cada um deles é o agente inteiro.

## Documentação

- [SDD do agente v2](docs/SDD_AGENTE_V2.md): o problema, as causas encontradas
  no código e as decisões de projeto.
- [PRD](PRD.md): o que o produto faz.

## Licença

MIT. Copyright (c) 2026 Wesley Menezes. Veja [LICENSE](LICENSE).
