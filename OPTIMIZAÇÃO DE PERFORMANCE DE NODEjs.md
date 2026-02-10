<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# Qual tipo de optimização para melhorar a performance de aplicação de backend em Nodejs com Express e que recebe muitas requisições ao mesmo tempo. Que eu possa ajustar no start dele via npm dentro do Dockerfile?

<Dockerfile>
# ============================================================================
# Node.js + TypeScript Multi-Stage Dockerfile
# Professional production-ready configuration
# ============================================================================

# ============================================================================
# Stage 1: Builder - Install dependencies and compile TypeScript
# ============================================================================
FROM node:20.11.0-alpine AS builder

# Set working directory
WORKDIR /app

# Install build dependencies
RUN apk add --no-cache \\
    git \\
    python3 \\
    make \\
    g++

# Copy package files
COPY package.json package-lock.json* ./

# Install all dependencies (including devDependencies for TypeScript compilation)
RUN npm ci --only=production=false || npm install

# Copy TypeScript configuration
COPY tsconfig.json ./

# Copy source code
COPY src ./src

# Compile TypeScript to JavaScript
# Using tsc directly with flags to allow compilation even with some type errors
# TypeScript will emit files even with type errors (unless --noEmit is used)
# We use || true to ensure the build continues even if tsc returns non-zero exit code
# The tsconfig.json has strict: false to be more lenient with type errors
RUN npx tsc --skipLibCheck || (echo "TypeScript compilation completed with errors, but files were emitted. Continuing..." && true)

# Install only production dependencies
RUN npm ci --only=production && npm cache clean --force

# ============================================================================
# Stage 2: Production - Minimal runtime image
# ============================================================================
FROM node:20.11.0-alpine AS production

# Set environment variables
ENV NODE_ENV=production \\
    PORT=3000 \\
    NODE_OPTIONS="--max-old-space-size=512"

# Install curl for healthcheck
RUN apk add --no-cache curl

# Create application user
# Create group and user without specifying IDs to avoid conflicts
RUN addgroup appuser && \\
    adduser -G appuser -s /bin/sh -D appuser

# Set working directory
WORKDIR /app

# Copy package files from builder
COPY --from=builder --chown=appuser:appuser /app/package.json /app/package-lock.json* ./

# Copy production node_modules from builder
COPY --from=builder --chown=appuser:appuser /app/node_modules ./node_modules

# Copy compiled JavaScript from builder
COPY --from=builder --chown=appuser:appuser /app/dist ./dist

# Copy uploads and data directories if they exist (create if not)
RUN mkdir -p uploads data && \\
    chown -R appuser:appuser uploads data

# ============================================================================
# ✅ CRITICAL: Accept build args and convert to env vars
# All environment variables must be provided at build time or runtime
# Coolify will pass these as environment variables at runtime
# ============================================================================
ARG DOMAIN
ARG DB_HOST
ARG DB_PORT
ARG DB_DATABASE
ARG DB_USERNAME
ARG DB_PASSWORD
ARG REDIS_HOST
ARG REDIS_PORT
ARG REDIS_PASSWORD
ARG JWT_SECRET
ARG JWT_SECRET_OHLA
ARG JWT_EXPIRES_IN
ARG OPENAI_API_KEY
ARG OPENAI_MODEL
ARG DISABLE_AI_VALIDATION
ARG API_WHATSAPP_URL
ARG API_WHATSAPP_TOKEN
ARG API_WHATSAPP_INSTANCE_ID
ARG API_EMAIL_URL
ARG API_EMAIL_TOKEN
ARG PORT
ARG AZURE_STORAGE_ACCOUNT_NAME
ARG AZURE_STORAGE_ACCOUNT_KEY
ARG AZURE_STORAGE_QUEUE_NAME
ARG AZURE_STORAGE_BLOB_CONTAINER_NAME
ARG AZURE_BLOB_SERVICE_URL
ARG COOLIFY_URL
ARG COOLIFY_FQDN
ARG COOLIFY_BRANCH
ARG COOLIFY_RESOURCE_UUID

# Convert ARG to ENV for runtime use
# These can be overridden by environment variables passed at runtime (Coolify)
ENV DOMAIN=$DOMAIN \\
    DB_HOST=$DB_HOST \\
    DB_PORT=$DB_PORT \\
    DB_DATABASE=$DB_DATABASE \\
    DB_USERNAME=$DB_USERNAME \\
    DB_PASSWORD=$DB_PASSWORD \\
    REDIS_HOST=$REDIS_HOST \\
    REDIS_PORT=$REDIS_PORT \\
    REDIS_PASSWORD=$REDIS_PASSWORD \\
    JWT_SECRET=$JWT_SECRET \\
    JWT_SECRET_OHLA=$JWT_SECRET_OHLA \\
    JWT_EXPIRES_IN=$JWT_EXPIRES_IN \\
    OPENAI_API_KEY=$OPENAI_API_KEY \\
    OPENAI_MODEL=$OPENAI_MODEL \\
    DISABLE_AI_VALIDATION=$DISABLE_AI_VALIDATION \\
    API_WHATSAPP_URL=$API_WHATSAPP_URL \\
    API_WHATSAPP_TOKEN=$API_WHATSAPP_TOKEN \\
    API_WHATSAPP_INSTANCE_ID=$API_WHATSAPP_INSTANCE_ID \\
    API_EMAIL_URL=$API_EMAIL_URL \\
    API_EMAIL_TOKEN=$API_EMAIL_TOKEN \\
    PORT=${PORT:-3000} \\
    AZURE_STORAGE_ACCOUNT_NAME=$AZURE_STORAGE_ACCOUNT_NAME \\
    AZURE_STORAGE_ACCOUNT_KEY=$AZURE_STORAGE_ACCOUNT_KEY \\
    AZURE_STORAGE_QUEUE_NAME=$AZURE_STORAGE_QUEUE_NAME \\
    AZURE_STORAGE_BLOB_CONTAINER_NAME=$AZURE_STORAGE_BLOB_CONTAINER_NAME \\
    AZURE_BLOB_SERVICE_URL=$AZURE_BLOB_SERVICE_URL \\
    COOLIFY_URL=$COOLIFY_URL \\
    COOLIFY_FQDN=$COOLIFY_FQDN \\
    COOLIFY_BRANCH=$COOLIFY_BRANCH \\
    COOLIFY_RESOURCE_UUID=$COOLIFY_RESOURCE_UUID

