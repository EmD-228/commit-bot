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

BOT_TAG="catchup"
BOT_LABEL="Catchup Bot"
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_commands curl jq git
load_env
require_vars GITHUB_PRO_USER GITHUB_PRO_TOKEN GITHUB_PERSO_USER GITHUB_PERSO_EMAIL \
    GITHUB_PERSO_REPO GITHUB_PERSO_TOKEN
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"

# Range : hier - (LOOKBACK_DAYS - 1) → hier (on ne touche PAS aujourd'hui, c'est bot.sh)
FROM_DATE=$(date_days_ago "$LOOKBACK_DAYS" "%Y-%m-%d")
TO_DATE=$(date_days_ago 1 "%Y-%m-%d")

log "Compte pro   : $GITHUB_PRO_USER"
log "Repo cible   : $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO"
log "Période      : $FROM_DATE → $TO_DATE"

# --- Contributions pro par jour (incluant les jours à 0) ---
response=$(query_contributions "$GITHUB_PRO_USER" "$GITHUB_PRO_TOKEN" \
    "${FROM_DATE}T00:00:00${TZ_OFFSET}" "${TO_DATE}T23:59:59${TZ_OFFSET}" \
    "contributionCalendar{weeks{contributionDays{date contributionCount}}}")
pro_days=$(echo "$response" | jq -r --arg from "$FROM_DATE" --arg to "$TO_DATE" '
    .data.user.contributionsCollection.contributionCalendar.weeks[].contributionDays[]
    | select(.date >= $from and .date <= $to)
    | "\(.date) \(.contributionCount)"
')

# --- Clone cible (sert au comptage ET aux commits à créer) ---
prepare_target_clone

# --- Commits perso déjà présents, par jour (date d'auteur, heure locale) ---
# Compté sur TOUT l'historique local. Surtout pas via `?since=` de l'API (ni
# `git log --since`) : le parcours s'arrête au premier commit plus ancien, et
# un backfill empile justement des commits anciens au sommet de l'historique
# → tout compterait 0 et on recréerait des commits déjà présents.
#
# Stdin : "YYYY-MM-DD sujet" ; $1 : sujets acceptés (un par ligne)
# Stdout : "YYYY-MM-DD n" pour les commits dont le sujet est dans la liste
count_by_day() {
    SUBJECTS="$1" awk '
        BEGIN { n = split(ENVIRON["SUBJECTS"], a, "\n"); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
        { s = substr($0, 12); if (s in ok) c[$1]++ }
        END { for (d in c) print d, c[d] }'
}
# Commits du bot (bot.sh / catchup.sh / backfill.sh)
bot_counts=$(git log --author="<${GITHUB_PERSO_EMAIL}>" --format='%ad %s' --date=format-local:%Y-%m-%d \
    | count_by_day "$(printf '%s\n' "${COMMIT_MESSAGES[@]}")")
# Commits squash des PRs de cosmetic.sh (auteur fixé par GitHub au merge : pas de filtre --author)
cosmetic_counts=$(git log --format='%ad %s' --date=format-local:%Y-%m-%d \
    | count_by_day "$(printf '%s\n' "${PR_TITLES[@]}")")
lookup() {
    echo "$1" | awk -v d="$2" '$1 == d { n = $2 } END { print n + 0 }'
}

# --- Détecte deltas ---
# Même règle que bot.sh : commits = pro − 2 × PRs cosmetic du jour, plafonné.
# Ici on prend les PRs cosmetic RÉELLEMENT créées : si cosmetic.sh a raté un
# jour, ses contributions sont complétées en commits.
declare -a plan_day plan_delta
total_to_create=0

while read -r day pro_count; do
    [ -z "$day" ] && continue
    pro_count=${pro_count:-0}
    prs=$(lookup "$cosmetic_counts" "$day")
    target=$((pro_count - 2 * prs))
    [ "$target" -lt 0 ] && target=0
    [ "$target" -gt "$MAX_COMMITS_PER_DAY" ] && target=$MAX_COMMITS_PER_DAY
    perso_count=$(lookup "$bot_counts" "$day")
    delta=$((target - perso_count))
    if [ "$delta" -gt 0 ]; then
        log "  $day : pro=$pro_count PRs cosmetic=$prs → cible $target commit(s), perso=$perso_count → manque $delta"
        plan_day+=("$day")
        plan_delta+=("$delta")
        total_to_create=$((total_to_create + delta))
    else
        log "  $day : pro=$pro_count PRs cosmetic=$prs → cible $target commit(s), perso=$perso_count → OK"
    fi
done <<< "$pro_days"

if [ "$total_to_create" -eq 0 ]; then
    log "Tout est à jour. Rien à rattraper."
    notify_discord "Catchup Bot — No-op" "Les ${LOOKBACK_DAYS} derniers jours sont déjà à jour." "$COLOR_NOOP" \
        "$(jq -nc --arg p "$FROM_DATE → $TO_DATE" '[{name:"Période vérifiée", value:$p, inline:false}]')"
    exit 0
fi

log "Total à créer : $total_to_create commit(s) répartis sur ${#plan_day[@]} jour(s)"

# --- Création des commits manquants ---
for idx in "${!plan_day[@]}"; do
    commit_spread_over_day "${plan_day[$idx]}" "${plan_delta[$idx]}"
done

push_target

log "Terminé : $total_to_create commit(s) catch-up créés sur ${#plan_day[@]} jour(s)"

# --- Notif Discord ---
days_summary=""
for idx in "${!plan_day[@]}"; do
    days_summary="${days_summary}${plan_day[$idx]} +${plan_delta[$idx]}, "
done
days_summary="${days_summary%, }"

success_fields=$(jq -nc \
    --arg created "$total_to_create" \
    --arg days "${#plan_day[@]}" \
    --arg detail "$days_summary" \
    --arg repo "$GITHUB_PERSO_USER/$GITHUB_PERSO_REPO" \
    '[{name:"Commits rattrapés", value:$created, inline:true},
      {name:"Jours concernés", value:$days, inline:true},
      {name:"Détail", value:$detail, inline:false},
      {name:"Repo cible", value:$repo, inline:false}]')
notify_discord "Catchup Bot — Daily" "Rattrapage des contributions oubliées." "$COLOR_SUCCESS" "$success_fields"
