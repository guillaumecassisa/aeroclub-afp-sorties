-- =====================================================================
--  Mise à jour n°23 : carte des « bons plans » sur les aérodromes
--  (restaurants, avitaillement, hébergement, visites…). Chaque membre
--  validé peut en ajouter ; l'auteur ou un administrateur peut le modifier
--  ou le retirer (archivage : rien n'est effacé).
-- =====================================================================
create table if not exists public.airfield_tips (
  id            uuid primary key default gen_random_uuid(),
  icao          text not null check (icao ~ '^[A-Z]{2}[A-Z0-9]{2}$'),
  airfield_name text not null check (length(btrim(airfield_name)) between 1 and 80),
  lat           numeric(8,5) not null check (lat between -90 and 90),
  lon           numeric(8,5) not null check (lon between -180 and 180),
  category      text not null default 'resto' check (category in ('resto','avitaillement','hebergement','visite','autre')),
  title         text not null check (length(btrim(title)) between 1 and 80),
  description   text check (description is null or length(description) <= 1000),
  on_field      boolean not null default true,
  contact       text check (contact is null or (length(contact) <= 200 and (contact ~* '^https?://' or contact ~ '^[0-9 +().-]{6,25}$'))),
  created_by    uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  archived_at   timestamptz
);
create index if not exists airfield_tips_icao on public.airfield_tips (icao) where archived_at is null;
alter table public.airfield_tips enable row level security;
revoke truncate on public.airfield_tips from public, anon, authenticated;

drop policy if exists airfield_tips_select on public.airfield_tips;
create policy airfield_tips_select on public.airfield_tips for select to authenticated using (public.is_approved());
drop policy if exists airfield_tips_insert on public.airfield_tips;
create policy airfield_tips_insert on public.airfield_tips for insert to authenticated
  with check (public.is_approved() and created_by = auth.uid() and archived_at is null);
drop policy if exists airfield_tips_update on public.airfield_tips;
create policy airfield_tips_update on public.airfield_tips for update to authenticated
  using (public.is_approved() and (created_by = auth.uid() or public.app_role() = 'admin'))
  with check (public.is_approved() and (created_by = auth.uid() or public.app_role() = 'admin'));
-- pas de suppression : on archive (archived_at)
revoke delete on public.airfield_tips from authenticated, anon;

drop trigger if exists zz_audit on public.airfield_tips;
create trigger zz_audit after insert or update on public.airfield_tips
  for each row execute function public._audit();

-- Premier bon plan (repris d'Inside)
insert into public.airfield_tips (icao, airfield_name, lat, lon, category, title, description, on_field, contact, created_by)
select 'LFTF', 'Cuers-Pierrefeu', 43.2476, 6.1267, 'resto', 'Le Saint Tex',
       'Un restaurant sympathique sur l''AD avec une carte restreinte composée de plats traditionnels faits maison (tartare, pâtes carbonara, entrecôte-frites).',
       true, 'https://www.facebook.com/lesainttex/', null
where not exists (select 1 from public.airfield_tips where icao = 'LFTF' and title = 'Le Saint Tex');

notify pgrst, 'reload schema';
