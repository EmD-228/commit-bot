#!/usr/bin/env bash
#
# Cosmetic Bot
#
# Crée des PRs et issues "falsifiées" sur le repo cible, en miroir des PRs/issues
# faites sur le compte PRO. Sert UNIQUEMENT à équilibrer le camembert
# "Activity Overview" du profil GitHub (commits / PRs / issues / reviews).
#
# Architecture identique à bot.sh : clone le repo cible dans TARGET_CLONE_DIR,
# crée branches → commits → PRs → squash merge → delete branch. Issues créées
# puis fermées immédiatement.
#
# Le README du repo cible n'est JAMAIS touché.
#
# Cron suggéré (tous les jours à 23h30, après bot.sh) :
#   30 23 * * * /bin/bash /<chemin-absolu>/commit-bot/cosmetic.sh >> bot.log 2>&1
#

set -euo pipefail

log() { echo "[cosmetic] $*"; }

# --- Notification Discord ---
notify_discord() {
    local title="$1"; local description="$2"; local color="$3"; local fields_json="${4:-[]}"
    [ -z "${DISCORD_WEBHOOK_URL:-}" ] && return 0
    local payload
    payload=$(jq -nc \
        --arg t "$title" --arg d "$description" \
        --argjson c "$color" --argjson f "$fields_json" \
        '{embeds:[{title:$t, description:$d, color:$c, fields:$f, footer:{text:"commit-bot — cosmetic"}, timestamp:(now | strftime("%Y-%m-%dT%H:%M:%SZ"))}]}')
    curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

fail() {
    local msg="$*"
    echo "[cosmetic] ERREUR : $msg" >&2
    notify_discord "Cosmetic Bot — ERROR" "$msg" 15158332
    exit 1
}

# --- Pool de titres de PRs (style change request) ---
PR_TITLES=(
    "refactor: simplify activity logging"
    "chore: tidy notes formatting"
    "docs: clarify usage example"
    "fix: typo in log entry"
    "chore: remove stale entries"
    "refactor: reorganize sections"
    "docs: update changelog"
    "chore: bump activity log"
    "fix: minor formatting"
    "refactor: collapse redundant lines"
)

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

pick_from() {
    local -n arr=$1
    local n=${#arr[@]}
    echo "${arr[$((RANDOM % n))]}"
}

# --- Placement ---
case "$OSTYPE" in
    darwin*) cd "$(dirname "$0")" || fail "cd impossible" ;;
    linux*)  cd "$(dirname "$(readlink -f "$0")")" || fail "cd impossible" ;;
    *)       fail "OS non supporté : $OSTYPE" ;;
esac
PROJECT_DIR="$(pwd)"

command -v curl >/dev/null || fail "curl est requis"
command -v jq   >/dev/null || fail "jq est requis"
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
    MAX_PRS_PER_DAY ISSUE_WEEKDAY

: "${GITHUB_PRO_USER:?GITHUB_PRO_USER manquant}"
: "${GITHUB_PRO_TOKEN:?GITHUB_PRO_TOKEN manquant}"
: "${GITHUB_PERSO_USER:?GITHUB_PERSO_USER manquant}"
: "${GITHUB_PERSO_EMAIL:?GITHUB_PERSO_EMAIL manquant}"
: "${GITHUB_PERSO_REPO:?GITHUB_PERSO_REPO manquant}"
: "${GITHUB_PERSO_TOKEN:?GITHUB_PERSO_TOKEN manquant}"
GITHUB_PERSO_NAME="${GITHUB_PERSO_NAME:-}"
TARGET_CLONE_DIR="${TARGET_CLONE_DIR:-$HOME/.commit-bot-target}"
TARGET_LOG_FILE="${TARGET_LOG_FILE:-notes.md}"
MAX_PRS_PER_DAY="${MAX_PRS_PER_DAY:-5}"
ISSUE_WEEKDAY="${ISSUE_WEEKDAY:-1}"  # 1 = lundi (jour où on crée 1 issue)
export TZ="${TZ:-Africa/Lome}"

