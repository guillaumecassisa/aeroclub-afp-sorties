\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Données : deux avions de types différents, des membres lâchés / non lâchés, un instructeur
insert into public.aircraft (id, registration, model, seats, type) values
  ('30000000-0000-0000-0000-0000000000d4', 'F-T30D', 'DR400', 4, 'DR400'),
  ('30000000-0000-0000-0000-0000000000a2', 'F-T30P', 'PS28', 2, 'PS28')
on conflict (id) do nothing;

insert into auth.users (id, email, raw_user_meta_data) values
  ('30000000-0000-0000-0000-000000000001', 'org30@club.fr', '{"full_name":"Orga TRENTE"}'),
  ('30000000-0000-0000-0000-000000000002', 'nl30@club.fr', '{"full_name":"Nonlache UN"}'),
  ('30000000-0000-0000-0000-000000000003', 'ps30@club.fr', '{"full_name":"Lache PS"}'),
  ('30000000-0000-0000-0000-000000000004', 'ins30@club.fr', '{"full_name":"Instructeur TRENTE"}'),
  ('30000000-0000-0000-0000-000000000005', 'dr30@club.fr', '{"full_name":"Lache DR"}')
on conflict (id) do nothing;
update public.profiles set role = 'member' where id::text like '30000000-%';
update public.profiles set role = 'admin' where id = '30000000-0000-0000-0000-000000000001';
update public.profiles set role = 'instructor', is_instructor = true where id = '30000000-0000-0000-0000-000000000004';
insert into public.pilot_types (user_id, aircraft_type) values
  ('30000000-0000-0000-0000-000000000003', 'PS28'),
  ('30000000-0000-0000-0000-000000000005', 'DR400')
on conflict do nothing;

-- L'organisateur (admin, non instructeur) crée une sortie PS28 + DR400 sans voler
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000001', false);
select set_config('t.o', (public.save_outing(null, 'Test lâchers', 'LFMQ', null, null, now() + interval '20 days', null, null,
  array['30000000-0000-0000-0000-0000000000a2', '30000000-0000-0000-0000-0000000000d4']::uuid[], null, 'vol', null) ->> 'outing_id'), false);

-- 1. Le non lâché s'inscrit en premier : aucun avion sans instructeur -> liste d'attente
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000002', false);
do $$ begin
  assert (public.register_for_outing(current_setting('t.o')::uuid) ->> 'status') = 'waitlist', 'non lâché en attente';
end $$;

-- 2. Le lâché DR400 s'inscrit : placé dans le DR400 (pas dans le PS28 pourtant listé en premier)
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000005', false);
select public.register_for_outing(current_setting('t.o')::uuid);
do $$ begin
  assert (select aircraft_id from public.registrations where outing_id = current_setting('t.o')::uuid
            and user_id = '30000000-0000-0000-0000-000000000005') = '30000000-0000-0000-0000-0000000000d4', 'lâché DR400 dans le DR400';
end $$;

-- 3. L'instructeur s'inscrit : il est placé, et le non lâché monte avec lui
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000004', false);
select public.register_for_outing(current_setting('t.o')::uuid);
do $$
declare v_ins uuid; v_nl uuid; v_nl_status text;
begin
  select aircraft_id into v_ins from public.registrations where outing_id = current_setting('t.o')::uuid
     and user_id = '30000000-0000-0000-0000-000000000004';
  select aircraft_id, status into v_nl, v_nl_status from public.registrations where outing_id = current_setting('t.o')::uuid
     and user_id = '30000000-0000-0000-0000-000000000002';
  assert v_nl_status = 'confirmed', 'non lâché confirmé grâce à l''instructeur';
  assert v_nl = v_ins, 'non lâché dans l''avion de l''instructeur';
end $$;

