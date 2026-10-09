
# ---------------------------------------------------------------------------
# Medicao
# ---------------------------------------------------------------------------
#
# Tudo sai de /proc. Sem mpstat (pacote sysstat, que pode nao estar instalado)
# e sem bc. O agente antigo dependia dos dois e morria calado quando faltavam.

# --- CPU ------------------------------------------------------------------
#
# A media vem do delta de /proc/stat entre duas execucoes, ou seja, cobre o
# intervalo inteiro do cron. O agente antigo usava "mpstat 1 2", uma janela de
# dois segundos, e por isso qualquer rajada virava alerta.
#
# Preenche: MEDIDA_CPU, MEDIDA_IOWAIT, MEDIDA_STEAL, MEDIDA_CPU_JANELA

le_cpu_bruto() {
  # user nice system idle iowait irq softirq steal
  awk '/^cpu /{
    total=0
    for (i=2; i<=NF; i++) total += $i
    idle = $5 + $6
    steal = (NF >= 9) ? $9 : 0
    printf "%.0f %.0f %.0f %.0f", total, idle, $6, steal
    exit
  }' "$PROC_STAT" 2>/dev/null
}

mede_cpu() {
  MEDIDA_CPU="" ; MEDIDA_IOWAIT="0.0" ; MEDIDA_STEAL="0.0" ; MEDIDA_CPU_JANELA="0"

  local amostra ts
  amostra="$(le_cpu_bruto)"
  ts="$(agora)"
  if [[ -z "$amostra" ]]; then
    log_erro "nao consegui ler ${PROC_STAT}"
    return 1
  fi

  local arq="${AGENTE_ESTADO}/cpu.amostra"
  local usar_delta=0 ant_total ant_idle ant_iowait ant_steal ant_ts

  if [[ -f "$arq" ]]; then
    read -r ant_total ant_idle ant_iowait ant_steal ant_ts <"$arq" 2>/dev/null || true
    if [[ -n "${ant_ts:-}" ]]; then
      local idade=$(( ts - ant_ts ))
      # Amostra velha demais (agente parado, servidor reiniciado) daria uma
      # media de horas, que nao representa o agora. Tambem rejeita idade
      # negativa, que acontece quando o relogio e ajustado para tras.
      if [[ "$idade" -ge 20 && "$idade" -le 900 ]]; then
        usar_delta=1
        MEDIDA_CPU_JANELA="$idade"
      fi
    fi
  fi

  # Sem amostra anterior utilizavel: tira uma curta agora, para a primeira
  # execucao depois de instalar nao ficar sem numero.
  if [[ "$usar_delta" -eq 0 ]]; then
    read -r ant_total ant_idle ant_iowait ant_steal <<<"$amostra"
    sleep 1
    amostra="$(le_cpu_bruto)"
    ts="$(agora)"
    MEDIDA_CPU_JANELA="1"
    [[ -z "$amostra" ]] && return 1
  fi

  local cur_total cur_idle cur_iowait cur_steal
  read -r cur_total cur_idle cur_iowait cur_steal <<<"$amostra"

  printf '%s %s %s %s %s\n' "$cur_total" "$cur_idle" "$cur_iowait" "$cur_steal" "$ts" \
    | escreve_atomico "$arq" 2>/dev/null || true

  local d_total d_idle d_iowait d_steal
  d_total="$(delta "$cur_total" "$ant_total")"
  d_idle="$(delta "$cur_idle" "$ant_idle")"
  d_iowait="$(delta "$cur_iowait" "${ant_iowait:-0}")"
  d_steal="$(delta "$cur_steal" "${ant_steal:-0}")"

  # Contador zerado (reboot) ou janela nula: sem numero confiavel nesta rodada.
  if [[ "${d_total:-0}" -le 0 ]]; then
    log_info "delta de /proc/stat nulo; CPU sem medida nesta rodada"
    return 1
  fi

  MEDIDA_CPU="$(pct "$(delta "$d_total" "$d_idle")" "$d_total")"
  MEDIDA_IOWAIT="$(pct "$d_iowait" "$d_total")"
  MEDIDA_STEAL="$(pct "$d_steal" "$d_total")"
  return 0
}

