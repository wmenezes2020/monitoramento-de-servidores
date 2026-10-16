# CLAUDE.md: monitoramento-de-servidores

Regras deste repositório. Valem junto das globais.

## Passo zero de toda tarefa: consultar o grafo

**Antes do SDD e antes do PRD, sempre.** Não é "quando eu precisar entender":
é a primeira coisa.

```bash
graphify.exe query "<pergunta>"
graphify.exe explain "<coisa>"
graphify.exe path A B
```

Sem grafo no repositório, **gerar antes de começar**:

```bash
python scripts/gerar-grafo.py
```

O alvo fica guardado em `graphify-out/.graphify_alvo`, então a próxima sessão
repete o mesmo escopo sem adivinhar.

**Nunca apagar `graphify-out/`.** Ele é versionado e entra no commit da tarefa.
Fica fora de qualquer limpeza de disco, mesmo com o disco apertado. O motivo é
concreto: ele já foi apagado numa limpeza e a sessão seguinte ficou sem o mapa,
lendo arquivo por arquivo de novo.

Se a PR mexeu em código e o `graphify-out/` não aparece no diff, a tarefa não
terminou.

## Este é um repositório PÚBLICO

Tudo que entra aqui é lido por qualquer pessoa, hoje e para sempre.

- **Licença MIT na raiz**, em nome de Wesley Menezes. Sem `LICENSE`, o
  repositório fica visível e juridicamente inútil.
- **Autoria apenas "Wesley Menezes".** Nunca citar o nome de nenhuma empresa.
- **Nenhuma citação interna.** Nada de nome de cliente, nome de produto nosso,
  post-mortem que nomeie o produto, caminho de repositório interno, print de
  painel nosso, nem nome de concorrente em comparação. A regra e o número que
  a sustenta podem ficar; quem era quem, não.
- **As skills versionadas entram redigidas.** O hook
  `~/.claude/hooks/ensure-global-skills.cjs` repropaga as skills no
  SessionStart e **pode desfazer a redação**. Conferir antes de todo commit:

```bash
# A lista de nomes a procurar fica no CLAUDE.md global da máquina, não aqui:
# escrevê-la neste arquivo publicaria justamente o que ela existe para
# esconder. Guarde-a em ~/.nomes-internos (fora do repositório) e rode:
grep -rliFf ~/.nomes-internos .claude/ docs/ *.md
```

A skill `archify` não está versionada aqui de propósito: são 5,4 MB e 128
arquivos de ferramenta de diagrama num repositório que entrega um script de
shell. A cópia global na máquina continua intacta e ativa.

### Conferência antes de publicar, nessa ordem

1. **Segredo.** Chave privada, prefixo de token conhecido, JWT, e
   `senha|password|secret|token|api_key` com valor atribuído.
2. **Caminho local.** Caminho absoluto do Windows com nome de usuário, e
   `AppData`.
3. **Artefato que não devia estar lá.** `.env`, `.pem`, `.key`, `id_rsa`, dump
   de API. Em 09/10/2026 havia um `Untitled-1.json` aqui: dump de `getUpdates`
   do Telegram com o chat ID do grupo de alertas, o user ID e o username
   pessoal, commitado por acidente e público por meses. Foi removido do
   rastreamento, e o `.gitignore` agora cobre `Untitled-*.json` e
   `getUpdates*.json`. **Remover no último commit não tira do histórico.**
4. **`.gitattributes` com `* text=auto eol=lf`.** Sem ele, clone no Windows com
   `autocrlf` devolve o script em CRLF, o shebang fica com um retorno de carro
   no fim, e o Linux responde `bad interpreter: no such file or directory`, que
   ninguém liga a fim de linha. Este repositório entrega script de shell: a
   regra não é opcional aqui.
5. **Histórico.** Conferir se algo sensível entrou e saiu em commit anterior.

## O agente é gerado, não escrito à mão

