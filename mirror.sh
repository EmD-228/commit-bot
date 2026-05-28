#!/usr/bin/env bash
#
# Mirror Bot
#
# Récupère le nombre de commits faits aujourd'hui par ton compte GitHub pro,
# et génère le même nombre de commits sur ce repo perso.
#
# NE LIT JAMAIS le contenu de tes commits pro — uniquement le compteur total.
#
# Configuration : copier .env.example en .env et remplir les variables.
#
# Déploiement local : ajouter au crontab
#   0 23 * * * /bin/bash /<chemin-absolu>/commit-bot/mirror.sh >> mirror.log 2>&1
#

set -euo pipefail

log() { echo "[mirror-bot] $*"; }
fail() { echo "[mirror-bot] ERREUR : $*" >&2; exit 1; }

# Se placer dans le dossier du script
case "$OSTYPE" in
    darwin*) cd "$(dirname "$0")" || fail "cd impossible" ;;
    linux*)  cd "$(dirname "$(readlink -f "$0")")" || fail "cd impossible" ;;
    *)       fail "OS non supporté : $OSTYPE" ;;
esac

# --- Dépendances ---
command -v curl >/dev/null || fail "curl est requis"
command -v jq   >/dev/null || fail "jq est requis (brew install jq)"
command -v git  >/dev/null || fail "git est requis"

# --- Configuration ---
[ -f .env ] || fail ".env introuvable — copie .env.example en .env et remplis-le"

# shellcheck disable=SC1091
set -a; source .env; set +a

: "${GITHUB_PRO_USER:?GITHUB_PRO_USER manquant dans .env}"
: "${GITHUB_PRO_TOKEN:?GITHUB_PRO_TOKEN manquant dans .env}"
: "${GITHUB_PERSO_USER:?GITHUB_PERSO_USER manquant dans .env}"
: "${GITHUB_PERSO_EMAIL:?GITHUB_PERSO_EMAIL manquant dans .env}"
: "${GITHUB_PERSO_REPO:?GITHUB_PERSO_REPO manquant dans .env}"
GITHUB_PERSO_NAME="${GITHUB_PERSO_NAME:-}"
GITHUB_PERSO_TOKEN="${GITHUB_PERSO_TOKEN:-}"
MAX_COMMITS_PER_DAY="${MAX_COMMITS_PER_DAY:-10}"

# TZ explicite : déterministe peu importe le shell parent (cron, IDE, etc.)
export TZ="${TZ:-America/New_York}"

# --- Identité git locale (au repo, pas globale) ---
git config user.email "$GITHUB_PERSO_EMAIL"
[ -n "$GITHUB_PERSO_NAME" ] && git config user.name "$GITHUB_PERSO_NAME"

# --- Bornes temporelles (journée locale) ---
TODAY=$(date +"%Y-%m-%d")
FROM=$(date +"%Y-%m-%dT00:00:00%z")
TO=$(date +"%Y-%m-%dT23:59:59%z")

log "Compte pro : $GITHUB_PRO_USER"
log "Fenêtre    : $FROM → $TO"

# --- Requête GraphQL ---
# On utilise contributionCalendar = exactement ce qui affiche un point vert sur le graphe GitHub.
# Inclut commits (branche par défaut), PRs, issues, reviews + privés (si scope OK).
payload=$(jq -nc \
    --arg u "$GITHUB_PRO_USER" \
    --arg f "$FROM" \
    --arg t "$TO" \
    '{
      query: "query($u:String!,$f:DateTime!,$t:DateTime!){user(login:$u){contributionsCollection(from:$f,to:$t){contributionCalendar{totalContributions}}}}",
      variables: {u:$u, f:$f, t:$t}
    }')

response=$(curl -sS \
    -H "Authorization: bearer $GITHUB_PRO_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    https://api.github.com/graphql)

# Vérif erreur API
if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    fail "API GitHub a retourné une erreur : $(echo "$response" | jq -c '.errors')"
fi

total=$(echo "$response" | jq -r '.data.user.contributionsCollection.contributionCalendar.totalContributions // 0')

log "Contributions pro aujourd'hui (telles que sur le graphe) : $total"

# Cap pour éviter un graphe absurde si grosse journée
if [ "$total" -gt "$MAX_COMMITS_PER_DAY" ]; then
    log "Cap appliqué : $total → $MAX_COMMITS_PER_DAY"
    total=$MAX_COMMITS_PER_DAY
fi

# --- État : ne pas re-miroirer ce qui l'a déjà été aujourd'hui ---
state_date=""
state_count=0
if [ -f .mirror_state ]; then
    read -r state_date state_count < .mirror_state || true
fi

if [ "$state_date" = "$TODAY" ]; then
    already=$state_count
else
    already=0
fi

to_create=$((total - already))

if [ "$to_create" -le 0 ]; then
    log "Rien à faire (déjà miroirés aujourd'hui : $already / total : $total)"
    exit 0
fi

log "À créer : $to_create commit(s) miroir(s)"

# --- Génération des commits ---
branch=$(git rev-parse --abbrev-ref HEAD)

for i in $(seq 1 "$to_create"); do
    ts=$(date +"%a %b %e %H:%M:%S %Z %Y")
    line="Commit: $ts"
    echo "$line" >> output.txt
    git add output.txt
    git commit -m "$line" || fail "git commit a échoué à l'itération $i"
    sleep 1  # léger décalage entre commits
done

# Push : avec token si fourni (cron-safe), sinon via remote `origin` existant
if [ -n "$GITHUB_PERSO_TOKEN" ]; then
    push_url="https://${GITHUB_PERSO_USER}:${GITHUB_PERSO_TOKEN}@github.com/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}.git"
    # On masque le token dans tout log éventuel
    git push "$push_url" "$branch" 2>&1 | sed "s|${GITHUB_PERSO_TOKEN}|***|g" \
        || fail "git push (token) a échoué"
    # Resync de la ref de tracking locale (push via URL ne le fait pas)
    git fetch --quiet origin "$branch" || true
else
    git push origin "$branch" || fail "git push (origin) a échoué (réseau ? credentials ?)"
fi

# --- Mise à jour de l'état ---
echo "$TODAY $total" > .mirror_state

log "Terminé : $to_create commit(s) poussé(s) sur $branch"
