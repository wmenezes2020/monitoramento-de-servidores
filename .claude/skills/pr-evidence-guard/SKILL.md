---
name: pr-evidence-guard
description: >
  Regra de OURO para PRs passarem no validador automático (o validador interno /
  agente sentinela) — todos os repos. Use SEMPRE ao abrir ou atualizar um
  Pull Request, ou no fim de turno com mudanças versionáveis. Obriga
  EVIDÊNCIA no corpo do PR (resumo do diff/arquivos, saída real de build +
  typecheck + testes, idempotência de migration) e uma AUTORREVISÃO de
  segurança/higiene (SSRF/timeouts/retry, sem PII/segredos em log,
  isolamento multi-tenant por companyId, deps com advisories, lint
  read-only, engines.node). Complementa dual-pr-guard e sdd-e-entrega.
  Auto-dispara em PR, push, deploy, merge ou conclusão de tarefa.
---

# pr-evidence-guard — PR pronto para o validador (sentinela)

Complementa `dual-pr-guard` (abre PR p/ staging+main) e `sdd-e-entrega`
(SDD + commit/push). Esta skill garante que o PR **carregue a evidência**
que o validador automático exige e **pré-resolva** os achados recorrentes.

## Por que existe

O validador (o validador interno · agente *sentinela*) reprova/condiciona PRs por
DOIS motivos distintos — trate cada um certo:

1. **Falta de EVIDÊNCIA** ("diff não fornecido", "log de `npm run build`/
   `npm test` não fornecido", "sem código não dá pra validar SSRF").
   → NÃO é bug: é o corpo do PR sem prova. Resolve-se ANEXANDO a evidência.
2. **Achado REAL** (package.json/deps/segurança/CI). → Corrija de fato.

## Bloco obrigatório no corpo do PR

Todo PR DEVE conter, além do problema/solução:

### Arquivos alterados (resumo do diff)
- Liste os arquivos tocados agrupados por área + 1 linha do que mudou.
- Aponte migrations, novos endpoints, e qualquer chamada HTTP externa.

### Validação (saída REAL, não "deve passar")
- Back: cole o resultado de `npm run build` (NestJS) — verde.
- Front: `npx tsc --noEmit` E `npm run build` (Next) — verdes.
- Testes: `npm test` quando houver suíte que cubra o caminho alterado
  (ex.: fallback/branch novo). Se não houver teste, diga explicitamente
  o que foi validado manualmente e por quê.
- Migration: confirme idempotência (checa coluna/tabela antes de alterar).

## Autorrevisão de segurança (quando o diff toca rede/integração/multi-tenant)

Responda no PR, item a item — é o que o sentinela pede em "SECURITY":

- **SSRF**: as URLs de saída são FIXAS/allowlist (Google, Gemini, gateway),
  nunca montadas a partir de entrada do usuário? Se host/URL vier de input,
  validar contra allowlist.
- **Timeout + retry**: toda chamada externa tem `timeout` e cap de
  tentativas (sem retry infinito).
- **Logs sem PII/segredo**: não logar token, chave, credencial nem dado
  pessoal sensível. Endereço/telefone de negócio: minimizar.
- **Isolamento multi-tenant**: queries/ações escopadas por `companyId`
  quando aplicável; job de plataforma não vaza dado entre empresas.
- **Dependências novas**: rodar/observar `npm audit`/OSV; não introduzir
  pacote com advisory aberto.

## Higiene de repo (pré-resolve achados recorrentes do validador)

- **Lint read-only na validação**: o script usado em CI/validação NÃO pode
  ter `--fix` (muta código durante a checagem). Mantenha:
  `"lint:check": "eslint ... "` (sem fix) para validar e
  `"lint:fix": "eslint ... --fix"` para corrigir local. Nunca validar com
  `--fix`.
- **`engines.node`**: declare no `package.json` raiz a faixa de Node
  suportada pelo runtime (NestJS/TS) — evita build em Node incompatível.
- **Dependência com advisory conhecido**: substituir por versão segura,
  **mantendo a dependência VISÍVEL aos scanners** (Dependabot/OSV). ⚠️
  Tarball por URL (`https://.../x.tgz`) some do `npm audit`/Dependabot —
  fica "limpo" porque ficou INVISÍVEL, não auditado. Prefira um pacote do
  REGISTRO. Ex. resolvido neste repo: `xlsx` saiu do `^0.18.5` (npm, CVEs)
  para o fork mantido do registro via alias
  `"xlsx": "npm:@e965/xlsx@^0.20.3"` — mantém `require('xlsx')`, é
  escaneável (Dependabot vê o pacote+versão) e traz as correções do SheetJS
  0.20.x. Registre no PR a versão instalada + `npm audit`.

## Bloco de evidência (COLE no corpo OU em comentário do PR)

O validador (sentinela) exige o transcript real da validação. Preencha e
cole este bloco — é o que faz os achados de "não fornecido" sumirem:

```
### Ambiente
- node: <versão>   | npm ci/install: ok
- eslint: <versão> | tsc: <versão> | jest: <versão>

### Validação (saídas reais — não "deve passar")
- npm run build .......... <verde | erro>
- npx tsc --noEmit ....... <verde | erro>   (front/quando aplicável)
- npm run lint:check ..... <verde | N warnings>
- npm test ............... <X/N passou | "sem suíte que cubra X; validado
                            manualmente: ..." com justificativa>

### Segurança / dependências (OSV)
- npm audit (deps do diff): <pacotes afetados + DECISÃO tomada>
- Integração/HTTP/multi-tenant tocado? SSRF(URL fixa?) · timeout · retry cap
  · sem PII/segredo em log · escopo por companyId
```

## Checklist antes de abrir/atualizar o PR

- [ ] Corpo tem "Arquivos alterados" + o que cada grupo faz?
- [ ] Colei a saída REAL de build + typecheck (+ teste quando cabe)?
- [ ] Migration idempotente confirmada?
- [ ] Toca rede/integração? Respondi SSRF/timeout/retry/PII/companyId?
- [ ] Dep nova sem advisory aberto (audit/OSV)?
- [ ] Lint de validação é read-only (sem `--fix`)? `engines.node` declarado?

## Anti-padrões

- "Build deve passar" / "validei" sem colar a saída.
- PR sem lista de arquivos/diff — o validador reprova por falta de contexto.
- Validar com `eslint --fix` (esconde problemas mutando o código).
- Introduzir/seguir com dependência vulnerável sem registrar a mitigação.

> Resumo: o PR é uma PROVA. Anexe diff + logs de build/teste + autorrevisão
> de segurança e higiene. O que o validador chama de "não fornecido" é
> evidência faltando; o que ele aponta em package.json/deps é para corrigir.