**Nunca editar `monitoring-agent.sh`, `monitor_cpu.sh`, `monitor_memory.sh` nem
`monitor_disk.sh` na raiz.** Eles são artefatos do build, e a próxima execução
de `scripts/build.sh` sobrescreve.

A fonte fica em `src/agent/`, um módulo por responsabilidade, concatenados na
ordem do prefixo numérico.

```bash
./scripts/build.sh          # monta a raiz e o manifesto
./scripts/build.sh --check  # falha se a raiz está desatualizada
```

O motivo é concreto: este repositório já teve a mesma lógica escrita em dois
lugares (os monitores na raiz e cópias embutidas em `update_scripts.sh`). As
duas divergiram, e a cópia embutida perdeu o bloco que envia métricas ao
painel. Quem rodasse `update_scripts.sh` desligava o próprio dashboard sem
receber aviso nenhum.

## Validação antes de qualquer commit

```bash
./scripts/build.sh
./tests/roda-testes.sh        # 134 verificações de unidade
./tests/testa-idioma.sh       # 112 verificações dos três idiomas
./tests/testa-migracao.sh     #  31 verificações de migração ponta a ponta
./tests/testa-remetente.sh    #  28 verificações do remetente e do Postfix
./tests/testa-envio-email.sh  #  25 verificações do envio de e-mail
./tests/testa-ruido.sh        #  77 verificações do que NÃO deve virar alerta
```

Todas precisam estar verdes. Elas rodam em qualquer máquina com
bash e awk, inclusive Windows com Git Bash, porque toda fonte de dado do
agente é injetável (`PROC_STAT`, `PROC_MEMINFO`, `PROC_LOADAVG`, `FIXTURE_DF`).

**Teste novo para todo defeito corrigido.** A bateria tem um teste que compara
a conta de memória nova com a antiga justamente para aquele defeito não voltar.

## O que não pode quebrar, nunca

### O formato que o canal antigo edita

Os artefatos precisam manter estas linhas, começando exatamente assim:

```
CPU_THRESHOLD=90
MEM_THRESHOLD=90
DISK_THRESHOLD=90
RECIPIENTS="RECIPIENTS_PLACEHOLDER"
```

O `dashboard_fetch_updates.sh` dos servidores que ainda não migraram aplica
`sed -i "s/^CPU_THRESHOLD=.*/..."` nesses arquivos. Mudar o formato corta a
ponte e deixa esses servidores sem receber limiar e destinatário do painel.
A bateria tem uma verificação para cada uma dessas quatro linhas.

### Os auxiliares de envio entram no manifesto

`send_html_alert.sh` e `send_telegram_alert.sh` vivem em `/usr/local/bin`, que
é onde o atualizador instala, então eles são distribuíveis como o agente. A
fonte fica em `src/envio/` e o build os publica na raiz.

Isso foi descoberto tarde: antes eles existiam só dentro do instalador, e um
servidor já instalado nunca os recebia de volta. A data em UTC e o cabeçalho
em português ficavam cravados para sempre.

### Cabeçalho de e-mail só aceita ASCII

Assunto e nome do remetente passam por `codifica_cabecalho()` em
`src/envio/send_html_alert.sh`, que converte em encoded-word da RFC 2047 quando
há byte fora do ASCII e devolve o texto intacto quando não há.

Isso não é detalhe de formatação. O motivo é concreto: a 2.1.0 trocou
`[ATENCAO]` por `[ATENÇÃO]` e `[CRITICO]` por `[CRÍTICO]` no catálogo, o MTA
passou a recusar esses cabeçalhos, e **o alerta de abertura parou de chegar
para a frota inteira**. Só o de recuperação saía, porque `[OK]` e `[SEGUE]` são
ASCII puro. Durou da 2.1.0 à 2.3.0.

