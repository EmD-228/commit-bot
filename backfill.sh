#!/usr/bin/env bash
#
# Backfill Bot
#
# Récupère les contributions passées du compte GitHub PRO et génère des
# commits historiques dans le repo CIBLE (avec leurs dates d'origine).
#
# Architecture identique à bot.sh :
#   - Les commits sont créés dans TARGET_CLONE_DIR (clone du repo cible),
#     dans TARGET_LOG_FILE (notes.md), pas dans ce projet.
#   - Le README du repo cible n'est JAMAIS touché.
#
# Usage :
#   ./backfill.sh --from YYYY-MM-DD --to YYYY-MM-DD [--dry-run] [--no-cap]
#

set -euo pipefail

log() { echo "[backfill] $*"; }
fail() { echo "[backfill] ERREUR : $*" >&2; exit 1; }

# --- Pool de messages identique à bot.sh ---
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

# --- Args ---
FROM=""
TO=""
DRY_RUN=false
NO_CAP=false
while [ $# -gt 0 ]; do
    case "$1" in
        --from)    FROM="$2"; shift 2 ;;
        --to)      TO="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --no-cap)  NO_CAP=true; shift ;;
        *)         fail "argument inconnu : $1" ;;
    esac
done

[ -n "$FROM" ] || fail "--from YYYY-MM-DD requis"
[ -n "$TO" ]   || fail "--to YYYY-MM-DD requis"

# --- Placement & dépendances ---
case "$OSTYPE" in
    darwin*) cd "$(dirname "$0")" || fail "cd impossible" ;;
    linux*)  cd "$(dirname "$(readlink -f "$0")")" || fail "cd impossible" ;;
    *)       fail "OS non supporté : $OSTYPE" ;;
esac
PROJECT_DIR="$(pwd)"

command -v curl >/dev/null || fail "curl est requis"
command -v jq   >/dev/null || fail "jq est requis (brew install jq)"
command -v git  >/dev/null || fail "git est requis"

[ -f .env ] || fail ".env introuvable"
# shellcheck disable=SC1091
set -a; source .env; set +a

# Sanitize : enlève sauts de ligne et espaces extérieurs
sanitize() {
    local v val
    for v in "$@"; do
        val=$(printenv "$v" 2>/dev/null || true)
        if [ -n "$val" ]; then
            export "$v=$(printf '%s' "$val" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        fi
    done
    return 0
}
sanitize GITHUB_PRO_USER GITHUB_PRO_TOKEN GITHUB_PERSO_USER GITHUB_PERSO_EMAIL \
    GITHUB_PERSO_NAME GITHUB_PERSO_REPO GITHUB_PERSO_TOKEN \
    TARGET_CLONE_DIR TARGET_LOG_FILE TZ DISCORD_WEBHOOK_URL \
    MAX_COMMITS_PER_DAY

: "${GITHUB_PRO_USER:?GITHUB_PRO_USER manquant}"
: "${GITHUB_PRO_TOKEN:?GITHUB_PRO_TOKEN manquant}"
: "${GITHUB_PERSO_USER:?GITHUB_PERSO_USER manquant}"
: "${GITHUB_PERSO_EMAIL:?GITHUB_PERSO_EMAIL manquant}"
: "${GITHUB_PERSO_REPO:?GITHUB_PERSO_REPO manquant}"
: "${GITHUB_PERSO_TOKEN:?GITHUB_PERSO_TOKEN manquant}"
GITHUB_PERSO_NAME="${GITHUB_PERSO_NAME:-}"
MAX_COMMITS_PER_DAY="${MAX_COMMITS_PER_DAY:-10}"
TARGET_CLONE_DIR="${TARGET_CLONE_DIR:-$HOME/.commit-bot-target}"
TARGET_LOG_FILE="${TARGET_LOG_FILE:-notes.md}"
export TZ="${TZ:-Africa/Lome}"

TZ_OFFSET=$(date +"%z")

log "Compte pro   : $GITHUB_PRO_USER"
log "Repo cible   : $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO"
log "Clone local  : $TARGET_CLONE_DIR"
log "Fichier log  : $TARGET_LOG_FILE"
log "Période      : $FROM → $TO (TZ=$TZ, offset=$TZ_OFFSET)"
$DRY_RUN && log "Mode DRY-RUN : aucun commit ni push"
$NO_CAP  && log "Mode NO-CAP : cap MAX_COMMITS_PER_DAY ignoré"

