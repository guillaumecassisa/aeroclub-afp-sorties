-- =====================================================================
--  Mise à jour n°27 : Shareflight — covoiturage aérien entre membres
--
--  Un pilote publie un projet de vol (départ, destination, date,
--  places libres, commentaire) ; d'autres membres peuvent s'inscrire
--  comme passagers. Le pilote ou un admin peut clore ou annuler le vol.
--  Les passagers peuvent se désinscrire tant que le vol n'est pas clôturé.
-- =====================================================================

-- Table principale : propositions de vols
create table if not exists public.flight_shares (
  id            uuid primary key default gen_random_uuid(),
  pilot_id      uuid not null references public.profiles (id) on delete cascade default auth.uid(),
  -- Aérodrome départ
  dep_icao      text not null check (dep_icao ~ '^[A-Z]{2}[A-Z0-9]{2}$'),
  dep_name      text not null check (length(btrim(dep_name)) between 1 and 80),
  dep_lat       numeric(8,5) not null,
  dep_lon       numeric(8,5) not null,
  -- Aérodrome arrivée
  arr_icao      text not null check (arr_icao ~ '^[A-Z]{2}[A-Z0-9]{2}$'),
  arr_name      text not null check (length(btrim(arr_name)) between 1 and 80),
  arr_lat       numeric(8,5) not null,
  arr_lon       numeric(8,5) not null,
  -- Vol
  flight_date   date not null,
  seats         smallint not null default 1 check (seats between 1 and 5),
  aircraft      text check (aircraft is null or length(btrim(aircraft)) <= 40),
  comment       text check (comment is null or length(comment) <= 600),
  -- Statut : open | closed | cancelled
  status        text not null default 'open' check (status in ('open','closed','cancelled')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  closed_at     timestamptz
);

create index if not exists flight_shares_date on public.flight_shares (flight_date) where status = 'open';
create index if not exists flight_shares_pilot on public.flight_shares (pilot_id);

alter table public.flight_shares enable row level security;
revoke truncate on public.flight_shares from public, anon, authenticated;

-- Lecture : tout membre approuvé
drop policy if exists flight_shares_select on public.flight_shares;
create policy flight_shares_select on public.flight_shares
  for select to authenticated using (public.is_approved());

-- Insertion : membre approuvé uniquement, pour soi-même
drop policy if exists flight_shares_insert on public.flight_shares;
create policy flight_shares_insert on public.flight_shares
  for insert to authenticated
  with check (public.is_approved() and pilot_id = auth.uid());

-- Mise à jour : pilote ou admin (statut, fermeture…)
drop policy if exists flight_shares_update on public.flight_shares;
create policy flight_shares_update on public.flight_shares
  for update to authenticated
  using (public.is_approved() and (pilot_id = auth.uid() or public.app_role() = 'admin'))
  with check (public.is_approved() and (pilot_id = auth.uid() or public.app_role() = 'admin'));

-- Pas de suppression physique
revoke delete on public.flight_shares from authenticated, anon;

-- Audit
drop trigger if exists zz_audit on public.flight_shares;
create trigger zz_audit after insert or update on public.flight_shares
  for each row execute function public._audit();


-- Table des passagers inscrits
create table if not exists public.flight_share_seats (
  id            uuid primary key default gen_random_uuid(),
  share_id      uuid not null references public.flight_shares (id) on delete cascade,
  member_id     uuid not null references public.profiles (id) on delete cascade,
  message       text check (message is null or length(message) <= 300),
  created_at    timestamptz not null default now(),
  unique (share_id, member_id)
);

create index if not exists flight_share_seats_share on public.flight_share_seats (share_id);

alter table public.flight_share_seats enable row level security;
revoke truncate on public.flight_share_seats from public, anon, authenticated;

-- Lecture : tout membre approuvé
drop policy if exists flight_share_seats_select on public.flight_share_seats;
create policy flight_share_seats_select on public.flight_share_seats
  for select to authenticated using (public.is_approved());

-- Inscription : pour soi-même, vol ouvert, pas déjà inscrit, place disponible
drop policy if exists flight_share_seats_insert on public.flight_share_seats;
create policy flight_share_seats_insert on public.flight_share_seats
  for insert to authenticated
  with check (
    public.is_approved()
    and member_id = auth.uid()
    and exists (
      select 1 from public.flight_shares fs
      where fs.id = share_id
        and fs.status = 'open'
        and fs.pilot_id <> auth.uid()
        and (
          select count(*) from public.flight_share_seats s2 where s2.share_id = fs.id
        ) < fs.seats
    )
  );

-- Désinscription : soi-même ou admin
drop policy if exists flight_share_seats_delete on public.flight_share_seats;
create policy flight_share_seats_delete on public.flight_share_seats
  for delete to authenticated
  using (public.is_approved() and (member_id = auth.uid() or public.app_role() = 'admin'));

notify pgrst, 'reload schema';
