
# ---------------------------------------------------------------------------
# Templates de e-mail
# ---------------------------------------------------------------------------
#
# Os templates em /opt/alerts/templates vem do instalador e tem rotulo fixo em
# portugues: "Data:", "Servidor:", "Alerta automatico. Nao responda.". Nem eles
# nem o send_html_alert.sh entram no manifesto de atualizacao, entao nao ha
# como traduzi-los pelo canal normal.
#
# A saida e o agente reescrever os arquivos. O send_html_alert.sh so faz
#   envsubst '${TITLE} ${MESSAGE} ${DATE} ${HOST}'
# ou seja, substitui quatro variaveis e copia o resto literalmente. Entao o
# template pode ir para o disco ja traduzido.
#
# A reescrita acontece quando o idioma muda, nao em toda rodada: gravar cinco
# arquivos por minuto em todo servidor da frota seria desperdicio puro.

TEMPLATES_DIR="${TEMPLATES_DIR:-/opt/alerts/templates}"

# Um arquivo por tipo de alerta, cada um com a cor da borda e o rotulo que o
# instalador original usava.
_templates_lista() {
  printf '%s\n' \
    "alert.html|#64748b" \
    "cpu-alert.html|#f97316" \
    "memory-alert.html|#8b5cf6" \
    "disk-alert.html|#0ea5e9" \
    "clamav-alert.html|#ef4444"
}

escreve_template() {
  local caminho="$1" cor="$2"
  local rot_data rot_servidor rodape
  rot_data="$(t tpl_data)"
  rot_servidor="$(t tpl_servidor)"
  rodape="$(t tpl_rodape)"

  # ${TITLE}, ${MESSAGE}, ${DATE} e ${HOST} ficam literais: quem substitui e o
  # envsubst dentro do send_html_alert.sh, na hora do envio.
  cat <<TEMPLATE | escreve_atomico "$caminho"
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" lang="$(idioma_html)">
<head>
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>\${TITLE}</title>
  <style type="text/css">
    table, td { border-collapse: collapse; }
    body { margin: 0; padding: 0; width: 100% !important; background-color: #f4f4f7; }
  </style>
</head>
<body style="margin: 0; padding: 0; background-color: #f4f4f7; font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;">
  <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" bgcolor="#f4f4f7">
    <tr><td align="center" style="padding: 40px 10px;">
      <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 640px; background-color: #ffffff; border-radius: 8px; border: 1px solid #eaeaec;">
        <tr>
          <td style="padding: 30px 40px 20px 40px; border-bottom: 4px solid ${cor};">
            <h1 style="margin: 0; font-size: 22px; font-weight: bold; color: #1f2937;">\${TITLE}</h1>
            <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="margin-top: 15px;">
              <tr><td style="color: #6b7280; font-size: 13px;"><strong>${rot_data}:</strong> \${DATE} | <strong>${rot_servidor}:</strong> \${HOST}</td></tr>
            </table>
          </td>
        </tr>
        <tr><td style="padding: 28px 40px; color: #374151; font-size: 14px; line-height: 1.6;">\${MESSAGE}</td></tr>
        <tr>
          <td style="padding: 18px 40px 30px 40px; border-top: 1px solid #eaeaec;">
            <p style="margin: 0; font-size: 12px; color: #9ca3af; text-align: center;">${rodape}</p>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>
TEMPLATE
}

idioma_html() {
  case "$(idioma_normalizado)" in
    pt) printf 'pt-BR' ;;
    en) printf 'en-US' ;;
    *)  printf 'es-CO' ;;
  esac
}

# Reescreve os templates se o idioma gravado em disco nao for o configurado.
# A marca fica num arquivo proprio, e nao dentro do HTML, para nao depender de
# conseguir ler de volta um arquivo que alguem pode ter editado a mao.
sincroniza_templates() {
  local marca="${TEMPLATES_DIR}/.idioma"
  local atual=""
  [[ -f "$marca" ]] && atual="$(tr -d '[:space:]' <"$marca" 2>/dev/null)"

  if [[ "$atual" == "${IDIOMA}" ]] && [[ -f "${TEMPLATES_DIR}/alert.html" ]]; then
    return 0
  fi

  if ! mkdir -p "$TEMPLATES_DIR" 2>/dev/null; then
    log_erro "nao consegui criar ${TEMPLATES_DIR}; templates nao traduzidos"
    return 1
  fi
  if [[ ! -w "$TEMPLATES_DIR" ]]; then
    log_erro "${TEMPLATES_DIR} nao e gravavel; templates seguem no idioma anterior"
    return 1
  fi

  local linha nome cor escritos=0
  while IFS='|' read -r nome cor; do
    [[ -z "$nome" ]] && continue
    if escreve_template "${TEMPLATES_DIR}/${nome}" "$cor"; then
      escritos=$(( escritos + 1 ))
    else
      log_erro "falhei ao escrever ${nome}"
    fi
  done < <(_templates_lista)

  if [[ "$escritos" -gt 0 ]]; then
    printf '%s' "$IDIOMA" | escreve_atomico "$marca" 2>/dev/null || true
    log_info "templates reescritos em ${IDIOMA} (${escritos} arquivos)"
  fi
  return 0
}
