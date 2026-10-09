
# ---------------------------------------------------------------------------
# Auto-atualizacao
# ---------------------------------------------------------------------------
#
# O mecanismo antigo baixava tres arquivos de main a cada minuto, para sempre,
# sem versao e sem checksum: conferia so HTTP 200 e a primeira linha comecando
# com "#!". Um commit quebrado em main chegava na frota inteira em 60 segundos
# sem caminho de volta, e o mv vinha de /tmp, que costuma ser outro filesystem,
# entao a troca nem atomica era.
#
# Aqui: versao, SHA-256 por arquivo, validacao de sintaxe, troca atomica no
# mesmo filesystem, autoteste e rollback automatico.

sha256_de() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
  else
    printf ''
  fi
}

baixa() {
  local url="$1" destino="$2" codigo
  codigo="$(curl -fsSL -o "$destino" -w '%{http_code}' --max-time 30 --retry 2 --retry-delay 2 "$url" 2>/dev/null)" || return 1
  [[ "$codigo" == "200" ]] || return 1
  [[ -s "$destino" ]] || return 1
  return 0
}

versao_instalada() {
  cat "${AGENTE_RAIZ}/VERSION" 2>/dev/null | tr -d '[:space:]' || printf ''
}

# Compara versoes semanticas: sucesso quando $1 > $2
versao_maior() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    na = split(a, x, "."); nb = split(b, y, ".")
    n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      xi = (i <= na) ? x[i]+0 : 0
      yi = (i <= nb) ? y[i]+0 : 0
      if (xi > yi) { exit 0 }
      if (xi < yi) { exit 1 }
    }
    exit 1
  }'
}

