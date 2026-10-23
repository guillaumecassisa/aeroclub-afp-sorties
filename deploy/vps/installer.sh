#!/usr/bin/env bash
# =====================================================================
#  Installation du site de l'aéroclub sur un serveur VPS neuf
#  (Ubuntu 24.04 ou Debian 12, par exemple un VPS OVHcloud).
#
#  À lancer en root (ou avec sudo), depuis ce dossier :
#     sudo DOMAINE=sorties.mon-club.fr EMAIL=admin@mon-club.fr bash installer.sh
#
#  Options (variables à placer devant la commande) :
#     DOMAINE   adresse du site (obligatoire), déjà dirigée vers l'IP du serveur
#     EMAIL     adresse pour le certificat HTTPS Let's Encrypt (obligatoire)
#     DEPOT     adresse du dépôt GitHub (par défaut celui de l'AFPA)
#               dépôt privé : git@github.com:compte/depot.git (une clé de déploiement est créée)
#     BRANCHE   branche publiée (par défaut main)
#     MAJ_AUTO  oui (défaut) : le serveur publie tout seul les nouveautés de la branche,
#               comme Vercel, en vérifiant toutes les 10 minutes ; non : à la main
#
#  Le script peut être relancé sans risque : il ne refait que ce qui manque.
#  La base de données et les fichiers restent chez Supabase : seul le site est hébergé ici.
# =====================================================================
set -euo pipefail

DOMAINE="${DOMAINE:-}"
EMAIL="${EMAIL:-}"
DEPOT="${DEPOT:-https://github.com/guillaumecassisa/aeroclub-afp-sorties.git}"
BRANCHE="${BRANCHE:-main}"
MAJ_AUTO="${MAJ_AUTO:-oui}"

ICI="$(cd "$(dirname "$0")" && pwd)"
BASE=/srv/aeroclub
CONF=/etc/aeroclub
ENVFILE=$CONF/aeroclub.env

etape() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
stop() { printf '\n\033[1;31mArrêt : %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || stop "lancez ce script en root (sudo bash installer.sh)."
[ -n "$DOMAINE" ] || stop "indiquez l'adresse du site : DOMAINE=sorties.mon-club.fr"
[ -n "$EMAIL" ] || stop "indiquez une adresse email pour le certificat : EMAIL=admin@mon-club.fr"
. /etc/os-release
case "$ID" in ubuntu|debian) ;; *) stop "système non prévu ($PRETTY_NAME) : Ubuntu 24.04 ou Debian 12 attendu." ;; esac

etape "1/9 Mise à jour du système et outils"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -yq
apt-get install -yq sudo curl ca-certificates git nginx certbot python3-certbot-nginx ufw fail2ban unattended-upgrades

etape "2/9 Node.js 22"
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -yq nodejs
fi
node -v

etape "3/9 Utilisateur et dossiers"
id aeroclub >/dev/null 2>&1 || useradd --system --home-dir "$BASE" --shell /usr/sbin/nologin aeroclub
mkdir -p "$BASE/releases" "$CONF"
chown -R aeroclub:aeroclub "$BASE"
chmod 750 "$CONF"
chown root:aeroclub "$CONF"

etape "4/9 Configuration du site ($ENVFILE)"
cat >"$CONF/deploiement.conf" <<EOF
# Lu par mettre-a-jour.sh
DEPOT=$DEPOT
BRANCHE=$BRANCHE
EOF
if [ ! -f "$ENVFILE" ]; then
  if [ -f "$ICI/../../.env.example" ]; then cp "$ICI/../../.env.example" "$ENVFILE"; else : >"$ENVFILE"; fi
  sed -i "s#^NEXT_PUBLIC_SITE_URL=.*#NEXT_PUBLIC_SITE_URL=https://$DOMAINE#" "$ENVFILE"
  chown root:aeroclub "$ENVFILE"
  chmod 640 "$ENVFILE"
fi
if grep -qE '^NEXT_PUBLIC_SUPABASE_URL=https://x+\.supabase\.co' "$ENVFILE" || ! grep -qE '^NEXT_PUBLIC_SUPABASE_URL=https://' "$ENVFILE"; then
  stop "complétez d'abord $ENVFILE (mêmes valeurs que dans Vercel → Settings → Environment Variables),
