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
# Limites :
#   - Période d'un an maximum par run (limite de l'API GitHub).
#   - GitHub ne compte que les ~1000 derniers commits d'un même push : au-delà,
#     découper en plusieurs runs (un push par run).
#

set -euo pipefail

BOT_TAG="backfill"
BOT_LABEL="Backfill Bot"
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

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

require_commands curl jq git
load_env
require_vars GITHUB_PRO_USER GITHUB_PRO_TOKEN GITHUB_PERSO_USER GITHUB_PERSO_EMAIL \
    GITHUB_PERSO_REPO GITHUB_PERSO_TOKEN

log "Compte pro   : $GITHUB_PRO_USER"
log "Repo cible   : $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO"
log "Clone local  : $TARGET_CLONE_DIR"
log "Fichier log  : $TARGET_LOG_FILE"
log "Période      : $FROM → $TO (TZ=$TZ, offset=$TZ_OFFSET)"
$DRY_RUN && log "Mode DRY-RUN : aucun commit ni push"
$NO_CAP  && log "Mode NO-CAP : cap MAX_COMMITS_PER_DAY ignoré"

# --- Contributions pro de la période ---
response=$(query_contributions "$GITHUB_PRO_USER" "$GITHUB_PRO_TOKEN" \
    "${FROM}T00:00:00${TZ_OFFSET}" "${TO}T23:59:59${TZ_OFFSET}" \
    "contributionCalendar{totalContributions weeks{contributionDays{date contributionCount}}}")

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
[ "$capped_total" -gt 1000 ] && log "ATTENTION : plus de 1000 commits en un push, GitHub risque de ne pas compter les plus anciens — découpe la période"

if $DRY_RUN; then
    log "DRY-RUN — aperçu des 20 premiers jours :"
    echo "$days" | head -20 | while read -r d c; do echo "    $d : $c contrib(s)"; done
    exit 0
fi

# --- Génération des commits ---
prepare_target_clone

while read -r day count; do
    [ -z "$day" ] && continue
    if ! $NO_CAP && [ "$count" -gt "$MAX_COMMITS_PER_DAY" ]; then
        count=$MAX_COMMITS_PER_DAY
    fi
    commit_spread_over_day "$day" "$count"
done <<< "$days"

log "$capped_total commit(s) créé(s) localement"

log "Push en cours..."
push_target

log "Terminé : $capped_total commit(s) backfillé(s) sur $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO ($FROM → $TO)"