-- 4. Le lâché PS28 s'inscrit : le PS28 (2 places) est pris par l'instructeur et le non lâché ;
--    il ne doit pas être mis seul dans le DR400 où il n'est pas lâché -> liste d'attente
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000003', false);
select public.register_for_outing(current_setting('t.o')::uuid);
do $$
declare v_status text; v_ac uuid;
begin
  select status, aircraft_id into v_status, v_ac from public.registrations
   where outing_id = current_setting('t.o')::uuid and user_id = '30000000-0000-0000-0000-000000000003';
  assert (v_status = 'confirmed' and v_ac = '30000000-0000-0000-0000-0000000000a2') or v_status = 'waitlist',
    'lâché PS28 : dans le PS28 ou en attente, jamais seul dans le DR400';
  -- aucun inscrit confirmé n'est sans instructeur sur un type où il n'est pas lâché
  assert not exists (select 1 from public.registrations r
                      where r.outing_id = current_setting('t.o')::uuid and r.status = 'confirmed'
                        and not public._can_fly_in(r.user_id, r.aircraft_id, r.outing_id)), 'règle des lâchers respectée';
end $$;

-- 5. Déplacement manuel : on ne peut pas sortir l'instructeur en laissant le non lâché seul
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000001', false);
do $$
declare v_ins_reg uuid; v_ins_ac uuid; v_other uuid;
begin
  select id, aircraft_id into v_ins_reg, v_ins_ac from public.registrations
   where outing_id = current_setting('t.o')::uuid and user_id = '30000000-0000-0000-0000-000000000004';
  select aircraft_id into v_other from public.outing_aircraft
   where outing_id = current_setting('t.o')::uuid and aircraft_id <> v_ins_ac limit 1;
  begin
    perform public.move_crew(current_setting('t.o')::uuid, v_ins_reg::text, v_other);
    raise exception 'ATTENDU';
  exception when others then
    if sqlerrm = 'ATTENDU' then raise exception 'l''instructeur a pu laisser un non lâché seul'; end if;
    assert sqlerrm like '%sans instructeur%' or sqlerrm like '%complet%', sqlerrm;
  end;
end $$;

-- 6. L'instructeur se désinscrit : le non lâché repasse en liste d'attente
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000004', false);
select public.cancel_registration((select id from public.registrations where outing_id = current_setting('t.o')::uuid
  and user_id = '30000000-0000-0000-0000-000000000004'));
do $$ begin
  assert (select status from public.registrations where outing_id = current_setting('t.o')::uuid
            and user_id = '30000000-0000-0000-0000-000000000002') = 'waitlist', 'non lâché repasse en attente';
end $$;

-- 7. Un organisateur instructeur à bord rend l'avion accessible
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000004', false);
select set_config('t.o2', (public.save_outing(null, 'Test lâchers 2', 'LFMQ', null, null, now() + interval '21 days', null, null,
  array['30000000-0000-0000-0000-0000000000d4']::uuid[], '30000000-0000-0000-0000-0000000000d4', 'vol', null) ->> 'outing_id'), false);
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000002', false);
do $$ begin
  assert (public.register_for_outing(current_setting('t.o2')::uuid) ->> 'status') = 'confirmed', 'non lâché avec organisateur instructeur';
end $$;

-- ===== Accompagnants : sortie avion =====
-- Sortie DR400 (4 places), organisateur admin non instructeur, +1 autorisés
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000001', false);
select set_config('t.o3', (public.save_outing(null, 'Test +1', 'LFMQ', null, null, now() + interval '22 days', null, null,
  array['30000000-0000-0000-0000-0000000000d4']::uuid[], null, 'vol', null) ->> 'outing_id'), false);
-- interdit tant que l'organisateur ne l'a pas autorisé
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000005', false);
select public.register_for_outing(current_setting('t.o3')::uuid);
do $$ begin
  begin perform public.add_guest(current_setting('t.o3')::uuid, 'Marie', 60); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%n''autorise pas%', sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000001', false);