Quem acrescentar prefixo de severidade, nome de métrica ou saudação em
cabeçalho de e-mail passa pela função. A bateria `testa-envio-email.sh` confere
nos três idiomas, e confere que o texto **decodifica de volta igual**, porque
codificar errado troca um alerta que não chega por um que chega ilegível.

### Um envio por destinatário

O `mail` espera um endereço por argumento. A lista do painel vem separada por
vírgula, e passá-la inteira faz ele tratar tudo como endereço único: foi o que
deixou só o primeiro da lista recebendo até a 2.3.0.

O laço envia um por um e devolve sucesso se ao menos um passou. Endereço com
erro de digitação no meio da lista não pode calar o alerta para o resto do
time, e cada falha vai para o registro com o endereço.

### O manifesto coerente com os arquivos

`agent.manifest` traz o SHA-256 de cada artefato. Se ele não bater com o que
está publicado, **todo agente da frota recusa a atualização** e fica parado na
versão anterior, em silêncio. Rodar o build sempre antes de commitar resolve;
a bateria confere os quatro checksums.

### Subir versão ao mudar o agente

`agent.version` é o que decide se a frota atualiza. Mudança em `src/agent/`
sem subir a versão não chega a servidor nenhum.

## Dependências que não podem voltar

`bc` e `mpstat` saíram de propósito. Podem faltar em servidor mínimo, e com
`set -euo pipefail` a ausência matava o monitor em silêncio: nenhum alerta
saía, e ninguém percebia. Toda aritmética é em `awk`, que é POSIX.

Pelo mesmo motivo o agente **não usa `set -e`**. Um `curl`, `du` ou `ps` que
falhe não pode derrubar a rodada inteira, porque o resultado seria um servidor
sem vigilância e ninguém sabendo.

## Idioma dos alertas

Catálogo em `src/agent/25-idioma.sh`, três idiomas: `pt-BR`, `en-US`, `es-CO`.
Todo texto que sai para uma pessoa passa por `t <chave>`.

`es-CO` é o padrão porque servidor sem painel não tem de quem herdar idioma.

**Nome de métrica não se traduz.** CPU, Swap, Inodes, Load average e contenção
de CPU são iguais nos três, porque é assim que aparecem no `top`, no `vmstat`
e no painel do provedor: é por esse nome que a pessoa pesquisa.

**"CPU roubada" não volta.** Era tradução literal, não existe em ferramenta
nenhuma e assusta quem lê. Há teste nos três idiomas garantindo isso.

O catálogo passa por `printf`: `%` literal precisa vir como `%%`. Errar isso
deixa `40%%` no corpo do e-mail ou come o argumento seguinte.

Os templates em `/opt/alerts/templates` são **reescritos pelo agente** quando
o idioma muda. Eles vêm do instalador com rótulo fixo em português, e a
reescrita é o único caminho para traduzi-los. As quatro variáveis
`${TITLE} ${MESSAGE} ${DATE} ${HOST}` precisam continuar literais no arquivo:
quem substitui é o `envsubst` dentro do `send_html_alert.sh`, no envio.

## Steal e load não são alerta sozinhos

Em instância burstable, steal aparece toda vez que a máquina usa burst acima
do baseline: é o mecanismo funcionando. Medição de 09/10/2026 num `t3a.xlarge`
deu steal de 16,6% com a CPU em 29,5% e load de 0,41 por núcleo, servidor
tranquilo, e virou e-mail porque o limiar era 10 e não olhava mais nada.

Hoje o limiar é 25 **e** a avaliação exige CPU acima do limiar de atenção no
mesmo ciclo. Steal só é problema quando o servidor quer CPU e o provedor não
dá. Com a CPU baixa ele continua aparecendo no corpo e no diagnóstico, que é
onde serve.

**O load caiu na mesma regra em 15/10/2026**, pelo mesmo motivo e com medição
própria: um servidor de 8 núcleos com load 1.56 por núcleo, CPU em 67.9%,
iowait em 1.0% e 18.6 GB livres renotificava de hora em hora havia seis dias.
Estava trabalhando, não sofrendo.

