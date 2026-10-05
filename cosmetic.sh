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
# Cron suggéré (tous les jours à 19h30) :
#   30 19 * * * /bin/bash /<chemin-absolu>/commit-bot/cosmetic.sh >> bot.log 2>&1
#

set -euo pipefail

BOT_TAG="cosmetic"
BOT_LABEL="Cosmetic Bot"
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# --- Pool de titres d'issues (style task tracker) ---
# (les titres de PRs, PR_TITLES, sont dans lib/common.sh : catchup.sh s'en sert aussi)
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

require_commands curl jq git
load_env
require_vars GITHUB_PRO_USER GITHUB_PRO_TOKEN GITHUB_PERSO_USER GITHUB_PERSO_EMAIL \
    GITHUB_PERSO_REPO GITHUB_PERSO_TOKEN
ISSUE_WEEKDAY="${ISSUE_WEEKDAY:-1}"  # 1 = lundi (jour où on crée 1 issue)

# Run tardif (après minuit) : on lit les PRs de la VEILLE (une PR ne peut pas
# être antidatée, elle apparaîtra sur le jour courant, mais le compte n'est plus perdu)
TODAY=$(target_date "%Y-%m-%d")
WEEKDAY=$(target_date "%u")  # 1=lundi … 7=dimanche

log "Compte pro : $GITHUB_PRO_USER"
log "Repo cible : $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO"
log "Jour       : $TODAY (weekday=$WEEKDAY)"

# --- Combien de PRs/issues sur le pro aujourd'hui ? ---
response=$(query_contributions "$GITHUB_PRO_USER" "$GITHUB_PRO_TOKEN" \
    "${TODAY}T00:00:00${TZ_OFFSET}" "${TODAY}T23:59:59${TZ_OFFSET}" \
    "totalPullRequestContributions totalIssueContributions")
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

API_BASE="https://api.github.com/repos/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}"

# Les PRs peuvent être désactivées dans les réglages du repo cible : on ne crée
# alors que les issues (catchup.sh complète en commits les PRs non créées)
if [ "$prs_to_create" -gt 0 ]; then
    prs_enabled=$(curl -sS -H "Authorization: bearer $GITHUB_PERSO_TOKEN" "$API_BASE" \
        | jq -r '.has_pull_requests | tostring')
    if [ "$prs_enabled" = "false" ]; then
        log "PRs désactivées sur $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO : $prs_to_create PR(s) ignorée(s)"
        notify_discord "Cosmetic Bot — PRs désactivées" \
            "Les pull requests sont désactivées sur $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO : aucune PR créée. Réactive-les dans Settings → General → Features → Pull requests." \
            "$COLOR_NOOP"
        prs_to_create=0
    fi
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
else
    state_prs=0; state_issues=0
fi

# Écrit l'état après CHAQUE PR/issue : un crash en cours de route
# ne provoque pas de doublons au run suivant
save_state() {
    echo "$TODAY $state_prs $state_issues" > "$state_file"
}

log "À créer : $prs_to_create PR(s) + $issues_to_create issue(s)"

if [ "$prs_to_create" -eq 0 ] && [ "$issues_to_create" -eq 0 ]; then
    log "Rien à faire."
    notify_discord "Cosmetic Bot — No-op" "Aucune PR ni issue à falsifier aujourd'hui." "$COLOR_NOOP" \
        "$(jq -nc --arg pro "$pro_prs" --arg today "$TODAY" \
            '[{name:"PRs pro aujourd'\''hui", value:$pro, inline:true},
              {name:"Jour", value:$today, inline:true}]')"
    exit 0
fi

prepare_target_clone

# Supprime une branche distante (nettoyage, ne fait jamais échouer le script)
delete_remote_branch() {
    curl -sS -X DELETE \
        -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
        "$API_BASE/git/refs/heads/$1" >/dev/null 2>&1 || true
}

# --- Cycle d'une PR ---
create_pr_cycle() {
    local idx="$1"
    local branch="cosmetic/$(date +%s)-${idx}-$RANDOM"
    local title resp number
    title=$(pick_from PR_TITLES)

    git checkout --quiet -b "$branch" "$DEFAULT_BRANCH"
    log_commit "$title"
    push_target "$branch"

    resp=$(curl -sS -X POST \
        -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --arg title "$title" --arg head "$branch" --arg base "$DEFAULT_BRANCH" \
            '{title:$title, head:$head, base:$base, body:"Auto-tracked activity."}')" \
        "$API_BASE/pulls")
    number=$(echo "$resp" | jq -r '.number // empty')
    if [ -z "$number" ]; then
        # Ne pas laisser de branche orpheline sur le repo cible
        delete_remote_branch "$branch"
        fail "création de PR a échoué : $(echo "$resp" | jq -c '.errors // .message')"
    fi

    # Juste après la création, GitHub n'a pas toujours fini de calculer la
    # mergeabilité (405) : on réessaie quelques fois avant d'abandonner.
    local attempt merge_resp merged=false
    for attempt in 1 2 3 4 5; do
        merge_resp=$(curl -sS -X PUT \
            -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/json" \
            -d "$(jq -nc --arg t "$title" '{merge_method:"squash", commit_title:$t}')" \
            "$API_BASE/pulls/$number/merge")
        if [ "$(echo "$merge_resp" | jq -r '.merged // false' 2>/dev/null)" = "true" ]; then
            merged=true
            break
        fi
        if [ "$attempt" -lt 5 ]; then sleep $((attempt * 2)); fi
    done
    $merged || fail "merge PR #$number a échoué : $(echo "$merge_resp" | jq -c '.message // .' 2>/dev/null || echo "$merge_resp")"

    delete_remote_branch "$branch"
    sync_target_branch
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

    resp=$(curl -sS -X PATCH \
        -H "Authorization: bearer $GITHUB_PERSO_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -d '{"state":"closed"}' \
        "$API_BASE/issues/$number")
    [ "$(echo "$resp" | jq -r '.state // empty' 2>/dev/null)" = "closed" ] \
        || fail "fermeture de l'issue #$number a échoué : $(echo "$resp" | jq -c '.message // .' 2>/dev/null || echo "$resp")"

    log "  Issue #$number : $title"
}

# --- Exécution ---
for i in $(seq 1 "$prs_to_create"); do
    create_pr_cycle "$i"
    state_prs=$((state_prs + 1)); save_state
    sleep 1
done

for i in $(seq 1 "$issues_to_create"); do
    create_issue "$(pick_from ISSUE_TITLES)"
    state_issues=$((state_issues + 1)); save_state
    sleep 1
done

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
notify_discord "Cosmetic Bot — Daily" "Activity Overview mis à jour." "$COLOR_SUCCESS" "$success_fields"

log "Terminé."
