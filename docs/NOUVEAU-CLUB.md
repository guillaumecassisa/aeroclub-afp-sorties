# Installer le site pour un nouvel aéroclub

Compter environ **1 heure**. Tout est gratuit (offres gratuites Supabase, Vercel, GitHub).
Aucune ligne de code à modifier : tout ce qui est propre au club se règle par des variables
ou depuis le site lui-même.

## 1. Copier le projet

1. GitHub → **Use this template** ou **Fork** (ou téléchargez le ZIP et créez un nouveau dépôt).
2. Mettez le dépôt en **privé** (Settings → General → Danger Zone → Change visibility).

## 2. Créer la base de données (Supabase)

1. [supabase.com](https://supabase.com) → **New project**, région *West EU (Paris)*. Notez le mot de passe de la base.
2. **SQL Editor → New query** → collez tout `supabase/installation-complete.sql` → **Run**.
   Le dernier message liste les vérifications : tout doit être `OK`.
3. Nouvelle requête → collez `supabase/nouveau-club-vider-exemples.sql` → **Run**
   (retire les avions, la carte du bar, les liens et les articles d'exemple).
4. **Authentication → Email Templates** :
   - *Confirm signup* : lien `{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=email`
   - *Reset password* : lien `{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=recovery`
5. **Authentication → Sign In / Providers → Email** : si votre offre le permet, activez *Leaked password protection* (refuse les mots de passe déjà piratés ; réservé aux offres payantes de Supabase).
6. **Authentication → SMTP Settings** : branchez un SMTP (Gmail ou Resend), sinon Supabase n'envoie que quelques emails par heure.
7. **Project Settings → API Keys** : notez l'URL du projet et la clé *publishable*.

## 3. Mettre le site en ligne (Vercel)

1. [vercel.com](https://vercel.com) → **Add New → Project** → importez le dépôt.
2. **Environment Variables** : recopiez `.env.example` et remplissez au minimum :
   `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `NEXT_PUBLIC_SITE_URL`,
   `NEXT_PUBLIC_CLUB_NAME`, `NEXT_PUBLIC_HOME_ICAO`, `NEXT_PUBLIC_HOME_AIRFIELD`,
   `QNH_STATIONS`, `TAF_STATIONS`, `NOTAM_LOCATIONS`, et les variables email.
3. **Deploy**, puis Supabase → **Authentication → URL Configuration** :
   *Site URL* = adresse du site ; *Redirect URLs* : `https://VOTRE-SITE/auth/confirm`.

## 4. Personnaliser

| Quoi | Où |
|---|---|
| Logo | remplacer `public/logo.png` (carré, fond transparent) |
| Couleurs | `app/globals.css`, lignes `--color-…` en haut du fichier |
| Calculateur de performances | `public/outils/performances.html` contient les données des avions de l'AFPA : remplacez-les par celles de vos appareils, ou retirez le lien |
| Nom, adresse, directeur de publication | site → ⚙️ Gestion → Informations du club (mentions légales) |
| Avions, masse et centrage, documents | site → ⚙️ Gestion → Flotte (maintenance) / Importer des documents |
| Carte du bar | site → ⚙️ Gestion → Trésorerie du bar |
| Articles du shop | site → ⚙️ Gestion → Shop (gestion) |
| Liens utiles (Préparer son vol) | site → ⚙️ Gestion → Liens utiles |
| Questions du quiz : environ 875 questions générales sont fournies (3 par jour) ; celles sur LFMA et sur la flotte de l'AFPA sont retirées par `nouveau-club-vider-exemples.sql`, écrivez celles de votre terrain et de vos avions | site → ⚙️ Gestion → Questions du quiz (chef pilote, resp. conformité ou admin). Les sources sont dans `supabase/quiz-source/` (`python3 supabase/quiz-source/build.py supabase/migration-34-quiz.sql` régénère la mise à jour) |
| Types d'avions proposés pour les lâchers | automatique : ce sont les types des avions de votre flotte |

## 5. Premier administrateur

1. Sur le site : **Créer un compte**, confirmez l'email.
2. Supabase → SQL Editor :
   ```sql
   update public.profiles set role = 'admin' where email = 'votre@email.fr';
   ```
3. Reconnectez-vous : **⚙️ Gestion → Membres et droits** permet ensuite de valider les comptes
   et de donner les fonctions (instructeur, trésorier, secrétaire, maintenance,
   chef pilote, responsable conformité).

## 6. Sauvegardes

Suivez `docs/SAUVEGARDES.md` (10 minutes) : sauvegarde nocturne chiffrée par GitHub, plus le
bouton de téléchargement manuel dans ⚙️ Gestion → Sauvegarde.

## 7. Mises à jour

Quand le projet d'origine évolue, récupérez les changements dans votre dépôt, puis exécutez dans
Supabase le ou les nouveaux fichiers `supabase/migration-NN-….sql` **avant** de redéployer le site.
`supabase/mise-a-jour-complete.sql` peut aussi être rejoué en entier : il n'ajoute que ce qui manque,
ne recrée jamais les données d'exemple de l'AFPA et ne modifie rien de ce qui a été saisi sur le site.
