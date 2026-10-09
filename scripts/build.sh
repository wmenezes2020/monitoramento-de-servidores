#!/usr/bin/env bash
#
# Monta os artefatos distribuiveis a partir de src/agent/*.sh.
#
# O repositorio tinha a mesma logica escrita em dois lugares: os monitores na
# raiz e copias embutidas dentro de update_scripts.sh. As duas divergiram, e
# rodar o update_scripts desligava o envio de metricas ao painel sem avisar.
# Agora existe uma fonte so, e a raiz e gerada.
#
#   ./scripts/build.sh            monta e valida
#   ./scripts/build.sh --check    so confere se a raiz esta em dia (para CI)
set -euo pipefail

cd "$(dirname "$0")/.."
RAIZ="$PWD"
SRC="${RAIZ}/src/agent"
SAIDA="${RAIZ}/dist"

SO_CHECAR=0
[[ "${1:-}" == "--check" ]] && SO_CHECAR=1

VERSAO="$(tr -d '[:space:]' <"${RAIZ}/agent.version")"
[[ "$VERSAO" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "agent.version invalido: ${VERSAO}" >&2; exit 1; }

rm -rf "$SAIDA"
mkdir -p "$SAIDA"

# Concatena na ordem numerica dos prefixos
BUNDLE="${SAIDA}/monitoring-agent.sh"
: >"$BUNDLE"
for f in "$SRC"/[0-9][0-9]-*.sh; do
  cat "$f" >>"$BUNDLE"
  printf '\n' >>"$BUNDLE"
done

# Carimba a versao
sed -i "s/__VERSAO__/${VERSAO}/" "$BUNDLE"
chmod 755 "$BUNDLE"

if ! bash -n "$BUNDLE"; then
  echo "bundle gerado nao passa em bash -n" >&2
  exit 1
fi

# Os tres nomes antigos sao o mesmo bundle. E por eles que a base ja instalada
# recebe a atualizacao, porque sao os unicos arquivos que o canal atual baixa.
for nome in monitor_cpu.sh monitor_memory.sh monitor_disk.sh; do
  cp "$BUNDLE" "${SAIDA}/${nome}"
  chmod 755 "${SAIDA}/${nome}"
done

# Manifesto: versao e sha256 de cada arquivo distribuido.
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Auxiliares de envio. Eles vivem em /usr/local/bin, que e exatamente onde o
# atualizador instala, entao entram no manifesto e chegam na frota pelo mesmo
# canal. Antes existiam so dentro do instalador, e um servidor ja instalado
# nunca os recebia de volta: data em UTC e cabecalho em portugues ficavam
# cravados para sempre.
for f in "$RAIZ"/src/envio/*.sh; do
  [[ -e "$f" ]] || continue
  nome="$(basename "$f")"
  cp "$f" "${SAIDA}/${nome}"
  chmod 755 "${SAIDA}/${nome}"
  bash -n "${SAIDA}/${nome}" || { echo "${nome} nao passa em bash -n" >&2; exit 1; }
done


MANIFESTO="${SAIDA}/agent.manifest"
{
  printf '# Manifesto do agente de monitoramento. Gerado por scripts/build.sh.\n'
  printf '# O agente so instala arquivo cujo sha256 bate com o desta lista.\n'
  # Sem carimbo de data nem de commit: o manifesto precisa ser reproduzivel,
  # senao "build --check" reprova a cada execucao e o portao de CI vira ruido.
  printf 'VERSAO=%s\n' "$VERSAO"
  for nome in monitoring-agent.sh monitor_cpu.sh monitor_memory.sh monitor_disk.sh; do
    printf 'ARQUIVO=%s %s\n' "$nome" "$(sha "${SAIDA}/${nome}")"
  done
  # Os auxiliares de envio tambem entram: sem eles no manifesto, o atualizador
  # nao os baixa, e a frota fica presa na versao que o instalador gravou.
  for f in "$SAIDA"/send_*.sh; do
    [[ -e "$f" ]] || continue
    printf 'ARQUIVO=%s %s\n' "$(basename "$f")" "$(sha "$f")"
  done
} >"$MANIFESTO"

# Os artefatos vao para a raiz porque e de la que o canal de distribuicao
# baixa: https://raw.githubusercontent.com/<repo>/main/<arquivo>
if [[ "$SO_CHECAR" -eq 1 ]]; then
  falhou=0
  for nome in monitoring-agent.sh monitor_cpu.sh monitor_memory.sh monitor_disk.sh agent.manifest send_html_alert.sh send_telegram_alert.sh; do
    [[ -e "${SAIDA}/${nome}" ]] || continue
    if ! diff -q "${SAIDA}/${nome}" "${RAIZ}/${nome}" >/dev/null 2>&1; then
      echo "desatualizado: ${nome} (rode ./scripts/build.sh)" >&2
      falhou=1
    fi
  done
  rm -rf "$SAIDA"
  exit "$falhou"
fi

for nome in monitoring-agent.sh monitor_cpu.sh monitor_memory.sh monitor_disk.sh agent.manifest send_html_alert.sh send_telegram_alert.sh; do
  [[ -e "${SAIDA}/${nome}" ]] || continue
  cp "${SAIDA}/${nome}" "${RAIZ}/${nome}"
done
chmod 755 "${RAIZ}/monitoring-agent.sh" "${RAIZ}/monitor_cpu.sh" "${RAIZ}/monitor_memory.sh" "${RAIZ}/monitor_disk.sh"
rm -rf "$SAIDA"

echo "agente ${VERSAO} montado:"
echo "  monitoring-agent.sh  $(wc -l <"${RAIZ}/monitoring-agent.sh") linhas"
echo "  monitor_cpu.sh / monitor_memory.sh / monitor_disk.sh  (mesmo bundle)"
echo "  agent.manifest"
