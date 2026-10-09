
# ---------------------------------------------------------------------------
# Idioma
# ---------------------------------------------------------------------------
#
# Tres idiomas: pt-BR, en-US e es-CO. O idioma chega do painel, junto com os
# limiares, e vale para e-mail, Telegram e para os templates HTML em disco.
#
# O padrao e es-CO de proposito: servidor instalado sem conectar ao painel nao
# tem de quem herdar idioma, e a decisao do dono foi essa.
#
# Nome de metrica: Swap, Inodes e Load average ficam como estao, porque e
# assim que aparecem no top, no vmstat, no CloudWatch e no Grafana.
#
# "steal" e o caso que precisou de cuidado. "CPU roubada" era traducao literal,
# nao existe em ferramenta nenhuma e assusta quem le: roubo sugere invasao,
# quando o fenomeno e o provedor limitando a fatia contratada. O rotulo passou
# a ser "Contencao de CPU" (CPU contention, termo usado em VMware, Nutanix e
# Kubernetes), e a palavra "steal" continua na linha tecnica da tabela de
# contexto, que e onde ela serve: para a pessoa pesquisar.

idioma_normalizado() {
  case "$(printf '%s' "${IDIOMA:-es-CO}" | tr '[:upper:]' '[:lower:]')" in
    pt*) printf 'pt' ;;
    en*) printf 'en' ;;
    *)   printf 'es' ;;
  esac
}

# t CHAVE [args...] -> texto no idioma vigente, com printf aplicado.
# Chave sem traducao no idioma cai no espanhol, que e o padrao do produto, em
# vez de sumir e deixar um alerta com buraco no meio.
t() {
  local chave="$1"; shift
  local modelo
  case "$(idioma_normalizado)" in
    pt) modelo="$(msg_pt "$chave")" ;;
    en) modelo="$(msg_en "$chave")" ;;
    *)  modelo="$(msg_es "$chave")" ;;
  esac
  [[ -z "$modelo" ]] && modelo="$(msg_es "$chave")"
  [[ -z "$modelo" ]] && modelo="$chave"
  # shellcheck disable=SC2059
  printf "$modelo" "$@"
}

# Nomes que NAO se traduzem, em nenhum idioma.
rotulo_metrica() {
  case "$1" in
    cpu)          printf 'CPU' ;;
    memoria)      printf '%s' "$(t rotulo_memoria)" ;;
    disco)        printf '%s' "$(t rotulo_disco)" ;;
    inode)        printf 'Inodes' ;;
    swap)         printf 'Swap' ;;
    load)         printf '%s' "$(t rotulo_load)" ;;
    steal)        printf '%s' "$(t rotulo_steal)" ;;
    agent_update) printf '%s' "$(t rotulo_agente)" ;;
    *)            printf '%s' "$1" ;;
  esac
}

unidade_metrica() {
  case "$1" in
    load) printf '' ;;
    *) printf '%%' ;;
  esac
}

prefixo_assunto() {
  case "$1" in
    abrir)    printf '[%s]' "$(t sev_atencao)" ;;
    escalar)  printf '[%s]' "$(t sev_critico)" ;;
    repetir)  printf '[%s]' "$(t sev_segue)" ;;
    resolver) printf '[%s]' "$(t sev_ok)" ;;
    *)        printf '[%s]' "$(t sev_aviso)" ;;
  esac
}

# Data no formato que cada lugar le sem precisar pensar.
data_local() {
  case "$(idioma_normalizado)" in
    en) date '+%Y-%m-%d %H:%M:%S %Z' ;;
    *)  date '+%d/%m/%Y %H:%M:%S %Z' ;;
  esac
}

duracao_humana() {
  local s="${1:-0}"
  awk -v s="$s" -v u_s="$(t dur_segundos)" -v u_m="$(t dur_minutos)" \
      -v u_h="$(t dur_horas)" -v u_d="$(t dur_dias)" 'BEGIN{
    s = int(s)
    if (s < 60)    { printf "%d%s", s, u_s; exit }
    if (s < 3600)  { printf "%d%s", int(s/60), u_m; exit }
    if (s < 86400) { printf "%d%s%02d%s", int(s/3600), u_h, int((s%3600)/60), u_m; exit }
    printf "%dd%d%s", int(s/86400), int((s%86400)/3600), u_h
  }'
}

