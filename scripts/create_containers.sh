
#!/usr/bin/env bash
# Déploiement Quiz App sur Azure Container Apps
# Usage : ACR_NAME=<nom-acr> ./scripts/deploy.sh
set -euo pipefail

export MSYS_NO_PATHCONV=1

# ---------- PARAMÈTRES ----------
RG="${RG:-rg-quiz-app}"
LOCATION="${LOCATION:-switzerlandnorth}"
ACR_NAME="${ACR_NAME:?ACR_NAME requis}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"

ENV_NAME="${ENV_NAME:-env-quiz-app}"

FRONT_APP="quiz-frontend"
BACK_APP="quiz-backend"

FRONT_IMAGE="quiz-frontend:$TAG"
BACK_IMAGE="quiz-backend:$TAG"

FRONT_PORT="${FRONT_PORT:-80}"
BACK_PORT=3007

echo "===================================="
echo " DEPLOIEMENT QUIZ APP"
echo "===================================="

# ---------- 1. AZURE ----------
echo "==> Vérification Azure"

az account show -o table

for p in Microsoft.App Microsoft.OperationalInsights Microsoft.ContainerRegistry; do
    az provider register --namespace "$p" --wait
done

# ---------- 2. RESOURCE GROUP ----------
echo "==> Resource Group"

az group create \
    --name "$RG" \
    --location "$LOCATION" \
    -o none

# ---------- 3. ACR ----------
echo "==> Récupération ACR"

ACR_SERVER=$(az acr show \
    --name "$ACR_NAME" \
    --query loginServer -o tsv)

echo "ACR : $ACR_SERVER"

# Vérification des images
az acr repository show \
    --name "$ACR_NAME" \
    --image "$BACK_IMAGE" >/dev/null

az acr repository show \
    --name "$ACR_NAME" \
    --image "$FRONT_IMAGE" >/dev/null

# ---------- 4. ENVIRONNEMENT ----------
echo "==> Création environnement Container Apps"

if ! az containerapp env show \
    --name "$ENV_NAME" \
    --resource-group "$RG" >/dev/null 2>&1; then

    az containerapp env create \
        --name "$ENV_NAME" \
        --resource-group "$RG" \
        --location "$LOCATION"
fi

# ---------- 5. AUTHENTIFICATION ACR ----------
echo "==> Configuration accès ACR"

az containerapp registry set \
    --name "$BACK_APP" \
    --resource-group "$RG" \
    --server "$ACR_SERVER" \
    --identity system

echo "NOTE : pour une première création, utiliser une identité managée avec AcrPull."

# ---------- 6. BACKEND ----------
echo "==> Déploiement backend"

az containerapp create \
    --name "$BACK_APP" \
    --resource-group "$RG" \
    --environment "$ENV_NAME" \
    --image "$ACR_SERVER/$BACK_IMAGE" \
    --registry-server "$ACR_SERVER" \
    --target-port "$BACK_PORT" \
    --ingress internal \
    --min-replicas 1 \
    --max-replicas 2

# ---------- 7. URL BACKEND ----------
BACKEND_FQDN=$(az containerapp show \
    --name "$BACK_APP" \
    --resource-group "$RG" \
    --query properties.configuration.ingress.fqdn -o tsv)

BACKEND_URL="http://$BACKEND_FQDN"

echo "Backend : $BACKEND_URL"

# ---------- 8. FRONTEND ----------
echo "==> Déploiement frontend"

az containerapp create \
    --name "$FRONT_APP" \
    --resource-group "$RG" \
    --environment "$ENV_NAME" \
    --image "$ACR_SERVER/$FRONT_IMAGE" \
    --registry-server "$ACR_SERVER" \
    --target-port "$FRONT_PORT" \
    --ingress external \
    --min-replicas 1 \
    --max-replicas 2 \
    --env-vars "BACKEND_URL=$BACKEND_URL"

# ---------- 9. URL FRONTEND ----------
FRONTEND_FQDN=$(az containerapp show \
    --name "$FRONT_APP" \
    --resource-group "$RG" \
    --query properties.configuration.ingress.fqdn -o tsv)

echo "Frontend : https://$FRONTEND_FQDN"

# ---------- 10. ÉTAT DES APPLICATIONS ----------
echo "==> Applications"

az containerapp list \
    --resource-group "$RG" \
    -o table

# ---------- 11. RÉVISIONS ----------
echo "==> Révisions backend"

az containerapp revision list \
    --name "$BACK_APP" \
    --resource-group "$RG" \
    -o table

echo "==> Révisions frontend"

az containerapp revision list \
    --name "$FRONT_APP" \
    --resource-group "$RG" \
    -o table

# ---------- 12. RÉPLICAS ----------
echo "==> Réplicas backend"

az containerapp replica list \
    --name "$BACK_APP" \
    --resource-group "$RG" \
    -o table

# ---------- 13. TEST FRONTEND ----------
echo "==> Test HTTP frontend"

curl -I --max-time 20 "https://$FRONTEND_FQDN" || true

# ---------- 14. TEST HEALTH BACKEND ----------
echo "==> Configuration test backend"

echo "Backend URL : $BACKEND_URL/health"
echo "Ingress interne : test à effectuer depuis le réseau Container Apps."

# ---------- 15. DIAGNOSTIC ----------
echo ""
echo "Commandes de diagnostic :"

echo "Logs backend :"
echo "az containerapp logs show -n $BACK_APP -g $RG --type console --follow"

echo ""
echo "État backend :"
echo "az containerapp show -n $BACK_APP -g $RG --query properties.runningStatus"

echo ""
echo "===================================="
echo " DEPLOIEMENT TERMINE"
echo "===================================="

echo "Frontend : https://$FRONTEND_FQDN"
echo "Backend  : $BACKEND_URL"
echo "ACR      : $ACR_SERVER"
echo "Tag      : $TAG"