TODAY=$(date +"%Y-%m-%d")
WEEKDAY=$(date +"%u")  # 1=lundi … 7=dimanche

log "Compte pro : $GITHUB_PRO_USER"
log "Repo cible : $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO"
log "Jour       : $TODAY (weekday=$WEEKDAY)"

# --- Requête API : combien de PRs/issues sur le pro aujourd'hui ? ---
FROM=$(date +"%Y-%m-%dT00:00:00%z")
TO=$(date +"%Y-%m-%dT23:59:59%z")

payload=$(jq -nc --arg u "$GITHUB_PRO_USER" --arg f "$FROM" --arg t "$TO" \
    '{query:"query($u:String!,$f:DateTime!,$t:DateTime!){user(login:$u){contributionsCollection(from:$f,to:$t){totalPullRequestContributions totalIssueContributions}}}", variables:{u:$u,f:$f,t:$t}}')
response=$(curl -sS \
    -H "Authorization: bearer $GITHUB_PRO_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST -d "$payload" \
    https://api.github.com/graphql)

if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    fail "API GitHub : $(echo "$response" | jq -c '.errors')"
fi

pro_prs=$(echo "$response" | jq -r '.data.user.contributionsCollection.totalPullRequestContributions // 0')
pro_issues=$(echo "$response" | jq -r '.data.user.contributionsCollection.totalIssueContributions // 0')
log "Pro aujourd'hui : $pro_prs PR(s), $pro_issues issue(s)"

# --- Plan ---
# PRs : mirror du pro, cappé à MAX_PRS_PER_DAY
prs_to_create=$pro_prs
[ "$prs_to_create" -gt "$MAX_PRS_PER_DAY" ] && {
    log "Cap PRs : $prs_to_create → $MAX_PRS_PER_DAY"
    prs_to_create=$MAX_PRS_PER_DAY
}

# Issues : 1 le lundi (et seulement si pas déjà créée aujourd'hui)
issues_to_create=0
if [ "$WEEKDAY" = "$ISSUE_WEEKDAY" ]; then
    issues_to_create=1
fi

# --- État (idempotence) ---
state_file="$PROJECT_DIR/.cosmetic_state"
state_date=""; state_prs=0; state_issues=0
[ -f "$state_file" ] && read -r state_date state_prs state_issues < "$state_file" || true

if [ "$state_date" = "$TODAY" ]; then
    prs_to_create=$((prs_to_create - state_prs))
    issues_to_create=$((issues_to_create - state_issues))
    [ "$prs_to_create" -lt 0 ] && prs_to_create=0
    [ "$issues_to_create" -lt 0 ] && issues_to_create=0
fi

log "À créer : $prs_to_create PR(s) + $issues_to_create issue(s)"

if [ "$prs_to_create" -eq 0 ] && [ "$issues_to_create" -eq 0 ]; then
    log "Rien à faire."
    notify_discord "Cosmetic Bot — No-op" "Aucune PR ni issue à falsifier aujourd'hui." 16776960 \
        "$(jq -nc --arg pro "$pro_prs" --arg today "$TODAY" \
            '[{name:"PRs pro aujourd'\''hui", value:$pro, inline:true},
              {name:"Jour", value:$today, inline:true}]')"
    exit 0
fi

# --- Préparation clone cible ---
push_url="https://${GITHUB_PERSO_USER}:${GITHUB_PERSO_TOKEN}@github.com/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}.git"

if [ ! -d "$TARGET_CLONE_DIR/.git" ]; then
    log "Clonage initial..."
    git clone --quiet "$push_url" "$TARGET_CLONE_DIR" 2>&1 \
        | sed "s|${GITHUB_PERSO_TOKEN}|***|g" \
        || fail "clonage a échoué"
fi

cd "$TARGET_CLONE_DIR" || fail "cd vers le clone impossible"

DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

git checkout --quiet "$DEFAULT_BRANCH"
git pull --quiet origin "$DEFAULT_BRANCH" || fail "pull a échoué"

