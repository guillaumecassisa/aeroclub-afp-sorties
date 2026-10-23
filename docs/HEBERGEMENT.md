# Héberger le site à l'adresse du club (OVH)

Le site est un programme Node.js (Next.js) qui tourne en permanence ; la base de données et les
fichiers restent chez **Supabase** quel que soit l'hébergement choisi. Trois cas selon l'offre OVH
du club :

| Offre OVH du club | Possible ? | Solution |
|---|---|---|
| Nom de domaine seul, ou domaine + hébergement web « mutualisé » (Perso, Pro, Performance) | Le site ne peut pas tourner sur le mutualisé (pas de Node.js) | **A.** Le site reste sur Vercel, à l'adresse du club |
| Serveur VPS (ou serveur dédié) | Oui | **A**, ou **B.** le site est installé sur le VPS |
| Rien chez OVH | — | **A** avec un domaine à acheter (≈ 10 €/an), ou garder l'adresse `….vercel.app` |

**Recommandation : A.** Gratuit, rien à maintenir, mises à jour automatiques et retour arrière en un
clic. Le site actuel du club (s'il y en a un sur le mutualisé) n'est pas touché : on utilise un
sous-domaine, par exemple `sorties.<domaine-du-club>`.

---

## A. Garder Vercel, avec l'adresse du club (15 minutes)

1. **Vercel** → projet `aeroclub-afpa` → **Settings → Domains → Add** : saisir
   `sorties.<domaine-du-club>`. Vercel affiche l'entrée DNS à créer (type **CNAME** et sa valeur).
2. **OVH** → espace client → **Web Cloud → Noms de domaine** → le domaine → onglet **Zone DNS** →
   **Ajouter une entrée** → **CNAME** :
   - sous-domaine : `sorties`
   - cible : la valeur donnée par Vercel, **avec un point final** (ex. `cname.vercel-dns.com.`)

   S'il existe déjà une entrée A, AAAA ou CNAME pour `sorties`, la supprimer d'abord.
3. Attendre que Vercel affiche **Valid Configuration** (quelques minutes à une heure) : le certificat
   HTTPS est créé tout seul.
4. **Vercel → Settings → Environment Variables** : `NEXT_PUBLIC_SITE_URL` =
   `https://sorties.<domaine-du-club>`, puis **Deployments → ⋯ → Redeploy**.
5. **Supabase → Authentication → URL Configuration** : *Site URL* = la nouvelle adresse ;
   *Redirect URLs* : ajouter `https://sorties.<domaine-du-club>/auth/confirm` (garder l'ancienne
   quelques jours, pour les emails déjà envoyés).
6. Optionnel : dans Vercel → Domains, rediriger l'ancienne adresse `aeroclub-afp-sorties.vercel.app`
   vers la nouvelle.

Pour utiliser le domaine nu (`<domaine-du-club>` sans sous-domaine), Vercel demande une entrée **A**
à la place du CNAME : il affiche sa valeur au même endroit. Cela remplace le site actuel du club.

---

## B. Installer le site sur un VPS OVH (1 heure)

Le serveur devient à la charge du club : les mises à jour de sécurité du système sont automatiques,
mais il faut surveiller qu'il tourne, et le renouveler/payer (VPS d'entrée de gamme OVH : 2 cœurs,
4 Go de mémoire, à partir de ≈ 4 € HT/mois, suffisant).

Tout est prêt dans `deploy/vps/` :

| Fichier | Rôle |
|---|---|
| `installer.sh` | Installe tout sur un serveur neuf : Node.js 22, Nginx, certificat HTTPS Let's Encrypt, pare-feu, protection contre les tentatives de connexion (fail2ban), mises à jour de sécurité automatiques, le site comme service qui redémarre tout seul |
| `mettre-a-jour.sh` | Publie la dernière version de la branche `main` : construction à part, bascule d'un coup, retour automatique à la version précédente si le site ne répond pas ; garde les 3 dernières versions |
| `revenir-en-arriere.sh` | Remet la version précédente en ligne en quelques secondes |
| `aeroclub-maj.timer` | Vérifie toutes les 10 minutes s'il y a du nouveau sur `main` et le publie (comme Vercel) |
| `aeroclub.service`, `nginx-aeroclub.conf` | Service du site et configuration Nginx |

### Étapes

1. **OVH** : VPS sous **Ubuntu 24.04** (ou Debian 12). Noter son adresse IP (IPv4, et IPv6 s'il y en a une).
2. **Zone DNS OVH** du domaine : entrée **A** `sorties` → IPv4 du VPS (et **AAAA** → IPv6). Supprimer
   une éventuelle entrée existante pour `sorties`.
3. Se connecter au serveur (`ssh ubuntu@IP`), puis :
   ```sh
   git clone https://github.com/guillaumecassisa/aeroclub-afp-sorties.git
   cd aeroclub-afp-sorties/deploy/vps
   sudo DOMAINE=sorties.<domaine-du-club> EMAIL=<email-admin> bash installer.sh
   ```
   Au premier passage, le script s'arrête et demande de compléter `/etc/aeroclub/aeroclub.env` :
   ```sh
   sudo nano /etc/aeroclub/aeroclub.env
   ```
   Y recopier **les mêmes valeurs que dans Vercel** (Settings → Environment Variables : adresse et
   clé publishable Supabase, nom du club, terrain, stations météo, email). Jamais la clé
   `service_role`. Puis relancer la même commande `sudo DOMAINE=… bash installer.sh`.

   Dépôt GitHub **privé** : ajouter `DEPOT=git@github.com:guillaumecassisa/aeroclub-afp-sorties.git`
   devant la commande ; le script affiche une clé à coller dans GitHub → Settings → Deploy keys
   (lecture seule), puis on relance.
4. **Supabase → Authentication → URL Configuration** : comme en A, étape 5.
5. Tester : connexion, inscription à un événement, un email. Quand tout va bien, le projet Vercel
   peut être gardé quelques semaines en secours, puis supprimé (Vercel → Settings → Delete).

### Au quotidien

| Besoin | Commande (sur le serveur) |
|---|---|
| Publier tout de suite | `sudo aeroclub-mettre-a-jour` |
| Revenir à la version précédente | `sudo aeroclub-revenir-en-arriere` puis `sudo systemctl stop aeroclub-maj.timer` le temps de corriger |
| Voir le journal du site | `sudo journalctl -u aeroclub -n 100` |
| Redémarrer le site | `sudo systemctl restart aeroclub` |
| Modifier une variable | `sudo nano /etc/aeroclub/aeroclub.env` puis `sudo aeroclub-mettre-a-jour --forcer` (les variables `NEXT_PUBLIC_…` sont intégrées à la construction) |

Comme avec Vercel : exécuter les mises à jour SQL dans Supabase **avant** de publier sur `main` le
code qui en dépend. La sauvegarde nocturne (GitHub) ne change pas : elle sauvegarde Supabase, pas le
serveur, qui ne contient aucune donnée (il se réinstalle avec `installer.sh`).
