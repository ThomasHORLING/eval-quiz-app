# ---------- Étape 1 : build ----------
FROM node:24-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# ---------- Étape 2 : exécution ----------
FROM nginx:alpine
RUN apk upgrade --no-cache

ENV BACKEND_UPSTREAM=backend:3007
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80