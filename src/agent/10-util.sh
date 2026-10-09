
# ---------------------------------------------------------------------------
# Utilitarios
# ---------------------------------------------------------------------------

# Caminhos. Todos sobrescrituveis por variavel de ambiente, que e o que permite
# rodar a bateria de testes sem root e sem /proc de verdade.
AGENTE_RAIZ="${AGENTE_RAIZ:-/opt/monitoring}"
AGENTE_ESTADO="${AGENTE_ESTADO:-/var/lib/monitoring/state}"
AGENTE_LOG="${AGENTE_LOG:-/var/log/monitoring-agent.log}"
AGENTE_BIN="${AGENTE_BIN:-/usr/local/bin}"
PROC_STAT="${PROC_STAT:-/proc/stat}"
PROC_MEMINFO="${PROC_MEMINFO:-/proc/meminfo}"
PROC_LOADAVG="${PROC_LOADAVG:-/proc/loadavg}"

# Tamanho maximo do log antes de rotacionar. Monitoramento que enche o disco
# que ele deveria vigiar ja aconteceu em servidor de gente seria.
LOG_MAX_BYTES="${LOG_MAX_BYTES:-2097152}"

log() {
  local nivel="$1"; shift
  local linha
  linha="$(date '+%Y-%m-%d %H:%M:%S') [$nivel] $*"
  if [[ -w "$(dirname "$AGENTE_LOG")" ]] || [[ -w "$AGENTE_LOG" ]]; then
    if [[ -f "$AGENTE_LOG" ]]; then
      local tam
      tam=$(wc -c <"$AGENTE_LOG" 2>/dev/null || echo 0)
      if [[ "${tam:-0}" -gt "$LOG_MAX_BYTES" ]]; then
        mv -f "$AGENTE_LOG" "${AGENTE_LOG}.1" 2>/dev/null || true
      fi
    fi
    printf '%s\n' "$linha" >>"$AGENTE_LOG" 2>/dev/null || true
  fi
  [[ "${AGENTE_VERBOSO:-0}" == "1" ]] && printf '%s\n' "$linha" >&2
  return 0
}

log_erro() { log ERRO "$@"; }
log_info() { log INFO "$@"; }

# Aritmetica em awk. "bc" nao esta em todo servidor, e com "set -e" no script
# antigo a falta dele matava o monitor em silencio.
num() { awk -v v="${1:-0}" -v d="${2:-1}" 'BEGIN{printf "%.*f", d, v+0}'; }

# maior A B -> sucesso (0) quando A > B
maior() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a+0 > b+0)}'; }

# menor A B -> sucesso (0) quando A < B
menor() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{exit !(a+0 < b+0)}'; }

# pct PARTE TOTAL -> percentual com uma casa; total zero devolve 0.0
pct() {
  awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{
    if (b+0 == 0) { printf "0.0"; exit }
    printf "%.1f", (a/b)*100
  }'
}

# subtrai A B, nunca negativo (contador de /proc pode zerar no reboot)
delta() { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{d=a-b; if (d<0) d=0; printf "%.0f", d}'; }

agora() { date +%s; }

# Escrita atomica: grava num temporario no MESMO diretorio e move por cima.
# mv entre filesystems diferentes nao e atomico, e era assim que o atualizador
# antigo instalava script vindo de /tmp.
escreve_atomico() {
  local destino="$1"
  local dir tmp
  dir="$(dirname "$destino")"
  mkdir -p "$dir" 2>/dev/null || true
  tmp="$(mktemp "${dir}/.tmp.XXXXXX" 2>/dev/null)" || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod --reference="$destino" "$tmp" 2>/dev/null || chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$destino" || { rm -f "$tmp"; return 1; }
  return 0
}

# Escapa para HTML
escapa_html() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# Escapa para campo string de JSON
escapa_json() {
  awk 'BEGIN{ORS=""} {
    gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\t/,"\\t"); gsub(/\r/,"")
    print $0 "\\n"
  }'
}

# Trava por arquivo: duas rodadas do agente ao mesmo tempo corromperiam o
# estado da histerese. Usa mkdir, que e atomico em qualquer filesystem POSIX.
TRAVA_DIR=""
pega_trava() {
  local nome="${1:-agente}"
  TRAVA_DIR="${AGENTE_ESTADO}/.lock-${nome}"
  mkdir -p "$AGENTE_ESTADO" 2>/dev/null || true
  if mkdir "$TRAVA_DIR" 2>/dev/null; then
    printf '%s' "$$" >"${TRAVA_DIR}/pid" 2>/dev/null || true
    trap 'solta_trava' EXIT INT TERM
    return 0
  fi
  # Trava presa por processo que ja morreu (OOM kill, reboot) e liberada.
  local pid_antigo idade
  pid_antigo="$(cat "${TRAVA_DIR}/pid" 2>/dev/null || echo "")"
  if [[ -n "$pid_antigo" ]] && ! kill -0 "$pid_antigo" 2>/dev/null; then
    rm -rf "$TRAVA_DIR" 2>/dev/null || true
    mkdir "$TRAVA_DIR" 2>/dev/null || return 1
    printf '%s' "$$" >"${TRAVA_DIR}/pid" 2>/dev/null || true
    trap 'solta_trava' EXIT INT TERM
    log_info "trava orfa do pid ${pid_antigo} liberada"
    return 0
  fi
  idade=$(( $(agora) - $(stat -c %Y "$TRAVA_DIR" 2>/dev/null || echo 0) ))
  if [[ "$idade" -gt 900 ]]; then
    rm -rf "$TRAVA_DIR" 2>/dev/null || true
    log_erro "trava com ${idade}s liberada por tempo"
    return 1
  fi
  return 1
}

solta_trava() {
  [[ -n "$TRAVA_DIR" ]] && rm -rf "$TRAVA_DIR" 2>/dev/null || true
  return 0
}

# Numero de nucleos, com os dois caminhos que existem num container
nucleos() {
  local n
  n="$(nproc 2>/dev/null || true)"
  [[ -z "$n" ]] && n="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
  [[ -z "$n" || "$n" -lt 1 ]] && n=1
  printf '%s' "$n"
}

# Converte "15m", "2h", "90s", "30" (segundos) em segundos
para_segundos() {
  local v="${1:-0}"
  case "$v" in
    *s) printf '%s' "${v%s}" ;;
    *m) awk -v n="${v%m}" 'BEGIN{printf "%d", n*60}' ;;
    *h) awk -v n="${v%h}" 'BEGIN{printf "%d", n*3600}' ;;
    *d) awk -v n="${v%d}" 'BEGIN{printf "%d", n*86400}' ;;
    *)  printf '%s' "$v" ;;
  esac
}

# duracao_humana vive em 25-idioma.sh: a unidade muda com o idioma.
