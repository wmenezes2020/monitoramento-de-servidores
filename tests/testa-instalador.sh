#!/usr/bin/env bash
#
# Bateria do instalador.
#
#   ./tests/testa-instalador.sh
#
# O defeito que motivou esta bateria, achado em producao em 16/10/2026:
#
# O instalador carregava uma COPIA EMBUTIDA do send_html_alert.sh. Essa copia
# ficou velha e so sabia usar o `mail` do Postfix local. Resultado: a cada
# instalacao, ela apagava do servidor todas as correcoes das versoes 2.3, 2.4 e
# 2.5, e o servidor nascia sem saber codificar assunto com acento, sem enviar
# um por destinatario e sem ler a conta de e-mail do painel.
#
# Pior: com conta vinda do painel o instalador nao instala o `mail`. A copia
# antiga nao tinha como enviar nada, e o e-mail de boas-vindas sumia em
# silencio. Foi assim que dois servidores foram reinstalados e nenhum e-mail
# chegou.
#
# O CLAUDE.md deste repositorio ja avisava: "este repositorio ja teve a mesma
# logica escrita em dois lugares. As duas divergiram." Era o mesmo erro, no
# mesmo lugar, pela segunda vez.
set -uo pipefail

cd "$(dirname "$0")/.."
RAIZ="$PWD"
INST="${RAIZ}/install-monitoring.sh"

