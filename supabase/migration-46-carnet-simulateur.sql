-- =====================================================================
--  Mise à jour n°46 : carnet de vol — date de la séance de simulateur
--  Colonne « Séances de simulateur : Date / Type / Durée » du carnet EASA.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================
alter table public.logbook_entries add column if not exists sim_date date;

select 'MISE A JOUR 46 OK' as resultat,
       exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'logbook_entries' and column_name = 'sim_date') as colonne_sim_date;
