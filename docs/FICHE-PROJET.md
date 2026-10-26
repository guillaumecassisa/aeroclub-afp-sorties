# Fiche projet

Carte d'identité technique du site, pour la personne qui reprend le projet ou le duplique.
Aucun mot de passe ni clé secrète n'est écrit ici : ils se trouvent dans les services eux-mêmes
et dans le gestionnaire de mots de passe de l'administrateur.

## Services en service pour l'AFPA

| Service | Élément | Valeur |
|---|---|---|
| GitHub | Dépôt | `guillaumecassisa/aeroclub-afp-sorties` — branche `main` = site en ligne |
| Vercel | Projet | `aeroclub-afpa` (équipe *perso13*), adresse `https://aeroclub-afp-sorties.vercel.app` |
| Supabase | Projet | `supabase-camel-ferry`, identifiant `hxapzevgenqnjswwgkum`, région Paris (eu-west-3), PostgreSQL 17 |
| Supabase | Facturation | Projet créé depuis Vercel (intégration *Vercel Marketplace*) : il se gère aussi depuis Vercel → Storage |

Volumes au 23/10/2026 : base 15 Mo, 30 tables ; fichiers ≈ 170 Mo (documents des avions 154 Mo,
documents 14 Mo, photos de profil). Largement dans les offres gratuites (500 Mo de base, 1 Go de fichiers).

## Technologies

- **Next.js 16** (App Router, React 19, server actions) hébergé sur **Vercel**. Tailwind CSS v4.
- **Supabase** : PostgreSQL (toutes les règles métier et de droits sont dans la base : RLS + fonctions
  `security definer`), authentification par email, stockage des fichiers.
- Emails : SMTP (Gmail) ou Resend. Météo, TAF : aviationweather.gov ; NOTAM : FAA (notams.aim.faa.gov).
- Export Excel : `exceljs`.

## Organisation du code

| Dossier | Contenu |
|---|---|
| `app/` | Une page par rubrique (`sorties`, `pedagogie`, `bar`, `shop`, `flotte`, `quiz`, `droits`, `sauvegarde`…) ; chaque `actions.ts` contient les actions serveur de la rubrique |
| `components/` | Éléments d'interface partagés (formulaire d'événement, météo, quiz, avatars…) |
| `lib/` | Droits (`auth.ts`), dates (heure de Paris), emails, masse et centrage, météo, shop, quiz |
| `proxy.ts` | Contrôle d'accès : toute page hors connexion / inscription exige d'être connecté |
| `public/` | Logo, outils HTML (calculateur de performances) |
| `supabase/` | Base de données : `installation-complete.sql` (nouvelle installation), `mise-a-jour-complete.sql` (rejouable), `migration-NN-….sql` (historique, dans l'ordre), `verification-finale.sql`, `nouveau-club-vider-exemples.sql`, `quiz-source/` (sources de la banque de questions) |
| `scripts/` | `assembler-sql.sh` (reconstruit les fichiers SQL complets), sauvegarde / restauration des fichiers |
| `tests/` | Tests de la base (droits, inscriptions, placement, bar, shop, quiz…) : `sh tests/run.sh` sur un PostgreSQL local |
| `.github/workflows/sauvegarde.yml` | Sauvegarde nocturne chiffrée |
| `deploy/vps/` | Installation et mise à jour du site sur un serveur VPS (voir `HEBERGEMENT.md`) |
| `docs/` | Ce dossier de documentation |

## Variables d'environnement (Vercel → Settings → Environment Variables)

Modèle complet commenté : `.env.example`.

| Variable | Obligatoire | Rôle |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | oui | Adresse du projet Supabase |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (ou `…_ANON_KEY`) | oui | Clé publique Supabase (non secrète) |
| `NEXT_PUBLIC_SITE_URL` | oui | Adresse du site (liens dans les emails) |
| `NEXT_PUBLIC_CLUB_NAME` | oui | Nom du club |
| `NEXT_PUBLIC_HOME_ICAO`, `NEXT_PUBLIC_HOME_AIRFIELD` | oui | Terrain de base |
| `QNH_STATIONS`, `TAF_STATIONS`, `NOTAM_LOCATIONS` | oui | Stations météo et NOTAM |
| `SMTP_USER`, `SMTP_PASS`, `SMTP_HOST`, `SMTP_PORT` ou `RESEND_API_KEY` | non | Envoi des emails |
| `EMAIL_FROM` | non | Expéditeur des emails |

Secrets GitHub (sauvegarde nocturne uniquement, jamais dans Vercel) : `SUPABASE_DB_URL`,
`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `BACKUP_PASSPHRASE`.

## Faire évoluer le site

1. Modifier le code sur une branche, vérifier : `npx tsc --noEmit`, `npx next build`, `sh tests/run.sh`.
2. Toute modification de la base = un nouveau fichier `supabase/migration-NN-….sql` **rejouable sans
   risque**, ajouté à `scripts/assembler-sql.sh` (puis `sh scripts/assembler-sql.sh`) et à
   `tests/run.sh` avec son test.
3. Exécuter la migration dans Supabase (SQL Editor) **avant** de fusionner dans `main` : Vercel
   déploie automatiquement `main`.
4. Une règle de droits change → mettre à jour `docs/DROITS.md`.

## Historique des mises à jour de la base

| N° | Objet |
|---|---|
| 02–08 | Profil, lâchers par type d'avion, bar, annuaire, propositions d'événements, poids, rôles et annonces |
| 09–15 | Maintenance de la flotte, documents des avions, événements de tous types, sections du bar, fonctions du club, emails d'événements, droits sur les documents |
| 16–19 | Sécurité et RGPD (journal, anonymisation), annonces et documents par fonction, accueil |
| 20–27 | Masse et centrage, carte du bar, bons plans terrains, déplacement des équipages, shop, partage de vols |
| 28–33 | Lancement (quiz, accompagnants), espace pédagogique, sorties avion et lâchers, placement par l'organisateur, sécurité et sauvegarde, fiabilité |
| 34–35 | Quiz : 3 questions par jour, banque de plus de 1 000 questions, questions sur la flotte |
| 36 | Shop : stock, prix d'achat, date de vente, tableau de bord |
| 37 | Quiz : tirage du jour figé, 3 réponses maximum par jour |
| 38 | Événements : projets sans date |
| 39 | Comptes : suppression de l'identifiant de connexion (fiche anonymisée, historique conservé) |
| 40 | Shop : mode « Bientôt disponible » (commandes bloquées) |
| 41 | Événements : affiche (photo) |
| 42 | Quiz : questions sur le règlement intérieur de l'AFPA |
| 43 | Bar : gestion (noms et emails des membres ayant une ardoise, pour les relances) |
| 44 | Shareflight : photos de vol |
