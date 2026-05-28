#!/usr/bin/env bash
#
# Commit Bot
#
# Maintenu par Kokou DENYO
# > https://github.com/EmD-228/commit-bot
#
# Basé sur le projet original de Steven Kneiser
# > https://github.com/theshteves/commit-bot
#
# Déploiement local : ajouter la ligne suivante à ton crontab
#   0 22 * * * /bin/bash /<chemin-absolu>/commit-bot/bot.sh
#
# Édition du crontab :
#   crontab -e
#
# Tourner sur ta propre machine plutôt qu'un serveur donne
# une activité plus réaliste — personne ne commit VRAIMENT tous les jours.
#

set -euo pipefail

log() { echo "[commit-bot] $*"; }
fail() { echo "[commit-bot] ERREUR : $*" >&2; exit 1; }

info="Commit: $(date)"
log "OS détecté : $OSTYPE"

case "$OSTYPE" in
    darwin*)
        cd "$(dirname "$0")" || fail "cd impossible vers le dossier du script"
        ;;

    linux*)
        cd "$(dirname "$(readlink -f "$0")")" || fail "cd impossible vers le dossier du script"
        ;;

    *)
        fail "OS non supporté : $OSTYPE"
        ;;
esac

echo "$info" >> output.txt
log "$info"

# Détection de la branche courante (main, master, etc.)
branch=$(git rev-parse --abbrev-ref HEAD)

# Ship it
git add output.txt
git commit -m "$info" || fail "git commit a échoué"
git push origin "$branch" || fail "git push a échoué (réseau ? credentials ?)"

log "Push effectué sur la branche $branch"
