#!/usr/bin/env bash
# Déploiement Quiz App sur Azure — J3 : groupe de ressources, ACR, images
# Prérequis : Azure CLI connecté (az login), Docker démarré, lancé depuis la racine du dépôt.
# Usage    : ACR_NAME=<nom-unique> ./scripts/deploy.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash (Windows) : ne pas transformer les chemins /subscriptions/...

# ---------- Paramètres (surchargeables par variables d'environnement) ----------
RG="${RG:-rg-quiz-app}"
LOCATION="${LOCATION:-switzerlandnorth}"     # région autorisée par l'abonnement Azure for Students
ACR_NAME="${ACR_NAME:?ACR_NAME requis : nom unique, 5-50 caractères, minuscules et chiffres}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"   # tag = commit Git -> traçabilité

echo "==> Abonnement utilisé"
az account show --query "{abonnement:name, etat:state}" -o table

echo "==> Enregistrement des fournisseurs Azure"
for p in Microsoft.ContainerRegistry Microsoft.App Microsoft.OperationalInsights; do
  az provider register --namespace "$p" --wait
done

echo "==> Groupe de ressources $RG ($LOCATION)"
az group create --name "$RG" --location "$LOCATION" -o none

echo "==> Registre ACR $ACR_NAME"
if ! az acr show --name "$ACR_NAME" --resource-group "$RG" -o none 2>/dev/null; then
  az acr create --name "$ACR_NAME" --resource-group "$RG" --sku Basic -o none
fi
ACR_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)

echo "==> Build et push des images (tag : $TAG)"
az acr login --name "$ACR_NAME"
docker build --platform linux/amd64 -t "$ACR_SERVER/quiz-backend:$TAG"  ./backend
docker build --platform linux/amd64 -t "$ACR_SERVER/quiz-frontend:$TAG" .
docker push "$ACR_SERVER/quiz-backend:$TAG"
docker push "$ACR_SERVER/quiz-frontend:$TAG"

echo "==> Images présentes dans $ACR_SERVER"
for repo in quiz-backend quiz-frontend; do
  az acr repository show-tags --name "$ACR_NAME" --repository "$repo" -o table
done