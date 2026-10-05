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

BOT_TAG="weekly"
BOT_LABEL="Weekly Summary"
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_commands curl jq
load_env
require_vars GITHUB_PRO_USER GITHUB_PRO_TOKEN GITHUB_PERSO_USER GITHUB_PERSO_TOKEN
[ -n "${DISCORD_WEBHOOK_URL:-}" ] || log "DISCORD_WEBHOOK_URL absent : le résumé ne sera pas envoyé"

# --- Fenêtre temporelle : 7 derniers jours ---
FROM_DATE=$(date_days_ago 6 "%Y-%m-%d")
TO_DATE=$(date +"%Y-%m-%d")
FROM="${FROM_DATE}T00:00:00${TZ_OFFSET}"
TO="${TO_DATE}T23:59:59${TZ_OFFSET}"

log "Fenêtre : $FROM_DATE → $TO_DATE"

CALENDAR_FIELDS="contributionCalendar{totalContributions weeks{contributionDays{date contributionCount}}}"

# --- Pro ---
pro_resp=$(query_contributions "$GITHUB_PRO_USER" "$GITHUB_PRO_TOKEN" "$FROM" "$TO" "$CALENDAR_FIELDS")
pro_total=$(echo "$pro_resp" | jq -r '.data.user.contributionsCollection.contributionCalendar.totalContributions // 0')
pro_active_days=$(echo "$pro_resp" | jq '[.data.user.contributionsCollection.contributionCalendar.weeks[].contributionDays[] | select(.contributionCount > 0)] | length')
pro_best=$(echo "$pro_resp" | jq -r '[.data.user.contributionsCollection.contributionCalendar.weeks[].contributionDays[]] | sort_by(.contributionCount) | reverse | .[0] | "\(.date) (\(.contributionCount))"')

log "Pro : $pro_total contribs sur $pro_active_days jours actifs"

# --- Perso ---
perso_resp=$(query_contributions "$GITHUB_PERSO_USER" "$GITHUB_PERSO_TOKEN" "$FROM" "$TO" "$CALENDAR_FIELDS")
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

notify_discord "Résumé hebdomadaire" "Bilan des 7 derniers jours." "$COLOR_INFO" "$fields"

log "Résumé envoyé."
