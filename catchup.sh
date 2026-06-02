#!/usr/bin/env bash
#
# Catch-up Bot
#
# Tourne le matin. Vérifie les LOOKBACK_DAYS derniers jours sur le compte pro
# et complète sur le compte perso ce qui manque.
#
# Cas typique : tu as fait des commits sur une feature branch hier qui ont été
# mergés ce matin. Côté pro, ces commits apparaissent maintenant comme des
# contributions du jour où ils ont été authored (= hier). Le bot.sh d'hier les
# avait ratés (il a tourné avant les merges). catchup.sh comble le delta.
#
# Cron suggéré (tous les jours à 07:00 UTC = 07:00 Lomé) :
#   0 7 * * * /bin/bash /<chemin-absolu>/commit-bot/catchup.sh >> bot.log 2>&1
#

set -euo pipefail

log() { echo "[catchup] $*"; }

# --- Notification Discord ---
notify_discord() {
    local title="$1"; local description="$2"; local color="$3"; local fields_json="${4:-[]}"
    [ -z "${DISCORD_WEBHOOK_URL:-}" ] && return 0
    local payload
    payload=$(jq -nc \
        --arg t "$title" --arg d "$description" \
        --argjson c "$color" --argjson f "$fields_json" \
        '{embeds:[{title:$t, description:$d, color:$c, fields:$f, footer:{text:"commit-bot — catchup"}, timestamp:(now | strftime("%Y-%m-%dT%H:%M:%SZ"))}]}')
    curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

fail() {
    local msg="$*"
    echo "[catchup] ERREUR : $msg" >&2
    notify_discord "Catchup Bot — ERROR" "$msg" 15158332
    exit 1
}

# --- Pool de messages ---
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

# --- Date helper cross-platform ---
date_days_ago() {
    local n="$1"
    local fmt="$2"
    if date --version >/dev/null 2>&1; then
        date -d "${n} days ago" +"$fmt"
    else
        date -v-${n}d +"$fmt"
    fi
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

# Sanitize
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
    MAX_COMMITS_PER_DAY LOOKBACK_DAYS

: "${GITHUB_PRO_USER:?}"
: "${GITHUB_PRO_TOKEN:?}"
: "${GITHUB_PERSO_USER:?}"
: "${GITHUB_PERSO_EMAIL:?}"
: "${GITHUB_PERSO_REPO:?}"
: "${GITHUB_PERSO_TOKEN:?}"
GITHUB_PERSO_NAME="${GITHUB_PERSO_NAME:-}"
MAX_COMMITS_PER_DAY="${MAX_COMMITS_PER_DAY:-10}"
TARGET_CLONE_DIR="${TARGET_CLONE_DIR:-$HOME/.commit-bot-target}"
TARGET_LOG_FILE="${TARGET_LOG_FILE:-notes.md}"
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
export TZ="${TZ:-Africa/Lome}"

TZ_OFFSET=$(date +"%z")
TODAY=$(date +"%Y-%m-%d")

# Range : hier - (LOOKBACK_DAYS - 1) → hier (on ne touche PAS aujourd'hui, c'est bot.sh)
FROM_DATE=$(date_days_ago "$LOOKBACK_DAYS" "%Y-%m-%d")
TO_DATE=$(date_days_ago 1 "%Y-%m-%d")
FROM_ISO="${FROM_DATE}T00:00:00${TZ_OFFSET}"
TO_ISO="${TO_DATE}T23:59:59${TZ_OFFSET}"

log "Compte pro   : $GITHUB_PRO_USER"
log "Repo cible   : $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO"
log "Période      : $FROM_DATE → $TO_DATE"

# --- Query pro : contributions par jour ---
payload=$(jq -nc \
    --arg u "$GITHUB_PRO_USER" \
    --arg f "$FROM_ISO" \
    --arg t "$TO_ISO" \
    '{query:"query($u:String!,$f:DateTime!,$t:DateTime!){user(login:$u){contributionsCollection(from:$f,to:$t){contributionCalendar{weeks{contributionDays{date contributionCount}}}}}}", variables:{u:$u,f:$f,t:$t}}')

response=$(curl -sS \
    -H "Authorization: bearer $GITHUB_PRO_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST -d "$payload" \
    https://api.github.com/graphql)

if echo "$response" | jq -e '.errors' >/dev/null 2>&1; then
    fail "API GitHub (pro) : $(echo "$response" | jq -c '.errors')"
fi

# Liste "date count" pour les jours de la période (incluant ceux à 0)
pro_days=$(echo "$response" | jq -r --arg from "$FROM_DATE" --arg to "$TO_DATE" '
    .data.user.contributionsCollection.contributionCalendar.weeks[].contributionDays[]
    | select(.date >= $from and .date <= $to)
    | "\(.date) \(.contributionCount)"
')

# --- Helper : compter commits perso sur master pour un jour donné ---
count_perso_commits_for_day() {
    local day="$1"
    local resp
    resp=$(curl -sS -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
        "https://api.github.com/repos/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}/commits?per_page=100&sha=master&since=${day}T00:00:00Z&until=${day}T23:59:59Z&author=${GITHUB_PERSO_EMAIL}")
    if [ "$(echo "$resp" | jq 'type')" = "\"array\"" ]; then
        echo "$resp" | jq 'length'
    else
        echo 0
    fi
}

# --- Préparation clone cible (pour les commits qu'on va peut-être créer) ---
push_url="https://${GITHUB_PERSO_USER}:${GITHUB_PERSO_TOKEN}@github.com/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}.git"

if [ ! -d "$TARGET_CLONE_DIR/.git" ]; then
    log "Clonage initial..."
    git clone --quiet "$push_url" "$TARGET_CLONE_DIR" 2>&1 \
        | sed "s|${GITHUB_PERSO_TOKEN}|***|g" \
        || fail "clonage a échoué"
fi

# --- Détecte deltas avant de cloner/checkout (économise du I/O si rien à faire) ---
declare -a plan_day plan_delta
total_to_create=0

while read -r day pro_count; do
    [ -z "$day" ] && continue
    pro_count=${pro_count:-0}
    # Apply cap on target
    target=$pro_count
    [ "$target" -gt "$MAX_COMMITS_PER_DAY" ] && target=$MAX_COMMITS_PER_DAY
    # Count what's already on perso
    perso_count=$(count_perso_commits_for_day "$day")
    delta=$((target - perso_count))
    if [ "$delta" -gt 0 ]; then
        log "  $day : pro=$pro_count (cap→$target) perso=$perso_count → manque $delta"
        plan_day+=("$day")
        plan_delta+=("$delta")
        total_to_create=$((total_to_create + delta))
    else
        log "  $day : pro=$pro_count (cap→$target) perso=$perso_count → OK"
    fi
done <<< "$pro_days"

if [ "$total_to_create" -eq 0 ]; then
    log "Tout est à jour. Rien à rattraper."
    notify_discord "Catchup Bot — No-op" "Les 7 derniers jours sont déjà à jour." 16776960 \
        "$(jq -nc --arg p "$FROM_DATE → $TO_DATE" '[{name:"Période vérifiée", value:$p, inline:false}]')"
    exit 0
fi

log "Total à créer : $total_to_create commit(s) répartis sur ${#plan_day[@]} jour(s)"

# --- Pull du clone cible ---
cd "$TARGET_CLONE_DIR" || fail "cd vers le clone impossible"
DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git checkout --quiet "$DEFAULT_BRANCH"
git pull --quiet origin "$DEFAULT_BRANCH" || fail "pull a échoué"
git config user.email "$GITHUB_PERSO_EMAIL"
[ -n "$GITHUB_PERSO_NAME" ] && git config user.name "$GITHUB_PERSO_NAME"

# --- Création des commits manquants ---
created=0
for idx in "${!plan_day[@]}"; do
    day="${plan_day[$idx]}"
    delta="${plan_delta[$idx]}"

    # Spread les $delta commits entre 09:00 et 21:00 (12h)
    for i in $(seq 1 "$delta"); do
        if [ "$delta" -eq 1 ]; then
            offset_min=360  # 15:00
        else
            offset_min=$(( (i - 1) * 720 / (delta - 1) ))
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
            git commit --quiet -m "$msg" || fail "commit échoué : $ts_iso"
        created=$((created + 1))
    done
done

# --- Push ---
git push --quiet "$push_url" "$DEFAULT_BRANCH" 2>&1 | sed "s|${GITHUB_PERSO_TOKEN}|***|g" \
    || fail "push a échoué"

log "Terminé : $created commit(s) catch-up créés sur ${#plan_day[@]} jour(s)"

# --- Notif Discord ---
days_summary=""
for idx in "${!plan_day[@]}"; do
    days_summary="${days_summary}${plan_day[$idx]} +${plan_delta[$idx]}, "
done
days_summary="${days_summary%, }"

success_fields=$(jq -nc \
    --arg created "$created" \
    --arg days "${#plan_day[@]}" \
    --arg detail "$days_summary" \
    --arg repo "$GITHUB_PERSO_USER/$GITHUB_PERSO_REPO" \
    '[{name:"Commits rattrapés", value:$created, inline:true},
      {name:"Jours concernés", value:$days, inline:true},
      {name:"Détail", value:$detail, inline:false},
      {name:"Repo cible", value:$repo, inline:false}]')
notify_discord "Catchup Bot — Daily" "Rattrapage des contributions oubliées." 3066993 "$success_fields"
