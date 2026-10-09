#!/usr/bin/env bash
#
# Teste de integracao da migracao automatica.
#
# Monta um servidor de mentira com a instalacao antiga (scripts v1, cron de
# quatro linhas por minuto, limiares e destinatarios gravados dentro dos
# scripts), entrega o bundle novo pelo mesmo caminho que o canal de
# atualizacao usa, e confere que o servidor migrou sozinho sem perder nada.
#
# E o ensaio do que vai acontecer na frota inteira no minuto seguinte ao push.
set -uo pipefail

cd "$(dirname "$0")/.."
RAIZ="$PWD"

TOTAL=0; FALHAS=0
ok()    { TOTAL=$((TOTAL+1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
falha() { TOTAL=$((TOTAL+1)); FALHAS=$((FALHAS+1)); printf '  \033[31mFALHA\033[0m %s\n' "$1"
          [[ -n "${2:-}" ]] && printf '        esperado: %s\n        obtido:   %s\n' "$2" "${3:-}"; }
igual() { [[ "$2" == "$3" ]] && ok "$1" || falha "$1" "$2" "$3"; }
tem()   { grep -q "$2" "$3" 2>/dev/null && ok "$1" || falha "$1" "achar '$2' em $3" "nao achou"; }
naotem(){ grep -q "$2" "$3" 2>/dev/null && falha "$1" "nao achar '$2'" "achou" || ok "$1"; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

export AGENTE_RAIZ="${SB}/opt/monitoring"
export AGENTE_ESTADO="${SB}/var/lib/monitoring/state"
export AGENTE_LOG="${SB}/var/log/monitoring-agent.log"
export AGENTE_BIN="${SB}/usr/local/bin"
mkdir -p "$AGENTE_RAIZ" "$AGENTE_ESTADO" "$AGENTE_BIN" "${SB}/var/log" "${SB}/falso"

printf '\nServidor de mentira com a instalacao antiga\n'

# --- crontab de mentira, guardado num arquivo ------------------------------
CRONFILE="${SB}/crontab.txt"
cat >"${SB}/falso/crontab" <<FALSOCRON
#!/usr/bin/env bash
ARQ="${CRONFILE}"
if [[ "\${1:-}" == "-l" ]]; then
  [[ -f "\$ARQ" ]] && cat "\$ARQ" || exit 1
  exit 0
fi
if [[ "\${1:-}" == "-" ]]; then cat >"\$ARQ"; exit 0; fi
exit 0
FALSOCRON
chmod +x "${SB}/falso/crontab"

# "id" de mentira: o bootstrap so roda como root, e $EUID nao pode ser
# sobrescrito no bash. Trocar o "id" no PATH e o jeito limpo de encenar isso.
cat >"${SB}/falso/id" <<'FALSOID'
#!/usr/bin/env bash
[[ "${1:-}" == "-u" ]] && { printf '0
'; exit 0; }
exec /usr/bin/id "$@"
FALSOID
chmod +x "${SB}/falso/id"
export PATH="${SB}/falso:${PATH}"

cat >"$CRONFILE" <<'CRONANTIGO'
# algo do usuario que nao pode sumir
30 4 * * * /usr/local/bin/backup-diario.sh
# --- Monitoramento de CPU, Memoria, Disco e Antivirus ---
# Monitoramento CPU a cada 5 min
* * * * * /usr/local/bin/monitor_cpu.sh
# Monitoramento Memoria a cada 5 min
* * * * * /usr/local/bin/monitor_memory.sh
# Monitoramento Disco a cada 5 min
* * * * * /usr/local/bin/monitor_disk.sh
# ClamAV varredura diaria 02:00 e alerta se virus
0 2 * * * /usr/bin/clamscan --infected / >/var/log/clamav/scan.log
# Consulta ao Dashboard a cada 2 min
* * * * * /usr/local/bin/dashboard_fetch_updates.sh
CRONANTIGO

# --- scripts v1 instalados, com a configuracao real do servidor ------------
for nome in monitor_cpu monitor_memory monitor_disk; do
  cat >"${AGENTE_BIN}/${nome}.sh" <<'V1'
#!/usr/bin/env bash
set -euo pipefail
RECIPIENTS="ops@empresa.com.br,plantao@empresa.com.br"
CPU_THRESHOLD=88
MEM_THRESHOLD=92
DISK_THRESHOLD=80
V1
  chmod +x "${AGENTE_BIN}/${nome}.sh"
done
printf 'SERVER_ID="servidor-de-producao"\n' >"${AGENTE_RAIZ}/email.conf"
printf 'DASHBOARD_ENABLED=1\nDASHBOARD_SERVER_UUID=uuid-de-teste\nDASHBOARD_API_URL=http://127.0.0.1:1/v1\n' >"${AGENTE_RAIZ}/dashboard.conf"

# Auxiliares de envio que nao mandam nada, so registram que foram chamados.
for aux in send_html_alert send_telegram_alert send_dashboard_metrics; do
  cat >"${AGENTE_BIN}/${aux}.sh" <<AUX
#!/usr/bin/env bash
printf '%s %s\n' "${aux}" "\$*" >>"${SB}/enviados.log"
cat >/dev/null 2>&1 || true
exit 0
AUX
  chmod +x "${AGENTE_BIN}/${aux}.sh"
done

ok "servidor de mentira montado"

# --- o canal de atualizacao entrega o bundle novo --------------------------
printf '\nO canal de atualizacao entrega o bundle v2\n'
for nome in monitor_cpu monitor_memory monitor_disk; do
  cp "${RAIZ}/${nome}.sh" "${AGENTE_BIN}/${nome}.sh"
  chmod +x "${AGENTE_BIN}/${nome}.sh"
done
# E aplica os limiares do painel com sed, exatamente como o fetch antigo faz.
sed -i "s/^CPU_THRESHOLD=.*/CPU_THRESHOLD=88/"  "${AGENTE_BIN}/monitor_cpu.sh"
sed -i "s/^MEM_THRESHOLD=.*/MEM_THRESHOLD=92/"  "${AGENTE_BIN}/monitor_memory.sh"
sed -i "s/^DISK_THRESHOLD=.*/DISK_THRESHOLD=80/" "${AGENTE_BIN}/monitor_disk.sh"
sed -i 's|^RECIPIENTS=.*|RECIPIENTS="ops@empresa.com.br,plantao@empresa.com.br"|' "${AGENTE_BIN}/monitor_cpu.sh"
ok "bundle entregue e limiares aplicados pelo canal antigo"

# --- o cron antigo dispara monitor_cpu.sh ----------------------------------
printf '\nO cron antigo roda monitor_cpu.sh e a migracao acontece\n'
SAIDA="$(cd "$AGENTE_BIN" && AGENTE_RAIZ="$AGENTE_RAIZ" AGENTE_ESTADO="$AGENTE_ESTADO" \
  AGENTE_LOG="$AGENTE_LOG" AGENTE_BIN="$AGENTE_BIN" EUID=0 \
  bash "${AGENTE_BIN}/monitor_cpu.sh" 2>&1)"
RET=$?
igual "a rodada termina sem erro" "0" "$RET"

[[ -x "${AGENTE_BIN}/monitoring-agent.sh" ]] && ok "monitoring-agent.sh instalado" \
  || falha "monitoring-agent.sh instalado" "arquivo executavel" "nao existe"

igual "VERSION gravada" "$(tr -d '[:space:]' <"${RAIZ}/agent.version")" "$(cat "${AGENTE_RAIZ}/VERSION" 2>/dev/null)"

printf '\nA configuracao antiga foi preservada, nao perdida\n'
tem "agent.conf criado"                      '^CPU_CRITICO=88'  "${AGENTE_RAIZ}/agent.conf"
tem "limiar de memoria do servidor mantido"  '^MEM_CRITICO=92'  "${AGENTE_RAIZ}/agent.conf"
tem "limiar de disco do servidor mantido"    '^DISCO_CRITICO=80' "${AGENTE_RAIZ}/agent.conf"
tem "limiar de atencao derivado abaixo"      '^CPU_ATENCAO=78'  "${AGENTE_RAIZ}/agent.conf"
tem "histerese configurada"                  '^CICLOS_CONFIRMACAO=3' "${AGENTE_RAIZ}/agent.conf"
tem "destinatarios migrados para email.conf" 'ops@empresa.com.br' "${AGENTE_RAIZ}/email.conf"
tem "SERVER_ID preservado"                   'servidor-de-producao' "${AGENTE_RAIZ}/email.conf"

printf '\nO cron virou uma linha e nao levou nada junto\n'
tem    "backup do usuario preservado"   'backup-diario.sh'          "$CRONFILE"
tem    "ClamAV preservado"              'clamscan'                  "$CRONFILE"
tem    "agente v2 agendado"             'monitoring-agent.sh rodada' "$CRONFILE"
naotem "monitor_cpu fora do cron"       'monitor_cpu.sh'            "$CRONFILE"
naotem "monitor_memory fora do cron"    'monitor_memory.sh'         "$CRONFILE"
naotem "monitor_disk fora do cron"      'monitor_disk.sh'           "$CRONFILE"
naotem "fetch antigo fora do cron"      'dashboard_fetch_updates'   "$CRONFILE"
naotem "marca antiga removida"          'CPU, Memoria, Disco e Antivirus' "$CRONFILE"
igual  "exatamente uma linha de agente" "1" "$(grep -c 'monitoring-agent.sh' "$CRONFILE")"

printf '\nSegunda execucao: nao refaz a migracao\n'
CRON_ANTES="$(cat "$CRONFILE")"
CONF_ANTES="$(cat "${AGENTE_RAIZ}/agent.conf")"
(cd "$AGENTE_BIN" && AGENTE_RAIZ="$AGENTE_RAIZ" AGENTE_ESTADO="$AGENTE_ESTADO" \
  AGENTE_LOG="$AGENTE_LOG" AGENTE_BIN="$AGENTE_BIN" \
  bash "${AGENTE_BIN}/monitoring-agent.sh" rodada >/dev/null 2>&1)
igual "cron intocado na segunda rodada"      "$CRON_ANTES" "$(cat "$CRONFILE")"
igual "agent.conf intocado na segunda rodada" "$CONF_ANTES" "$(cat "${AGENTE_RAIZ}/agent.conf")"
igual "exatamente uma linha de agente ainda" "1" "$(grep -c 'monitoring-agent.sh' "$CRONFILE")"

printf '\nO servidor esta saudavel, entao ninguem foi incomodado\n'
# Os limiares migrados sao altos e a maquina de teste nao esta em crise. Com a
# histerese, nem um valor alto isolado geraria mensagem na primeira rodada.
if [[ -f "${SB}/enviados.log" ]]; then
  ENVIOS_ALERTA="$(grep -c 'send_html_alert\|send_telegram_alert' "${SB}/enviados.log" 2>/dev/null)"
  ENVIOS_ALERTA="${ENVIOS_ALERTA:-0}"
else
  ENVIOS_ALERTA=0
fi
igual "nenhum e-mail ou Telegram nas duas rodadas" "0" "$ENVIOS_ALERTA"

printf '\nO agente responde aos comandos de operacao\n'
AGENTE_RAIZ="$AGENTE_RAIZ" AGENTE_ESTADO="$AGENTE_ESTADO" AGENTE_LOG="$AGENTE_LOG" AGENTE_BIN="$AGENTE_BIN" \
  bash "${AGENTE_BIN}/monitoring-agent.sh" autoteste >/dev/null 2>&1 \
  && ok "autoteste verde no servidor migrado" || falha "autoteste verde no servidor migrado"

AGENTE_RAIZ="$AGENTE_RAIZ" AGENTE_ESTADO="$AGENTE_ESTADO" AGENTE_LOG="$AGENTE_LOG" AGENTE_BIN="$AGENTE_BIN" \
  bash "${AGENTE_BIN}/monitoring-agent.sh" silenciar 10m "deploy" >/dev/null 2>&1
tem "silencio gravado" '^ATE=' "${AGENTE_RAIZ}/silencio"

AGENTE_RAIZ="$AGENTE_RAIZ" AGENTE_ESTADO="$AGENTE_ESTADO" AGENTE_LOG="$AGENTE_LOG" AGENTE_BIN="$AGENTE_BIN" \
  bash "${AGENTE_BIN}/monitoring-agent.sh" falar >/dev/null 2>&1
[[ ! -f "${AGENTE_RAIZ}/silencio" ]] && ok "silencio encerrado pelo comando" || falha "silencio encerrado pelo comando"

VER="$(AGENTE_RAIZ="$AGENTE_RAIZ" bash "${AGENTE_BIN}/monitoring-agent.sh" versao 2>/dev/null | awk '{print $1}')"
igual "comando versao responde" "$(tr -d '[:space:]' <"${RAIZ}/agent.version")" "$VER"

printf '\nO registro conta o que aconteceu\n'
tem "migracao registrada no log" 'migracao concluida' "$AGENTE_LOG"
tem "cron registrado no log"     'cron migrado'       "$AGENTE_LOG"

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32m%s verificacoes de migracao, todas verdes.\033[0m\n' "$TOTAL"; exit 0
fi
printf '\033[31m%s verificacoes de migracao, %s falha(s).\033[0m\n' "$TOTAL" "$FALHAS"
exit 1