# --- Memoria --------------------------------------------------------------
#
# Aqui estava o defeito que gerava alerta de RAM a cada minuto em servidor
# saudavel: o script antigo somava "used + buff/cache" do free e chamava de
# memoria ocupada. Cache de disco nao e memoria ocupada; o kernel devolve no
# instante em que alguem precisa. Num servidor com 8,4 GB livres de 15 GB a
# conta antiga dava 96,7%, a correta da 44%.
#
# Preenche: MEDIDA_MEM, MEDIDA_MEM_TOTAL_KB, MEDIDA_MEM_DISP_KB,
#           MEDIDA_SWAP, MEDIDA_SWAP_TOTAL_KB

campo_meminfo() {
  awk -v chave="^$1:" '$0 ~ chave { print $2; exit }' "$PROC_MEMINFO" 2>/dev/null
}

mede_memoria() {
  MEDIDA_MEM="" ; MEDIDA_SWAP="" ; MEDIDA_SWAP_TOTAL_KB="0"

  local total disp
  total="$(campo_meminfo MemTotal)"
  if [[ -z "$total" || "$total" -le 0 ]]; then
    log_erro "nao consegui ler MemTotal de ${PROC_MEMINFO}"
    return 1
  fi

  disp="$(campo_meminfo MemAvailable)"
  if [[ -z "$disp" ]]; then
    # Kernel anterior ao 3.14 nao expoe MemAvailable. A aproximacao aceita e
    # free + buffers + cache reclamavel.
    local livre buffers cached sreclaim
    livre="$(campo_meminfo MemFree)"; buffers="$(campo_meminfo Buffers)"
    cached="$(campo_meminfo Cached)"; sreclaim="$(campo_meminfo SReclaimable)"
    disp="$(awk -v a="${livre:-0}" -v b="${buffers:-0}" -v c="${cached:-0}" -v d="${sreclaim:-0}" \
      'BEGIN{printf "%.0f", a+b+c+d}')"
    log_info "MemAvailable ausente; usando MemFree+Buffers+Cached+SReclaimable"
  fi

  MEDIDA_MEM_TOTAL_KB="$total"
  MEDIDA_MEM_DISP_KB="$disp"
  MEDIDA_MEM="$(pct "$(delta "$total" "$disp")" "$total")"

  local swap_total swap_livre
  swap_total="$(campo_meminfo SwapTotal)"
  swap_livre="$(campo_meminfo SwapFree)"
  MEDIDA_SWAP_TOTAL_KB="${swap_total:-0}"
  if [[ -n "$swap_total" && "$swap_total" -gt 0 ]]; then
    MEDIDA_SWAP="$(pct "$(delta "$swap_total" "${swap_livre:-0}")" "$swap_total")"
  else
    # Servidor sem swap: medir "percentual de swap" nao significa nada. Em
    # EC2 isso e o padrao, e o agente nao deve inventar metrica.
    MEDIDA_SWAP=""
  fi
  return 0
}

# --- Load -----------------------------------------------------------------
#
# Normalizado por nucleo: 1.0 quer dizer "todos os nucleos ocupados, sem fila",
# o que torna o numero comparavel entre servidores de tamanhos diferentes.

mede_load() {
  MEDIDA_LOAD="" ; MEDIDA_LOAD_BRUTO=""
  local l1 n
  l1="$(awk '{print $1; exit}' "$PROC_LOADAVG" 2>/dev/null)"
  [[ -z "$l1" ]] && return 1
  n="$(nucleos)"
  MEDIDA_LOAD_BRUTO="$l1"
  MEDIDA_LOAD="$(awk -v l="$l1" -v n="$n" 'BEGIN{printf "%.2f", l/n}')"
  MEDIDA_NUCLEOS="$n"
  return 0
}

