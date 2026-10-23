#!/usr/bin/env bash
# Remet en ligne la version précédente du site (sans rien reconstruire).
#    sudo aeroclub-revenir-en-arriere
# Pensez à suspendre la publication automatique tant que le problème n'est pas corrigé :
#    sudo systemctl stop aeroclub-maj.timer     (puis « start » pour la relancer)
set -euo pipefail
BASE=/srv/aeroclub
[ "$(id -u)" -eq 0 ] || { echo "Lancez en root : sudo aeroclub-revenir-en-arriere" >&2; exit 1; }
courant=$(basename "$(readlink -f "$BASE/current")")
precedent=$(ls -1d "$BASE"/releases/*/ | sed 's#/$##' | xargs -n1 basename | sort -r | grep -v -x "$courant" | head -n1 || true)
[ -n "$precedent" ] || { echo "Aucune version précédente disponible." >&2; exit 1; }
ln -sfn "$BASE/releases/$precedent" "$BASE/current"
systemctl restart aeroclub
echo "Version remise en ligne : $precedent (au lieu de $courant)"
