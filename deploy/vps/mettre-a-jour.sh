#!/usr/bin/env bash
# =====================================================================
#  Publie la dernière version du site sur le serveur (installé par installer.sh).
#     sudo aeroclub-mettre-a-jour            publie si la branche a changé
#     sudo aeroclub-mettre-a-jour --forcer   reconstruit même sans changement
#  Chaque version est construite à part (dossier releases/), puis activée d'un coup :
#  si le site ne répond pas après le redémarrage, la version précédente est remise.
#  Rappel : exécutez les mises à jour SQL dans Supabase AVANT de publier le code qui en dépend.
# =====================================================================
set -euo pipefail

BASE=/srv/aeroclub
CONF=/etc/aeroclub
ENVFILE=$CONF/aeroclub.env
GARDER=3
# shellcheck disable=SC1091
. "$CONF/deploiement.conf"

[ "$(id -u)" -eq 0 ] || { echo "Lancez en root : sudo aeroclub-mettre-a-jour" >&2; exit 1; }
exec 9>/run/aeroclub-maj.lock
flock -n 9 || { echo "Une mise à jour est déjà en cours."; exit 0; }

comme_site() { sudo -u aeroclub -H "$@"; }

distant=$(comme_site git ls-remote "$DEPOT" "refs/heads/$BRANCHE" | cut -f1)
[ -n "$distant" ] || { echo "Branche $BRANCHE introuvable sur $DEPOT" >&2; exit 1; }
actuel=$(cat "$BASE/current/.version" 2>/dev/null || true)
if [ "${1:-}" != "--forcer" ] && [ "$distant" = "$actuel" ]; then
  exit 0 # rien de nouveau
fi

rel="$BASE/releases/$(date +%Y%m%d-%H%M%S)-${distant:0:7}"
echo "Nouvelle version ${distant:0:7} → $rel"
comme_site git clone -q --depth 1 --branch "$BRANCHE" "$DEPOT" "$rel"
cd "$rel"
echo "$distant" | comme_site tee .version >/dev/null

# Les variables NEXT_PUBLIC_… sont intégrées au moment de la construction : on les charge ici
# (lecture ligne à ligne : les valeurs peuvent contenir des espaces, comme pour Vercel et systemd)
while IFS= read -r ligne || [ -n "$ligne" ]; do
  ligne="${ligne%$'\r'}"
  case "$ligne" in ''|'#'*) continue ;; esac
  cle="${ligne%%=*}"
  valeur="${ligne#*=}"
  [[ "$cle" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  if [[ "$valeur" =~ ^\"(.*)\"$ ]] || [[ "$valeur" =~ ^\'(.*)\'$ ]]; then valeur="${BASH_REMATCH[1]}"; fi
  export "$cle=$valeur"
done <"$ENVFILE"
export NEXT_TELEMETRY_DISABLED=1
comme_site --preserve-env npm ci --no-audit --no-fund --loglevel=error
comme_site --preserve-env npm run build

precedent=""
[ -L "$BASE/current" ] && precedent=$(readlink -f "$BASE/current")
ln -sfn "$rel" "$BASE/current"
systemctl restart aeroclub 9>&-

ok=0
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/connexion || true)
  if [ "$code" = "200" ]; then ok=1; break; fi
  sleep 2
done
if [ "$ok" != 1 ]; then
  echo "Le site ne répond pas avec la nouvelle version : retour à la précédente." >&2
  if [ -n "$precedent" ] && [ -d "$precedent" ]; then
    ln -sfn "$precedent" "$BASE/current"
    systemctl restart aeroclub 9>&-
  else
    rm -f "$BASE/current"
  fi
  echo "Détails : journalctl -u aeroclub -n 50" >&2
  exit 1
fi
echo "Version ${distant:0:7} en ligne."

# Ménage : on garde les $GARDER dernières versions
cd "$BASE/releases"
courant=$(basename "$(readlink -f "$BASE/current")")
ls -1d */ 2>/dev/null | sed 's#/$##' | sort -r | tail -n +$((GARDER + 1)) | while read -r d; do
  [ "$d" = "$courant" ] || rm -rf -- "$d"
done
