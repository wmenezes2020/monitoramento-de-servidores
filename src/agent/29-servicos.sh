
# ---------------------------------------------------------------------------
# Servicos de notificacao vindos do painel
# ---------------------------------------------------------------------------
#
# A conta de envio de e-mail e o bot do Telegram passaram a ser cadastro do
# painel, com titulo, e cada servidor escolhe qual usa. O que chega aqui sao as
# credenciais do que foi escolhido.
#
# A DECISAO QUE IMPORTA NESTE ARQUIVO: quando ha conta de e-mail do painel, o
# envio deixa de passar pelo servico de e-mail da maquina.
#
# O motivo e concreto. O instalador detecta Postfix, Exim, Sendmail e cPanel ja
# instalados e, achando qualquer um, DESLIGA o e-mail em vez de configurar, para
# nao brigar com o que ja existe. Isso protege o servidor e deixa o monitoramento
# mudo: servidor com painel de hospedagem nunca recebeu alerta por e-mail.
#
# Enviando direto pelo SMTP com curl, o agente nao instala nada, nao edita
# main.cf, nao toca em sasl_passwd nem em generic, e funciona do lado de um
# Exim, de um cPanel ou do Postfix de outra pessoa sem disputar nada com eles.
#
# O caminho antigo continua inteiro para quem nao tem servico no painel.

CAMINHO_SMTP="${AGENTE_RAIZ}/smtp.conf"
CAMINHO_TELEGRAM="${AGENTE_RAIZ}/telegram.conf"

# Le um valor de um arquivo de configuracao sem dar source. O arquivo pode ter
# sido editado a mao, e um source executaria o que estivesse la dentro.
le_do_arquivo() {
  local chave="$1" arq="$2"
  [[ -f "$arq" ]] || return 1
  sed -n "s/^${chave}=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$arq" 2>/dev/null | head -1
}

# Grava com permissao 600 ANTES de escrever o conteudo: criar o arquivo aberto
# e apertar depois deixa uma janela em que a senha do SMTP fica legivel para
# qualquer usuario da maquina.
escreve_arquivo_de_credencial() {
  local arq="$1"; shift
  local tmp="${arq}.novo.$$"
  : >"$tmp" 2>/dev/null || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  printf '%s\n' "$@" >>"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$arq" 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 600 "$arq" 2>/dev/null || true
  return 0
}

# aplica_servico_email HOST PORTA SEGURO USUARIO SENHA REMETENTE NOME
#
# Nao valida a credencial contra o servidor de e-mail: quem sabe se a senha
# esta certa e o proprio SMTP, no envio. Testar aqui, a cada ciclo, seria uma
# conexao por minuto em todo servidor da frota para responder uma pergunta que
# o primeiro alerta responde de graca.
aplica_servico_email() {
  local host="$1" porta="$2" seguro="$3" usuario="$4" senha="$5" remetente="$6" nome="${7:-}"

  if [[ -z "$host" || -z "$usuario" || -z "$senha" ]]; then
    log_erro "servico de e-mail do painel veio incompleto; mantida a configuracao atual"
    return 1
  fi
  if ! email_valido "$remetente"; then
    log_erro "remetente invalido no servico de e-mail do painel: ${remetente}"
    return 1
  fi

  # Nada mudou: sair sem reescrever evita log repetido a cada cinco minutos e
  # evita trocar o arquivo debaixo de um envio em andamento.
  local host_atual porta_atual usuario_atual senha_atual
  host_atual="$(le_do_arquivo SMTP_HOST "$CAMINHO_SMTP")"
  porta_atual="$(le_do_arquivo SMTP_PORTA "$CAMINHO_SMTP")"
  usuario_atual="$(le_do_arquivo SMTP_USUARIO "$CAMINHO_SMTP")"
  senha_atual="$(le_do_arquivo SMTP_SENHA "$CAMINHO_SMTP")"
  if [[ "$host" == "$host_atual" && "$porta" == "$porta_atual" \
     && "$usuario" == "$usuario_atual" && "$senha" == "$senha_atual" ]]; then
    return 0
  fi

  if ! escreve_arquivo_de_credencial "$CAMINHO_SMTP" \
    "# Conta de envio escolhida no painel. Gerado pelo agente: editar a mao" \
    "# nao adianta, porque a proxima sincronia sobrescreve." \
    "SMTP_HOST=\"${host}\"" \
    "SMTP_PORTA=\"${porta:-587}\"" \
    "SMTP_SEGURO=\"${seguro:-0}\"" \
    "SMTP_USUARIO=\"${usuario}\"" \
    "SMTP_SENHA=\"${senha}\""
  then
    log_erro "nao consegui gravar ${CAMINHO_SMTP}"
    return 1
  fi

  # O remetente continua no email.conf, que e de onde o enviador le, para o
  # caminho antigo e o novo falarem do mesmo lugar.
  grava_no_email_conf SENDER_EMAIL "$remetente" || true
  [[ -n "$nome" ]] && grava_no_email_conf SENDER_NAME "$nome"

  log_info "conta de envio do painel aplicada: ${usuario} em ${host}:${porta:-587}"
  return 0
}

