# CLAUDE.md: monitoramento-de-servidores

Regras deste repositório. Valem junto das globais.

## Passo zero de toda tarefa: consultar o grafo

**Antes do SDD e antes do PRD, sempre.** Não é "quando eu precisar entender":
é a primeira coisa.

Esta seção vale para quem desenvolve neste repositório. Ela não vale para
quem revisa: não muda a ordem, o escopo nem o critério de nenhuma revisão,
automática ou humana, e não substitui as instruções da plataforma que as
executa.

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

## O instalador não carrega cópia dos scripts de envio

`send_html_alert.sh` e `send_telegram_alert.sh` vêm do **manifesto**, com
checksum conferido, junto do agente. O instalador não os escreve.

Eles já vieram embutidos nele, e a cópia ficou velha: só sabia usar o `mail` do
Postfix local. A cada instalação ela apagava do servidor as correções das
versões 2.3, 2.4 e 2.5, e com conta de e-mail vinda do painel o instalador nem
instala o `mail`. Resultado, em 16/10/2026: dois servidores reinstalados, nenhum
e-mail, nem o de boas-vindas.

O agravante que fecha a armadilha: o instalador baixa **a versão publicada** do
agente, então a auto-atualização não tem o que fazer e o enviador velho fica
lá para sempre, até sair uma versão nova.

Isto é o mesmo erro que já está documentado logo abaixo, na seção do bundle,
pela segunda vez e no mesmo lugar. `tests/testa-instalador.sh` existe para não
haver terceira.

**Os limiares do `agent.conf` gerado também são conferidos lá**, contra os
padrões de `20-config.sh`. O arquivo vence o padrão do código: gravar valor
velho ali desfaz, em toda instalação nova, a correção feita no agente. Foi o
que aconteceu com `LOAD_ATENCAO=1.5` e `STEAL_ATENCAO=10`, que o instalador
continuava gravando depois de a 2.4 tê-los corrigido.

## A instalação é a fonte da verdade, e a atualização também

Rodar o instalador numa máquina que já tem o agente tem que deixar tudo igual
ao que o painel diz. Enquanto o `agent.conf` era preservado, o servidor
reinstalado seguia com os limiares de meses atrás, e a única forma de a
instalação valer alguma coisa era apagar o arquivo à mão antes.

O que a instalação faz agora, sempre:

- **reescreve o `agent.conf`** com os padrões desta versão, guardando o
  anterior em `agent.conf.anterior`;
- **apaga a marca `/opt/alerts/templates/.idioma`**, para o agente reescrever
  os cinco templates no idioma da empresa. Os templates nascem em português;
  sem apagar a marca, um servidor em espanhol ficava com eles em português;
- **tira da máquina o serviço que saiu do painel**: conta de envio e bot
  viram `.anterior` e param de valer. Sem isso, o alerta continuava saindo por
  uma conta que o dono achava que tinha desligado. **Só com o painel
  conectado**: sem painel não há fonte da verdade, e apagar seria desligar o
  que a pessoa configurou à mão;
- **termina sincronizando** (`monitoring-agent.sh sincronizar`), para a
  máquina sair da instalação já valendo o que o painel diz, em vez de esperar
  a rodada de cinco minutos.

**A atualização automática fecha o mesmo ciclo.** Binário novo não basta: o
cron, os templates e a configuração do painel vêm junto, logo depois do
autoteste verde. A ordem não é estilo: mexer no cron com um agente que não
sabe rodar trocaria uma falha de atualização por um servidor sem
monitoramento. E nenhuma das três desfaz a atualização, porque a versão nova
já provou que roda.

**A marca dos templates carrega a versão** (`es-CO+2.6.3`), e não só o idioma.
Template corrigido numa versão nova não chegava a quem já estava instalado: o
idioma continuava o mesmo, a marca batia, e o servidor ficava com o arquivo
velho para sempre.

**O `dashboard.conf` é a exceção, de propósito.** Reinstalar sem conectar ao
painel não apaga o vínculo: a regra existe para a máquina espelhar o painel, e
cortar o painel é o oposto disso.

## Com o UUID na chamada, o instalador não pergunta nada

```bash
curl -fsSL <endereço>/install-monitoring.sh | sudo bash -s -- --uuid=<UUID>
```

Isso é o modo silencioso: `MODO_SILENCIOSO=1`, configuração inteira vinda do
painel, e nenhuma pergunta. O que o painel não tiver fica de fora, com aviso no
resumo do final.

**Toda pergunta nova do instalador precisa ficar dentro de um caminho que o
modo silencioso não percorre.** Uma pergunta solta trava a instalação
automatizada para sempre, porque não há ninguém no teclado para responder, e o
`read` fica esperando até o cron matar a sessão. `tests/testa-instalador.sh`
conta os `read ... </dev/tty` do arquivo justamente para uma pergunta nova não
entrar sem passar por aqui: subiu a conta, atualize o número e prove que a
pergunta está no ramo interativo.

