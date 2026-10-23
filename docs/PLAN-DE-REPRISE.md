# Plan de reprise : que faire s'il arrive quelque chose

Le site repose sur trois services. Chacun peut être reconstruit à partir de ce dossier.

| Service | Rôle | Ce qui est perdu s'il disparaît | Comment le reconstruire |
|---|---|---|---|
| **GitHub** (code) | Le code du site, les scripts SQL, la sauvegarde nocturne | Rien si vous avez une copie du code (ce dossier, ou un clone) | Recréer un dépôt et y pousser le dossier `code-source` |
| **Supabase** (base + fichiers) | Membres, comptes, événements, bar, shop, quiz, documents, photos | **Les données** : c'est la seule partie irremplaçable | Restaurer la dernière sauvegarde (voir plus bas) |
| **Vercel** (hébergement) | Met le site en ligne | Rien : le site se redéploie à partir du code | Réimporter le dépôt, recopier les variables |

## Les sauvegardes à avoir

1. **Sauvegarde nocturne automatique** (base complète avec les comptes + tous les fichiers, chiffrée,
   30 jours) : GitHub → onglet **Actions** → « Sauvegarde nocturne ». À vérifier une fois par mois :
   la dernière exécution doit porter un fichier `sauvegarde-AAAA-MM-JJ.tar.gz.gpg` dans **Artifacts**.
   Attention : si les secrets ne sont pas configurés, l'exécution reste verte mais affiche un
   avertissement « Sauvegarde non configurée » et **ne sauvegarde rien**. Mise en place : `SAUVEGARDES.md`.
2. **Sauvegarde manuelle** : site → ⚙️ Gestion → Sauvegarde → *Télécharger la sauvegarde* (fichier
   `.json`, toutes les tables). Une fois par mois et avant toute grosse modification, rangée hors
   ligne (clé USB, coffre en ligne personnel).
3. **Une copie de ce dossier** (code complet) hors de GitHub.
4. **La phrase secrète** des sauvegardes (`BACKUP_PASSPHRASE`) et le **mot de passe de la base**
   Supabase, dans un gestionnaire de mots de passe. Sans la phrase secrète, les sauvegardes
   nocturnes sont illisibles.

Les sauvegardes contiennent des données personnelles des membres (RGPD) : stockage sûr, accès limité
aux administrateurs.

## Scénarios

### Le site affiche une erreur après une modification
1. Vercel → projet → **Deployments** → le dernier déploiement qui fonctionnait → **⋯ → Promote to
   Production** (retour arrière immédiat, sans toucher aux données).
2. Si une mise à jour SQL vient d'être exécutée, elle n'est pas en cause tant que le site précédent
   fonctionne avec : les mises à jour n'enlèvent rien.

### Des données ont été supprimées ou abîmées par erreur
1. ⚙️ Gestion → **Journal des modifications** : il trace les créations, modifications et suppressions
   (qui, quand, quelle ligne, avec le détail enregistré). Une petite erreur se corrige souvent à la
   main à partir du journal.
2. Sinon, restaurer la sauvegarde nocturne de la veille **dans un projet Supabase neuf** (jamais
   par-dessus la base en service), puis recopier les lignes perdues.

### Le projet Supabase est perdu, supprimé ou inaccessible
1. Créer un nouveau projet Supabase (région Paris).
2. Restaurer la dernière sauvegarde nocturne : `SAUVEGARDES.md`, section *Restaurer* (base avec les
   comptes, puis fichiers). Les membres gardent leur mot de passe.
3. À défaut de sauvegarde nocturne : exécuter `supabase/installation-complete.sql` (structure +
   banque de questions), faire recréer leur compte aux membres, puis reprendre les données du dernier
   fichier `.json` de sauvegarde manuelle (reprise manuelle, table par table : prévoir l'aide d'une
   personne à l'aise avec SQL). C'est beaucoup plus long : d'où l'importance de la sauvegarde nocturne.
4. Vercel → Settings → Environment Variables : nouvelle adresse et nouvelle clé du projet, puis
   **Redeploy**. Supabase → Authentication → URL Configuration et Email Templates : comme dans
   `NOUVEAU-CLUB.md`, étape 2.

### Le compte GitHub ou le dépôt est perdu
1. Créer un nouveau dépôt **privé** et y pousser le dossier `code-source` de ce dossier.
2. Vercel → projet → Settings → Git : reconnecter le nouveau dépôt.
3. Recréer les 4 secrets de la sauvegarde nocturne (`SAUVEGARDES.md`).

### Le compte Vercel est perdu
1. Nouveau compte Vercel → **Add New → Project** → importer le dépôt.
2. Recopier les variables d'environnement (liste dans `FICHE-PROJET.md`).
3. Supabase → Authentication → URL Configuration : nouvelle adresse du site.

### Plus aucun administrateur ne peut se connecter
Supabase → SQL Editor :
```sql
update public.profiles set role = 'admin' where email = 'adresse@du-nouvel-admin.fr';
```

### Une clé secrète a fuité (clé *service_role*, mot de passe de la base)
1. Supabase → Project Settings → API Keys : générer une nouvelle clé secrète et révoquer l'ancienne ;
   Database → *Reset database password*.
2. Mettre à jour les secrets GitHub `SUPABASE_SERVICE_ROLE_KEY` / `SUPABASE_DB_URL`.
3. La clé *publishable* du site n'est pas secrète : rien à faire côté Vercel.

## Vérification mensuelle (5 minutes)

- [ ] GitHub → Actions → « Sauvegarde nocturne » : la dernière exécution a bien un fichier dans **Artifacts**
- [ ] ⚙️ Gestion → Sauvegarde → télécharger le `.json` et le ranger hors ligne
- [ ] Supabase → tableau de bord : pas d'alerte de quota (base < 500 Mo, fichiers < 1 Go en offre gratuite)
- [ ] Une fois par an : tester une restauration dans un projet Supabase de test
