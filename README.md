# Site de l'aéroclub

Site web privé d'un aéroclub : événements et sorties avion, espace pédagogique, préparation des vols,
flotte et documents, bar et shop, annuaire, quiz… Conçu pour être **réutilisable par un autre club**
sans toucher au code : voir **[docs/NOUVEAU-CLUB.md](docs/NOUVEAU-CLUB.md)**.

Technologies : Next.js 16 (Vercel) + Supabase (PostgreSQL, comptes, fichiers). Offres gratuites suffisantes.

## Fonctions

| Rubrique | Ce qu'on y fait |
|---|---|
| Accueil | Annonces, prochains événements, météo/QNH, statistiques, 3 questions du jour (QCM) |
| Événements | Sorties avion, activités, événements conviviaux, formations. Inscription, liste d'attente automatique, accompagnants (+1, jusqu'à 5 pour un événement), placement dans les avions qui respecte les lâchers, glisser-déposer pour l'organisateur, emails |
| Espace pédagogique | Annonces et documents du chef pilote / responsable conformité, retours d'expérience (REX, anonymisables), séances de formation |
| Préparer son vol | Météo, TAF, NOTAM, liens utiles, calcul de performances, masse et centrage |
| Flotte | Avions, disponibilité, documents (manuels, check-lists, pesées) |
| Bar | Ardoise personnelle, classement, trésorerie mensuelle |
| Le shop | Boutique du club, commandes |
| Annuaire, Bons plans, Shareflight, Quiz | Entraide entre membres |
| ⚙️ Gestion | Regroupe les outils de chacun selon ses fonctions (droits, infos du club, journal, sauvegarde, trésorerie, stats, maintenance…) |

## Rôles et fonctions

- **En attente** : compte créé, pas encore validé par un administrateur.
- **Membre** : s'inscrit aux événements, propose des événements (validés par un instructeur ou un admin), consomme au bar, commande au shop.
- **Instructeur** : organise des sorties, valide les propositions, compte comme « instructeur à bord » (permet d'emmener un membre non lâché sur le type).
- **Administrateur** (et **secrétaire**, qui en a les droits) : validation des comptes, fonctions, gestion du shop, sauvegarde.
- Fonctions cumulables : **trésorier** (bar de tous, stats), **resp. maintenance** (flotte, masse et centrage),
  **chef pilote** et **responsable conformité** (espace pédagogique, REX, quiz). Toute fonction permet de publier des événements.

Le détail action par action : **[docs/DROITS.md](docs/DROITS.md)**.

Toutes les règles (places, liste d'attente, lâchers, droits) sont appliquées **dans la base de données**
(règles RLS et fonctions sécurisées) : contourner le site ne permet pas de les enfreindre.

## Installation

Pas à pas complet : **[docs/NOUVEAU-CLUB.md](docs/NOUVEAU-CLUB.md)**. En résumé :

1. Supabase : exécuter `supabase/installation-complete.sql`, puis `supabase/nouveau-club-vider-exemples.sql`.
2. Vercel : importer le dépôt, renseigner les variables de `.env.example`.
3. Créer son compte puis se nommer administrateur (une requête SQL).

Mise à jour d'une installation existante : exécuter dans Supabase les nouveaux fichiers
`supabase/migration-NN-….sql` **avant** de déployer le site (ou `supabase/mise-a-jour-complete.sql`,
qui peut être relancé sans risque : il ne recrée aucune donnée d'exemple et ne modifie rien de ce
qui a été saisi sur le site).

Développeurs : après avoir ajouté ou modifié une migration, reconstruire les deux fichiers
« tout-en-un » avec `sh scripts/assembler-sql.sh`, puis lancer les tests de la base avec
`sh tests/run.sh` (PostgreSQL local).

## Sauvegardes

**[docs/SAUVEGARDES.md](docs/SAUVEGARDES.md)** : téléchargement manuel depuis le site, et sauvegarde
nocturne chiffrée (base + fichiers) par GitHub Actions, avec la procédure de restauration.
**[docs/PLAN-DE-REPRISE.md](docs/PLAN-DE-REPRISE.md)** : que faire en cas de panne, de perte ou de fuite.
**[docs/FICHE-PROJET.md](docs/FICHE-PROJET.md)** : services utilisés, organisation du code, variables, historique.
**[docs/HEBERGEMENT.md](docs/HEBERGEMENT.md)** : mettre le site à l'adresse du club (Vercel + domaine OVH, ou serveur VPS avec `deploy/vps/`).

## Développement

```bash
npm install
cp .env.example .env.local   # puis renseignez les valeurs
npm run dev                  # http://localhost:3000
sh tests/run.sh              # tests SQL sur un PostgreSQL local (logique des places, droits par rôle…)
```

## Structure

```
supabase/                  Schéma, migrations numérotées, installation complète
app/                       Pages (une par rubrique) et actions serveur
components/                Éléments d'interface partagés
lib/                       Accès aux données, droits (auth.ts), emails, météo, paramètres du club (club.ts)
public/outils/             Calculateur de performances
scripts/                   Sauvegarde / restauration des fichiers, assemblage des fichiers SQL
tests/                     Tests SQL
docs/                      Droits, nouveau club, sauvegardes, plan de reprise, fiche projet
```
