#!/usr/bin/env bash
#
# Commit Bot — script daily
#
# Maintenu par Kokou DENYO
# > https://github.com/EmD-228/commit-bot
#
# Basé sur le projet original de Steven Kneiser
# > https://github.com/theshteves/commit-bot
#
# Architecture :
#   - Ce projet (commit-bot) = code des outils.
#   - Le repo CIBLE (où les commits sont poussés) est défini par GITHUB_PERSO_REPO.
#     Le script clone ce repo dans TARGET_CLONE_DIR, modifie UNIQUEMENT
#     TARGET_LOG_FILE (par défaut notes.md), commit & push. README intact.
#
# Comportement :
#   1. Lit le nombre de contributions du jour sur le compte GitHub PRO via GraphQL.
#   2. Génère le même nombre de commits dans le repo cible.
#   3. Push avec l'identité PERSO.
#
# NE LIT JAMAIS le contenu de tes commits pro — uniquement le compteur total.
#
# Cron :
#   0 23 * * * /bin/bash /<chemin-absolu>/commit-bot/bot.sh >> bot.log 2>&1
#

set -euo pipefail

log() { echo "[bot] $*"; }

# --- Notification Discord (silencieuse si DISCORD_WEBHOOK_URL absent) ---
# Couleurs : success=3066993 (vert) / noop=16776960 (jaune) / error=15158332 (rouge) / info=3447003 (bleu)
notify_discord() {
    local title="$1"; local description="$2"; local color="$3"; local fields_json="${4:-[]}"
    [ -z "${DISCORD_WEBHOOK_URL:-}" ] && return 0
    local payload
    payload=$(jq -nc \
        --arg t "$title" --arg d "$description" \
        --argjson c "$color" --argjson f "$fields_json" \
        '{embeds:[{title:$t, description:$d, color:$c, fields:$f, footer:{text:"commit-bot"}, timestamp:(now | strftime("%Y-%m-%dT%H:%M:%SZ"))}]}')
    curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

fail() {
    local msg="$*"
    echo "[bot] ERREUR : $msg" >&2
    notify_discord "Commit Bot — ERROR" "$msg" 15158332
    exit 1
}

# --- Pool de messages au format Conventional Commits ---
COMMIT_MESSAGES=(
    "chore: daily activity log"
    "chore: routine maintenance"
    "chore: update activity log"
    "chore: housekeeping"
    "chore: daily sync"
    "chore: routine update"
    "chore: log entry"
    "docs: update notes"
    "docs: log update"
    "refactor: minor cleanup"
)

pick_message() {
    local n=${#COMMIT_MESSAGES[@]}
    echo "${COMMIT_MESSAGES[$((RANDOM % n))]}"
}

# --- Pool de titres d'issues (style task tracker) ---
ISSUE_TITLES=(
    "Improve documentation clarity"
    "Add changelog entry"
    "Polish README formatting"
    "Refactor for clarity"
    "Add inline comments"
    "Tidy up dead code"
    "Better error messages"
    "Add usage example"
    "Update notes"
    "Cleanup unused imports"
)

pick_issue_title() {
    local n=${#ISSUE_TITLES[@]}
    echo "${ISSUE_TITLES[$((RANDOM % n))]}"
}

# --- Distribution des contributions par type ---
# Args: total_contribs
# Stdout: "commits prs issues" (où prs * 2 = contribs apportées par les PRs : 1 PR open + 1 squash commit)
distribute_contributions() {
    local n=$1
    if [ "$n" -le 3 ]; then
        echo "$n 0 0"
    elif [ "$n" -le 6 ]; then
        # 1 PR (= 2 contribs) + reste en commits
        echo "$((n - 2)) 1 0"
    else
        # ~10% issues, ~20% PRs (=40% des contribs), reste en commits
        local issues=$((n / 10))
        [ "$issues" -lt 1 ] && issues=1
        local prs=$((n / 5))
        local commits=$((n - 2 * prs - issues))
        echo "$commits $prs $issues"
    fi
}

# --- Placement (dossier du projet commit-bot) ---
case "$OSTYPE" in
    darwin*) cd "$(dirname "$0")" || fail "cd impossible" ;;
    linux*)  cd "$(dirname "$(readlink -f "$0")")" || fail "cd impossible" ;;
    *)       fail "OS non supporté : $OSTYPE" ;;
esac
PROJECT_DIR="$(pwd)"

# --- Dépendances ---
command -v curl >/dev/null || fail "curl est requis"
command -v jq   >/dev/null || fail "jq est requis (brew install jq)"
command -v git  >/dev/null || fail "git est requis"

# --- Configuration ---
[ -f .env ] || fail ".env introuvable — copie .env.example en .env et remplis-le"
# shellcheck disable=SC1091
set -a; source .env; set +a

# Sanitize : enlève sauts de ligne et espaces extérieurs (défense contre les copier-coller depuis GitHub Variables)
sanitize() {
    local v
    for v in "$@"; do
        local val
        val=$(printenv "$v" 2>/dev/null || true)
        [ -n "$val" ] && export "$v=$(printf '%s' "$val" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    done
}
sanitize GITHUB_PRO_USER GITHUB_PRO_TOKEN GITHUB_PERSO_USER GITHUB_PERSO_EMAIL \
    GITHUB_PERSO_NAME GITHUB_PERSO_REPO GITHUB_PERSO_TOKEN \
    TARGET_CLONE_DIR TARGET_LOG_FILE TZ DISCORD_WEBHOOK_URL \
    MAX_COMMITS_PER_DAY

