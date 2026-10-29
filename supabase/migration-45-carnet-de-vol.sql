-- =====================================================================
--  Mise à jour n°45 : carnet de vol personnel
--  Chaque membre tient son carnet de vol (colonnes du carnet EASA, FCL.050) :
--  vols, report des heures antérieures, date d'échéance de sa qualification SEP.
--  Strictement personnel : seul le pilote voit et modifie ses lignes (pas même
--  les administrateurs). Effacé avec les autres données du membre (RGPD).
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Les lignes du carnet (durées en minutes)
create table if not exists public.logbook_entries (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind            text not null default 'vol' check (kind in ('vol', 'report')),
  flight_date     date not null,
  dep_place       text check (dep_place is null or length(dep_place) <= 40),
  dep_time        time,
  arr_place       text check (arr_place is null or length(arr_place) <= 40),
  arr_time        time,
  aircraft_model  text check (aircraft_model is null or length(aircraft_model) <= 40),
  aircraft_reg    text check (aircraft_reg is null or length(aircraft_reg) <= 20),
  se_min          integer not null default 0 check (se_min between 0 and 600000),
  me_min          integer not null default 0 check (me_min between 0 and 600000),
  multi_pilot_min integer not null default 0 check (multi_pilot_min between 0 and 600000),
  total_min       integer not null default 0 check (total_min between 0 and 600000),
  pic_name        text check (pic_name is null or length(pic_name) <= 80),
  landings_day    integer not null default 0 check (landings_day between 0 and 100000),
  landings_night  integer not null default 0 check (landings_night between 0 and 100000),
  ifr_approaches  integer not null default 0 check (ifr_approaches between 0 and 100000),
  night_min       integer not null default 0 check (night_min between 0 and 600000),
  ifr_min         integer not null default 0 check (ifr_min between 0 and 600000),
  pic_min         integer not null default 0 check (pic_min between 0 and 600000),
  copilot_min     integer not null default 0 check (copilot_min between 0 and 600000),
  dual_min        integer not null default 0 check (dual_min between 0 and 600000),
  instructor_min  integer not null default 0 check (instructor_min between 0 and 600000),
  sim_type        text check (sim_type is null or length(sim_type) <= 40),
  sim_min         integer not null default 0 check (sim_min between 0 and 600000),
  remarks         text check (remarks is null or length(remarks) <= 500),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists logbook_entries_user_date on public.logbook_entries (user_id, flight_date desc, dep_time desc nulls last);
alter table public.logbook_entries enable row level security;
revoke all on public.logbook_entries from anon, authenticated;
grant select, insert, update, delete on public.logbook_entries to authenticated;

drop policy if exists logbook_own_select on public.logbook_entries;
create policy logbook_own_select on public.logbook_entries for select to authenticated
  using (user_id = auth.uid() and public.is_approved());
drop policy if exists logbook_own_insert on public.logbook_entries;
create policy logbook_own_insert on public.logbook_entries for insert to authenticated
  with check (user_id = auth.uid() and public.is_approved());
drop policy if exists logbook_own_update on public.logbook_entries;
create policy logbook_own_update on public.logbook_entries for update to authenticated
  using (user_id = auth.uid() and public.is_approved())
  with check (user_id = auth.uid());
drop policy if exists logbook_own_delete on public.logbook_entries;
create policy logbook_own_delete on public.logbook_entries for delete to authenticated
  using (user_id = auth.uid() and public.is_approved());

-- 2. Réglages du carnet (échéance de la qualification de classe SEP)
create table if not exists public.logbook_settings (
  user_id     uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  sep_expiry  date,
  updated_at  timestamptz not null default now()
);
alter table public.logbook_settings enable row level security;
revoke all on public.logbook_settings from anon, authenticated;
grant select, insert, update, delete on public.logbook_settings to authenticated;
drop policy if exists logbook_settings_own on public.logbook_settings;
create policy logbook_settings_own on public.logbook_settings for all to authenticated
  using (user_id = auth.uid() and public.is_approved())
  with check (user_id = auth.uid());

-- 3. Anonymisation d'un membre : son carnet part avec ses données
do $$
declare d text;
begin
  select pg_get_functiondef('public._anonymize_profile(uuid)'::regprocedure) into d;
  if position('logbook_entries' in d) = 0 then
    d := replace(d, 'delete from public.pilot_types where user_id = p_user;',
                    'delete from public.pilot_types where user_id = p_user;' || E'\n  delete from public.logbook_entries where user_id = p_user;\n  delete from public.logbook_settings where user_id = p_user;');
    if position('logbook_entries' in d) = 0 then raise exception '_anonymize_profile : emplacement introuvable'; end if;
    execute d;
  end if;
end $$;

-- Vérification
select 'MISE A JOUR 45 OK' as resultat,
       to_regclass('public.logbook_entries') is not null as table_carnet,
       to_regclass('public.logbook_settings') is not null as table_reglages;
