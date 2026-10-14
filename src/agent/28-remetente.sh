
# ---------------------------------------------------------------------------
# Remetente dos e-mails
# ---------------------------------------------------------------------------
#
# O remetente chega do painel, por servidor, junto com os limiares. Trocar ele
# exige mais do que gravar uma variavel.
#
# O Postfix REESCREVE o endereco de origem na saida, usando o mapa
# /etc/postfix/generic que o instalador criou e ligou no main.cf por
# smtp_generic_maps. Isso acontece DEPOIS que o send_html_alert.sh montou o
# cabecalho From:.
#
# Entao mudar so o SENDER_EMAIL do email.conf faria o painel mostrar o
# remetente novo, o arquivo ter o valor novo, e o e-mail chegar com o antigo.
# A funcionalidade pareceria pronta e estaria quebrada.
#
# A ordem que funciona: gravar o email.conf, reescrever o generic, rodar
# postmap, recarregar o Postfix. Falhando do segundo passo em diante, o
# email.conf volta ao valor anterior: e melhor seguir enviando pelo remetente
# antigo, que funciona, do que ficar num estado em que o cabecalho diz uma
# coisa e o envelope diz outra.

POSTFIX_GENERIC="${POSTFIX_GENERIC:-/etc/postfix/generic}"

email_valido() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# Le um valor do email.conf sem dar source: o arquivo pode ter sido editado a
# mao e um source traria junto qualquer coisa que estiver la.
le_do_email_conf() {
  local chave="$1" arq="${AGENTE_RAIZ}/email.conf"
  [[ -f "$arq" ]] || return 0
  grep -m1 "^${chave}=" "$arq" 2>/dev/null | sed 's/^[^=]*=//; s/^"//; s/"$//'
}

grava_no_email_conf() {
  local chave="$1" valor="$2" arq="${AGENTE_RAIZ}/email.conf"
  mkdir -p "$AGENTE_RAIZ" 2>/dev/null || true
  touch "$arq" 2>/dev/null || return 1
  if grep -q "^${chave}=" "$arq" 2>/dev/null; then
    sed -i "s|^${chave}=.*|${chave}=\"${valor}\"|" "$arq" 2>/dev/null || return 1
  else
    printf '%s="%s"\n' "$chave" "$valor" >>"$arq" 2>/dev/null || return 1
  fi
  return 0
}

# Reescreve o mapa do Postfix preservando qualquer linha que nao seja do
# dominio que mapeamos. Apagar o arquivo inteiro levaria junto regra que
# alguem tenha somado a mao.
atualiza_generic_do_postfix() {
  local remetente="$1" dominio="$2"
  [[ -f "$POSTFIX_GENERIC" ]] || return 1
  command -v postmap >/dev/null 2>&1 || { log_erro "postmap ausente; remetente nao aplicado no Postfix"; return 1; }

  local tmp
  tmp="$(mktemp "${POSTFIX_GENERIC}.XXXXXX" 2>/dev/null)" || return 1

  awk -v dom="$dominio" -v rem="$remetente" '
    $1 == "root@" dom { next }
    $1 == "@" dom     { next }
    { print }
    END {
      printf "root@%s    %s\n", dom, rem
      printf "@%s    %s\n", dom, rem
    }
  ' "$POSTFIX_GENERIC" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }

  chmod --reference="$POSTFIX_GENERIC" "$tmp" 2>/dev/null || chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$POSTFIX_GENERIC" || { rm -f "$tmp"; return 1; }

  postmap "$POSTFIX_GENERIC" 2>/dev/null || { log_erro "postmap falhou em ${POSTFIX_GENERIC}"; return 1; }
  # O reload falha em servidor onde o Postfix nao esta rodando, e isso nao
  # invalida a troca: o mapa ja esta no disco e vale na proxima subida.
  postfix reload >/dev/null 2>&1 || systemctl reload postfix >/dev/null 2>&1 || true
  return 0
}

# Dominio do LADO ESQUERDO do mapa, que e o dominio de onde o Postfix envia.
#
# Nao e o dominio do remetente: o mapa diz "o que sai de @servidor.com vira
# avisos@empresa.com", e o lado esquerdo nao muda quando o remetente muda. Ler
# o dominio do remetente fazia o awk procurar linhas que nao existiam, deixar
# as antigas no lugar e somar as novas: o Postfix ficava com duas regras e
# continuava reescrevendo pela primeira.
#
# A fonte certa e o proprio mapa, que e a verdade sobre o que o Postfix faz.
dominio_do_postfix() {
  local do_mapa
  if [[ -f "$POSTFIX_GENERIC" ]]; then
    do_mapa="$(awk '$1 ~ /^@/ { sub(/^@/, "", $1); print $1; exit }' "$POSTFIX_GENERIC" 2>/dev/null)"
    [[ -n "$do_mapa" ]] && { printf '%s' "$do_mapa"; return 0; }
  fi
  hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'localhost'
}

# aplica_remetente EMAIL [NOME]
#
# Devolve 0 quando o remetente passou a valer, 1 quando nada mudou ou quando a
# troca foi revertida.
aplica_remetente() {
  local novo="$1" nome="${2:-}"

  [[ -n "$novo" ]] || return 1
  if ! email_valido "$novo"; then
    log_erro "remetente invalido recusado: ${novo}"
    return 1
  fi

  local atual
  atual="$(le_do_email_conf SENDER_EMAIL)"
  local nome_atual
  nome_atual="$(le_do_email_conf SENDER_NAME)"
  if [[ "$atual" == "$novo" && "$nome_atual" == "$nome" ]]; then
    return 1
  fi

  # Lido ANTES de gravar: depois da gravacao o valor ja seria o novo.
  local dominio
  dominio="$(dominio_do_postfix)"

  grava_no_email_conf SENDER_EMAIL "$novo" || { log_erro "nao consegui gravar o remetente"; return 1; }
  [[ -n "$nome" ]] && grava_no_email_conf SENDER_NAME "$nome"

  if ! atualiza_generic_do_postfix "$novo" "$dominio"; then
    # Volta atras: o Postfix continua reescrevendo para o antigo, e manter o
    # email.conf com o novo deixaria o cabecalho e o envelope discordando.
    log_erro "remetente revertido para ${atual:-vazio}: o Postfix nao aceitou a troca"
    grava_no_email_conf SENDER_EMAIL "$atual"
    [[ -n "$nome_atual" ]] && grava_no_email_conf SENDER_NAME "$nome_atual"
    return 1
  fi

  log_info "remetente agora e ${novo}${nome:+ (${nome})}"
  return 0
}
