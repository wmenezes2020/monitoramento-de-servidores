# SDD: o alerta tem que ser entendido de olho batido, e só sair quando importa

Versão 2.4.0. Nasce de um e-mail real recebido em 15/10/2026.

## O e-mail que motivou isto

Assunto: `[CONTINÚA] Load average 1.56 - <servidor>`
Título: `Load average en 1.56 en <servidor>`
Corpo: `Así desde hace 6d4h, pico de 2.29. Confirmado en 3 lecturas seguidas.`

Leitura de quem recebeu, na palavra dele:

> Esse e-mail chegou mais confuso que tudo, você esqueceu tudo tem que ser
> NO BRAIN, e aqui não tem nenhuma clareza do que se trata de fato, todo aviso
> deve ser bem claro e objetivo: bater o olho e já saber do que se trata.
> E só gerar avisos importantes de fato.

Ele está certo nos dois pontos, e o e-mail revela seis defeitos.

## Os seis defeitos

### 1. Um incidente de seis dias renotificando de hora em hora

`RENOTIFICAR_MIN` é 60 e o intervalo é fixo. Um incidente aberto há 6d4h já
gerou perto de 148 e-mails iguais. Isso é exatamente o que o projeto existe
para não fazer: treinar a pessoa a ignorar o aviso.

### 2. O load sozinho não é incidente

O servidor do e-mail estava com load 1.56 por núcleo, CPU em 67.9%, iowait em
1.0%, memória em 40.2% e 18.6 GB livres. Ou seja: trabalhando, não sofrendo.
O limiar de 1.5 por núcleo transforma qualquer servidor de build ou de banco
em alerta permanente.

Load é medida de fila, não de dano. Fila que importa vem acompanhada de CPU
saturada ou de espera de disco, e nesses dois casos quem precisa ser dito é a
CPU ou o iowait.

### 3. O texto é jargão, não informação

"Load average en 1.56" não diz a quem lê se o site está fora do ar, se precisa
levantar da cama, ou o que fazer. Um número e uma unidade não são um aviso.

### 4. Cabeçalho em português dentro de um e-mail em espanhol

`90-main.sh` monta o bloco de processos com `<strong>Processos por CPU</strong>`
cravado, embora as chaves `corpo_proc_cpu` e `corpo_proc_mem` existam nos três
idiomas desde a 2.1.0.

### 5. A lista de processos acusa o próprio medidor

O primeiro item da lista do e-mail é:

```
1737724 root  400%  0.0%  ps -eo pid,user,pcpu,pmem,comm,args --sort=-%cpu
```

É o próprio comando de medição, e logo abaixo aparece o próprio agente. Quem
lê conclui que o monitoramento é o que está consumindo o servidor.

### 6. O incidente de load nao tinha como se fechar

Achado ao conferir o fechamento, depois que os cinco acima ja estavam
corrigidos, e e o mais grave dos seis.

A banda de saida da histerese vinha em pontos percentuais para toda metrica.
O ponto de saida e `limiar - banda`, preso em zero quando da negativo:

```
CPU:  85 - 8 = 77     sai abaixo de 77, faz sentido
load: 2.5 - 8 = -5.5  preso em 0, so sairia com load EXATAMENTE zero
```

Load zero nao existe em servidor ligado. Medido com o agente:

```
load 3.0 -> abrir
load 1.2 -> nada (nivel guardado: atencao)
load 0.8 -> nada (nivel guardado: atencao)
load 0.1 -> nada (nivel guardado: atencao)
```

Ou seja: o incidente de load abria e **nunca** se fechava, e ficava
renotificando para sempre. Isso sozinho explica os seis dias, mesmo sem os
outros cinco defeitos.

A banda passou a vir na unidade da metrica, por `banda_de()`: pontos
percentuais para percentual, fila por nucleo para load (0.3, entao um limiar
de 2.5 sai abaixo de 2.2).

## Objetivo

1. Bater o olho no assunto e saber qual servidor, o que houve e se precisa
   agir agora.
2. Só gerar alerta que corresponde a problema de verdade.
3. Um incidente longo avisa cada vez menos, em vez de todo dia da mesma forma.

## Solução

### Menos aviso: espaçamento que dobra

A renotificação passa a dobrar a cada repetição, a partir de
`RENOTIFICAR_MIN`, com teto em `RENOTIFICAR_MAX_MIN` (padrão 1440, um dia):

```
1h, 2h, 4h, 8h, 16h, 24h, 24h, 24h...
```

Seis dias de incidente passam de perto de 148 e-mails para 10. A escalada de
atenção para crítico zera o contador, porque piorar de verdade vale interromper
alguém de novo.

### Menos aviso: load precisa de sintoma junto

Mesma regra que a 2.1.0 aplicou ao steal. Load só é avaliado quando, no mesmo
ciclo, a CPU está acima do limiar de atenção **ou** o iowait está acima de
`IOWAIT_ATENCAO` (padrão 25). O limiar sobe de 1.5 para 2.5 (atenção) e de 3.0
para 4.0 (crítico).

O load continua medido, continua na tabela de contexto de todo alerta e
continua indo para o painel. O que muda é só ele deixar de abrir incidente
sozinho.

Quando a condição deixa de valer com um incidente de load aberto, ele é
fechado pelo caminho normal, com aviso de recuperação, em vez de ficar
pendurado.

### O aviso em linguagem de gente

Ordem nova do e-mail, de cima para baixo:

1. **O que houve**, em uma frase, no título e no assunto.
2. **O que isso causa** para quem usa o servidor.
3. **Se precisa de alguém agora**, dito com essas palavras.
4. **O que fazer**, que já existia como "Por onde começar".
5. **Detalhes técnicos**: valor, limiar, há quanto tempo, tabela, processos.

Assunto antes e depois:

```
antes:  [CONTINÚA] Load average 1.56 - <servidor>
depois: [ATENCIÓN] <servidor>: CPU al límite (97%)
```

A frase é por métrica, nos três idiomas:

| métrica | frase |
| --- | --- |
| cpu | CPU no limite (97%) |
| memoria | Memória quase cheia (98%) |
| disco | Disco quase cheio (91%) |
| inode | Disco sem espaço para arquivo novo |
| swap | Swap em uso alto (85%) |
| load | Fila de processos esperando CPU |
| steal | O provedor está limitando a CPU |

A linha de urgência tem três estados e nenhum deles usa número: "Precisa de
alguém agora", "Não é emergência, dá para resolver hoje", "Nada a fazer, é só
para registro".

### Os dois defeitos pequenos

O bloco de processos passa a usar `t corpo_proc_cpu` e `t corpo_proc_mem`, que
já existiam. E `top_processos()` deixa de fora o próprio `ps` e o próprio
agente, pelo PID da rodada e pelo nome do comando.

## Não-objetivos

- Não mexe na medição. O que o agente mede continua igual; muda o que ele
  decide contar e como escreve.
- Não acrescenta canal nem painel novo.
- Não torna o limiar de load configurável por métrica no painel: quem quiser
  o comportamento antigo ajusta `LOAD_ATENCAO` e `IOWAIT_ATENCAO` no arquivo
  de configuração.

## Validação

Bateria nova `tests/testa-ruido.sh`, com o caso medido do e-mail real:
load 1.56 por núcleo, CPU 67.9%, iowait 1.0%, que **não pode** gerar alerta.
Mais o espaçamento dobrando até o teto, a escalada zerando o contador, e a
lista de processos sem o medidor dentro.

As chaves novas entram nos três catálogos, e a bateria de idioma confere
paridade e que nenhuma frase de assunto saiu em outro idioma.