# --- Requête GraphQL : calendar pour la période ---
FROM_ISO="${FROM}T00:00:00${TZ_OFFSET}"
TO_ISO="${TO}T23:59:59${TZ_OFFSET}"

payload=$(jq -nc \
    --arg u "$GITHUB_PRO_USER" \
    --arg f "$FROM_ISO" \
    --arg t "$TO_ISO" \
    '{
      query: "query($u:String!,$f:DateTime!,$t:DateTime!){user(login:$u){contributionsCollection(from:$f,to:$t){contributionCalendar{totalContributions weeks{contributionDays{date contributionCount}}}}}}",
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

days=$(echo "$response" | jq -r '
    .data.user.contributionsCollection.contributionCalendar.weeks[].contributionDays[]
    | select(.contributionCount > 0)
    | "\(.date) \(.contributionCount)"
')

if [ -z "$days" ]; then
    log "Aucune contribution pro trouvée dans la période. Rien à faire."
    exit 0
fi

day_count=$(echo "$days" | wc -l | tr -d ' ')
raw_total=$(echo "$days" | awk '{s+=$2} END {print s}')

if $NO_CAP; then
    capped_total=$raw_total
else
    capped_total=$(echo "$days" | awk -v cap="$MAX_COMMITS_PER_DAY" '{ if ($2 > cap) s+=cap; else s+=$2 } END {print s}')
fi

log "Jours actifs        : $day_count"
log "Contributions pro   : $raw_total (avant cap)"
log "Commits à créer     : $capped_total"

if $DRY_RUN; then
    log "DRY-RUN — aperçu des 20 premiers jours :"
    echo "$days" | head -20 | while read -r d c; do echo "    $d : $c contrib(s)"; done
    exit 0
fi

# --- Préparation du clone cible ---
push_url="https://${GITHUB_PERSO_USER}:${GITHUB_PERSO_TOKEN}@github.com/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}.git"

if [ ! -d "$TARGET_CLONE_DIR/.git" ]; then
    log "Premier run : clonage de $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO..."
    git clone --quiet "$push_url" "$TARGET_CLONE_DIR" 2>&1 \
        | sed "s|${GITHUB_PERSO_TOKEN}|***|g" \
        || fail "clonage de la cible a échoué"
fi

cd "$TARGET_CLONE_DIR" || fail "cd vers le clone cible impossible"

DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
log "Branche cible : $DEFAULT_BRANCH"

git checkout --quiet "$DEFAULT_BRANCH"
git pull --quiet origin "$DEFAULT_BRANCH" || fail "pull a échoué"

git config user.email "$GITHUB_PERSO_EMAIL"
[ -n "$GITHUB_PERSO_NAME" ] && git config user.name "$GITHUB_PERSO_NAME"

# --- Génération des commits ---
created=0

while read -r day count; do
    [ -z "$day" ] && continue
    if ! $NO_CAP && [ "$count" -gt "$MAX_COMMITS_PER_DAY" ]; then
        count=$MAX_COMMITS_PER_DAY
    fi

    # Spread N commits entre 09:00 et 21:00 (12h)
    for i in $(seq 1 "$count"); do
        if [ "$count" -eq 1 ]; then
            offset_min=360
        else
            offset_min=$(( (i - 1) * 720 / (count - 1) ))
        fi
        total_min=$(( 9 * 60 + offset_min ))
        hh=$(printf '%02d' $(( total_min / 60 )))
        mm=$(printf '%02d' $(( total_min % 60 )))
        ss=$(printf '%02d' $(( (i * 7) % 60 )))
        ts_iso="${day}T${hh}:${mm}:${ss}${TZ_OFFSET}"

        msg=$(pick_message)
        echo "$msg @ $ts_iso" >> "$TARGET_LOG_FILE"
        git add "$TARGET_LOG_FILE"
        GIT_AUTHOR_DATE="$ts_iso" GIT_COMMITTER_DATE="$ts_iso" \
            git commit --quiet -m "$msg" || fail "commit a échoué : $ts_iso"
        created=$((created + 1))
    done
done <<< "$days"

log "$created commit(s) créé(s) localement"

# --- Push ---
log "Push en cours..."
git push "$push_url" "$DEFAULT_BRANCH" 2>&1 | sed "s|${GITHUB_PERSO_TOKEN}|***|g" \
    || fail "push a échoué"

log "Terminé : $created commit(s) backfillé(s) sur $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO ($FROM → $TO)"
