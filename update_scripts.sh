#!/usr/bin/env bash
#
# Atualiza o agente de monitoramento para a versao mais recente.
#
#   curl -fsSL https://raw.githubusercontent.com/wmenezes2020/monitoramento-de-servidores/main/update_scripts.sh | sudo bash
#
# Em servidor que ja roda o agente v2 isso nem e necessario: ele se atualiza
# sozinho, conferindo o manifesto a cada cinco minutos. O script continua
# existindo para forcar a atualizacao na hora.
#
# A versao anterior deste arquivo carregava copias dos tres monitores escritas
# dentro dele, em heredoc. Essas copias divergiram do que estava no
# repositorio e tinham perdido o bloco que envia metricas ao painel: quem
# rodasse o script desligava o proprio dashboard sem receber nenhum aviso.
# Agora existe uma fonte so, em src/agent/, e este script apenas baixa o que
# foi publicado, com conferencia de checksum.
set -uo pipefail

BASE="${UPDATE_BASE_URL:-https://raw.githubusercontent.com/wmenezes2020/monitoramento-de-servidores}/${UPDATE_CANAL:-main}"
BIN="/usr/local/bin"
CONF="/opt/monitoring"

log() { printf '[atualizar] %s\n' "$*" >&2; }

[[ "$(id -u)" -eq 0 ]] || { log "Execute como root: sudo bash"; exit 1; }

# Caminho normal: o agente ja esta instalado e sabe se atualizar sozinho, com
# checksum, validacao de sintaxe, autoteste e rollback.
if [[ -x "${BIN}/monitoring-agent.sh" ]]; then
  log "agente presente na versao $(cat "${CONF}/VERSION" 2>/dev/null || printf 'desconhecida')"
  "${BIN}/monitoring-agent.sh" atualizar
  log "concluido. Estado atual:"
  "${BIN}/monitoring-agent.sh" versao
  exit 0
fi

# Caminho de primeira vez ou de recuperacao: baixar o bundle e deixar que ele
# mesmo faca a instalacao e a migracao do cron.
log "agente nao encontrado em ${BIN}; baixando"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

baixar() {
  curl -fsSL --max-time 30 --retry 2 -o "$2" "$1" 2>/dev/null
}

if ! baixar "${BASE}/agent.manifest" "${TMP}/manifest"; then
  log "nao consegui baixar o manifesto de ${BASE}"
  exit 1
fi

VERSAO="$(awk -F= '/^VERSAO=/{print $2; exit}' "${TMP}/manifest" | tr -d '[:space:]')"
ESPERADO="$(awk '/^ARQUIVO=monitoring-agent.sh/{print $2; exit}' "${TMP}/manifest")"
[[ -n "$VERSAO" && -n "$ESPERADO" ]] || { log "manifesto incompleto"; exit 1; }

if ! baixar "${BASE}/monitoring-agent.sh" "${TMP}/monitoring-agent.sh"; then
  log "nao consegui baixar o agente"
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  OBTIDO="$(sha256sum "${TMP}/monitoring-agent.sh" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  OBTIDO="$(shasum -a 256 "${TMP}/monitoring-agent.sh" | awk '{print $1}')"
else
  log "sem sha256sum nem shasum; nao da para conferir a integridade. Abortado."
  exit 1
fi

if [[ "$OBTIDO" != "$ESPERADO" ]]; then
  log "checksum nao confere (esperado ${ESPERADO}, obtido ${OBTIDO}). Nada foi instalado."
  exit 1
fi

bash -n "${TMP}/monitoring-agent.sh" || { log "o arquivo baixado nao passa em bash -n. Abortado."; exit 1; }

mkdir -p "$BIN"
install -m 755 "${TMP}/monitoring-agent.sh" "${BIN}/monitoring-agent.sh"
for nome in monitor_cpu.sh monitor_memory.sh monitor_disk.sh; do
  install -m 755 "${TMP}/monitoring-agent.sh" "${BIN}/${nome}"
done

log "agente ${VERSAO} instalado; rodando a migracao"
"${BIN}/monitoring-agent.sh" instalar || { log "a migracao falhou; confira /var/log/monitoring-agent.log"; exit 1; }

if ! "${BIN}/monitoring-agent.sh" autoteste; then
  log "o autoteste falhou. O agente esta instalado, mas confira o registro antes de confiar nele."
  exit 1
fi

log "pronto."
"${BIN}/monitoring-agent.sh" status
