# Graph Report - monitoramento-de-servidores  (2026-10-09)

## Corpus Check
- Corpus is ~9,226 words - fits in a single context window. You may not need a graph.

## Summary
- 150 nodes · 199 edges · 14 communities (11 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- roda-testes
- 10-util
- 30-medir
- 90-main
- testa-migracao
- 40-estado
- 80-bootstrap
- gerar-grafo
- 60-notificar
- 70-autoupdate
- 20-config
- 50-avaliar
- build
- 00-cabecalho

## God Nodes (most connected - your core abstractions)
1. `atualiza_agente()` - 8 edges
2. `roda-testes.sh script` - 7 edges
3. `roda_bootstrap()` - 6 edges
4. `principal()` - 6 edges
5. `testa-migracao.sh script` - 6 edges
6. `envia_alerta()` - 5 edges
7. `rodada()` - 5 edges
8. `ok()` - 5 edges
9. `falha()` - 5 edges
10. `main()` - 4 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Import Cycles
- None detected.

## Communities (14 total, 3 thin omitted)

### Community 0 - "roda-testes"
Cohesion: 0.13
Nodes (19): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, AGENTE_SO_CARREGAR, falha(), FIXTURE_DF, FIXTURE_DF_INODES (+11 more)

### Community 1 - "10-util"
Cohesion: 0.13
Nodes (6): agora(), log(), log_erro(), log_info(), pega_trava(), 10-util.sh script

### Community 2 - "30-medir"
Cohesion: 0.22
Nodes (9): campo_meminfo(), ignorar_montagem(), le_cpu_bruto(), mede_cpu(), mede_disco(), mede_memoria(), _saida_df(), _saida_df_inodes() (+1 more)

### Community 3 - "90-main"
Cohesion: 0.26
Nodes (9): autoteste(), avalia_e_notifica(), principal(), registra_heartbeat(), rodada(), 90-main.sh script, sincroniza_config(), status() (+1 more)

### Community 4 - "testa-migracao"
Cohesion: 0.33
Nodes (11): AGENTE_BIN, AGENTE_ESTADO, AGENTE_LOG, AGENTE_RAIZ, falha(), igual(), naotem(), ok() (+3 more)

### Community 5 - "40-estado"
Cohesion: 0.20
Nodes (3): caminho_estado(), le_estado(), 40-estado.sh script

### Community 6 - "80-bootstrap"
Cohesion: 0.31
Nodes (9): escreve_config_inicial(), instala_binarios(), instala_cron(), le_legado(), meu_caminho(), preserva_destinatarios(), roda_bootstrap(), 80-bootstrap.sh script (+1 more)

### Community 7 - "gerar-grafo"
Cohesion: 0.27
Nodes (9): json, Path, pathlib, alvos(), arquivos_do_corpus(), limpa_midia(), main(), Gera o grafo do repositorio em graphify-out/. python scripts/gerar-grafo.py usa… (+1 more)

### Community 8 - "60-notificar"
Cohesion: 0.29
Nodes (6): envia_alerta(), envia_incidente_dashboard(), monta_corpo(), prefixo_assunto(), registra_agregado(), 60-notificar.sh script

### Community 9 - "70-autoupdate"
Cohesion: 0.33
Nodes (8): atualiza_agente(), baixa(), reporta_falha_update(), restaura_rollback(), 70-autoupdate.sh script, sha256_de(), versao_instalada(), versao_maior()

### Community 10 - "20-config"
Cohesion: 0.40
Nodes (3): carrega_config(), 20-config.sh script, valida_config()

## Knowledge Gaps
- **25 isolated node(s):** `build.sh script`, `00-cabecalho.sh script`, `10-util.sh script`, `20-config.sh script`, `30-medir.sh script` (+20 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 72 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What connects `build.sh script`, `00-cabecalho.sh script`, `10-util.sh script` to the rest of the system?**
  _25 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `roda-testes` be split into smaller, more focused modules?**
  _Cohesion score 0.12681159420289856 - nodes in this community are weakly interconnected._
- **Should `10-util` be split into smaller, more focused modules?**
  _Cohesion score 0.13450292397660818 - nodes in this community are weakly interconnected._