: "${GITHUB_PRO_USER:?GITHUB_PRO_USER manquant dans .env}"
: "${GITHUB_PRO_TOKEN:?GITHUB_PRO_TOKEN manquant dans .env}"
: "${GITHUB_PERSO_USER:?GITHUB_PERSO_USER manquant dans .env}"
: "${GITHUB_PERSO_EMAIL:?GITHUB_PERSO_EMAIL manquant dans .env}"
: "${GITHUB_PERSO_REPO:?GITHUB_PERSO_REPO manquant dans .env}"
: "${GITHUB_PERSO_TOKEN:?GITHUB_PERSO_TOKEN manquant dans .env (requis pour push automatique)}"
GITHUB_PERSO_NAME="${GITHUB_PERSO_NAME:-}"
MAX_COMMITS_PER_DAY="${MAX_COMMITS_PER_DAY:-10}"
TARGET_CLONE_DIR="${TARGET_CLONE_DIR:-$HOME/.commit-bot-target}"
TARGET_LOG_FILE="${TARGET_LOG_FILE:-notes.md}"
export TZ="${TZ:-Africa/Lome}"

log "Compte pro   : $GITHUB_PRO_USER"
log "Repo cible   : $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO"
log "Clone local  : $TARGET_CLONE_DIR"
log "Fichier log  : $TARGET_LOG_FILE"

# --- Bornes temporelles (journée locale) ---
TODAY=$(date +"%Y-%m-%d")
FROM=$(date +"%Y-%m-%dT00:00:00%z")
TO=$(date +"%Y-%m-%dT23:59:59%z")
log "Fenêtre      : $FROM → $TO"

# --- Requête GraphQL ---
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

if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    fail "API GitHub : $(echo "$response" | jq -c '.errors')"
fi

total=$(echo "$response" | jq -r '.data.user.contributionsCollection.contributionCalendar.totalContributions // 0')
log "Contributions pro aujourd'hui : $total"

if [ "$total" -gt "$MAX_COMMITS_PER_DAY" ]; then
    log "Cap appliqué : $total → $MAX_COMMITS_PER_DAY"
    total=$MAX_COMMITS_PER_DAY
fi

# --- État (dans PROJECT_DIR pour que le clone reste lisible) ---
state_file="$PROJECT_DIR/.bot_state"
state_date=""
state_count=0
if [ -f "$state_file" ]; then
    read -r state_date state_count < "$state_file" || true
fi

if [ "$state_date" = "$TODAY" ]; then
    already=$state_count
else
    already=0
fi

to_create=$((total - already))

if [ "$to_create" -le 0 ]; then
    log "Rien à faire (déjà créés aujourd'hui : $already / total : $total)"
    noop_fields=$(jq -nc --arg pro "$total" --arg done "$already" --arg repo "$GITHUB_PERSO_USER/$GITHUB_PERSO_REPO" \
        '[{name:"Contributions pro", value:$pro, inline:true},
          {name:"Déjà miroirées", value:$done, inline:true},
          {name:"Repo cible", value:$repo, inline:false}]')
    notify_discord "Commit Bot — No-op" "Aucun nouveau commit à créer aujourd'hui." 16776960 "$noop_fields"
    exit 0
fi

log "À créer : $to_create commit(s)"

# --- Préparation du clone cible ---
push_url="https://${GITHUB_PERSO_USER}:${GITHUB_PERSO_TOKEN}@github.com/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}.git"

if [ ! -d "$TARGET_CLONE_DIR/.git" ]; then
    log "Premier run : clonage de $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO..."
    git clone --quiet "$push_url" "$TARGET_CLONE_DIR" 2>&1 \
        | sed "s|${GITHUB_PERSO_TOKEN}|***|g" \
        || fail "clonage de la cible a échoué"
fi

cd "$TARGET_CLONE_DIR" || fail "cd vers le clone cible impossible"

# Détection branche par défaut
DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
log "Branche cible : $DEFAULT_BRANCH"

git checkout --quiet "$DEFAULT_BRANCH"
git pull --quiet origin "$DEFAULT_BRANCH" || fail "pull du clone cible a échoué"

# Identité pour les commits (locale au clone cible)
git config user.email "$GITHUB_PERSO_EMAIL"
[ -n "$GITHUB_PERSO_NAME" ] && git config user.name "$GITHUB_PERSO_NAME"

# --- Génération des commits ---
for i in $(seq 1 "$to_create"); do
    ts=$(date +"%a %b %e %H:%M:%S %Z %Y")
    msg=$(pick_message)
    echo "$msg @ $ts" >> "$TARGET_LOG_FILE"
    git add "$TARGET_LOG_FILE"
    git commit --quiet -m "$msg" || fail "git commit a échoué à l'itération $i"
    sleep 1
done

# --- Push ---
git push "$push_url" "$DEFAULT_BRANCH" 2>&1 | sed "s|${GITHUB_PERSO_TOKEN}|***|g" \
    || fail "git push a échoué"

# --- Mise à jour de l'état ---
echo "$TODAY $total" > "$state_file"

log "Terminé : $to_create commit(s) poussé(s) sur $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO@$DEFAULT_BRANCH"

success_fields=$(jq -nc --arg pro "$total" --arg created "$to_create" --arg repo "$GITHUB_PERSO_USER/$GITHUB_PERSO_REPO" --arg branch "$DEFAULT_BRANCH" \
    '[{name:"Contributions pro", value:$pro, inline:true},
      {name:"Commits créés", value:$created, inline:true},
      {name:"Repo cible", value:($repo + " (" + $branch + ")"), inline:false}]')
notify_discord "Commit Bot — Daily Sync" "Synchronisation quotidienne réussie." 3066993 "$success_fields"
