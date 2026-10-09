#!/usr/bin/env python3
"""Gera o grafo do repositorio em graphify-out/.

    python scripts/gerar-grafo.py            usa o alvo gravado, ou o padrao
    python scripts/gerar-grafo.py src tests  escaneia so o que for passado

Entrega sempre os tres artefatos: graph.json, GRAPH_REPORT.md e graph.html.
O HTML e o mapa que se abre no navegador, e ja foi esquecido antes por um
script que parava no JSON.

Pontos que custaram tempo e ficam registrados aqui:

* `cache_root` e a raiz do REPOSITORIO, nao a pasta escaneada, e vale para o
  `detect()` E para o `extract()`. Passar so num dos dois cria um segundo
  graphify-out/ dentro da pasta escaneada, e aí o repositorio fica com dois,
  contra a regra de um por repositorio.
* No Windows, `extract()` usa processos em paralelo. Sem o
  `if __name__ == '__main__'` cada filho reexecuta o script inteiro, a saida
  sai embaralhada e o pool quebra com BrokenProcessPool.
* Imagem, video, PDF e documento saem do corpus. Descreve-los exige visao, que
  gasta token e chave de API. Sem eles a passagem fica puramente AST: local,
  deterministica e de graca.
* `to_json` tem trava contra encolher o grafo: devolve False e nao escreve
  nada quando o grafo novo tem menos nos que o graph.json existente. Aqui o
  encolhimento e tratado como aviso, nao como erro, porque arquivo removido de
  proposito e normal neste repositorio.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
SAIDA = RAIZ / "graphify-out"
ALVO_GRAVADO = SAIDA / ".graphify_alvo"

# Este repositorio e um agente de shell: a fonte fica em src/ e os artefatos
# gerados ficam na raiz. Escanear a raiz inteira duplicaria cada modulo, uma
# vez na fonte e outra dentro do bundle concatenado.
ALVOS_PADRAO = ["src", "scripts", "tests"]


def alvos() -> list[str]:
    if len(sys.argv) > 1:
        return sys.argv[1:]
    if ALVO_GRAVADO.exists():
        guardado = [
            linha.strip()
            for linha in ALVO_GRAVADO.read_text(encoding="utf-8").splitlines()
            if linha.strip() and not linha.startswith("#")
        ]
        if guardado:
            return guardado
    return ALVOS_PADRAO


# Categorias que vao para o corpus. As de midia ficam de fora: descrever
# imagem e video exige visao, que custa token e chave de API, enquanto o resto
# e passagem AST pura, local e de graca.
CATEGORIAS_UTEIS = ("code", "text", "data", "config", "notebook", "markup")
CATEGORIAS_MIDIA = ("image", "video", "paper", "document", "office", "audio")


def limpa_midia(deteccao: dict) -> dict:
    arquivos = deteccao.get("files")
    if isinstance(arquivos, dict):
        for categoria in CATEGORIAS_MIDIA:
            if categoria in arquivos:
                arquivos[categoria] = []
    return deteccao


def arquivos_do_corpus(deteccao: dict) -> list[Path]:
    arquivos = deteccao.get("files")
    if not isinstance(arquivos, dict):
        return []
    saida: list[Path] = []
    for categoria in CATEGORIAS_UTEIS:
        for caminho in arquivos.get(categoria, []) or []:
            saida.append(Path(caminho))
    return saida


def main() -> int:
    from graphify.detect import detect
    from graphify.extract import extract
    from graphify.build import build_from_json
    from graphify.cluster import cluster, score_all
    from graphify.analyze import god_nodes, surprising_connections, suggest_questions
    from graphify.report import generate
    from graphify.export import to_json, to_html

    escolhidos = [a for a in alvos() if (RAIZ / a).exists()]
    if not escolhidos:
        print("nenhum alvo encontrado; nada a fazer", file=sys.stderr)
        return 1

    SAIDA.mkdir(parents=True, exist_ok=True)
    ALVO_GRAVADO.write_text("\n".join(escolhidos) + "\n", encoding="utf-8")
    print(f"escaneando: {', '.join(escolhidos)}")

    deteccao: dict = {"files": {}}
    arquivos: list[Path] = []
    for alvo in escolhidos:
        # cache_root = RAIZ nos dois lugares, sempre.
        parcial = limpa_midia(detect(RAIZ / alvo, cache_root=RAIZ))
        arquivos.extend(arquivos_do_corpus(parcial))
        for chave, valor in parcial.items():
            if chave == "files" and isinstance(valor, dict):
                for categoria, lista in valor.items():
                    deteccao["files"].setdefault(categoria, []).extend(lista or [])
            elif isinstance(valor, list):
                deteccao.setdefault(chave, []).extend(valor)
            elif isinstance(valor, (int, float)) and isinstance(deteccao.get(chave), (int, float)):
                deteccao[chave] += valor
            else:
                deteccao.setdefault(chave, valor)

    arquivos = sorted({p for p in arquivos if p.exists()})
    if not arquivos:
        print("detect nao devolveu arquivo de codigo ou texto", file=sys.stderr)
        return 1
    print(f"  {len(arquivos)} arquivo(s) no corpus")

    extracao = extract(arquivos, cache_root=RAIZ, root=RAIZ)

    G = build_from_json(extracao, root=str(RAIZ), directed=True)
    if G.number_of_nodes() == 0:
        print("grafo vazio: a extracao nao produziu no nenhum", file=sys.stderr)
        return 1

    comunidades = cluster(G)
    coesao = score_all(G, comunidades)
    gods = god_nodes(G)
    surpresas = surprising_connections(G, comunidades)

    # Comunidade sem nome nao entra util no mapa. O nome sai do arquivo de
    # origem mais comum do grupo; no sem arquivo (pacote importado) e ignorado,
    # porque contar o vazio deixava metade dos grupos com "?".
    rotulos: dict = {}
    for cid, membros in comunidades.items():
        origens: dict[str, int] = {}
        for no in membros:
            arq = G.nodes.get(no, {}).get("source_file") or G.nodes.get(no, {}).get("file")
            if not arq:
                continue
            nome = Path(str(arq)).stem
            origens[nome] = origens.get(nome, 0) + 1
        if origens:
            rotulos[cid] = max(origens, key=lambda k: origens[k])
        else:
            mais_ligado = max(membros, key=lambda n: G.degree(n), default=None)
            rotulos[cid] = str(mais_ligado) if mais_ligado else f"grupo {cid}"

    perguntas = suggest_questions(G, comunidades, rotulos)
    tokens = {
        "input": extracao.get("input_tokens", 0),
        "output": extracao.get("output_tokens", 0),
    }

    escreveu = to_json(G, comunidades, str(SAIDA / "graph.json"))
    if not escreveu:
        print(
            "aviso: to_json recusou encolher o graph.json existente; "
            "refazendo com force porque a reducao e esperada aqui",
            file=sys.stderr,
        )
        escreveu = to_json(G, comunidades, str(SAIDA / "graph.json"), force=True)
    if not escreveu:
        print("nao consegui escrever graph.json", file=sys.stderr)
        return 1

    relatorio = generate(
        G, comunidades, coesao, rotulos, gods, surpresas, deteccao, tokens,
        str(RAIZ), suggested_questions=perguntas,
    )
    (SAIDA / "GRAPH_REPORT.md").write_text(relatorio, encoding="utf-8")

    # Passo que ja foi esquecido: to_json NAO gera o HTML.
    to_html(G, comunidades, str(SAIDA / "graph.html"), community_labels=rotulos)

    (SAIDA / ".graphify_analysis.json").write_text(
        json.dumps(
            {
                "communities": {str(k): v for k, v in comunidades.items()},
                "cohesion": {str(k): v for k, v in coesao.items()},
                "gods": gods,
                "surprises": surpresas,
                "questions": perguntas,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    faltou = False
    for nome in ("graph.json", "GRAPH_REPORT.md", "graph.html"):
        existe = (SAIDA / nome).exists()
        faltou = faltou or not existe
        print(f"  {'ok' if existe else 'FALTOU':7} graphify-out/{nome}")

    print(
        f"grafo: {G.number_of_nodes()} nos, {G.number_of_edges()} arestas, "
        f"{len(comunidades)} comunidades"
    )
    return 1 if faltou else 0


if __name__ == "__main__":
    raise SystemExit(main())