# --- Disco ----------------------------------------------------------------
#
# Uma linha por ponto de montagem: "montagem uso_pct inode_pct dispositivo
# tamanho usado disponivel". Ignora o que nao e problema de ninguem (volume de
# container, snap) pela lista DISCO_IGNORAR.

ignorar_montagem() {
  local mnt="$1" padrao
  for padrao in $DISCO_IGNORAR; do
    # shellcheck disable=SC2053
    [[ "$mnt" == $padrao ]] && return 0
  done
  return 1
}

_saida_df()        { if [[ -n "${FIXTURE_DF:-}" ]];        then cat "$FIXTURE_DF";        else df -P  -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null; fi; }
_saida_df_inodes() { if [[ -n "${FIXTURE_DF_INODES:-}" ]]; then cat "$FIXTURE_DF_INODES"; else df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null; fi; }

mede_disco() {
  MEDIDA_DISCO_LINHAS=""

  # Os campos sao lidos a partir do FIM da linha, nao do comeco. O nome do
  # dispositivo pode conter espaco (share de rede, caminho montado), e aí um
  # "read fs size used avail pct mnt" desloca tudo e o agente passa a comparar
  # o ponto de montagem com o percentual. O layout do df -P e fixo pela direita:
  #   ... TAMANHO USADO DISPONIVEL USO% MONTAGEM
  local inodes linhas
  inodes="$(_saida_df_inodes | tail -n +2 | awk 'NF >= 2 {print $NF, $(NF-1)}' 2>/dev/null || true)"
  linhas="$(_saida_df | tail -n +2 | awk 'NF >= 6 {
    gsub(/%/, "", $(NF-1))
    printf "%s|%s|%s|%s|%s\n", $NF, $(NF-1), $(NF-4), $(NF-3), $(NF-2)
  }' 2>/dev/null || true)"
  [[ -z "$linhas" ]] && { log_erro "df nao devolveu nada utilizavel"; return 1; }

  local mnt pct_uso size used avail ipct
  while IFS='|' read -r mnt pct_uso size used avail; do
    [[ -z "${mnt:-}" ]] && continue
    [[ "$pct_uso" =~ ^[0-9]+$ ]] || continue
    ignorar_montagem "$mnt" && continue
    ipct="$(printf '%s\n' "$inodes" | awk -v m="$mnt" '$1==m {gsub(/%/,"",$2); print $2; exit}')"
    # Filesystem sem contagem de inode (btrfs, zfs, ntfs) devolve "-". Zero
    # aqui significa "nao se aplica" e nunca dispara alerta.
    [[ "${ipct:-}" =~ ^[0-9]+$ ]] || ipct="0"
    MEDIDA_DISCO_LINHAS+="${mnt} ${pct_uso} ${ipct} ${size} ${used} ${avail}"$'\n'
  done <<<"$linhas"
  [[ -z "$MEDIDA_DISCO_LINHAS" ]] && return 1
  return 0
}

# --- Contexto para o texto do alerta --------------------------------------

top_processos() {
  local por="${1:-cpu}" n="${2:-12}"
  local chave="-%cpu"
  [[ "$por" == "mem" ]] && chave="-%mem"
  ps -eo pid,user,pcpu,pmem,comm,args --sort="$chave" --no-headers 2>/dev/null \
    | head -n "$n" \
    | awk '{
        cmd=""
        for (i=6; i<=NF; i++) cmd = cmd $i " "
        printf "%-7s %-10s %5s%% %5s%% %.60s\n", $1, $2, $3, $4, substr(cmd,1,60)
      }' 2>/dev/null || printf 'ps indisponivel\n'
}

maiores_diretorios() {
  local mnt="$1"
  timeout 20 du -xh --max-depth=1 "$mnt" 2>/dev/null | sort -hr | head -n 12 \
    || printf 'du nao terminou em 20s\n'
}