# --- Catalogos ------------------------------------------------------------
#
# Um "case" por idioma. Bash associativo com "set -u" explode em chave que nao
# existe, e aqui chave faltando precisa cair no padrao, nao derrubar a rodada.
#
# As strings passam por printf: "%" literal precisa vir como "%%".

msg_pt() {
  case "$1" in
    rotulo_memoria) printf 'Memória' ;;
    rotulo_steal)   printf 'Contenção de CPU' ;;
    rotulo_load)    printf 'Load average' ;;
    tabela_steal)   printf 'Contenção (steal)' ;;
    rotulo_disco)   printf 'Disco' ;;
    rotulo_agente)  printf 'Agente' ;;

    sev_atencao) printf 'ATENÇÃO' ;;
    sev_critico) printf 'CRÍTICO' ;;
    sev_segue)   printf 'SEGUE' ;;
    sev_ok)      printf 'OK' ;;
    sev_aviso)   printf 'AVISO' ;;
    nivel_atencao) printf 'atenção' ;;
    nivel_critico) printf 'crítico' ;;

    dur_segundos) printf 's' ;;
    dur_minutos)  printf 'min' ;;
    dur_horas)    printf 'h' ;;
    dur_dias)     printf 'd' ;;

    titulo_normalizou) printf '%%s normalizou em %%s' ;;
    titulo_alerta)     printf '%%s em %%s%%s no %%s' ;;
    corpo_normalizou)  printf '<strong>%%s normalizou.</strong> Valor atual: %%s%%s. O problema durou %%s e chegou a %%s%%s.' ;;
    corpo_valor)       printf '<strong>%%s: %%s%%s</strong> (limiar %%s%%s)' ;;
    corpo_desde)       printf 'Assim há %%s, pico de %%s%%s. Confirmado em %%s leituras seguidas.' ;;
    corpo_estado)      printf 'Estado do servidor agora' ;;
    corpo_comecar)     printf 'Por onde começar' ;;
    corpo_proc_cpu)    printf 'Processos por CPU' ;;
    corpo_proc_mem)    printf 'Processos por memória' ;;
    corpo_dirs)        printf 'Maiores diretórios em %%s' ;;
    corpo_media_de)    printf 'média de %%s' ;;
    corpo_sem_swap)    printf 'sem swap configurado' ;;
    corpo_disponiveis) printf '%%s GB disponíveis' ;;
    corpo_por_nucleo)  printf '%%s por núcleo, %%s núcleos' ;;

    tg_normalizou) printf '%%s %%s normalizou em %%s\n\nAtual: %%s%%s | durou %%s | pico %%s%%s' ;;
    tg_alerta)     printf '%%s %%s em %%s%%s - %%s\n\nAssim há %%s (pico %%s%%s, limiar %%s%%s)\n\n%%s' ;;

    resumo_assunto) printf '%%s alertas na última hora' ;;
    resumo_titulo)  printf 'Várias métricas fora do normal' ;;
    resumo_corpo)   printf 'O servidor passou do limite de %%s alertas por hora. Em vez de uma mensagem por ocorrência, segue o agrupamento:' ;;
    resumo_tg)      printf '[RESUMO] %%s - %%s alertas na última hora\n\nO limite de %%s por hora foi atingido e as mensagens individuais foram agrupadas.\n\n%%s' ;;

    diag_steal)   printf 'Contenção de CPU em %%s%%%% (steal): o limite está no provedor, não no servidor. Em instância burstable (EC2 t2/t3/t3a) isso é crédito de CPU esgotado. Conferir CPUCreditBalance no painel do provedor.' ;;
    diag_iowait)  printf 'iowait em %%s%%%%: a CPU está esperando disco, não calculando. O gargalo é de I/O. Conferir com: iostat -x 1 5' ;;
    diag_load)    printf 'Load average em %%s por núcleo: há processo na fila esperando CPU, não só usando. Conferir os processos abaixo.' ;;
    diag_cpu)     printf 'Uso sustentado de CPU. Conferir os processos abaixo e se há build, cron ou importação rodando.' ;;
    diag_mem_sem_swap) printf 'Restam %%s MB disponíveis e este servidor não tem swap: estourar significa OOM kill, processo morto sem erro no log da aplicação. Conferir os processos abaixo.' ;;
    diag_mem)     printf 'Restam %%s MB disponíveis. Conferir os processos abaixo e, se for aplicação Node, se há limite de heap configurado.' ;;
    diag_disco)   printf 'Conferir os maiores diretórios abaixo. Suspeitos frequentes: /var/log, /var/lib/docker e dump de banco esquecido.' ;;
    diag_inode)   printf 'Inodes esgotados: o disco aceita bytes mas não aceita arquivo novo, e o df comum não mostra isso. Procurar diretório com muitos arquivos pequenos (cache de sessão, fila de e-mail).' ;;
    diag_swap)    printf 'Swap em uso alto deixa a aplicação lenta sem derrubar nada, então chega como reclamação de lentidão. Páginas em swap não voltam sozinhas.' ;;
    diag_load_m)  printf 'Load average em %%s por núcleo: há processo esperando a vez. Load alto com CPU baixa costuma ser espera de disco ou de rede.' ;;
    diag_steal_m) printf 'A instância está pedindo mais CPU do que o provedor entrega neste momento. Em EC2 burstable, isso é crédito esgotado. Trocar de família ou ligar o modo unlimited resolve; ajuste dentro do servidor não.' ;;
    diag_padrao)  printf 'Conferir os processos abaixo.' ;;

    tpl_data)     printf 'Data' ;;
    tpl_servidor) printf 'Servidor' ;;
    tpl_rodape)   printf 'Alerta automático. Não responda.' ;;
    *) printf '' ;;
  esac
}

