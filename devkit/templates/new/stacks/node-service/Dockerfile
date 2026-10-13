# --- Stage 0: build ---
FROM node:22-slim AS build

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

# --- Stage 1: runtime ---
FROM node:22-slim

WORKDIR /app
COPY package.json package-lock.json ./
# Runtime dependencies only; the cache is cleared in the same layer.
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY --from=build /app/dist ./dist

ENV NODE_ENV=production
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/health/ready').then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]

# Release identity, last so a new version never invalidates a cached layer. The build passes
# it once (publish.yml: sha-<7>; Makefile: ci-<7> / gate-<n>); /health/ready reports it.
# devkit/bin/release_check.sh requires all three lines in this final stage.
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
LABEL org.opencontainers.image.version=$APP_VERSION

# node is PID 1, so `docker stop`'s SIGTERM reaches main.ts, which closes the server.
USER node
CMD ["node", "dist/main.js"]
