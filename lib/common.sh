# shellcheck shell=bash
#
# Code commun aux scripts de commit-bot. Chargé par `source`, jamais exécuté seul.
#
# Le script appelant définit avant de le charger :
#   BOT_TAG   — préfixe des logs et du footer Discord (ex. "bot")
#   BOT_LABEL — nom dans les notifications d'erreur (ex. "Commit Bot")
#
# Au chargement : se place dans le dossier du projet (PROJECT_DIR).
#
# Compatible bash 3.2 (macOS) : pas de `local -n`, pas de tableaux associatifs.

# --- Placement (dossier du projet commit-bot) ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || { echo "[$BOT_TAG] ERREUR : cd vers $PROJECT_DIR impossible" >&2; exit 1; }

log() { echo "[$BOT_TAG] $*"; }

# --- Notification Discord (silencieuse si DISCORD_WEBHOOK_URL absent) ---
COLOR_SUCCESS=3066993   # vert
COLOR_NOOP=16776960     # jaune
COLOR_ERROR=15158332    # rouge
COLOR_INFO=3447003      # bleu

# Args : titre, description, couleur, [champs JSON]
notify_discord() {
    local title="$1"; local description="$2"; local color="$3"; local fields_json="${4:-[]}"
    [ -z "${DISCORD_WEBHOOK_URL:-}" ] && return 0
    local payload
    payload=$(jq -nc \
        --arg t "$title" --arg d "$description" \
        --argjson c "$color" --argjson f "$fields_json" \
        --arg footer "commit-bot — $BOT_TAG" \
        '{embeds:[{title:$t, description:$d, color:$c, fields:$f, footer:{text:$footer}, timestamp:(now | strftime("%Y-%m-%dT%H:%M:%SZ"))}]}')
    curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

fail() {
    local msg="$*"
    echo "[$BOT_TAG] ERREUR : $msg" >&2
    notify_discord "$BOT_LABEL — ERROR" "$msg" "$COLOR_ERROR"
    exit 1
}

require_commands() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null || fail "$c est requis"
    done
}

# --- Configuration ---
# Enlève sauts de ligne et espaces extérieurs (défense contre les copier-coller
# depuis les Variables GitHub)
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

# Charge .env (en CI : fichier vide, les valeurs arrivent par le bloc env: du
# workflow), nettoie les variables et pose les valeurs par défaut communes.
load_env() {
    [ -f .env ] || fail ".env introuvable — copie .env.example en .env et remplis-le"
    # shellcheck disable=SC1091
    set -a; source .env; set +a

    sanitize GITHUB_PRO_USER GITHUB_PRO_TOKEN GITHUB_PERSO_USER GITHUB_PERSO_EMAIL \
        GITHUB_PERSO_NAME GITHUB_PERSO_REPO GITHUB_PERSO_TOKEN \
        TARGET_CLONE_DIR TARGET_LOG_FILE TZ DISCORD_WEBHOOK_URL \
        MAX_COMMITS_PER_DAY MIN_COMMITS_PER_DAY MAX_PRS_PER_DAY \
        LOOKBACK_DAYS ISSUE_WEEKDAY LATE_RUN_CUTOFF_HOUR

    GITHUB_PERSO_NAME="${GITHUB_PERSO_NAME:-}"
    TARGET_CLONE_DIR="${TARGET_CLONE_DIR:-$HOME/.commit-bot-target}"
    TARGET_LOG_FILE="${TARGET_LOG_FILE:-notes.md}"
    MAX_COMMITS_PER_DAY="${MAX_COMMITS_PER_DAY:-10}"
    # Partagé par cosmetic.sh (PRs créées) et bot.sh (contributions réservées)
    MAX_PRS_PER_DAY="${MAX_PRS_PER_DAY:-5}"
    LATE_RUN_CUTOFF_HOUR="${LATE_RUN_CUTOFF_HOUR:-6}"
    export TZ="${TZ:-Africa/Lome}"
    TZ_OFFSET=$(date +"%z")
}

require_vars() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] || fail "$v manquant (.env ou variables GitHub Actions)"
    done
}

# --- Dates ---
# Args : nombre de jours, format date
date_days_ago() {
    if date --version >/dev/null 2>&1; then
        date -d "$1 days ago" +"$2"   # GNU (Linux / GH Actions)
    else
        date -v-"$1"d +"$2"           # BSD (macOS)
    fi
}

# Les cron GitHub démarrent souvent 2-3h en retard, donc après minuit. Avant
# LATE_RUN_CUTOFF_HOUR, le run traite la VEILLE au lieu d'une journée qui commence.
is_late_run() {
    [ "$(date +%H)" -lt "$LATE_RUN_CUTOFF_HOUR" ]
}

# Date (au format $1) du jour traité : aujourd'hui, ou la veille si run tardif
target_date() {
    if is_late_run; then
        date_days_ago 1 "$1"
    else
        date +"$1"
    fi
}

