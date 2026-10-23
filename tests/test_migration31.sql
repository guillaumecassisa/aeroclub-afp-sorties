\set ON_ERROR_STOP on
set client_min_messages = warning;

-- Sortie PS28 + DR400, organisateur admin non instructeur ; deux membres non lâchés en attente
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000001', false);
select set_config('t.o', (public.save_outing(null, 'Test placement', 'LFKC', null, null, now() + interval '30 days', null, null,
  array['30000000-0000-0000-0000-0000000000a2', '30000000-0000-0000-0000-0000000000d4']::uuid[],
  '30000000-0000-0000-0000-0000000000d4', 'vol', null) ->> 'outing_id'), false);
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000002', false);
select public.register_for_outing(current_setting('t.o')::uuid);
select set_config('t.r', (select id::text from public.registrations where outing_id = current_setting('t.o')::uuid
  and user_id = '30000000-0000-0000-0000-000000000002'), false);
do $$ begin
  assert (select status from public.registrations where id = current_setting('t.r')::uuid) = 'waitlist', 'en attente';
  -- un simple membre ne peut pas se placer lui-même
  begin perform public.place_waitlisted(current_setting('t.r')::uuid, '30000000-0000-0000-0000-0000000000d4'); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%organisateur%', sqlerrm; end;
end $$;

-- L'organisateur le place d'office dans le DR400
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000001', false);
select public.place_waitlisted(current_setting('t.r')::uuid, '30000000-0000-0000-0000-0000000000d4');
do $$ begin
  assert (select status = 'confirmed' and forced_seat from public.registrations where id = current_setting('t.r')::uuid), 'placé d''office';
end $$;

-- Un recalcul (nouvel inscrit lâché) ne lui retire pas sa place
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000005', false);
select public.register_for_outing(current_setting('t.o')::uuid);
do $$ begin
  assert (select status = 'confirmed' and aircraft_id = '30000000-0000-0000-0000-0000000000d4'
            from public.registrations where id = current_setting('t.r')::uuid), 'garde sa place';
end $$;

-- L'organisateur peut le déplacer vers le PS28
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000001', false);
select public.move_crew(current_setting('t.o')::uuid, current_setting('t.r'), '30000000-0000-0000-0000-0000000000a2');
do $$ begin
  assert (select aircraft_id from public.registrations where id = current_setting('t.r')::uuid)
       = '30000000-0000-0000-0000-0000000000a2', 'déplacé';
end $$;

-- Désinscription puis réinscription : la place d'office ne se conserve pas
select set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-000000000002', false);
select public.cancel_registration(current_setting('t.r')::uuid);
do $$ begin
  assert (public.register_for_outing(current_setting('t.o')::uuid) ->> 'status') = 'waitlist', 'de nouveau en attente';
end $$;

select 'test_migration31 OK';