TOTAL=0; FALHAS=0
grupo() { printf '\n%s\n' "$1"; }
ok()    { TOTAL=$((TOTAL+1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
falha() {
  TOTAL=$((TOTAL+1)); FALHAS=$((FALHAS+1))
  printf '  \033[31mFALHA\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '        %s\n' "$2"
  return 0
}
contem()     { if grep -qF -- "$2" "$INST"; then ok "$1"; else falha "$1" "esperava achar: $2"; fi; }
nao_contem() { if grep -qF -- "$2" "$INST"; then falha "$1" "nao podia ter: $2"; else ok "$1"; fi; }
igual()      { [[ "$2" == "$3" ]] && ok "$1" || falha "$1" "esperado [$2], obtido [$3]"; }

[[ -f "$INST" ]] || { echo "install-monitoring.sh nao encontrado" >&2; exit 1; }

# =========================================================================
grupo "O instalador nao carrega copia propria dos scripts de envio"
# =========================================================================

nao_contem "sem copia embutida do enviador de e-mail" "cat > /usr/local/bin/send_html_alert.sh"
nao_contem "sem copia embutida do enviador do Telegram" "cat > /usr/local/bin/send_telegram_alert.sh"

contem "os auxiliares vem do manifesto" 'for auxiliar in send_html_alert.sh send_telegram_alert.sh'
contem "com checksum conferido"         'Checksum de ${auxiliar} nao confere'
contem "e com bash -n antes de instalar" 'bash -n "${AGENTE_TMP}/${auxiliar}"'

# =========================================================================
grupo "Os limiares gravados sao os mesmos que o agente usa hoje"
# =========================================================================
#
# O agent.conf vence o padrao do codigo: gravar valor velho aqui desfaz, em
# toda instalacao nova, a correcao feita no agente.

valor_no_instalador() { grep -m1 "^${1}=" "$INST" | cut -d= -f2 | tr -d '[:space:]'; }
padrao_no_agente()    { grep -m1 "  ${1}=\"\${${1}:-" src/agent/20-config.sh | sed 's/.*:-\([^}]*\)}.*/\1/' | tr -d '[:space:]'; }

for chave in LOAD_ATENCAO LOAD_CRITICO STEAL_ATENCAO STEAL_CRITICO \
             CPU_ATENCAO CPU_CRITICO MEM_ATENCAO MEM_CRITICO \
             DISCO_ATENCAO DISCO_CRITICO SWAP_ATENCAO SWAP_CRITICO \
             INODE_ATENCAO INODE_CRITICO BANDA_SAIDA RENOTIFICAR_MIN \
             MAX_ALERTAS_HORA CICLOS_CONFIRMACAO CICLOS_RECUPERACAO
do
  esperado="$(padrao_no_agente "$chave")"
  obtido="$(valor_no_instalador "$chave")"
  if [[ -z "$esperado" ]]; then
    falha "${chave}: nao achei o padrao no agente"
  else
    igual "${chave} igual ao padrao do agente" "$esperado" "$obtido"
  fi
done

# =========================================================================
grupo "O que a 2.4 e a 2.5 acrescentaram esta no arquivo gerado"
# =========================================================================

contem "teto da renotificacao"  "RENOTIFICAR_MAX_MIN="
contem "banda de saida do load" "BANDA_SAIDA_LOAD="
contem "limiar de iowait"       "IOWAIT_ATENCAO="

# =========================================================================
grupo "A protecao contra mexer no servico de e-mail de terceiro continua"
# =========================================================================

contem "detecta MTA ja instalado"        "detect_mail_conflict()"
contem "procura Postfix"                 "dpkg -l postfix"
contem "procura Exim"                    "dpkg -l exim4"
contem "procura cPanel"                  "/usr/local/cpanel"
contem "com conta do painel nao instala MTA" 'SERVICO_EMAIL_DO_PAINEL -eq 0 ]] && PACKS="postfix'
contem "e pula a configuracao do Postfix" 'EMAIL_ENABLED -eq 1 && $SERVICO_EMAIL_DO_PAINEL -eq 0 ]]; then'

# =========================================================================
grupo "Instalacao silenciosa: o UUID vem na chamada"
# =========================================================================
#
# Com o UUID na linha de comando o instalador nao pode perguntar nada. Cada
# pergunta que escapar deste modo trava a instalacao automatizada, porque nao
# ha ninguem no teclado para responder.

contem "le os argumentos da chamada"      "while [[ \$# -gt 0 ]]; do"
contem "aceita --uuid=<UUID>"             "--uuid=*|--server-uuid=*"
contem "aceita --api=<URL>"               "--api=*|--api-url=*"
contem "aceita --help"                    "--help|-h) mostra_ajuda; exit 0 ;;"
contem "aceita SERVER_UUID do ambiente"   '${UUID_DA_CHAMADA:-${SERVER_UUID:-}}'
contem "UUID invalido para a instalacao"  'log_err "UUID invalido: ${UUID_DA_CHAMADA}"'
contem "silencioso dispensa o terminal"   'if [[ $MODO_SILENCIOSO -eq 0 ]] && [[ ! -t 0 ]]; then'
contem "nao pergunta pelo painel"         'if [[ $MODO_SILENCIOSO -eq 1 ]]; then
  USE_DASHBOARD="s"'
contem "nao pergunta destinatario"        'INSTALL_WARNINGS+=("Sem destinatario de e-mail.'
contem "nao pergunta e-mail"              'elif [[ $MODO_SILENCIOSO -eq 1 ]]; then'
contem "nao pergunta Telegram"            'INSTALL_WARNINGS+=("Telegram de fora.'
contem "painel mudo encerra com erro"     'log_err "O painel nao respondeu com a configuracao deste servidor."'
contem "o resumo diz que foi silenciosa"  "Instalacao silenciosa: tudo veio do painel"

# Toda pergunta do instalador tem que estar dentro de um caminho que o modo
# silencioso nao percorre. A contagem existe para uma pergunta nova nao entrar
# sem passar por aqui.
PERGUNTAS="$(grep -c 'read -r.*</dev/tty' "$INST")"
igual "o instalador tem 13 perguntas, todas no fluxo interativo" "13" "$PERGUNTAS"

# As perguntas de SMTP ficam no ramo em que NOS cuidamos do envio. No modo
# silencioso o e-mail so liga com a conta vinda do painel, que cai no ramo de
# cima, entao esse bloco nunca e alcancado sem alguem no teclado.
contem "perguntas de SMTP so sem conta do painel" 'elif [[ $EMAIL_ENABLED -eq 1 ]]; then'

# --- o leitor de argumentos rodando de verdade ---------------------------
#
# Grep nao prova que a opcao funciona. Este trecho recorta o leitor do
# instalador e o executa, que e a unica forma de saber se --uuid vira modo
# silencioso.

SANDBOX_ARGS="$(mktemp -d)"
limpa_args() { rm -rf "$SANDBOX_ARGS" 2>/dev/null || true; }
trap limpa_args EXIT

sed -n '/^# --- Instalacao silenciosa: o UUID vem na chamada/,/^# --- fim do leitor de argumentos/p' \
  "$INST" >"${SANDBOX_ARGS}/leitor.sh"

cat >"${SANDBOX_ARGS}/roda.sh" <<'RODA'
#!/usr/bin/env bash
set -uo pipefail
log_warn() { echo "[AVISO] $*" >&2; }
log_err()  { echo "[ERRO] $*" >&2; }
LEITOR="$1"; shift
# shellcheck disable=SC1090
source "$LEITOR"
printf '%s|%s|%s\n' "$MODO_SILENCIOSO" "$UUID_DA_CHAMADA" "$API_DA_CHAMADA"
RODA

leitor() { bash "${SANDBOX_ARGS}/roda.sh" "${SANDBOX_ARGS}/leitor.sh" "$@" 2>/dev/null; }

UUID_TESTE="636383ce-41c6-49b2-bfc9-96501e01a17c"

igual "sem argumento, fluxo interativo"   "0||"                       "$(leitor)"
igual "--uuid=<UUID> liga o silencioso"   "1|${UUID_TESTE}|"          "$(leitor --uuid=$UUID_TESTE)"
igual "--uuid <UUID> separado por espaco" "1|${UUID_TESTE}|"          "$(leitor --uuid $UUID_TESTE)"
igual "UUID solto tambem vale"            "1|${UUID_TESTE}|"          "$(leitor $UUID_TESTE)"
igual "--api junto do --uuid"             "1|${UUID_TESTE}|https://painel.exemplo/v1" \
      "$(leitor --uuid=$UUID_TESTE --api=https://painel.exemplo/v1)"
igual "SERVER_UUID do ambiente"           "1|${UUID_TESTE}|"          "$(SERVER_UUID=$UUID_TESTE leitor)"
igual "opcao desconhecida nao liga nada"  "0||"                       "$(leitor --nao-existe)"

leitor --uuid=nao-e-uuid >/dev/null 2>&1
igual "UUID malformado para a instalacao" "1" "$?"

# =========================================================================

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32m%s verificacoes do instalador, todas verdes.\033[0m\n' "$TOTAL"; exit 0
fi
printf '\033[31m%s verificacoes do instalador, %s falha(s).\033[0m\n' "$TOTAL" "$FALHAS"
exit 1
