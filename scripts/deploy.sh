#!/usr/bin/env bash
# Déploiement Quiz App sur Azure
#   J3 : groupe de ressources, ACR, build/push des images
#   J4 : environnement Container Apps (WorkloadProfiles), backend (ingress interne), frontend (ingress externe)
# Prérequis : az login (MFA), Docker démarré, lancé depuis la racine du dépôt (Git Bash sous Windows).
# Secrets   : fournis par variables d'environnement : set -a; source .env.azure; set +a
# Usage     : ./scripts/deploy.sh
#             SKIP_BUILD=true TAG=<tag> ./scripts/deploy.sh   (réutiliser des images déjà dans ACR)
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash (Windows) : ne pas transformer les chemins /subscriptions/...

# ---------- Paramètres ----------
RG="${RG:-rg-quiz-app}"
LOCATION="${LOCATION:-switzerlandnorth}"      # région autorisée par l'abonnement Azure for Students
ACR_NAME="${ACR_NAME:?ACR_NAME requis : nom unique, minuscules et chiffres}"
ENV_NAME="${ENV_NAME:-cae-quiz-app}"
BACKEND_APP="${BACKEND_APP:-quiz-backend}"
FRONTEND_APP="${FRONTEND_APP:-quiz-frontend}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"   # tag = commit Git -> traçabilité
SKIP_BUILD="${SKIP_BUILD:-false}"             # true : images déjà construites et poussées (ex. CI)

# ---------- Secrets (jamais écrits dans le dépôt) ----------
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD requis}"
: "${JWT_SECRET:?JWT_SECRET requis}"
: "${RESEND_API_KEY:?RESEND_API_KEY requis (valeur factice acceptée)}"

echo "==> Abonnement utilisé"
az account show --query "{abonnement:name, etat:state}" -o table

echo "==> Fournisseurs Azure et extension containerapp"
for p in Microsoft.ContainerRegistry Microsoft.App Microsoft.OperationalInsights; do
  az provider register --namespace "$p" --wait
done
az extension add --name containerapp --upgrade -o none

echo "==> Groupe de ressources $RG ($LOCATION)"
az group create --name "$RG" --location "$LOCATION" -o none

# ================= J3 : registre et images =================
echo "==> Registre ACR $ACR_NAME"
if ! az acr show --name "$ACR_NAME" --resource-group "$RG" -o none 2>/dev/null; then
  az acr create --name "$ACR_NAME" --resource-group "$RG" --sku Basic -o none
fi
ACR_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
BACKEND_IMAGE="$ACR_SERVER/quiz-backend:$TAG"
FRONTEND_IMAGE="$ACR_SERVER/quiz-frontend:$TAG"

if [ "$SKIP_BUILD" != "true" ]; then
  echo "==> Build et push des images (tag : $TAG)"
  az acr login --name "$ACR_NAME"
  docker build --platform linux/amd64 -t "$BACKEND_IMAGE"  ./backend
  docker build --platform linux/amd64 -t "$FRONTEND_IMAGE" .
  docker push "$BACKEND_IMAGE"
  docker push "$FRONTEND_IMAGE"
else
  echo "==> SKIP_BUILD=true : utilisation des images existantes (tag : $TAG)"
  az acr repository show --name "$ACR_NAME" --image "quiz-backend:$TAG"  -o none
  az acr repository show --name "$ACR_NAME" --image "quiz-frontend:$TAG" -o none
fi

# ================= J4 : Azure Container Apps =================
# Mode WorkloadProfiles imposé : le mode "express" (préversion) ne permet ni la découverte
# de services entre applications (http://quiz-backend) ni l'identité managée système pour ACR.
echo "==> Environnement Container Apps $ENV_NAME (mode WorkloadProfiles)"
if ! az containerapp env show --name "$ENV_NAME" --resource-group "$RG" -o none 2>/dev/null; then
  az containerapp env create --name "$ENV_NAME" --resource-group "$RG" --location "$LOCATION" \
    --environment-mode WorkloadProfiles \
    --logs-destination log-analytics -o none
fi

# Secrets Container Apps + variables qui y font référence (secretref:)
SECRETS=(
  "resend-api-key=$RESEND_API_KEY"
  "admin-password=$ADMIN_PASSWORD"
  "jwt-secret=$JWT_SECRET"
)
BACKEND_ENV=(
  "RESEND_API_KEY=secretref:resend-api-key"
  "ADMIN_PASSWORD=secretref:admin-password"
  "JWT_SECRET=secretref:jwt-secret"
  "ADMIN_USERNAME=${ADMIN_USERNAME:-admin}"
  "FROM_EMAIL=${FROM_EMAIL:-Quiz App <noreply@example.com>}"
)
if [ -n "${DATABASE_URL:-}" ]; then           # J5 : base Neon
  SECRETS+=("database-url=$DATABASE_URL")
  BACKEND_ENV+=("DATABASE_URL=secretref:database-url")
fi

echo "==> Backend $BACKEND_APP (ingress interne, port 3007)"
if ! az containerapp show --name "$BACKEND_APP" --resource-group "$RG" -o none 2>/dev/null; then
  az containerapp create --name "$BACKEND_APP" --resource-group "$RG" \
    --environment "$ENV_NAME" --workload-profile-name Consumption \
    --image "$BACKEND_IMAGE" \
    --registry-server "$ACR_SERVER" --registry-identity system \
    --ingress internal --target-port 3007 \
    --cpu 0.25 --memory 0.5Gi --min-replicas 0 --max-replicas 1 \
    --secrets "${SECRETS[@]}" --env-vars "${BACKEND_ENV[@]}" -o none
else
  az containerapp secret set --name "$BACKEND_APP" --resource-group "$RG" --secrets "${SECRETS[@]}" -o none
  az containerapp update --name "$BACKEND_APP" --resource-group "$RG" \
    --image "$BACKEND_IMAGE" --set-env-vars "${BACKEND_ENV[@]}" -o none
fi
# Appels HTTP internes (Nginx -> backend) sans redirection HTTPS ; l'ingress reste interne
az containerapp ingress update --name "$BACKEND_APP" --resource-group "$RG" --allow-insecure -o none

echo "==> Frontend $FRONTEND_APP (ingress externe, port 80)"
if ! az containerapp show --name "$FRONTEND_APP" --resource-group "$RG" -o none 2>/dev/null; then
  az containerapp create --name "$FRONTEND_APP" --resource-group "$RG" \
    --environment "$ENV_NAME" --workload-profile-name Consumption \
    --image "$FRONTEND_IMAGE" \
    --registry-server "$ACR_SERVER" --registry-identity system \
    --ingress external --target-port 80 \
    --cpu 0.25 --memory 0.5Gi --min-replicas 0 --max-replicas 1 \
    --env-vars "BACKEND_UPSTREAM=$BACKEND_APP" -o none
else
  az containerapp update --name "$FRONTEND_APP" --resource-group "$RG" \
    --image "$FRONTEND_IMAGE" --set-env-vars "BACKEND_UPSTREAM=$BACKEND_APP" -o none
fi

# ================= Résumé =================
FQDN=$(az containerapp show --name "$FRONTEND_APP" --resource-group "$RG" --query properties.configuration.ingress.fqdn -o tsv)
for app in "$BACKEND_APP" "$FRONTEND_APP"; do
  echo "==> Révisions de $app"
  az containerapp revision list --name "$app" --resource-group "$RG" \
    --query "[].{revision:name, actif:properties.active, sante:properties.healthState, image:properties.template.containers[0].image}" -o table
done
echo
echo "Frontend : https://$FQDN"
echo "Test     : curl -i https://$FQDN/health"