# Switch to non-root user
USER appuser

# Expose port
EXPOSE ${PORT:-3000}

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \\
    CMD curl -f http://localhost:${PORT:-3000}/ || exit 1

# Start the application
# Using node directly to run the compiled JavaScript
CMD ["node", "dist/index.js"]

</Dockerfile>
Para otimizar uma app Node.js/Express com alta concorrência diretamente no start via `npm` no Dockerfile, use PM2 (process manager com cluster mode) ou flags `NODE_OPTIONS` avançadas — isso escala para múltiplos cores sem código extra.[^1][^2]

## PM2 Cluster (Recomendado)

Instale PM2 como devDep no `package.json` (`npm i -D pm2`), adicione script `"start:prod": "pm2-runtime start ecosystem.config.js"`.

Crie `ecosystem.config.js` na raiz:

```js
module.exports = {
  apps: [{
    name: 'app',
    script: 'dist/index.js',
    instances: 'max',  // Ou '4' (número de cores)
    exec_mode: 'cluster',
    env: { NODE_ENV: 'production' }
  }]
};
```

No Dockerfile (stage production), mude CMD para:

```dockerfile
# Após COPY, adicione:
RUN npm install pm2@latest -g --unsafe-perm  # Como user appuser, ou no builder

USER root  # Temporário
RUN npm install -g pm2
USER appuser

CMD ["npm", "run", "start:prod"]
```

Isso roda múltiplas instâncias (uma por core), balanceando load via round-robin, lidando com restarts zero-downtime. Ganho: 3-5x throughput em multi-core.[^2][^3][^1]

## NODE_OPTIONS Avançadas

Expanda no Dockerfile:

```dockerfile
ENV NODE_OPTIONS="--max-old-space-size=1024 --max-semi-space-size=128 --experimental-worker --optimize-for-size"
```

- `--max-old-space-size`: Heap até 1GB (ajuste por container RAM).
- `--experimental-worker`: Worker threads para CPU-bound (embeddings/AI).
- Outros: `--abort-on-uncaught-exception` para estabilidade.

Para cluster nativo, adicione script `"start:cluster": "node -r cluster dist/index.js"` com código cluster no `index.js` (master fork workers).[^4]

## Comparação de Otimizações no Start

| Método | CMD no Dockerfile | Benefício Principal | Concorrência Esperada |
| :-- | :-- | :-- | :-- |
| PM2 Cluster | `["npm", "run", "start:prod"]` | Multi-instâncias auto, restarts | 1000+ req/s multi-core [^2] |
| NODE_OPTIONS | Já tem, expanda ENV | Heap/GC tuning, workers | 2-3x mem efficiency |
| Cluster Nativo | `["npm", "run", "start:cluster"]` | Leve, sem deps extras | Similar PM2, manual [^5] |

## Dicas Extras sem Mudar Start

- Redis para cache/sessões (já tem vars).
- Rate limiting: `express-rate-limit`.
- Monitore com `pm2 monit` ou Prometheus.

Teste com `wrk -t12 -c400 -d30s http://localhost:3000`. PM2 é o mais simples para produção Docker/Coolify.[^6][^7]
<span style="display:none">[^10][^11][^12][^13][^14][^15][^8][^9]</span>

<div align="center">⁂</div>

[^1]: https://expressjs.com/en/advanced/best-practice-performance.html

[^2]: https://blogs.halodoc.io/nodejs-clustering-using-pm2/

[^3]: https://stackoverflow.com/questions/45590348/pm2-cluster-mode-vs-node-cluster-performance/45590817

[^4]: https://stackoverflow.com/questions/66207752/a-better-way-to-manage-nodejs-configuration-flags

[^5]: https://engineering.zalando.com/posts/2024/07/nodejs-tale-worker-threads.html

[^6]: https://www.codingeasypeasy.com/blog/optimizing-expressjs-for-high-concurrency-a-comprehensive-guide

[^7]: https://noobtools.dev/blog/optimizing-nodejs-for-high-concurrency-a-comprehensive-guide-to-scaling-your-app

[^8]: https://stackoverflow.com/questions/45126321/how-exactly-does-nodejs-handle-high-concurrent-requests

[^9]: https://github.com/orgs/community/discussions/157082

[^10]: https://dev.to/evle/practical-concurrent-control-for-nodejs-servers-keep-your-server-from-being-overwhelmed-by-2kgf

[^11]: https://github.com/nodejs/help/issues/2564

[^12]: https://stackoverflow.com/questions/40598556/tune-nodejs-expressjs-to-handle-many-concurrent-requests

[^13]: https://stackoverflow.com/questions/61328960/when-is-better-using-clustering-or-worker-threads

[^14]: https://github.com/coderhammer/express-concurrent

[^15]: https://www.reddit.com/r/javascript/comments/7zzv1j/express_cant_handle_more_than_1100_requests_per/

