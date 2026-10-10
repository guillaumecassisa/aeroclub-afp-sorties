-- =====================================================================
--  Mise à jour n°20 : masse et centrage par avion (d'après le manuel de vol
--  et la dernière fiche de pesée). Lecture : tous les membres validés.
--  Modification : administrateurs et responsables maintenance.
-- =====================================================================
create table if not exists public.aircraft_mb (
  aircraft_id     uuid primary key references public.aircraft (id) on delete cascade,
  serial          text,                               -- n° de série
  empty_mass      numeric(7,2) check (empty_mass is null or empty_mass > 0),      -- masse à vide (kg)
  empty_moment    numeric(9,3),                        -- moment à vide (kg.m)
  mtow            numeric(7,2) check (mtow is null or mtow > 0),                  -- masse max décollage (kg)
  mlw             numeric(7,2) check (mlw is null or mlw > 0),                    -- masse max atterrissage (kg), facultatif
  fuel_arm        numeric(6,3),                        -- bras du carburant (m)
  fuel_density    numeric(4,3) not null default 0.72 check (fuel_density between 0.5 and 1),
  fuel_capacity_l numeric(6,1) check (fuel_capacity_l is null or fuel_capacity_l > 0),
  stations        jsonb not null default '[]'::jsonb,  -- [{label, arm, max}]
  envelope        jsonb not null default '[]'::jsonb,  -- [{arm, mass}] polygone du domaine de centrage
  source          text,                                -- ex. « Manuel de vol rév. 3 — pesée du 12/03/2025 »
  updated_at      timestamptz not null default now(),
  updated_by      uuid references public.profiles (id) on delete set null default auth.uid()
);
alter table public.aircraft_mb enable row level security;
revoke truncate on public.aircraft_mb from public, anon, authenticated;

drop policy if exists aircraft_mb_select on public.aircraft_mb;
create policy aircraft_mb_select on public.aircraft_mb for select to authenticated using (public.is_approved());
drop policy if exists aircraft_mb_insert on public.aircraft_mb;
create policy aircraft_mb_insert on public.aircraft_mb for insert to authenticated with check (public.can_manage_fleet());
drop policy if exists aircraft_mb_update on public.aircraft_mb;
create policy aircraft_mb_update on public.aircraft_mb for update to authenticated
  using (public.can_manage_fleet()) with check (public.can_manage_fleet());
-- pas de suppression : on corrige les valeurs

drop trigger if exists zz_audit on public.aircraft_mb;
create trigger zz_audit after insert or update on public.aircraft_mb
  for each row execute function public._audit();

-- Pré-remplissage F-HSAA (valeurs relevées dans l'outil Inside AFPA : masse et moment à vide,
-- postes de chargement, MTOW). Le bras carburant et le domaine de centrage restent à saisir
-- depuis le manuel de vol avant que le calcul soit disponible.
insert into public.aircraft_mb (aircraft_id, serial, empty_mass, empty_moment, mtow, stations, source)
select a.id, 'C0502', 393.5, 169.8, 600,
       '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages coffre AR","arm":1.31,"max":18}]'::jsonb,
       'Repris de l''outil Inside AFPA — à compléter (bras carburant, domaine de centrage)'
from public.aircraft a
where a.registration = 'F-HSAA'
  and not exists (select 1 from public.aircraft_mb m where m.aircraft_id = a.id);

notify pgrst, 'reload schema';