select public.set_guests_allowed(current_setting('t.o3')::uuid, true);
-- le lâché DR400 ajoute un accompagnant (non lâché, mais il ne pilote pas)
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000005', false);
do $$ begin
  assert (public.add_guest(current_setting('t.o3')::uuid, 'Marie', 60) ->> 'status') = 'confirmed', '+1 confirmé';
  begin perform public.add_guest(current_setting('t.o3')::uuid, 'Paul', 80); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%déjà un accompagnant%', sqlerrm; end;
  -- get_outing : nom de l'accompagnant, son poids visible par le membre, pas de badge « non lâché »
  assert jsonb_path_exists(public.get_outing(current_setting('t.o3')::uuid),
    '$.aircraft[*].occupants[*] ? (@.full_name == "Marie" && @.is_guest == true && @.released == true && @.weight_kg == 60)'), 'accompagnant affiché';
  assert (public.get_outing(current_setting('t.o3')::uuid) -> 'my_registration' ->> 'status') = 'confirmed', 'mon inscription, pas celle du +1';
  assert (select my_status from jsonb_to_recordset(public.list_outings(false)) as x(id uuid, my_status text)
           where id = current_setting('t.o3')::uuid) = 'confirmed', 'list_outings ne plante pas avec un +1';
end $$;
-- un non lâché sans instructeur reste en attente ; son +1 aussi
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000002', false);
select public.register_for_outing(current_setting('t.o3')::uuid);
do $$ begin
  assert (public.add_guest(current_setting('t.o3')::uuid, 'Léa', 55) ->> 'status') = 'waitlist', '+1 en attente avec son membre';
end $$;
-- le membre se désinscrit : son +1 part avec lui
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000005', false);
select public.cancel_registration((select id from public.registrations where outing_id = current_setting('t.o3')::uuid
  and user_id = '30000000-0000-0000-0000-000000000005' and guest_of is null));
do $$ begin
  assert not exists (select 1 from public.registrations where outing_id = current_setting('t.o3')::uuid
                       and guest_name = 'Marie' and status <> 'cancelled'), '+1 annulé avec son membre';
end $$;
-- l'organisateur retire l'autorisation : les +1 restants sont retirés
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000001', false);
select public.set_guests_allowed(current_setting('t.o3')::uuid, false);
do $$ begin
  assert not exists (select 1 from public.registrations where outing_id = current_setting('t.o3')::uuid
                       and guest_of is not null and status <> 'cancelled'), '+1 retirés';
end $$;

-- ===== Accompagnants : événement convivial (jusqu'à 5) =====
select set_config('t.o4', (public.save_outing(null, 'Barbapéro', 'Club-house', null, null, now() + interval '23 days', null, null,
  null, null, 'evenement', 6) ->> 'outing_id'), false);
select public.set_guests_allowed(current_setting('t.o4')::uuid, true);
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000003', false);
select public.register_for_outing(current_setting('t.o4')::uuid);
do $$
declare r jsonb;
begin
  begin perform public.set_guest_count(current_setting('t.o4')::uuid, 6); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%0 et 5%', sqlerrm; end;
  r := public.set_guest_count(current_setting('t.o4')::uuid, 5);
  assert (r ->> 'confirmed')::int = 5, '5 accompagnants confirmés (6 places)';
  assert (public.get_outing(current_setting('t.o4')::uuid) ->> 'my_guest_count')::int = 5, 'compteur';
end $$;
-- un autre membre : l'événement est complet (1 + 5 = 6) -> liste d'attente, et ses +1 aussi
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000005', false);
do $$ begin
  assert (public.register_for_outing(current_setting('t.o4')::uuid) ->> 'status') = 'waitlist', 'complet';
  assert (public.set_guest_count(current_setting('t.o4')::uuid, 2) ->> 'confirmed')::int = 0, '+1 en attente avec leur membre';
end $$;
-- le premier réduit à 2 accompagnants : le second membre et ses 2 +1 passent
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000003', false);
select public.set_guest_count(current_setting('t.o4')::uuid, 2);
do $$ begin
  assert (select count(*) from public.registrations where outing_id = current_setting('t.o4')::uuid and status = 'confirmed') = 6, '6 confirmés';
  assert (select status from public.registrations where outing_id = current_setting('t.o4')::uuid
            and user_id = '30000000-0000-0000-0000-000000000005' and guest_of is null) = 'confirmed', 'second membre confirmé';
end $$;

select 'test_migration30 OK';