par exemple avec : nano $ENVFILE
puis relancez la même commande. Ne mettez JAMAIS la clé service_role dans ce fichier."
fi

etape "5/9 Accès au dépôt"
if [[ "$DEPOT" == git@* ]]; then
  install -d -o aeroclub -g aeroclub -m 700 "$BASE/.ssh"
  if [ ! -f "$BASE/.ssh/id_ed25519" ]; then
    sudo -u aeroclub ssh-keygen -q -t ed25519 -N "" -C "deploiement-$DOMAINE" -f "$BASE/.ssh/id_ed25519"
  fi
  sudo -u aeroclub sh -c "ssh-keyscan -t ed25519 github.com >> '$BASE/.ssh/known_hosts' 2>/dev/null; sort -u -o '$BASE/.ssh/known_hosts' '$BASE/.ssh/known_hosts'"
  if ! sudo -u aeroclub git ls-remote "$DEPOT" >/dev/null 2>&1; then
    echo
    echo "Dépôt privé : ajoutez cette clé dans GitHub → dépôt → Settings → Deploy keys → Add deploy key"
    echo "(titre : serveur $DOMAINE, NE PAS cocher « Allow write access ») :"
    echo
    cat "$BASE/.ssh/id_ed25519.pub"
    stop "puis relancez la même commande."
  fi
else
  git ls-remote "$DEPOT" >/dev/null 2>&1 || stop "dépôt inaccessible : $DEPOT (privé ? utilisez DEPOT=git@github.com:compte/depot.git)"
fi

etape "6/9 Service du site (systemd)"
install -m 644 "$ICI/aeroclub.service" /etc/systemd/system/aeroclub.service
install -m 755 "$ICI/mettre-a-jour.sh" /usr/local/bin/aeroclub-mettre-a-jour
install -m 755 "$ICI/revenir-en-arriere.sh" /usr/local/bin/aeroclub-revenir-en-arriere
systemctl daemon-reload
systemctl enable aeroclub >/dev/null

etape "7/9 Première publication du site (construction : 2 à 5 minutes)"
/usr/local/bin/aeroclub-mettre-a-jour --forcer

etape "8/9 Nginx et certificat HTTPS"
sed "s#__DOMAINE__#$DOMAINE#g" "$ICI/nginx-aeroclub.conf" >/etc/nginx/sites-available/aeroclub
ln -sfn /etc/nginx/sites-available/aeroclub /etc/nginx/sites-enabled/aeroclub
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx
# (relancé, certbot remet le certificat existant dans la configuration au lieu d'en redemander un)
certbot --nginx -d "$DOMAINE" -m "$EMAIL" --agree-tos -n --redirect --keep-until-expiring \
  || stop "certificat refusé : vérifiez que $DOMAINE pointe bien vers l'IP de ce serveur (zone DNS OVH), puis relancez."
systemctl reload nginx

etape "9/9 Sécurité et mises à jour automatiques"
ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null
systemctl enable --now fail2ban >/dev/null
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null
if [ "$MAJ_AUTO" = "oui" ]; then
  install -m 644 "$ICI/aeroclub-maj.service" /etc/systemd/system/aeroclub-maj.service
  install -m 644 "$ICI/aeroclub-maj.timer" /etc/systemd/system/aeroclub-maj.timer
  systemctl daemon-reload
  systemctl enable --now aeroclub-maj.timer >/dev/null
fi

printf '\n\033[1;32mTerminé : https://%s\033[0m\n' "$DOMAINE"
cat <<EOF

À faire maintenant :
  - Supabase → Authentication → URL Configuration : Site URL = https://$DOMAINE
    et Redirect URLs : https://$DOMAINE/auth/confirm
  - Tester : connexion, inscription à un événement, envoi d'un email.

Au quotidien :
  - Nouveautés publiées : $( [ "$MAJ_AUTO" = "oui" ] && echo "automatiquement (toutes les 10 min, branche $BRANCHE)" || echo "sudo aeroclub-mettre-a-jour" )
  - Revenir à la version précédente : sudo aeroclub-revenir-en-arriere
  - Journal du site : sudo journalctl -u aeroclub -n 100
EOF