Load é medida de fila, não de dano. A decisão vive em `load_vira_alerta()`, em
`50-avaliar.sh`, fora do fluxo da rodada, justamente para poder ser conferida
com os números do caso real. Ela exige CPU acima do limiar de atenção **ou**
iowait acima de `IOWAIT_ATENCAO`. O limiar de fábrica subiu de 1.5 para 2.5 por
núcleo, e o load continua medido, continua na tabela de contexto de todo alerta
e continua indo para o painel.

## A banda de saída vem na unidade da métrica

`banda_de()` devolve pontos percentuais para as métricas percentuais e fila por
núcleo para o load. O ponto de saída da histerese é `limiar - banda`, preso em
zero quando dá negativo.

Com os 8 pontos percentuais aplicados ao load, o ponto de saída de um limiar
2.5 dava `-5.5`, virava zero, e **o incidente de load só se fecharia com o load
exatamente zero**. Load zero não existe em servidor ligado: o incidente abria e
nunca mais saía, renotificando para sempre.

Foi o pior dos defeitos do e-mail de 15/10/2026 e o único que não aparece
olhando para limiar nenhum. Métrica nova que não seja percentual precisa da
própria banda aqui.

## A renotificação dobra, e isso não é detalhe

`espera_renotificacao()` dobra a espera a cada repetição do mesmo incidente, de
`RENOTIFICAR_MIN` até `RENOTIFICAR_MAX_MIN`: 1h, 2h, 4h, 8h, 16h, 24h, 24h.

Intervalo fixo foi o que transformou um incidente de seis dias em perto de 148
e-mails idênticos. Alerta que chega sempre igual vira filtro de caixa de
entrada, e aí o alerta que importa também morre lá.

Abrir e escalar zeram o contador: piorar de verdade merece a atenção inteira de
novo. `RENOTIFICAR_MIN=0` continua desligando a renotificação.

## O alerta é escrito para ser entendido de olho batido

A ordem é a das perguntas de quem abre o e-mail:

1. **O que houve**, em uma frase, no assunto e no título. Nunca o nome cru da
   métrica com o número do lado.
2. **O que isso causa** para quem usa o servidor (`impacto_metrica`).
3. **Se precisa de alguém agora** (`urgencia`), dito sem número nenhum.
4. **O que fazer**, que é o diagnóstico de sempre.
5. **Detalhes técnicos**: valor, limiar, há quanto tempo, tabela, processos.

O assunto fica `[ATENÇÃO] nome-do-servidor: CPU no limite (97%)`. O que motivou
isso foi um e-mail de produção que abria com `Load average en 1.56`, sobre o
qual a reação foi: não dá para saber do que se trata.

**Frase nova de métrica entra nos três catálogos**, com `frase_<metrica>`,
`sujeito_<metrica>` e `impacto_<metrica>`. A bateria `testa-ruido.sh` confere a
ordem dos blocos no corpo e que nenhum idioma vazou para dentro do outro.

**O medidor não entra na lista de processos.** O `ps` aparecia em primeiro
lugar com 400%, porque o percentual dele é calculado sobre uma vida de
milissegundos, e o agente logo abaixo: o alerta parecia acusar o próprio
monitoramento.

## Texto que a pessoa lê

Alerta, registro e documentação passam pelo `humanizer`.

**Sem travessão**, em nenhuma posição, nem meia-risca nem barra horizontal.
A bateria reprova se aparecer um em `src/` ou `docs/`.

## Entrega

- `docs/SDD_<NOME>.md` antes de codar, para mudança não trivial.
- `PRD.md` atualizado na mesma entrega.
- Branch `feat/` ou `fix/`, nunca commit direto em `main`.
- `git pull` antes de todo `git push`.
- Nunca deletar branch, tag, commit ou stash.
- Commit e push a cada funcionalidade entregue, não só no fim.