O leitor de argumentos fica entre os marcadores
`# --- Instalacao silenciosa: o UUID vem na chamada` e
`# --- fim do leitor de argumentos ---`, antes da checagem de root, para que
`--help` funcione sem sudo e para a bateria conseguir recortá-lo e executá-lo
de verdade. Grep não prova que `--uuid` funciona.

**UUID malformado para a instalação com erro.** Cair no fluxo de perguntas
deixaria o servidor com agente instalado e invisível no painel, que é o pior
dos dois mundos. Pelo mesmo motivo, painel que não responde encerra a
instalação silenciosa em vez de seguir sem configuração.

Desenho em `docs/SDD_INSTALACAO_SILENCIOSA.md`.

## A mensagem sai com CRLF, e isso foi um defeito de dois dias

O RFC 5322 exige CRLF no fim de cada linha. O arquivo que o
`send_html_alert.sh` monta tem LF solto, como todo arquivo de texto no Linux.
Quem converte é o `curl`, com **`--crlf`**, e sem essa opção a mensagem sai
malformada, inclusive na linha em branco que separa cabeçalho de corpo.

**O servidor de e-mail responde `250` do mesmo jeito.** O envio "dá certo", o
`curl` volta com código 0, o instalador diz "E-mail de boas-vindas enviado", e
a mensagem some depois, sem erro em lugar nenhum. Foi o que aconteceu em 17 e
18/10/2026: duas reinstalações, nenhum e-mail, e nada no servidor apontando
para o problema.

Medido contra um servidor SMTP de mentira que grava os bytes crus: sem
`--crlf` chegavam 9 fins de linha LF e 2 CRLF; com `--crlf`, 10 CRLF e nenhum
LF.

**Converter duas vezes é tão ruim quanto não converter.** Conteúdo que já
tivesse CR viraria `CRCRLF`, que é outra forma de mensagem malformada. Por
isso `monta_mime` limpa o CR do corpo antes de gravar, e o arquivo chega ao
`curl` com LF puro.

A bateria confere o argumento, não a saída: quem converte é o `curl`, e o que
está em jogo é ele receber a ordem.

## A conversa com o servidor de e-mail entra no registro, menos o AUTH

`send_html_alert.sh` chama o `curl` com `--verbose` e guarda a conversa num
arquivo com permissão 600, criado antes de receber qualquer byte. Do que está
lá, só entram no registro as linhas que **começam com `< `**, que são as
respostas do servidor.

**O filtro é por lista de permissão, e isso não é estilo.** O `curl` prefixa
com `> ` o que ele envia, e a linha `AUTH PLAIN` carrega usuário e senha em
base64. Filtro que remove o que conhece deixa passar o que não conhece, e aqui
o que passaria é a credencial da empresa, num arquivo de log que vai inteiro
para quem pedir ajuda com um problema de entrega.

**O sucesso também é registrado, e é a parte que faltava.** Aceitar não é
entregar: o servidor responde `250` com o identificador da fila, e é por ele
que se acha a mensagem no painel do provedor. Em 17/10/2026 um servidor foi
instalado, o envio deu certo, o alerta não chegou, e não havia no servidor uma
linha sequer que dissesse qual mensagem procurar.

`tests/testa-envio-email.sh` tem o `curl` de mentira com a linha do `AUTH` no
meio da conversa, justamente para provar que ela não vaza.

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
./tests/testa-servicos.sh     #  56 verificações dos serviços vindos do painel
./tests/testa-instalador.sh   #  33 verificações do instalador
./tests/testa-config-do-painel.sh  # 29 verificações do que chega do painel
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

### MTA nosso tem precedência; direto só no que não é nosso

A regra tem duas metades, e a ordem entre elas importa:

1. **O Postfix da máquina é nosso** (tem a marca do instalador no `main.cf`):
   a conta do painel é aplicada NELE, por `aplica_relay_no_postfix`, e o envio
   continua saindo pela própria máquina, como sempre saiu. Atualizar o que é
   nosso é diferente de mexer no que não é.
2. **O serviço de e-mail é de outra pessoa, ou não existe:** nada é tocado, e o
   envio vai direto ao SMTP por `curl`.

`mta_e_nosso()` existe nos dois lados, no agente e no enviador, e procura a
mesma linha: `# --- Sistema de Monitoramento de Servidores ---`.

No caminho direto, o agente não instala Postfix, não edita `main.cf`, não toca
em `sasl_passwd` nem em `generic`.

O motivo é concreto: `detect_mail_conflict`, no instalador, acha Postfix, Exim,
Sendmail ou cPanel e **desliga o e-mail** para não brigar com eles. Protege o
servidor e deixava o monitoramento mudo, para sempre, sem ninguém notar.

Dois pontos que não podem ser relaxados:

- **Senha nunca na linha de comando.** `--user usuario:senha` fica visível no
  `ps` para qualquer usuário da máquina. Ela vai num arquivo de configuração do
  `curl`, com permissão 600 antes de receber conteúdo, apagado no fim.
- **`--ssl-reqd` fora da porta 465.** Servidor sem TLS faz o alerta não sair,
  em vez de a credencial viajar em texto claro.

