# Aéroclub — Organisation des sorties

Site web pour organiser les sorties du club :

- **Comptes membres** : chacun crée son compte (email + mot de passe). Un administrateur le valide avant qu'il puisse s'inscrire.
- **Instructeurs** : créent les sorties et y affectent un ou plusieurs avions de la flotte (4 places ou 2 places). Ils indiquent s'ils volent eux-mêmes : dans ce cas leur siège est retiré des places ouvertes aux membres.
- **Inscriptions et liste d'attente** : les places sont attribuées dans l'ordre d'inscription. Exemple : 2 × DR400 (4 places) + 1 × WT9 (2 places) = 10 places ; les 10 premiers inscrits sont confirmés et répartis dans les avions, les suivants passent en liste d'attente.
- **Désistement** : le premier de la liste d'attente prend la place automatiquement et reçoit un email.
- **Modification d'une sortie** : si un instructeur retire un avion ou décide de voler lui-même, les derniers inscrits repassent en tête de liste d'attente (prévenus par email). Si des places sont ajoutées, la liste d'attente avance toute seule.
- **Annulation d'une sortie** : tous les inscrits sont prévenus par email.

Technologies : Next.js 16 (hébergé sur Vercel) + Supabase (base PostgreSQL, comptes). Il existe des offres gratuites pour les deux, largement suffisantes pour un club.

---

## Rôles

| Rôle | Ce qu'il peut faire |
|---|---|
| En attente | Rien : il attend qu'un administrateur valide son compte |
| Membre | Voir les sorties, s'inscrire, se désinscrire |
| Instructeur | + créer/modifier/annuler des sorties, gérer la flotte, inscrire ou retirer un membre, voir les téléphones des membres |
| Administrateur | + valider les comptes et changer les rôles (page **Membres**) |

Toutes les règles (places, liste d'attente, droits) sont appliquées **dans la base de données** : un membre ne peut ni s'attribuer une place, ni changer son rôle, même en contournant le site. Deux inscriptions simultanées sur la dernière place sont traitées l'une après l'autre (pas de surréservation).

---

## Mise en ligne (≈ 30 minutes)

### 1. Supabase : la base de données et les comptes

1. Créez un compte sur [supabase.com](https://supabase.com), puis **New project** (région conseillée : *West EU (Paris)*).
2. Menu **SQL Editor** → **New query** → collez tout le contenu de `supabase/schema.sql` → **Run**, puis faites de même avec `supabase/migration-02-profil.sql` (photos, coordonnées, lâchers).
3. Menu **Project Settings → API Keys** (ou **Data API**) : notez l'**URL du projet** et la **clé publishable** (ou « anon »).
4. Menu **Authentication → Email Templates** :
   - modèle **Confirm signup** : remplacez le lien par
     `{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=email`
   - modèle **Reset password** : remplacez le lien par
     `{{ .SiteURL }}/auth/confirm?token_hash={{ .TokenHash }}&type=recovery`

   (Les textes des emails peuvent être traduits en français au passage.)
5. **Recommandé** : le service email intégré de Supabase n'envoie que quelques emails par heure. Dans **Authentication → SMTP Settings**, branchez un vrai serveur SMTP (Resend, voir étape 3, fournit un SMTP gratuit).

### 2. Vercel : le site

1. Mettez ce dossier sur un dépôt GitHub (privé de préférence).
2. Sur [vercel.com](https://vercel.com) → **Add New → Project** → importez le dépôt.
3. Dans **Environment Variables**, ajoutez (modèle dans `.env.example`) :

   | Variable | Valeur |
   |---|---|
   | `NEXT_PUBLIC_SUPABASE_URL` | URL du projet Supabase |
   | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | clé publishable (ou anon) |
   | `NEXT_PUBLIC_SITE_URL` | l'adresse du site, ex. `https://sorties-aeroclub.vercel.app` |
   | `NEXT_PUBLIC_CLUB_NAME` | le nom affiché, ex. `Aéroclub de Provence` |
   | `RESEND_API_KEY` | (étape 3) |
   | `EMAIL_FROM` | (étape 3), ex. `Aéroclub <sorties@mon-club.fr>` |

4. **Deploy**. Vous pouvez ensuite brancher votre propre nom de domaine (Settings → Domains).
5. Retour dans Supabase → **Authentication → URL Configuration** :
   - **Site URL** = l'adresse du site
   - **Redirect URLs** : ajoutez `https://VOTRE-SITE/auth/confirm`

### 3. Emails de liste d'attente (Resend)

1. Créez un compte sur [resend.com](https://resend.com) (gratuit jusqu'à 3 000 emails/mois).
2. **Domains** → ajoutez le domaine du club et les enregistrements DNS indiqués (sans domaine vérifié, Resend ne peut écrire qu'à votre propre adresse).
3. **API Keys** → créez une clé → mettez-la dans `RESEND_API_KEY` sur Vercel, et l'expéditeur dans `EMAIL_FROM`. Redéployez.

Sans ces deux variables, le site fonctionne normalement mais n'envoie pas les emails de promotion/annulation (la liste d'attente avance quand même).

### 4. Premier administrateur

1. Sur le site, créez votre compte (**Créer un compte**) et confirmez votre email.
2. Dans Supabase → **SQL Editor**, exécutez (avec votre email) :
   ```sql
   update public.profiles set role = 'admin' where email = 'votre@email.fr';
   ```
3. Reconnectez-vous : la page **Membres** apparaît. Validez les comptes des membres et désignez les instructeurs depuis cette page.
4. Un instructeur ajoute les avions dans **Flotte**, puis crée la première sortie.

---

## Développement local

```bash
npm install
cp .env.example .env.local   # puis renseignez les valeurs
npm run dev                  # http://localhost:3000
```

### Tests de la logique

`tests/` contient des tests SQL (inscriptions, liste d'attente, désistements, retrait d'avion, instructeur à bord, dates limites, droits d'accès). Ils se lancent sur un PostgreSQL local :

```bash
sh tests/run.sh
```

## Structure

```
supabase/schema.sql        Tables, règles de sécurité et toute la logique des places
app/page.tsx               Liste des sorties
app/sorties/[id]/          Détail, inscription, gestion par l'instructeur
app/sorties/nouvelle/      Création (instructeurs)
app/flotte/                Gestion des avions (instructeurs)
app/membres/               Validation des comptes et rôles
app/compte/                Profil et mot de passe
lib/email.ts               Emails (Resend)
```
