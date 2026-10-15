#!/usr/bin/env bash
#
# Bateria do envio de e-mail.
#
#   ./tests/testa-envio-email.sh
#
# Dois defeitos reais, achados em producao em 14/10/2026, e que esta bateria
# existe para nao deixar voltar:
#
# 1. O alerta de recuperacao chegava e o de abertura nao. A diferenca era o
#    acento. Cabecalho de e-mail so aceita ASCII (RFC 5322), e quando o
#    catalogo de idiomas entrou, "[ATENCAO]" virou "[ATENÇÃO]" e "[CRITICO]"
#    virou "[CRÍTICO]". "[OK]" ficou sem acento, e era o unico que passava.
#
# 2. So o primeiro destinatario da lista recebia. O `mail` espera enderecos
#    como argumentos separados; passar "a@x.com,b@y.com" faz ele tratar tudo
#    como um endereco so.
#
# O `mail` e de mentira: ele grava o que recebeu num arquivo, entao nada sai
# da maquina.
set -uo pipefail

cd "$(dirname "$0")/.."
RAIZ="$PWD"

TOTAL=0; FALHAS=0
grupo() { printf '\n%s\n' "$1"; }
ok()    { TOTAL=$((TOTAL+1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
falha() {
  TOTAL=$((TOTAL+1)); FALHAS=$((FALHAS+1))
  printf '  \033[31mFALHA\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '        esperado: %s\n' "$2"
  [[ -n "${3:-}" ]] && printf '        obtido:   %s\n' "$3"
  return 0
}
igual()      { [[ "$2" == "$3" ]] && ok "$1" || falha "$1" "$2" "$3"; }
contem()     { case "$2" in *"$3"*) ok "$1" ;; *) falha "$1" "conter \"$3\"" "$2" ;; esac; }
nao_contem() { case "$2" in *"$3"*) falha "$1" "nao conter \"$3\"" "$2" ;; *) ok "$1" ;; esac; }
verdade()    { local d="$1"; shift; if "$@"; then ok "$d"; else falha "$d"; fi; }
# Cabecalho de e-mail so aceita ASCII. O texto vai por argumento: interpolar
# dentro de um "bash -c" quebra com acento, aspas e colchete.
so_ascii()   { if LC_ALL=C grep -q '[^ -~]' <<<"$2"; then falha "$1" "so ASCII" "$2"; else ok "$1"; fi; }
mentira()    { local d="$1"; shift; if "$@"; then falha "$d"; else ok "$d"; fi; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "${SANDBOX}/falso" "${SANDBOX}/templates"

ENVIOS="${SANDBOX}/envios.log"

# `mail` de mentira: registra uma linha por chamada com assunto e destinatario,
# e devolve erro para o endereco que comeca com "recusa".
cat >"${SANDBOX}/falso/mail" <<'FALSO'
#!/usr/bin/env bash
assunto=""; destino=""; from=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) assunto="$2"; shift 2 ;;
    -r) shift 2 ;;
    -a) [[ "$2" == From:* ]] && from="${2#From: }"; shift 2 ;;
    *)  destino="$1"; shift ;;
  esac
done
cat >/dev/null
printf 'DESTINO=%s|ASSUNTO=%s|FROM=%s\n' "$destino" "$assunto" "$from" >> "$ENVIOS_LOG"
[[ "$destino" == recusa* ]] && exit 1
exit 0
FALSO
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' >"${SANDBOX}/falso/envsubst_fake"
chmod +x "${SANDBOX}/falso/mail"
export PATH="${SANDBOX}/falso:${PATH}"
export ENVIOS_LOG="$ENVIOS"

printf '<html><body>${TITLE} ${MESSAGE} ${DATE} ${HOST}</body></html>\n' >"${SANDBOX}/templates/alert.html"

ENVIA="${RAIZ}/send_html_alert.sh"
[[ -f "$ENVIA" ]] || { echo "rode ./scripts/build.sh primeiro" >&2; exit 1; }

# O script le /opt/monitoring/email.conf, que nao existe nesta maquina: ele
# apenas segue com os padroes, que e o que queremos testar.
chama() { : >"$ENVIOS"; bash "$ENVIA" "${SANDBOX}/templates/alert.html" "$1" "$2" "Titulo" "<p>corpo</p>" >/dev/null 2>&1; }
# grep -c imprime 0 E sai com erro quando nao acha nada; o "|| printf 0"
# grep -c imprime 0 E sai com erro quando nao acha nada. O fallback antigo
# imprimia um segundo zero, e a comparacao recebia dois zeros em vez de um.
linhas() { grep -c . "$ENVIOS" 2>/dev/null; true; }
campo()  { grep -o "$1=[^|]*" "$ENVIOS" | sed "s/^$1=//" | sed -n "${2:-1}p"; }

# =========================================================================
grupo "Assunto com acento precisa ir codificado"
# =========================================================================
#
# Era este o motivo de o alerta de abertura nao chegar: o MTA recusa um
# cabecalho com byte fora do ASCII.

chama "um@empresa.com" "[ATENÇÃO] CPU 97% - servidor"
ASSUNTO="$(campo ASSUNTO)"
contem     "assunto acentuado vira encoded-word" "$ASSUNTO" "=?UTF-8?B?"
nao_contem "e nao vai com o acento cru"          "$ASSUNTO" "ATENÇÃO"
so_ascii   "nenhum byte fora do ASCII no cabecalho" "$ASSUNTO"

# O que foi codificado precisa voltar igual: codificar errado seria trocar um
# alerta que nao chega por um que chega ilegivel.
DECODIFICADO="$(printf '%s' "$ASSUNTO" | sed 's/^=?UTF-8?B?//; s/?=$//' | base64 -d 2>/dev/null)"
igual "e decodifica de volta no texto certo" "[ATENÇÃO] CPU 97% - servidor" "$DECODIFICADO"