git config user.email "$GITHUB_PERSO_EMAIL"
[ -n "$GITHUB_PERSO_NAME" ] && git config user.name "$GITHUB_PERSO_NAME"

API_BASE="https://api.github.com/repos/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}"

# --- Cycle d'une PR ---
create_pr_cycle() {
    local idx="$1"
    local branch="cosmetic/$(date +%s)-${idx}-$RANDOM"
    local title ts resp number
    title=$(pick_from PR_TITLES)
    ts=$(date +"%a %b %e %H:%M:%S %Z %Y")

    git checkout --quiet -b "$branch" "$DEFAULT_BRANCH"
    echo "$title @ $ts" >> "$TARGET_LOG_FILE"
    git add "$TARGET_LOG_FILE"
    git commit --quiet -m "$title"
    git push --quiet "$push_url" "$branch" 2>&1 | sed "s|${GITHUB_PERSO_TOKEN}|***|g" \
        || fail "push de la branche $branch a échoué"

    resp=$(curl -sS -X POST \
        -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg title "$title" --arg head "$branch" --arg base "$DEFAULT_BRANCH" \
            '{title:$title, head:$head, base:$base, body:"Auto-tracked activity."}')" \
        "$API_BASE/pulls")
    number=$(echo "$resp" | jq -r '.number // empty')
    [ -z "$number" ] && fail "création de PR a échoué : $(echo "$resp" | jq -c '.errors // .message')"

    curl -sS -X PUT \
        -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg t "$title" '{merge_method:"squash", commit_title:$t}')" \
        "$API_BASE/pulls/$number/merge" >/dev/null \
        || fail "merge PR #$number a échoué"

    curl -sS -X DELETE \
        -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
        "$API_BASE/git/refs/heads/$branch" >/dev/null 2>&1 || true
    git checkout --quiet "$DEFAULT_BRANCH"
    git pull --quiet origin "$DEFAULT_BRANCH" || true
    git branch --quiet -D "$branch" 2>/dev/null || true

    log "  PR #$number : $title"
}

# --- Création d'une issue (ouverte puis fermée) ---
create_issue() {
    local title="$1"
    local resp number
    resp=$(curl -sS -X POST \
        -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg t "$title" '{title:$t, body:"Auto-tracked activity."}')" \
        "$API_BASE/issues")
    number=$(echo "$resp" | jq -r '.number // empty')
    [ -z "$number" ] && fail "création d'issue a échoué : $(echo "$resp" | jq -c '.errors // .message')"

    curl -sS -X PATCH \
        -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d '{"state":"closed"}' \
        "$API_BASE/issues/$number" >/dev/null || true

    log "  Issue #$number : $title"
}

# --- Exécution ---
for i in $(seq 1 "$prs_to_create"); do
    create_pr_cycle "$i"
    sleep 1
done

for i in $(seq 1 "$issues_to_create"); do
    create_issue "$(pick_from ISSUE_TITLES)"
    sleep 1
done

# --- État ---
new_prs=$((state_prs + prs_to_create))
new_issues=$((state_issues + issues_to_create))
[ "$state_date" != "$TODAY" ] && { new_prs=$prs_to_create; new_issues=$issues_to_create; }
echo "$TODAY $new_prs $new_issues" > "$state_file"

# --- Notif Discord ---
success_fields=$(jq -nc \
    --arg prs "$prs_to_create" \
    --arg issues "$issues_to_create" \
    --arg pro_prs "$pro_prs" \
    --arg pro_issues "$pro_issues" \
    --arg repo "$GITHUB_PERSO_USER/$GITHUB_PERSO_REPO" \
    '[{name:"PRs créées (perso)", value:$prs, inline:true},
      {name:"Issues créées (perso)", value:$issues, inline:true},
      {name:"Référence pro (PRs/issues)", value:($pro_prs + " / " + $pro_issues), inline:false},
      {name:"Repo cible", value:$repo, inline:false}]')
notify_discord "Cosmetic Bot — Daily" "Activity Overview mis à jour." 3066993 "$success_fields"

log "Terminé."