`testa-servicos.sh` cobre os três casos com o mesmo servidor de teste: com a
marca, sem a marca e sem `main.cf` nenhum. No caso de terceiro, compara
`main.cf`, `sasl_passwd` e `generic` byte a byte depois do envio.

**Trocar a conta no painel tira do `sasl_passwd` a linha do relay anterior**,
que era nossa e guardava uma senha que não serve mais. Linha de qualquer outro
destino fica: pode ser regra que alguém somou à mão.

### Bloco ausente não apaga configuração

Em `aplica_servicos_do_painel`, bloco que não veio quer dizer "nada escolhido
no painel", e não "apague o que existe". Quem nunca abriu a tela de serviços
não pode perder o envio que já funcionava.

Os arquivos `smtp.conf` e `telegram.conf` nascem com 600 **antes** de receber
conteúdo: criar aberto e apertar depois deixa uma janela em que a senha fica
legível para qualquer usuário da máquina.

### Teste que o ambiente não consegue provar é pulado, não aprovado

`chmod` não tem efeito em todo sistema de arquivos: no Git Bash sobre NTFS ele
é aceito e ignorado. `testa-servicos.sh` descobre isso sozinho e marca a
verificação como **pulada**, com o motivo. Marcar verde ali seria dizer que a
permissão foi conferida quando não foi.

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

## O agent.conf vence o padrão do código

Quem escreve no `agent.conf` manda, porque `20-config.sh` só preenche o que
ainda não está lá. Isso tem uma consequência que custou caro: **valor gravado
na instalação vale para sempre**, e correção feita no padrão do agente não
alcança quem já está instalado.

Foi assim que dois servidores instalados em 16/10/2026 nasceram com
`LOAD_ATENCAO=1.5` e `STEAL_ATENCAO=10`, desfazendo em silêncio a correção da
2.4.

Por isso **tudo que o agente sabe aplicar chega do painel** desde a 2.6.0:
limiares de fila, contenção, swap, inodes e espera de disco, teto da
renotificação, banda de saída da fila, o que vigiar, por onde avisar e a lista
de montagens ignoradas.

**O número do painel pode ser decimal.** O parser lia só `[0-9]+`: a fila por
núcleo chega como `2.5` e era descartada sem deixar rastro, então o valor local
continuava mandando. Parâmetro novo entra na mesma lista de pares em
`sincroniza_config`, e a bateria `testa-config-do-painel.sh` confere o caminho
inteiro com um `curl` de mentira.

**Campo ausente mantém o que está no servidor.** Vale para a lista de montagens
ignoradas em especial: mandar vazio apagaria o filtro e faria voltar o alerta
de volume de container, que não é problema de ninguém.

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

## Sem destinatário o e-mail não sai, e não avisa que não saiu

Três defeitos no mesmo caminho, todos calados, achados em 17/10/2026 depois de
dois servidores reinstalados passarem a mandar alerta pelo Telegram e nenhum
por e-mail:

1. **A reinstalação reescrevia o `email.conf` do zero** e levava embora a linha
   `RECIPIENTS`. Ela era regravada depois, mas só quando a instalação tinha
   algum destinatário em mãos. Quem recebia alerta parava de receber.
2. **Com a conta de e-mail vinda do painel, a instalação nem perguntava o
   destinatário.** Conta de envio e destinatário são dois cadastros diferentes:
   ter um não garante o outro.
3. **Sem destinatário, o agente não chamava o enviador e não registrava nada.**
   O `60-notificar.sh` exigia `-n RECIPIENTS` na mesma condição que decide o
   envio, então a ausência virava silêncio em vez de erro.

Hoje `garante_destinatarios`, no instalador, procura no painel, depois no que
já está na máquina, e só então pergunta. A linha `RECIPIENTS` nasce no mesmo
`printf` do resto do `email.conf`. E o agente registra o alerta que não saiu por
falta de destinatário.

O autoteste também avisa, com `_aviso` e **não** com `_fail`: o autoteste decide
o rollback da auto-atualização, e reprovar ali por configuração faltando
prenderia o servidor na versão antiga para sempre.

### O `\1` do sed virou um byte 0x01 dentro do arquivo

No mesmo caminho, a parte de troca do sed que lê o remetente estava vazia
(`.*//p` em vez de `.*/\1/p`), e em algum momento o `\1` foi gravado como um
byte de controle literal por um script de edição. O shell não reclama, o sed não
reclama, e a substituição devolve um caractere de controle onde deveria vir o
endereço: o remetente escolhido na tela do servidor nunca saiu do painel.

`tests/testa-destinatario.sh` varre `src/` e os artefatos da raiz por byte de
controle (ESC fica de fora, é o que desenha cor no terminal) e confere o caminho
inteiro do remetente com um `curl` e um `postmap` de mentira.

## Entrega

- `docs/SDD_<NOME>.md` antes de codar, para mudança não trivial.
- `PRD.md` atualizado na mesma entrega.
- Branch `feat/` ou `fix/`, nunca commit direto em `main`.
- `git pull` antes de todo `git push`.
- Nunca deletar branch, tag, commit ou stash.
- Commit e push a cada funcionalidade entregue, não só no fim.
