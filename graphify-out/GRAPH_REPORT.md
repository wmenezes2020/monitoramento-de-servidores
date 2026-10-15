# Graph Report - monitoramento-de-servidores  (2026-10-14)

## Corpus Check
- Corpus is ~14,053 words - fits in a single context window. You may not need a graph.

## Summary
- 230 nodes · 334 edges · 22 communities (17 shown, 5 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- roda-testes
- testa-remetente
- 10-util
- testa-idioma
- testa-envio-email
- 30-medir
- 90-main
- 25-idioma
- testa-migracao
- 40-estado
- 80-bootstrap
- gerar-grafo
- 70-autoupdate
- 60-notificar
- 28-remetente
- 20-config
- 27-templates
- 50-avaliar
- build
- send_html_alert
- 00-cabecalho
- send_telegram_alert

## God Nodes (most connected - your core abstractions)
1. `testa-envio-email.sh script` - 10 edges
2. `atualiza_agente()` - 8 edges
3. `testa-idioma.sh script` - 8 edges
4. `roda-testes.sh script` - 7 edges
5. `ok()` - 7 edges
6. `falha()` - 7 edges
7. `ok()` - 7 edges
8. `falha()` - 7 edges
9. `testa-remetente.sh script` - 7 edges
10. `aplica_remetente()` - 6 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Import Cycles
- None detected.

## Communities (22 total, 5 thin omitted)

### Community 0 - "roda-testes"
Cohesion: 0.13
Nodes (19): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, AGENTE_SO_CARREGAR, falha(), FIXTURE_DF, FIXTURE_DF_INODES (+11 more)

### Community 1 - "testa-remetente"
Cohesion: 0.19
Nodes (18): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, AGENTE_SO_CARREGAR, contem(), falha(), grupo() (+10 more)

### Community 2 - "10-util"
Cohesion: 0.14
Nodes (6): agora(), log(), log_erro(), log_info(), pega_trava(), 10-util.sh script

### Community 3 - "testa-idioma"
Cohesion: 0.24
Nodes (16): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, AGENTE_SO_CARREGAR, casa(), contem(), falha() (+8 more)

### Community 4 - "testa-envio-email"
Cohesion: 0.30
Nodes (14): campo(), chama(), contem(), ENVIOS_LOG, falha(), grupo(), igual(), mentira() (+6 more)

### Community 5 - "30-medir"
Cohesion: 0.22
Nodes (9): campo_meminfo(), ignorar_montagem(), le_cpu_bruto(), mede_cpu(), mede_disco(), mede_memoria(), _saida_df(), _saida_df_inodes() (+1 more)

### Community 6 - "90-main"
Cohesion: 0.26
Nodes (9): autoteste(), avalia_e_notifica(), principal(), registra_heartbeat(), rodada(), 90-main.sh script, sincroniza_config(), status() (+1 more)

### Community 7 - "25-idioma"
Cohesion: 0.21
Nodes (5): msg_en(), msg_es(), msg_pt(), 25-idioma.sh script, t()

### Community 8 - "testa-migracao"
Cohesion: 0.33
Nodes (11): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, falha(), igual(), naotem(), ok() (+3 more)

### Community 9 - "40-estado"
Cohesion: 0.20
Nodes (3): caminho_estado(), le_estado(), 40-estado.sh script

### Community 10 - "80-bootstrap"
Cohesion: 0.31
Nodes (9): escreve_config_inicial(), instala_binarios(), instala_cron(), le_legado(), meu_caminho(), preserva_destinatarios(), roda_bootstrap(), 80-bootstrap.sh script (+1 more)

### Community 11 - "gerar-grafo"
Cohesion: 0.27
Nodes (9): json, Path, pathlib, alvos(), arquivos_do_corpus(), limpa_midia(), main(), Gera o grafo do repositorio em graphify-out/. python scripts/gerar-grafo.py usa… (+1 more)

### Community 12 - "70-autoupdate"
Cohesion: 0.33
Nodes (8): atualiza_agente(), baixa(), reporta_falha_update(), restaura_rollback(), 70-autoupdate.sh script, sha256_de(), versao_instalada(), versao_maior()

### Community 13 - "60-notificar"
Cohesion: 0.31
Nodes (5): envia_alerta(), envia_incidente_dashboard(), monta_corpo(), registra_agregado(), 60-notificar.sh script

### Community 14 - "28-remetente"
Cohesion: 0.43
Nodes (7): aplica_remetente(), atualiza_generic_do_postfix(), dominio_do_postfix(), email_valido(), grava_no_email_conf(), le_do_email_conf(), 28-remetente.sh script

### Community 15 - "20-config"
Cohesion: 0.40
Nodes (3): carrega_config(), 20-config.sh script, valida_config()

### Community 16 - "27-templates"
Cohesion: 0.40
Nodes (3): escreve_template(), 27-templates.sh script, sincroniza_templates()

## Knowledge Gaps
- **46 isolated node(s):** `build.sh script`, `00-cabecalho.sh script`, `10-util.sh script`, `20-config.sh script`, `25-idioma.sh script` (+41 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 101 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **5 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `build.sh script`, `00-cabecalho.sh script`, `10-util.sh script` to the rest of the system?**
  _46 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `roda-testes` be split into smaller, more focused modules?**
  _Cohesion score 0.12681159420289856 - nodes in this community are weakly interconnected._
- **Should `10-util` be split into smaller, more focused modules?**
  _Cohesion score 0.1437908496732026 - nodes in this community are weakly interconnected._