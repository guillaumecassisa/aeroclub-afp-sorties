#!/bin/sh
# Reconstruit les deux fichiers « tout-en-un » à partir des mises à jour numérotées :
#   supabase/mise-a-jour-complete.sql  (base existante : peut être relancé sans risque)
#   supabase/installation-complete.sql (nouveau club : projet Supabase vide)
# À lancer après avoir ajouté ou modifié un fichier supabase/migration-NN-….sql :
#   sh scripts/assembler-sql.sh
set -e
cd "$(dirname "$0")/../supabase"

MIGRATIONS="
migration-02-profil.sql
migration-03-lachers-par-type.sql
migration-04-bar.sql
migration-05-annuaire.sql
migration-06-propositions.sql
migration-07-poids.sql
migration-08-roles-annonces.sql
migration-09-maintenance.sql
migration-10-documents-avions.sql
migration-11-evenements.sql
migration-12-bar-sections.sql
migration-13-fonctions.sql
migration-14-mail-evenements.sql
migration-15-droits-documents.sql
migration-16-securite-rgpd.sql
migration-17-annonces-fonctions.sql
migration-18-documents-fonctions.sql
migration-19-accueil-inside.sql
migration-20-masse-centrage.sql
migration-21-documents-masse-centrage.sql
migration-22-carte-bar.sql
migration-23-bons-plans.sql
migration-24-deplacer-equipage.sql
migration-25-instructeur-referent.sql
migration-25-shop.sql
migration-26-aircraft-mb-data.sql
migration-27-shareflight.sql
migration-28-lancement.sql
migration-29-espace-pedagogique.sql
migration-30-sorties-avion.sql
migration-31-placement-organisateur.sql
migration-32-securite-sauvegarde.sql
migration-33-fiabilite.sql
"
LAST=$(echo "$MIGRATIONS" | grep . | tail -1 | sed 's/migration-\([0-9]*\).*/\1/')

body() {
  cat <<SQL
-- Base déjà en service : ses données d'exemple sont déjà en place, on ne les repose jamais.
do \$boot\$ begin
  if to_regclass('public._seeds') is null and exists (select 1 from public.profiles) then
    create table public._seeds (name text primary key, done_at timestamptz not null default now());
    insert into public._seeds (name)
    select unnest(array['bar-04', 'avions-08', 'bar-12', 'avions-19', 'liens-19', 'centrage-20', 'centrage-21',
                        'bar-22', 'bons-plans-23', 'shop-25', 'centrage-26']);
  end if;
end \$boot\$;

SQL
  for f in $MIGRATIONS; do
    printf '\n-- =====================================================================\n-- %s\n-- =====================================================================\n' "$f"
    cat "$f"
    printf '\n'
  done
  printf '\n'
  cat verification-finale.sql
}

{
  cat <<SQL
-- =====================================================================
--  MISE À JOUR COMPLÈTE (n°2 à n°$LAST) d'une base existante.
--  Peut être relancée autant de fois que nécessaire : elle n'ajoute que ce qui
--  manque et ne modifie aucune donnée saisie sur le site.
--  Supabase > SQL Editor > New query > coller tout le fichier > Run.
--  Fichier généré par scripts/assembler-sql.sh : ne pas le modifier à la main.
-- =====================================================================
SQL
  body
} > mise-a-jour-complete.sql

{
  cat <<SQL
-- =====================================================================
--  INSTALLATION COMPLÈTE d'un nouveau site (projet Supabase vide)
--  = schéma de base + toutes les mises à jour (n°2 à n°$LAST).
--  Supabase > SQL Editor > New query > coller tout le fichier > Run.
--  Ensuite (facultatif) : nouveau-club-vider-exemples.sql pour retirer
--  les données d'exemple (avions, bar, liens, bons plans, shop de l'AFPA).
--  Guide : docs/NOUVEAU-CLUB.md
--  Fichier généré par scripts/assembler-sql.sh : ne pas le modifier à la main.
-- =====================================================================

SQL
  cat schema.sql
  body
} > installation-complete.sql

echo "mise-a-jour-complete.sql et installation-complete.sql reconstruits (jusqu'à la n°$LAST)."