# aplica_servico_telegram TOKEN CHAT
aplica_servico_telegram() {
  local token="$1" chat="$2"
  if [[ -z "$token" || -z "$chat" ]]; then
    log_erro "servico de Telegram do painel veio incompleto; mantida a configuracao atual"
    return 1
  fi

  local token_atual chat_atual
  token_atual="$(le_do_arquivo TELEGRAM_BOT_TOKEN "$CAMINHO_TELEGRAM")"
  chat_atual="$(le_do_arquivo TELEGRAM_CHAT_ID "$CAMINHO_TELEGRAM")"
  [[ "$token" == "$token_atual" && "$chat" == "$chat_atual" ]] && return 0

  if ! escreve_arquivo_de_credencial "$CAMINHO_TELEGRAM" \
    "# Bot escolhido no painel. Gerado pelo agente." \
    "TELEGRAM_BOT_TOKEN=\"${token}\"" \
    "TELEGRAM_CHAT_ID=\"${chat}\""
  then
    log_erro "nao consegui gravar ${CAMINHO_TELEGRAM}"
    return 1
  fi

  log_info "bot do Telegram do painel aplicado (chat ${chat})"
  return 0
}

# Extrai um campo de texto de um bloco JSON simples, sem jq: o agente nao tem
# dependencia alem de bash, awk, coreutils e curl, e nao vai ganhar uma agora.
campo_json() {
  local bloco="$1" chave="$2"
  printf '%s' "$bloco" | sed -n "s/.*\"${chave}\":\"\([^\"]*\)\".*/\1/p" | head -1
}

campo_json_numero() {
  local bloco="$1" chave="$2"
  printf '%s' "$bloco" | grep -o "\"${chave}\":[0-9]\+" | head -1 | cut -d: -f2
}

campo_json_booleano() {
  local bloco="$1" chave="$2"
  if printf '%s' "$bloco" | grep -q "\"${chave}\":true"; then printf '1'; else printf '0'; fi
}

# Recorta o objeto de uma chave do JSON de resposta. Objeto aninhado nao
# aparece aqui: os dois blocos sao planos de proposito, do lado do backend.
bloco_json() {
  local resp="$1" chave="$2"
  printf '%s' "$resp" | grep -o "\"${chave}\":{[^}]*}" | head -1
}

# aplica_servicos_do_painel RESPOSTA_JSON
#
# Ausencia de bloco quer dizer "nada escolhido no painel", e nao "apague o que
# existe": o servidor segue com o que ja tem, que e o unico comportamento
# seguro para quem nunca abriu a tela de servicos.
aplica_servicos_do_painel() {
  local resp="$1" bloco

  bloco="$(bloco_json "$resp" email_service)"
  if [[ -n "$bloco" ]]; then
    aplica_servico_email \
      "$(campo_json "$bloco" host)" \
      "$(campo_json_numero "$bloco" port)" \
      "$(campo_json_booleano "$bloco" secure)" \
      "$(campo_json "$bloco" username)" \
      "$(campo_json "$bloco" password)" \
      "$(campo_json "$bloco" sender_email)" \
      "$(campo_json "$bloco" sender_name)" || true
  fi

  bloco="$(bloco_json "$resp" telegram_service)"
  if [[ -n "$bloco" ]]; then
    aplica_servico_telegram \
      "$(campo_json "$bloco" bot_token)" \
      "$(campo_json "$bloco" chat_id)" || true
  fi

  return 0
}