msg_en() {
  case "$1" in
    rotulo_memoria) printf 'Memory' ;;
    rotulo_steal)   printf 'CPU contention' ;;
    rotulo_load)    printf 'Load average' ;;
    tabela_steal)   printf 'Contention (steal)' ;;
    rotulo_disco)   printf 'Disk' ;;
    rotulo_agente)  printf 'Agent' ;;

    sev_atencao) printf 'WARNING' ;;
    sev_critico) printf 'CRITICAL' ;;
    sev_segue)   printf 'ONGOING' ;;
    sev_ok)      printf 'RESOLVED' ;;
    sev_aviso)   printf 'NOTICE' ;;
    nivel_atencao) printf 'warning' ;;
    nivel_critico) printf 'critical' ;;

    dur_segundos) printf 's' ;;
    dur_minutos)  printf 'min' ;;
    dur_horas)    printf 'h' ;;
    dur_dias)     printf 'd' ;;

    titulo_normalizou) printf '%%s back to normal on %%s' ;;
    titulo_alerta)     printf '%%s at %%s%%s on %%s' ;;
    corpo_normalizou)  printf '<strong>%%s is back to normal.</strong> Current value: %%s%%s. It lasted %%s and peaked at %%s%%s.' ;;
    corpo_valor)       printf '<strong>%%s: %%s%%s</strong> (threshold %%s%%s)' ;;
    corpo_desde)       printf 'Like this for %%s, peaked at %%s%%s. Confirmed over %%s consecutive readings.' ;;
    corpo_estado)      printf 'Server state right now' ;;
    corpo_comecar)     printf 'Where to start' ;;
    corpo_proc_cpu)    printf 'Top processes by CPU' ;;
    corpo_proc_mem)    printf 'Top processes by memory' ;;
    corpo_dirs)        printf 'Largest directories in %%s' ;;
    corpo_media_de)    printf '%%s average' ;;
    corpo_sem_swap)    printf 'no swap configured' ;;
    corpo_disponiveis) printf '%%s GB available' ;;
    corpo_por_nucleo)  printf '%%s per core, %%s cores' ;;

    tg_normalizou) printf '%%s %%s back to normal on %%s\n\nCurrent: %%s%%s | lasted %%s | peak %%s%%s' ;;
    tg_alerta)     printf '%%s %%s at %%s%%s - %%s\n\nLike this for %%s (peak %%s%%s, threshold %%s%%s)\n\n%%s' ;;

    resumo_assunto) printf '%%s alerts in the last hour' ;;
    resumo_titulo)  printf 'Several metrics out of range' ;;
    resumo_corpo)   printf 'This server went over the limit of %%s alerts per hour. Instead of one message per event, here is the grouped summary:' ;;
    resumo_tg)      printf '[SUMMARY] %%s - %%s alerts in the last hour\n\nThe limit of %%s per hour was reached and individual messages were grouped.\n\n%%s' ;;

    diag_steal)   printf 'CPU contention at %%s%%%% (steal): the limit is on the provider side, not on the server. On a burstable instance (EC2 t2/t3/t3a) this means CPU credits ran out. Check CPUCreditBalance in the provider console.' ;;
    diag_iowait)  printf 'iowait at %%s%%%%: the CPU is waiting on disk, not computing. The bottleneck is I/O. Check with: iostat -x 1 5' ;;
    diag_load)    printf 'Load average at %%s per core: processes are queued waiting for CPU, not just using it. Check the processes below.' ;;
    diag_cpu)     printf 'Sustained CPU usage. Check the processes below and whether a build, cron job or import is running.' ;;
    diag_mem_sem_swap) printf 'Only %%s MB available and this server has no swap: running out means an OOM kill, a process killed with no error in the application log. Check the processes below.' ;;
    diag_mem)     printf 'Only %%s MB available. Check the processes below and, for a Node application, whether a heap limit is configured.' ;;
    diag_disco)   printf 'Check the largest directories below. Usual suspects: /var/log, /var/lib/docker and a forgotten database dump.' ;;
    diag_inode)   printf 'Inodes exhausted: the disk still accepts bytes but refuses new files, and plain df does not show this. Look for a directory with many small files (session cache, mail queue).' ;;
    diag_swap)    printf 'Heavy swap usage makes the application slow without taking anything down, so it arrives as a complaint about slowness. Pages in swap do not come back on their own.' ;;
    diag_load_m)  printf 'Load average at %%s per core: processes are waiting their turn. High load with low CPU usually means waiting on disk or network.' ;;
    diag_steal_m) printf 'This instance is asking for more CPU than the provider is delivering right now. On EC2 burstable, that means credits ran out. Switching instance family or enabling unlimited mode fixes it; tuning inside the server does not.' ;;
    diag_padrao)  printf 'Check the processes below.' ;;

    tpl_data)     printf 'Date' ;;
    tpl_servidor) printf 'Server' ;;
    tpl_rodape)   printf 'Automated alert. Do not reply.' ;;
    *) printf '' ;;
  esac
}

