-- =====================================================================
--  Mise à jour n°33 : fiabilité avant la mise en service
--  - Les données d'exemple (avions, masse et centrage, carte du bar, liens,
--    bons plans, shop) ne sont posées qu'à la première installation :
--    relancer « mise-a-jour-complete.sql » ne remet plus d'anciennes
--    masses à vide, d'anciens prix ou des avions retirés.
--  - Organisateurs (CA, trésorier, chef pilote…) : peuvent modifier leurs
--    événements publiés et retirer un participant ; les propositions à
--    valider ne s'affichent qu'à ceux qui peuvent les valider.
--  - Quiz : le chef pilote et le responsable conformité gèrent les
--    questions depuis l'Espace pédagogique.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Données d'exemple déjà posées sur cette base --------------------------------
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

insert into public._seeds (name)
select unnest(array['bar-04', 'avions-08', 'bar-12', 'avions-19', 'liens-19', 'centrage-20', 'centrage-21',
                    'bar-22', 'bons-plans-23', 'shop-25', 'centrage-26'])
on conflict (name) do nothing;

-- 2. Questions du quiz : gérées par le chef pilote / resp. conformité / admins -------
grant select, insert, update on public.quiz_questions to authenticated;
grant usage on sequence public.quiz_questions_id_seq to authenticated;
drop policy if exists quiz_questions_teach_select on public.quiz_questions;
create policy quiz_questions_teach_select on public.quiz_questions for select to authenticated
  using (public.can_teach());
drop policy if exists quiz_questions_teach_insert on public.quiz_questions;
create policy quiz_questions_teach_insert on public.quiz_questions for insert to authenticated
  with check (public.can_teach());
drop policy if exists quiz_questions_teach_update on public.quiz_questions;
create policy quiz_questions_teach_update on public.quiz_questions for update to authenticated
  using (public.can_teach()) with check (public.can_teach());
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'quiz_questions_text_check') then
    alter table public.quiz_questions add constraint quiz_questions_text_check check (
      length(btrim(question)) between 1 and 500
      and length(btrim(option_a)) between 1 and 300 and length(btrim(option_b)) between 1 and 300
      and length(btrim(option_c)) between 1 and 300 and length(btrim(option_d)) between 1 and 300
      and (explanation is null or length(explanation) <= 1500)) not valid;
  end if;
end $$;
drop trigger if exists zz_audit on public.quiz_questions;
create trigger zz_audit after insert or update on public.quiz_questions
  for each row execute function public._audit();

