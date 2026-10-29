-- =====================================================================
--  Mise à jour n°47 : carnet de vol — licence du pilote
--  Type de licence (PPL(A) ou LAPL(A)), numéro, date de délivrance et
--  qualification de vol de nuit : le récapitulatif applique les conditions
--  de maintien des privilèges propres à chaque licence.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================
alter table public.logbook_settings add column if not exists licence_type text not null default 'PPL';
alter table public.logbook_settings add column if not exists licence_number text;
alter table public.logbook_settings add column if not exists licence_issued date;
alter table public.logbook_settings add column if not exists night_rating boolean not null default false;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'logbook_settings_licence_type_check') then
    alter table public.logbook_settings add constraint logbook_settings_licence_type_check check (licence_type in ('PPL', 'LAPL'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'logbook_settings_licence_number_check') then
    alter table public.logbook_settings add constraint logbook_settings_licence_number_check check (licence_number is null or length(licence_number) <= 40);
  end if;
end $$;

select 'MISE A JOUR 47 OK' as resultat,
       exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'logbook_settings' and column_name = 'licence_type') as colonne_licence;
