#!/usr/bin/env bash
#
# Weekly Summary
#
# Une fois par semaine, poste un récap Discord :
#   - Activité du compte pro (jours actifs, total contribs)
#   - Activité du compte perso (graphe rempli)
#
# Cron suggéré (dimanche 22h) :
#   0 22 * * 0 /bin/bash /<chemin-absolu>/commit-bot/weekly-summary.sh >> bot.log 2>&1
#

set -euo pipefail

log() { echo "[weekly] $*"; }
fail() { echo "[weekly] ERREUR : $*" >&2; exit 1; }

# --- Notification Discord ---
notify_discord() {
    local title="$1"; local description="$2"; local color="$3"; local fields_json="${4:-[]}"
    [ -z "${DISCORD_WEBHOOK_URL:-}" ] && { log "DISCORD_WEBHOOK_URL absent, skip notif"; return 0; }
    local payload
    payload=$(jq -nc \
        --arg t "$title" --arg d "$description" \
        --argjson c "$color" --argjson f "$fields_json" \
        '{embeds:[{title:$t, description:$d, color:$c, fields:$f, footer:{text:"commit-bot — résumé hebdomadaire"}, timestamp:(now | strftime("%Y-%m-%dT%H:%M:%SZ"))}]}')
    curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# --- Placement ---
case "$OSTYPE" in
    darwin*) cd "$(dirname "$0")" || fail "cd impossible" ;;
    linux*)  cd "$(dirname "$(readlink -f "$0")")" || fail "cd impossible" ;;
    *)       fail "OS non supporté : $OSTYPE" ;;
esac

command -v curl >/dev/null || fail "curl est requis"
command -v jq   >/dev/null || fail "jq est requis (brew install jq)"

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
sanitize GITHUB_PRO_USER GITHUB_PRO_TOKEN GITHUB_PERSO_USER \
    GITHUB_PERSO_TOKEN TZ DISCORD_WEBHOOK_URL

: "${GITHUB_PRO_USER:?GITHUB_PRO_USER manquant}"
: "${GITHUB_PRO_TOKEN:?GITHUB_PRO_TOKEN manquant}"
: "${GITHUB_PERSO_USER:?GITHUB_PERSO_USER manquant}"
: "${GITHUB_PERSO_TOKEN:?GITHUB_PERSO_TOKEN manquant}"
GITHUB_PERSO_REPO="${GITHUB_PERSO_REPO:-?}"
export TZ="${TZ:-Africa/Lome}"

# --- Helper cross-platform pour date math ---
date_days_ago() {
    local n="$1"
    local fmt="$2"
    if date --version >/dev/null 2>&1; then
        date -d "${n} days ago" +"$fmt"   # GNU (Linux / GH Actions)
    else
        date -v-${n}d +"$fmt"             # BSD (macOS)
    fi
}

# --- Fenêtre temporelle : 7 derniers jours ---
FROM=$(date_days_ago 6 "%Y-%m-%dT00:00:00%z")
TO=$(date +"%Y-%m-%dT23:59:59%z")
FROM_DATE=$(date_days_ago 6 "%Y-%m-%d")
TO_DATE=$(date +"%Y-%m-%d")

log "Fenêtre : $FROM_DATE → $TO_DATE"

# --- Helper : query contributionCalendar pour un user ---
query_calendar() {
    local user="$1"; local token="$2"
    local payload
    payload=$(jq -nc --arg u "$user" --arg f "$FROM" --arg t "$TO" \
        '{query:"query($u:String!,$f:DateTime!,$t:DateTime!){user(login:$u){contributionsCollection(from:$f,to:$t){contributionCalendar{totalContributions weeks{contributionDays{date contributionCount}}}}}}", variables:{u:$u,f:$f,t:$t}}')
    curl -sS -H "Authorization: bearer $token" -H "Content-Type: application/json" -X POST -d "$payload" \
        https://api.github.com/graphql
}

# --- Pro ---
pro_resp=$(query_calendar "$GITHUB_PRO_USER" "$GITHUB_PRO_TOKEN")
pro_total=$(echo "$pro_resp" | jq -r '.data.user.contributionsCollection.contributionCalendar.totalContributions // 0')
pro_active_days=$(echo "$pro_resp" | jq '[.data.user.contributionsCollection.contributionCalendar.weeks[].contributionDays[] | select(.contributionCount > 0)] | length')
pro_best=$(echo "$pro_resp" | jq -r '[.data.user.contributionsCollection.contributionCalendar.weeks[].contributionDays[]] | sort_by(.contributionCount) | reverse | .[0] | "\(.date) (\(.contributionCount))"')

log "Pro : $pro_total contribs sur $pro_active_days jours actifs"

# --- Perso ---
perso_resp=$(query_calendar "$GITHUB_PERSO_USER" "$GITHUB_PERSO_TOKEN")
perso_total=$(echo "$perso_resp" | jq -r '.data.user.contributionsCollection.contributionCalendar.totalContributions // 0')
perso_active_days=$(echo "$perso_resp" | jq '[.data.user.contributionsCollection.contributionCalendar.weeks[].contributionDays[] | select(.contributionCount > 0)] | length')

log "Perso : $perso_total contribs sur $perso_active_days jours actifs"

# --- Build Discord embed ---
fields=$(jq -nc \
    --arg pro_total "$pro_total" \
    --arg pro_days "$pro_active_days" \
    --arg pro_best "$pro_best" \
    --arg perso_total "$perso_total" \
    --arg perso_days "$perso_active_days" \
    --arg from "$FROM_DATE" \
    --arg to "$TO_DATE" \
    '[
      {name:"Période", value:($from + " → " + $to), inline:false},
      {name:"Compte pro — total", value:$pro_total, inline:true},
      {name:"Compte pro — jours actifs", value:$pro_days, inline:true},
      {name:"Compte pro — meilleur jour", value:$pro_best, inline:false},
      {name:"Compte perso — total affiché", value:$perso_total, inline:true},
      {name:"Compte perso — jours actifs", value:$perso_days, inline:true}
    ]')

notify_discord "Résumé hebdomadaire" "Bilan des 7 derniers jours." 3447003 "$fields"

log "Résumé envoyé."