-- 3. Événements : droits des organisateurs ------------------------------------------
CREATE OR REPLACE FUNCTION public.get_outing(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_staff boolean := public.is_staff();
  v_row   public.outings;
  v_org   public.profiles;
  v_kind  text;
  v_ac    jsonb;
  v_wait  jsonb;
  v_part  jsonb;
  v_mine  jsonb;
  v_org_w numeric;
  v_guest jsonb;
begin
  select * into v_row from public.outings where id = p_id;
  if not found then return null; end if;

  v_kind := coalesce(v_row.kind, 'vol');

  if v_row.approval <> 'approved' and v_row.status <> 'cancelled' then
    if not (v_staff or v_row.instructor_id = v_uid) then return null; end if;
  end if;
  if v_row.status = 'cancelled' then
    if not (v_staff or v_row.instructor_id = v_uid
            or exists (select 1 from public.registrations where outing_id = p_id and user_id = v_uid)) then
      return null;
    end if;
  end if;

  select * into v_org from public.profiles where id = v_row.instructor_id;

  if v_row.instructor_id = v_uid then
    select weight_kg into v_org_w from public.pilot_weights where user_id = v_uid order by updated_at desc limit 1;
  end if;

  if v_kind = 'vol' then
    select coalesce(jsonb_agg(ac_data order by ac_reg), '[]') into v_ac
    from (
      select
        a.registration as ac_reg,
        jsonb_build_object(
          'id', a.id,
          'registration', a.registration,
          'model', a.model,
          'type', a.type,
          'seats', a.seats,
          'instructor_onboard', v_row.instructor_aircraft_id = a.id,
          'capacity', greatest(a.seats - case when v_row.instructor_aircraft_id = a.id then 1 else 0 end, 0),
          'occupants', coalesce((
            select jsonb_agg(jsonb_build_object(
              'registration_id', r.id,
              'user_id', r.user_id,
              'full_name', coalesce(r.guest_name, p.full_name),
              'avatar_url', case when r.guest_of is null then p.avatar_url end,
              'is_guest', r.guest_of is not null,
              'host_name', case when r.guest_of is not null then p.full_name end,
              'released', r.guest_of is not null or public._is_instructor(r.user_id) or exists (
                select 1 from public.pilot_types pt
                 where pt.user_id = r.user_id and pt.aircraft_type = a.type
              ),
              'phone', case when r.guest_of is null and (v_staff or v_row.instructor_id = v_uid) then p.phone end,
              'weight_kg', case when v_row.instructor_id = v_uid or r.user_id = v_uid
                                then case when r.guest_of is null then pw.weight_kg else r.guest_weight_kg end end
            ) order by r.created_at)
            from public.registrations r
            join public.profiles p on p.id = r.user_id
            left join public.pilot_weights pw on pw.user_id = r.user_id
              and pw.updated_at = (select max(updated_at) from public.pilot_weights where user_id = r.user_id)
            where r.outing_id = p_id and r.status = 'confirmed' and r.aircraft_id = a.id
          ), '[]')
        ) as ac_data
      from public.outing_aircraft oa
      join public.aircraft a on a.id = oa.aircraft_id
      where oa.outing_id = p_id
    ) sub;
  else
    v_ac := '[]';
  end if;

  select coalesce(jsonb_agg(w order by w_created), '[]') into v_wait
  from (
    select jsonb_build_object(
      'registration_id', r.id,
      'user_id', r.user_id,
      'full_name', coalesce(r.guest_name, p.full_name),
      'avatar_url', case when r.guest_of is null then p.avatar_url end,
      'is_guest', r.guest_of is not null,
      'host_name', case when r.guest_of is not null then p.full_name end,
      'released', false,
      'phone', case when r.guest_of is null and (v_staff or v_row.instructor_id = v_uid) then p.phone end,
      'weight_kg', case when v_row.instructor_id = v_uid or r.user_id = v_uid
                        then case when r.guest_of is null then pw.weight_kg else r.guest_weight_kg end end,
      'position', row_number() over (order by r.created_at)
    ) as w,
    r.created_at as w_created
    from public.registrations r
    join public.profiles p on p.id = r.user_id
    left join public.pilot_weights pw on pw.user_id = r.user_id
      and pw.updated_at = (select max(updated_at) from public.pilot_weights where user_id = r.user_id)
    where r.outing_id = p_id and r.status = 'waitlist'
  ) sub;

  if v_kind <> 'vol' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'registration_id', r.id,
      'user_id', r.user_id,
      'full_name', coalesce(r.guest_name, p.full_name),
      'avatar_url', case when r.guest_of is null then p.avatar_url end,
      'is_guest', r.guest_of is not null,
      'host_name', case when r.guest_of is not null then p.full_name end,
      'released', false,
      'phone', case when r.guest_of is null and (v_staff or v_row.instructor_id = v_uid) then p.phone end
    ) order by r.created_at), '[]') into v_part
    from public.registrations r
    join public.profiles p on p.id = r.user_id
    where r.outing_id = p_id and r.status = 'confirmed';
  else
    v_part := '[]';
  end if;

  select jsonb_build_object('id', r.id, 'status', r.status, 'aircraft_id', r.aircraft_id) into v_mine
  from public.registrations r
  where r.outing_id = p_id and r.user_id = v_uid and r.guest_of is null and r.status <> 'cancelled'
  limit 1;

  select jsonb_build_object('id', g.id, 'name', g.guest_name, 'weight_kg', g.guest_weight_kg,
                            'status', g.status, 'aircraft_id', g.aircraft_id) into v_guest
  from public.registrations g
  join public.registrations h on h.id = g.guest_of
  where g.outing_id = p_id and h.user_id = v_uid and g.status <> 'cancelled'
  limit 1;

  return jsonb_build_object(
    'id',                    v_row.id,
    'title',                 v_row.title,
    'destination',           v_row.destination,
    'description',           v_row.description,
    'meeting_point',         v_row.meeting_point,
    'departure_at',          v_row.departure_at,
    'return_at',             v_row.return_at,
    'registration_deadline', v_row.registration_deadline,
    'max_participants',      v_row.max_participants,
    'kind',                  v_kind,
    'status',                v_row.status,
    'instructor_aircraft_id',v_row.instructor_aircraft_id,
    'instructor', jsonb_build_object(
      'id',          v_org.id,
      'full_name',   v_org.full_name,
      'phone',       case when v_staff or v_row.instructor_id = v_uid then v_org.phone end,
      'avatar_url',  v_org.avatar_url
    ),
    'can_manage',            v_staff,
    'is_organizer',          v_row.instructor_id = v_uid,
    'organizer_weight_kg',   v_org_w,
    'approval',              v_row.approval,
    'rejection_reason',      v_row.rejection_reason,
    'can_edit',              public.can_organize() or (v_row.instructor_id = v_uid and v_row.approval <> 'approved'),
    'can_remove',            v_staff or public.can_organize() or v_row.instructor_id = v_uid,
    'aircraft',              v_ac,
    'waitlist',              v_wait,
    'participants',          v_part,
    'my_registration',       v_mine,
    'my_guest',              v_guest,
    'my_guest_count',        (select count(*) from public.registrations g
                               join public.registrations h on h.id = g.guest_of
                              where g.outing_id = p_id and h.user_id = v_uid and g.status <> 'cancelled'),
    'guests_allowed',        coalesce(v_row.guests_allowed, false)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_registration(p_registration uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid    uuid := auth.uid();
  v_reg    public.registrations;
  v_outing public.outings;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;

  select * into v_reg from public.registrations where id = p_registration;
  if not found then raise exception 'Inscription introuvable.'; end if;

  -- verrouille la sortie pour sérialiser les modifications
  select * into v_outing from public.outings where id = v_reg.outing_id for update;
  select * into v_reg from public.registrations where id = p_registration;

  if v_reg.user_id <> v_uid and not (public.is_staff() or public.can_organize() or v_outing.instructor_id = v_uid) then
    raise exception 'Vous ne pouvez pas annuler l''inscription d''un autre membre.';
  end if;
  if v_reg.status = 'cancelled' then raise exception 'Inscription déjà annulée.'; end if;
  if v_outing.departure_at <= now() and not public.is_staff() then
    raise exception 'La sortie a déjà commencé : contactez l''instructeur.';
  end if;

  -- le membre et son accompagnant éventuel
  update public.registrations
     set status = 'cancelled', aircraft_id = null, cancelled_at = now()
   where (id = p_registration or guest_of = p_registration) and status <> 'cancelled';

  if v_outing.departure_at <= now() then
    return jsonb_build_object('changes', '[]'::jsonb);
  end if;
  return jsonb_build_object('changes', public._rebalance_outing(v_outing.id));
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_outings(p_past boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
begin
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  return coalesce((
    select jsonb_agg(row_to_json(t) order by
             case when p_past then null else t.departure_at end asc,
             case when p_past then t.departure_at end desc)
    from (
      select o.id, o.title, o.destination, o.departure_at, o.return_at,
             o.registration_deadline, o.status,
             ip.full_name as instructor_name,
             (o.instructor_aircraft_id is not null) as instructor_flies,
             case when coalesce(o.kind, 'vol') = 'vol' then
             (select coalesce(sum(greatest(a.seats - case when a.id = o.instructor_aircraft_id then 1 else 0 end, 0)), 0)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id)
             else o.max_participants end as total_capacity,
             coalesce(o.kind, 'vol') as kind, o.max_participants, o.meeting_point,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'confirmed') as confirmed_count,
             (select count(*) from public.registrations r
               where r.outing_id = o.id and r.status = 'waitlist') as waitlist_count,
             (select string_agg(a.registration || ' (' || a.seats || 'pl.)', ', ' order by oa.position)
                from public.outing_aircraft oa join public.aircraft a on a.id = oa.aircraft_id
               where oa.outing_id = o.id) as aircraft_summary,
             (select r.status from public.registrations r
               where r.outing_id = o.id and r.user_id = v_uid and r.status <> 'cancelled'
                 and r.guest_of is null) as my_status,
             (o.instructor_id = v_uid) as i_am_instructor,
             o.approval, o.rejection_reason
      from public.outings o
      join public.profiles ip on ip.id = o.instructor_id
      where (o.approval = 'approved' or o.instructor_id = v_uid or public.is_staff())
        and case when p_past
                 then coalesce(o.return_at, o.departure_at) < now()
                 else coalesce(o.return_at, o.departure_at) >= now() end
      limit 200
    ) t), '[]'::jsonb);
end;
$function$;

revoke execute on function public.get_outing(uuid), public.cancel_registration(uuid), public.list_outings(boolean) from public, anon;
grant execute on function public.get_outing(uuid), public.cancel_registration(uuid), public.list_outings(boolean) to authenticated;

notify pgrst, 'reload schema';

select exists (select 1 from public._seeds where name = 'centrage-26')
   and exists (select 1 from pg_policies where policyname = 'quiz_questions_teach_update') as "MISE A JOUR 33 OK";