# --- API GitHub ---
# Interroge contributionsCollection d'un utilisateur sur une période.
# Args : login, token, from (ISO), to (ISO), champs à sélectionner
# Stdout : la réponse JSON. Échoue sur erreur API ou utilisateur introuvable :
# ne jamais continuer avec des compteurs à 0 par défaut.
query_contributions() {
    local login="$1" token="$2" from="$3" to="$4" fields="$5"
    local payload resp
    payload=$(jq -nc --arg u "$login" --arg f "$from" --arg t "$to" \
        --arg q "query(\$u:String!,\$f:DateTime!,\$t:DateTime!){user(login:\$u){contributionsCollection(from:\$f,to:\$t){$fields}}}" \
        '{query:$q, variables:{u:$u, f:$f, t:$t}}')
    resp=$(curl -sS \
        -H "Authorization: bearer $token" \
        -H "Content-Type: application/json" \
        -X POST -d "$payload" \
        https://api.github.com/graphql)
    if echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
        fail "API GitHub ($login) : $(echo "$resp" | jq -c '.errors')"
    fi
    echo "$resp" | jq -e '.data.user' >/dev/null 2>&1 \
        || fail "API GitHub : utilisateur '$login' introuvable ou réponse invalide : $(echo "$resp" | jq -c '.message // .' 2>/dev/null || echo "$resp")"
    echo "$resp"
}

# --- Repo cible ---
# Masque le token dans toute sortie git
mask_token() {
    sed "s|${GITHUB_PERSO_TOKEN}|***|g"
}

# Clone le repo cible si besoin, s'y place, l'aligne sur le remote et pose
# l'identité perso. Définit PUSH_URL et DEFAULT_BRANCH.
prepare_target_clone() {
    PUSH_URL="https://${GITHUB_PERSO_USER}:${GITHUB_PERSO_TOKEN}@github.com/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}.git"

    if [ ! -d "$TARGET_CLONE_DIR/.git" ]; then
        log "Premier run : clonage de $GITHUB_PERSO_USER/$GITHUB_PERSO_REPO..."
        git clone --quiet "$PUSH_URL" "$TARGET_CLONE_DIR" 2>&1 | mask_token \
            || fail "clonage du repo cible a échoué"
    fi

    cd "$TARGET_CLONE_DIR" || fail "cd vers le clone cible impossible"

    # Le token ne doit jamais rester dans .git/config (nettoie aussi les anciens clones)
    git remote set-url origin "https://github.com/${GITHUB_PERSO_USER}/${GITHUB_PERSO_REPO}.git"

    DEFAULT_BRANCH=$(git ls-remote --symref "$PUSH_URL" HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2}')
    [ -n "$DEFAULT_BRANCH" ] || fail "branche par défaut du repo cible introuvable"
    log "Branche cible : $DEFAULT_BRANCH"

    sync_target_branch

    git config user.email "$GITHUB_PERSO_EMAIL"
    if [ -n "$GITHUB_PERSO_NAME" ]; then
        git config user.name "$GITHUB_PERSO_NAME"
    fi
}

# Aligne le clone sur le remote : jette tout commit local orphelin d'un push raté
sync_target_branch() {
    git fetch --quiet "$PUSH_URL" "$DEFAULT_BRANCH" 2>&1 | mask_token \
        || fail "fetch du repo cible a échoué"
    git reset --quiet --hard
    git checkout --quiet -B "$DEFAULT_BRANCH" FETCH_HEAD
}

# Args : [branche] (défaut : branche par défaut)
push_target() {
    local branch="${1:-$DEFAULT_BRANCH}"
    git push --quiet "$PUSH_URL" "$branch" 2>&1 | mask_token \
        || fail "push de $branch a échoué"
}

# --- Commits ---
# Pool de messages des commits du bot (bot.sh / catchup.sh / backfill.sh).
# catchup.sh s'en sert aussi pour reconnaître ces commits dans l'historique.
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

# Titres des PRs de cosmetic.sh. catchup.sh s'en sert pour reconnaître leurs
# commits squash (chaque PR cosmetic = 2 contributions : PR + squash).
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

# Élément aléatoire d'un tableau, passé par son nom
pick_from() {
    local ref="$1[@]"
    local arr=("${!ref}")
    local n=${#arr[@]}
    echo "${arr[$((RANDOM % n))]}"
}

pick_message() {
    pick_from COMMIT_MESSAGES
}

# Ajoute une ligne à TARGET_LOG_FILE et commite (dans le clone cible).
# Args : message, [date ISO pour antidater auteur + committer]
log_commit() {
    local msg="$1" iso="${2:-}"
    if [ -n "$iso" ]; then
        echo "$msg @ $iso" >> "$TARGET_LOG_FILE"
        git add "$TARGET_LOG_FILE"
        GIT_AUTHOR_DATE="$iso" GIT_COMMITTER_DATE="$iso" \
            git commit --quiet -m "$msg" || fail "git commit a échoué ($iso)"
    else
        echo "$msg @ $(date +"%a %b %e %H:%M:%S %Z %Y")" >> "$TARGET_LOG_FILE"
        git add "$TARGET_LOG_FILE"
        git commit --quiet -m "$msg" || fail "git commit a échoué"
    fi
}

# Crée N commits antidatés sur un jour, répartis entre 09:00 et 21:00.
# Args : jour (YYYY-MM-DD), nombre
commit_spread_over_day() {
    local day="$1" count="$2" i offset_min total_min
    for i in $(seq 1 "$count"); do
        if [ "$count" -eq 1 ]; then
            offset_min=360  # 15:00
        else
            offset_min=$(( (i - 1) * 720 / (count - 1) ))
        fi
        total_min=$(( 9 * 60 + offset_min ))
        log_commit "$(pick_message)" \
            "$(printf '%sT%02d:%02d:%02d%s' "$day" $((total_min / 60)) $((total_min % 60)) $(((i * 7) % 60)) "$TZ_OFFSET")"
    done
}