# O manifesto e a lista do que compoe uma versao, com o hash de cada arquivo:
#   VERSAO=2.0.0
#   ARQUIVO=monitoring-agent.sh <sha256>
#   ARQUIVO=monitor_cpu.sh <sha256>
atualiza_agente() {
  [[ "${AUTO_UPDATE:-1}" == "1" ]] || { log_info "auto-update desligado"; return 0; }

  local base="${UPDATE_BASE_URL}/${UPDATE_CANAL}"
  local tmpdir
  tmpdir="$(mktemp -d "${AGENTE_RAIZ}/.update.XXXXXX" 2>/dev/null)" || {
    log_erro "nao consegui criar diretorio temporario para a atualizacao"; return 1; }
  # mktemp dentro de AGENTE_RAIZ de proposito: a troca final precisa ser um mv
  # dentro do mesmo filesystem de destino para ser atomica.

  local limpar=1
  _limpa_update() { [[ "$limpar" == "1" ]] && rm -rf "$tmpdir" 2>/dev/null || true; }

  if ! baixa "${base}/agent.manifest" "${tmpdir}/manifest"; then
    log_erro "manifesto indisponivel em ${base}/agent.manifest"
    _limpa_update; return 1
  fi

  local nova
  nova="$(awk -F= '/^VERSAO=/{print $2; exit}' "${tmpdir}/manifest" | tr -d '[:space:]')"
  if [[ -z "$nova" ]]; then
    log_erro "manifesto sem campo VERSAO"
    _limpa_update; return 1
  fi

  local atual
  atual="$(versao_instalada)"
  [[ -z "$atual" ]] && atual="0.0.0"
  if ! versao_maior "$nova" "$atual"; then
    _limpa_update
    return 0
  fi

  log_info "atualizacao disponivel: ${atual} -> ${nova}"

  # 1. Baixar e conferir TUDO antes de instalar qualquer coisa. Instalar
  #    arquivo por arquivo deixaria o servidor com meia versao se o quinto
  #    download falhasse.
  local arquivos=() nome hash_esperado hash_obtido
  while read -r linha; do
    [[ "$linha" == ARQUIVO=* ]] || continue
    nome="$(printf '%s' "${linha#ARQUIVO=}" | awk '{print $1}')"
    hash_esperado="$(printf '%s' "${linha#ARQUIVO=}" | awk '{print $2}')"
    [[ -z "$nome" || -z "$hash_esperado" ]] && continue

    if ! baixa "${base}/${nome}" "${tmpdir}/${nome}"; then
      log_erro "download de ${nome} falhou; atualizacao abortada sem alterar nada"
      _limpa_update; return 1
    fi
    hash_obtido="$(sha256_de "${tmpdir}/${nome}")"
    if [[ -z "$hash_obtido" ]]; then
      log_erro "sem ferramenta de sha256 no servidor; atualizacao abortada por seguranca"
      _limpa_update; return 1
    fi
    if [[ "$hash_obtido" != "$hash_esperado" ]]; then
      log_erro "checksum de ${nome} nao confere (esperado ${hash_esperado}, obtido ${hash_obtido}); atualizacao abortada"
      _limpa_update; return 1
    fi
    if ! bash -n "${tmpdir}/${nome}" 2>/dev/null; then
      log_erro "${nome} nao passa em bash -n; atualizacao abortada"
      _limpa_update; return 1
    fi
    arquivos+=("$nome")
  done <"${tmpdir}/manifest"

  if [[ "${#arquivos[@]}" -eq 0 ]]; then
    log_erro "manifesto sem arquivos"
    _limpa_update; return 1
  fi

  # 2. Guardar a versao atual para poder voltar
  local backup="${AGENTE_RAIZ}/rollback"
  rm -rf "$backup" 2>/dev/null || true
  mkdir -p "$backup" 2>/dev/null || true
  for nome in "${arquivos[@]}"; do
    [[ -f "${AGENTE_BIN}/${nome}" ]] && cp -a "${AGENTE_BIN}/${nome}" "${backup}/${nome}" 2>/dev/null || true
  done
  printf '%s' "$atual" >"${backup}/VERSION" 2>/dev/null || true

  # 3. Instalar. O temporario precisa estar no filesystem do destino.
  local falhou=0 staging
  staging="$(mktemp -d "${AGENTE_BIN}/.staging.XXXXXX" 2>/dev/null)" || {
    log_erro "nao consegui criar staging em ${AGENTE_BIN}"; _limpa_update; return 1; }
  for nome in "${arquivos[@]}"; do
    cp "${tmpdir}/${nome}" "${staging}/${nome}" 2>/dev/null || { falhou=1; break; }
    chmod 755 "${staging}/${nome}" 2>/dev/null || true
  done
  if [[ "$falhou" -eq 0 ]]; then
    for nome in "${arquivos[@]}"; do
      mv -f "${staging}/${nome}" "${AGENTE_BIN}/${nome}" 2>/dev/null || falhou=1
    done
  fi
  rm -rf "$staging" 2>/dev/null || true

  if [[ "$falhou" -ne 0 ]]; then
    log_erro "instalacao falhou no meio; restaurando"
    restaura_rollback
    _limpa_update; return 1
  fi

  printf '%s' "$nova" | escreve_atomico "${AGENTE_RAIZ}/VERSION" 2>/dev/null || true

  # 4. Autoteste. Versao que nao roda nao fica instalada.
  if ! "${AGENTE_BIN}/monitoring-agent.sh" autoteste >/dev/null 2>&1; then
    log_erro "autoteste da versao ${nova} falhou; voltando para ${atual}"
    restaura_rollback
    printf '%s' "$atual" | escreve_atomico "${AGENTE_RAIZ}/VERSION" 2>/dev/null || true
    reporta_falha_update "$nova" "$atual"
    _limpa_update; return 1
  fi

  log_info "atualizado para ${nova} com autoteste verde"
  _limpa_update
  return 0
}

restaura_rollback() {
  local backup="${AGENTE_RAIZ}/rollback" nome
  [[ -d "$backup" ]] || { log_erro "sem backup para restaurar"; return 1; }
  for f in "$backup"/*; do
    nome="$(basename "$f")"
    [[ "$nome" == "VERSION" ]] && continue
    cp -a "$f" "${AGENTE_BIN}/${nome}" 2>/dev/null || true
    chmod 755 "${AGENTE_BIN}/${nome}" 2>/dev/null || true
  done
  log_info "rollback aplicado"
  return 0
}

reporta_falha_update() {
  local tentada="$1" voltou="$2"
  [[ "${DASHBOARD_ENABLED:-0}" == "1" && -n "${DASHBOARD_SERVER_UUID:-}" ]] || return 0
  [[ -x "${AGENTE_BIN}/send_dashboard_metrics.sh" ]] || return 0
  printf '{"server_uuid":"%s","timestamp":"%s","server_id":"%s","type":"agent_update","value":0,"threshold":0,"severity":"warning","status":"open","subject":"Atualizacao %s revertida em %s","snapshot_top":"O autoteste da versao %s falhou e o agente voltou para %s automaticamente.","agent_version":"%s","notifications_sent":{"email":false,"telegram":false}}\n' \
    "$DASHBOARD_SERVER_UUID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SERVER_ID" \
    "$tentada" "$SERVER_ID" "$tentada" "$voltou" "$voltou" \
    | "${AGENTE_BIN}/send_dashboard_metrics.sh" incident >/dev/null 2>&1 || true
}