chama "um@empresa.com" "[CRÍTICO] Memória 98% - servidor"
contem "critico tambem e codificado" "$(campo ASSUNTO)" "=?UTF-8?B?"

chama "um@empresa.com" "[ATENCIÓN] CPU 97%"
contem "espanhol tambem" "$(campo ASSUNTO)" "=?UTF-8?B?"

# =========================================================================
grupo "Assunto sem acento segue legivel"
# =========================================================================
#
# Codificar tudo funcionaria, mas deixa o log do servidor de e-mail ilegivel
# e dificulta procurar por um alerta antigo.

chama "um@empresa.com" "[OK] CPU 12% - servidor"
igual "ASCII puro nao e codificado" "[OK] CPU 12% - servidor" "$(campo ASSUNTO)"

chama "um@empresa.com" "[WARNING] CPU at 97% - server"
igual "ingles nao e codificado" "[WARNING] CPU at 97% - server" "$(campo ASSUNTO)"

# =========================================================================
grupo "Todos os destinatarios recebem"
# =========================================================================
#
# O script do instalador passava a lista inteira como um argumento so, e o
# `mail` tratava "a@x.com,b@y.com" como um endereco unico.

chama "um@empresa.com,dois@empresa.com,tres@empresa.com" "[OK] teste"
igual "tres enderecos, tres envios" "3" "$(linhas)"
igual "o primeiro recebe"  "um@empresa.com"   "$(campo DESTINO 1)"
igual "o segundo tambem"   "dois@empresa.com" "$(campo DESTINO 2)"
igual "e o terceiro"       "tres@empresa.com" "$(campo DESTINO 3)"

# A lista vem de um campo de texto: espaco depois da virgula e o normal.
chama "um@empresa.com, dois@empresa.com ,  tres@empresa.com" "[OK] teste"
igual "espaco em volta da virgula nao atrapalha" "3" "$(linhas)"
igual "e o endereco vai sem espaco"              "dois@empresa.com" "$(campo DESTINO 2)"

chama "um@empresa.com,,dois@empresa.com," "[OK] teste"
igual "virgula sobrando nao vira envio vazio" "2" "$(linhas)"

chama "unico@empresa.com" "[OK] teste"
igual "um destinatario so continua funcionando" "1" "$(linhas)"

# =========================================================================
grupo "Endereco ruim no meio nao derruba os outros"
# =========================================================================
#
# Um envio por endereco, e nao todos de uma vez, existe por isto.

chama "bom@empresa.com,recusa@invalido,outro@empresa.com" "[OK] teste"
igual   "tentou nos tres"                  "3" "$(linhas)"
verdade "e o terceiro foi tentado"         grep -q "outro@empresa.com" "$ENVIOS"

: >"$ENVIOS"
bash "$ENVIA" "${SANDBOX}/templates/alert.html" "bom@empresa.com,recusa@invalido" "[OK] x" "T" "<p>c</p>" >/dev/null 2>&1
verdade "sucesso parcial ainda e sucesso" test $? -eq 0

: >"$ENVIOS"
bash "$ENVIA" "${SANDBOX}/templates/alert.html" "recusa@a,recusa@b" "[OK] x" "T" "<p>c</p>" >/dev/null 2>&1
mentira "mas falhar em todos e falha" test $? -eq 0

# =========================================================================
grupo "Remetente com acento no nome"
# =========================================================================

# O script le /opt/monitoring/email.conf, que nao existe aqui. Em vez de um
# bash -c com sed embutido, que vira um ninho de aspas, a copia e preparada
# antes e chamada direto.
printf 'SENDER_EMAIL="alertas@empresa.com"\nSENDER_NAME="Monitoracao"\n' >"${SANDBOX}/email.conf"
sed "s|/opt/monitoring/email.conf|${SANDBOX}/email.conf|g" "$ENVIA" >"${SANDBOX}/envia.sh"
: >"$ENVIOS"
bash "${SANDBOX}/envia.sh" "${SANDBOX}/templates/alert.html" "um@empresa.com" "[OK] teste" "T" "<p>c</p>" >/dev/null 2>&1
igual "nome sem acento fica legivel" "Monitoracao <alertas@empresa.com>" "$(campo FROM)"

printf 'SENDER_EMAIL="alertas@empresa.com"\nSENDER_NAME="Monitoracao"\n' >"${SANDBOX}/email.conf"
sed -i 's/Monitoracao/Monitoração/' "${SANDBOX}/email.conf"
: >"$ENVIOS"
bash "${SANDBOX}/envia.sh" "${SANDBOX}/templates/alert.html" "um@empresa.com" "[OK] teste" "T" "<p>c</p>" >/dev/null 2>&1
FROM="$(campo FROM)"
contem   "nome acentuado tambem e codificado" "$FROM" "=?UTF-8?B?"
contem   "e o endereco fica legivel ao lado"  "$FROM" "<alertas@empresa.com>"
so_ascii "sem byte cru no From"               "$FROM"

# =========================================================================
grupo "Nada a enviar"
# =========================================================================

: >"$ENVIOS"
bash "$ENVIA" "${SANDBOX}/templates/alert.html" "" "[OK] x" "T" "<p>c</p>" >/dev/null 2>&1
igual "lista vazia nao chama o mail" "0" "$(linhas)"

# =========================================================================

printf '\n'
if [[ "$FALHAS" -eq 0 ]]; then
  printf '\033[32m%s verificacoes de envio, todas verdes.\033[0m\n' "$TOTAL"; exit 0
fi
printf '\033[31m%s verificacoes de envio, %s falha(s).\033[0m\n' "$TOTAL" "$FALHAS"
exit 1