msg_es() {
  case "$1" in
    rotulo_memoria) printf 'Memoria' ;;
    rotulo_steal)   printf 'Contención de CPU' ;;
    rotulo_load)    printf 'Load average' ;;
    tabela_steal)   printf 'Contención (steal)' ;;
    rotulo_disco)   printf 'Disco' ;;
    rotulo_agente)  printf 'Agente' ;;

    sev_atencao) printf 'ATENCIÓN' ;;
    sev_critico) printf 'CRÍTICO' ;;
    sev_segue)   printf 'CONTINÚA' ;;
    sev_ok)      printf 'OK' ;;
    sev_aviso)   printf 'AVISO' ;;
    nivel_atencao) printf 'atención' ;;
    nivel_critico) printf 'crítico' ;;

    dur_segundos) printf 's' ;;
    dur_minutos)  printf 'min' ;;
    dur_horas)    printf 'h' ;;
    dur_dias)     printf 'd' ;;

    titulo_normalizou) printf '%%s se normalizó en %%s' ;;
    titulo_alerta)     printf '%%s en %%s%%s en %%s' ;;
    corpo_normalizou)  printf '<strong>%%s se normalizó.</strong> Valor actual: %%s%%s. El problema duró %%s y llegó a %%s%%s.' ;;
    corpo_valor)       printf '<strong>%%s: %%s%%s</strong> (umbral %%s%%s)' ;;
    corpo_desde)       printf 'Así desde hace %%s, pico de %%s%%s. Confirmado en %%s lecturas seguidas.' ;;
    corpo_estado)      printf 'Estado del servidor ahora' ;;
    corpo_comecar)     printf 'Por dónde empezar' ;;
    corpo_proc_cpu)    printf 'Procesos por CPU' ;;
    corpo_proc_mem)    printf 'Procesos por memoria' ;;
    corpo_dirs)        printf 'Directorios más grandes en %%s' ;;
    corpo_media_de)    printf 'promedio de %%s' ;;
    corpo_sem_swap)    printf 'sin swap configurado' ;;
    corpo_disponiveis) printf '%%s GB disponibles' ;;
    corpo_por_nucleo)  printf '%%s por núcleo, %%s núcleos' ;;

    tg_normalizou) printf '%%s %%s se normalizó en %%s\n\nActual: %%s%%s | duró %%s | pico %%s%%s' ;;
    tg_alerta)     printf '%%s %%s en %%s%%s - %%s\n\nAsí desde hace %%s (pico %%s%%s, umbral %%s%%s)\n\n%%s' ;;

    resumo_assunto) printf '%%s alertas en la última hora' ;;
    resumo_titulo)  printf 'Varias métricas fuera de rango' ;;
    resumo_corpo)   printf 'El servidor superó el límite de %%s alertas por hora. En lugar de un mensaje por evento, este es el resumen agrupado:' ;;
    resumo_tg)      printf '[RESUMEN] %%s - %%s alertas en la última hora\n\nSe alcanzó el límite de %%s por hora y los mensajes individuales fueron agrupados.\n\n%%s' ;;

    diag_steal)   printf 'Contención de CPU en %%s%%%% (steal): el límite está en el proveedor, no en el servidor. En instancia burstable (EC2 t2/t3/t3a) significa que se agotaron los créditos de CPU. Revisar CPUCreditBalance en la consola del proveedor.' ;;
    diag_iowait)  printf 'iowait en %%s%%%%: la CPU está esperando el disco, no calculando. El cuello de botella es de E/S. Revisar con: iostat -x 1 5' ;;
    diag_load)    printf 'Load average en %%s por núcleo: hay procesos en cola esperando CPU, no solo usándola. Revisar los procesos abajo.' ;;
    diag_cpu)     printf 'Uso sostenido de CPU. Revisar los procesos abajo y si hay un build, cron o importación corriendo.' ;;
    diag_mem_sem_swap) printf 'Quedan %%s MB disponibles y este servidor no tiene swap: agotarla significa OOM kill, un proceso terminado sin error en el log de la aplicación. Revisar los procesos abajo.' ;;
    diag_mem)     printf 'Quedan %%s MB disponibles. Revisar los procesos abajo y, si es una aplicación Node, si hay límite de heap configurado.' ;;
    diag_disco)   printf 'Revisar los directorios más grandes abajo. Sospechosos frecuentes: /var/log, /var/lib/docker y un dump de base de datos olvidado.' ;;
    diag_inode)   printf 'Inodos agotados: el disco acepta bytes pero no acepta archivos nuevos, y el df normal no muestra esto. Buscar un directorio con muchos archivos pequeños (caché de sesión, cola de correo).' ;;
    diag_swap)    printf 'El uso alto de swap deja la aplicación lenta sin tumbar nada, así que llega como queja de lentitud. Las páginas en swap no vuelven solas.' ;;
    diag_load_m)  printf 'Load average en %%s por núcleo: hay procesos esperando su turno. Load alto con CPU baja suele ser espera de disco o de red.' ;;
    diag_steal_m) printf 'La instancia está pidiendo más CPU de la que el proveedor entrega en este momento. En EC2 burstable, eso significa que se agotaron los créditos. Cambiar de familia o activar el modo unlimited lo resuelve; ajustar dentro del servidor no.' ;;
    diag_padrao)  printf 'Revisar los procesos abajo.' ;;

    tpl_data)     printf 'Fecha' ;;
    tpl_servidor) printf 'Servidor' ;;
    tpl_rodape)   printf 'Alerta automática. No responda.' ;;
    *) printf '' ;;
  esac
}
