FROM node:24-alpine

ENV NODE_ENV=production
WORKDIR /app

#Dépendances d'abord : cette couche reste en cache tant que package*.json ne change pas
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

#Puis le code
COPY server.js ./

#On n'exécute pas en root
USER node

EXPOSE 3007

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3007/health || exit 1

CMD ["node", "server.js"]