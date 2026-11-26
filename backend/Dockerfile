# ---------- Étape 1 : installation des dépendances ----------
FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---------- Étape 2 : exécution ----------
FROM node:24-alpine
ENV NODE_ENV=production

# Correctifs Alpine (OpenSSL, zlib) + suppression des gestionnaires de paquets inutiles à l'exécution
RUN apk upgrade --no-cache \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
           /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json server.js ./

USER node
EXPOSE 3007
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3007/health || exit 1
CMD ["node", "server.js"]