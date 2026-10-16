# Graph Report - monitoramento-de-servidores  (2026-10-16)

## Corpus Check
- Corpus is ~19,117 words - fits in a single context window. You may not need a graph.

## Summary
- 307 nodes · 482 edges · 26 communities (23 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- roda-testes
- testa-servicos
- testa-remetente
- 10-util
- testa-idioma
- 25-idioma
- testa-ruido
- testa-envio-email
- 30-medir
- 29-servicos
- 90-main
- testa-migracao
- 40-estado
- 80-bootstrap
- gerar-grafo
- 60-notificar
- 70-autoupdate
- testa-instalador
- 28-remetente
- 50-avaliar
- send_html_alert
- 20-config
- 27-templates
- build
- 00-cabecalho
- send_telegram_alert

## God Nodes (most connected - your core abstractions)
1. `testa-envio-email.sh script` - 10 edges
2. `t()` - 9 edges
3. `testa-ruido.sh script` - 9 edges
4. `atualiza_agente()` - 8 edges
5. `testa-idioma.sh script` - 8 edges
6. `testa-instalador.sh script` - 8 edges
7. `testa-servicos.sh script` - 8 edges
8. `roda-testes.sh script` - 7 edges
9. `ok()` - 7 edges
10. `falha()` - 7 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Import Cycles
- None detected.

## Communities (26 total, 3 thin omitted)

### Community 0 - "roda-testes"
Cohesion: 0.13
Nodes (19): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, AGENTE_SO_CARREGAR, falha(), FIXTURE_DF, FIXTURE_DF_INODES (+11 more)

### Community 1 - "testa-servicos"
Cohesion: 0.21
Nodes (19): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, AGENTE_SO_CARREGAR, chmod_funciona(), contem(), falha() (+11 more)

### Community 2 - "testa-remetente"
Cohesion: 0.19
Nodes (18): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, AGENTE_SO_CARREGAR, contem(), falha(), grupo() (+10 more)

### Community 3 - "10-util"
Cohesion: 0.14
Nodes (6): agora(), log(), log_erro(), log_info(), pega_trava(), 10-util.sh script

### Community 4 - "testa-idioma"
Cohesion: 0.24
Nodes (16): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, AGENTE_SO_CARREGAR, casa(), contem(), falha() (+8 more)

### Community 5 - "25-idioma"
Cohesion: 0.18
Nodes (10): frase_problema(), frase_recuperacao(), impacto_metrica(), msg_en(), msg_es(), msg_pt(), 25-idioma.sh script, sujeito_metrica() (+2 more)

### Community 6 - "testa-ruido"
Cohesion: 0.26
Nodes (16): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, AGENTE_SO_CARREGAR, antes_de(), contem(), envelhece() (+8 more)

### Community 7 - "testa-envio-email"
Cohesion: 0.30
Nodes (14): campo(), chama(), contem(), ENVIOS_LOG, falha(), grupo(), igual(), mentira() (+6 more)

### Community 8 - "30-medir"
Cohesion: 0.18
Nodes (9): campo_meminfo(), ignorar_montagem(), le_cpu_bruto(), mede_cpu(), mede_disco(), mede_memoria(), _saida_df(), _saida_df_inodes() (+1 more)

### Community 9 - "29-servicos"
Cohesion: 0.27
Nodes (9): aplica_relay_no_postfix(), aplica_servico_email(), aplica_servico_telegram(), aplica_servicos_do_painel(), bloco_json(), escreve_arquivo_de_credencial(), le_do_arquivo(), mta_e_nosso() (+1 more)

### Community 10 - "90-main"
Cohesion: 0.26
Nodes (9): autoteste(), avalia_e_notifica(), principal(), registra_heartbeat(), rodada(), 90-main.sh script, sincroniza_config(), status() (+1 more)

### Community 11 - "testa-migracao"
Cohesion: 0.33
Nodes (11): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, falha(), igual(), naotem(), ok() (+3 more)

### Community 12 - "40-estado"
Cohesion: 0.20
Nodes (3): caminho_estado(), le_estado(), 40-estado.sh script

### Community 13 - "80-bootstrap"
Cohesion: 0.31
Nodes (9): escreve_config_inicial(), instala_binarios(), instala_cron(), le_legado(), meu_caminho(), preserva_destinatarios(), roda_bootstrap(), 80-bootstrap.sh script (+1 more)

### Community 14 - "gerar-grafo"
Cohesion: 0.27
Nodes (9): json, Path, pathlib, alvos(), arquivos_do_corpus(), limpa_midia(), main(), Gera o grafo do repositorio em graphify-out/. python scripts/gerar-grafo.py usa… (+1 more)

### Community 15 - "60-notificar"
Cohesion: 0.29
Nodes (6): envia_alerta(), envia_incidente_dashboard(), monta_corpo(), monta_texto_tg(), registra_agregado(), 60-notificar.sh script

### Community 16 - "70-autoupdate"
Cohesion: 0.33
Nodes (8): atualiza_agente(), baixa(), reporta_falha_update(), restaura_rollback(), 70-autoupdate.sh script, sha256_de(), versao_instalada(), versao_maior()

### Community 17 - "testa-instalador"
Cohesion: 0.49
Nodes (9): contem(), falha(), grupo(), igual(), nao_contem(), ok(), padrao_no_agente(), testa-instalador.sh script (+1 more)

### Community 18 - "28-remetente"
Cohesion: 0.43
Nodes (7): aplica_remetente(), atualiza_generic_do_postfix(), dominio_do_postfix(), email_valido(), grava_no_email_conf(), le_do_email_conf(), 28-remetente.sh script

### Community 19 - "50-avaliar"
Cohesion: 0.32
Nodes (5): avalia(), banda_de(), espera_renotificacao(), 50-avaliar.sh script, valor_para_fechar_load()

### Community 20 - "send_html_alert"
Cohesion: 0.46
Nodes (7): codifica_cabecalho(), envia_direto(), monta_mime(), mta_e_nosso(), send_html_alert.sh script, tem_smtp_do_painel(), usa_smtp_direto()

### Community 21 - "20-config"
Cohesion: 0.40
Nodes (3): carrega_config(), 20-config.sh script, valida_config()

### Community 22 - "27-templates"
Cohesion: 0.40
Nodes (3): escreve_template(), 27-templates.sh script, sincroniza_templates()

## Knowledge Gaps
- **59 isolated node(s):** `build.sh script`, `00-cabecalho.sh script`, `10-util.sh script`, `20-config.sh script`, `25-idioma.sh script` (+54 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 119 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `build.sh script`, `00-cabecalho.sh script`, `10-util.sh script` to the rest of the system?**
  _59 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `roda-testes` be split into smaller, more focused modules?**
  _Cohesion score 0.12681159420289856 - nodes in this community are weakly interconnected._
- **Should `10-util` be split into smaller, more focused modules?**
  _Cohesion score 0.1437908496732026 - nodes in this community are weakly interconnected._