# Sauvegardes

Deux façons de sauvegarder les données du club, complémentaires.

## 1. Sauvegarde manuelle (immédiate, sans configuration)

Site → **⚙️ Gestion → Sauvegarde → Télécharger la sauvegarde**.
Vous obtenez un fichier `.json` avec toutes les tables (membres, événements, bar, shop, flotte,
pédagogie, REX, journal…) et la liste des fichiers stockés. À faire au moins une fois par mois et
avant toute grosse modification. Le fichier contient des données personnelles : rangez-le en lieu sûr.

## 2. Sauvegarde automatique chaque nuit (base + fichiers, chiffrée)

Le fichier `.github/workflows/sauvegarde.yml` fait chaque nuit :
- une copie complète de la base (`pg_dump`, y compris les comptes) ;
- une copie de tous les fichiers (documents des avions, documents pédagogiques, photos, images du shop) ;
- le tout chiffré (AES-256) avec votre phrase secrète, conservé **30 jours** dans GitHub → onglet
  **Actions** → « Sauvegarde nocturne » → la dernière exécution → **Artifacts**.

### Mise en place (une seule fois, 10 minutes)

Dans GitHub : dépôt → **Settings → Secrets and variables → Actions → New repository secret**, créez :

| Secret | Où le trouver |
|---|---|
| `SUPABASE_DB_URL` | Supabase → bouton **Connect** (en haut) → **Session pooler** → copiez l'adresse `postgresql://…` et remplacez `[YOUR-PASSWORD]` par le mot de passe de la base (Project Settings → Database → *Reset database password* si vous ne l'avez plus). Utilisez bien le *Session pooler* : GitHub ne sait pas joindre l'adresse « directe ». |
| `SUPABASE_URL` | Supabase → Project Settings → API → *Project URL* |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase → Project Settings → API Keys → clé **secret** / *service_role*. Ne la mettez **jamais** ailleurs que dans ce secret. |
| `BACKUP_PASSPHRASE` | Inventez une longue phrase (au moins 5 mots) et rangez-la dans un gestionnaire de mots de passe : **sans elle, les sauvegardes sont illisibles**, même pour vous. |

Puis **Actions → Sauvegarde nocturne → Run workflow** pour tester tout de suite.

> Le dépôt est actuellement **public** : le code est visible de tous. Les sauvegardes sont chiffrées,
> mais passer le dépôt en **privé** (Settings → General → Danger Zone → Change visibility) est recommandé.

### Restaurer

1. Téléchargez l'artifact voulu, puis :
   ```sh
   gpg -d sauvegarde-AAAA-MM-JJ.tar.gz.gpg | tar -xz
   ```
   (la phrase secrète est demandée). Vous obtenez `base.sql` et le dossier `fichiers/`.
2. Base : dans un projet Supabase **neuf**,
   ```sh
   psql "<adresse Session pooler du nouveau projet>" -f base.sql
   ```
3. Fichiers :
   ```sh
   SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… node scripts/restauration-fichiers.mjs fichiers
   ```
4. Mettez à jour les variables du site sur Vercel (adresse et clé du nouveau projet) et redéployez.
