#!/usr/bin/env bash
# Supprime TOUTES les ressources Quiz App (groupe de ressources entier).
# Usage : ./scripts/destroy.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1
RG="${RG:-rg-quiz-app}"

az group show --name "$RG" -o none 2>/dev/null || { echo "Groupe $RG inexistant, rien à faire."; exit 0; }

echo "Ressources qui seront supprimées :"
az resource list --resource-group "$RG" --query "[].{nom:name, type:type}" -o table

read -r -p "Supprimer définitivement le groupe '$RG' et tout son contenu ? (oui/non) " r
[ "$r" = "oui" ] || { echo "Annulé."; exit 0; }

az group delete --name "$RG" --yes --no-wait
echo "Suppression lancée (az group show -n $RG pour suivre)."