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
#   2. Génère autant de commits dans le repo cible, moins les contributions
#      que cosmetic.sh produira pour les PRs (2 par PR).
#   3. Push avec l'identité PERSO.
#
# NE LIT JAMAIS le contenu de tes commits pro — uniquement les compteurs.
#
# Cron :
#   0 23 * * * /bin/bash /<chemin-absolu>/commit-bot/bot.sh >> bot.log 2>&1
#

set -euo pipefail

BOT_TAG="bot"
BOT_LABEL="Commit Bot"
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_commands curl jq git
load_env
require_vars GITHUB_PRO_USER GITHUB_PRO_TOKEN GITHUB_PERSO_USER GITHUB_PERSO_EMAIL \
    GITHUB_PERSO_REPO GITHUB_PERSO_TOKEN
MIN_COMMITS_PER_DAY="${MIN_COMMITS_PER_DAY:-1}"

log "Compte pro   : $GITHUB_PRO_USER"
log "Repo cible   : $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO"
log "Clone local  : $TARGET_CLONE_DIR"
log "Fichier log  : $TARGET_LOG_FILE"

# --- Journée traitée ---
# Run tardif (après minuit) : on traite la veille et on antidate les commits à
# 23h30 de ce jour-là, au lieu de lire le compteur (≈ 0) d'une journée qui commence.
TODAY=$(target_date "%Y-%m-%d")
if is_late_run; then
    BACKDATE=true
    log "Run après minuit : traitement de la veille ($TODAY)"
else
    BACKDATE=false
fi
FROM="${TODAY}T00:00:00${TZ_OFFSET}"
TO="${TODAY}T23:59:59${TZ_OFFSET}"
log "Fenêtre      : $FROM → $TO"

# --- Contributions pro ---
response=$(query_contributions "$GITHUB_PRO_USER" "$GITHUB_PRO_TOKEN" "$FROM" "$TO" \
    "totalPullRequestContributions contributionCalendar{totalContributions}")
pro_total=$(echo "$response" | jq -r '.data.user.contributionsCollection.contributionCalendar.totalContributions // 0')
pro_prs=$(echo "$response" | jq -r '.data.user.contributionsCollection.totalPullRequestContributions // 0')
log "Contributions pro aujourd'hui : $pro_total (dont $pro_prs PR(s))"

# Les PRs sont reproduites par cosmetic.sh : 1 PR + 1 commit squash = 2
# contributions chacune (plafonné à MAX_PRS_PER_DAY). On les retire du total
# pour que le profil perso affiche le même total que le pro.
cosmetic_prs=$pro_prs
[ "$cosmetic_prs" -gt "$MAX_PRS_PER_DAY" ] && cosmetic_prs=$MAX_PRS_PER_DAY
reserved=$((2 * cosmetic_prs))
total=$((pro_total - reserved))
[ "$total" -lt 0 ] && total=0
[ "$reserved" -gt 0 ] && log "Réservé à cosmetic.sh : $reserved contribution(s) ($cosmetic_prs PR(s)) → $total commit(s)"

if [ "$total" -gt "$MAX_COMMITS_PER_DAY" ]; then
    log "Cap appliqué : $total → $MAX_COMMITS_PER_DAY"
    total=$MAX_COMMITS_PER_DAY
fi

# Baseline uniquement si cosmetic.sh ne crée rien : sinon le jour a déjà ses contributions
if [ "$reserved" -eq 0 ] && [ "$total" -lt "$MIN_COMMITS_PER_DAY" ]; then
    log "Baseline appliqué : $total → $MIN_COMMITS_PER_DAY (au moins 1 commit par jour)"
    total=$MIN_COMMITS_PER_DAY
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
    noop_fields=$(jq -nc --arg pro "$pro_total" --arg done "$already" --arg repo "$GITHUB_PERSO_USER/$GITHUB_PERSO_REPO" \
        '[{name:"Contributions pro", value:$pro, inline:true},
          {name:"Déjà miroirées", value:$done, inline:true},
          {name:"Repo cible", value:$repo, inline:false}]')
    notify_discord "Commit Bot — No-op" "Aucun nouveau commit à créer aujourd'hui." "$COLOR_NOOP" "$noop_fields"
    exit 0
fi

log "À créer : $to_create commit(s)"

# --- Commits ---
prepare_target_clone

for i in $(seq 1 "$to_create"); do
    if $BACKDATE; then
        # 23:30:00, 23:30:01, … sur la journée traitée
        log_commit "$(pick_message)" \
            "$(printf '%sT23:%02d:%02d%s' "$TODAY" $((30 + i / 60)) $((i % 60)) "$TZ_OFFSET")"
    else
        log_commit "$(pick_message)"
        sleep 1
    fi
done

push_target

# --- Mise à jour de l'état ---
echo "$TODAY $total" > "$state_file"

log "Terminé : $to_create commit(s) poussé(s) sur $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO@$DEFAULT_BRANCH"

success_fields=$(jq -nc --arg pro "$pro_total" --arg created "$to_create" --arg repo "$GITHUB_PERSO_USER/$GITHUB_PERSO_REPO" --arg branch "$DEFAULT_BRANCH" \
    '[{name:"Contributions pro", value:$pro, inline:true},
      {name:"Commits créés", value:$created, inline:true},
      {name:"Repo cible", value:($repo + " (" + $branch + ")"), inline:false}]')
notify_discord "Commit Bot — Daily Sync" "Synchronisation quotidienne réussie." "$COLOR_SUCCESS" "$success_fields"
