\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.m', (select id::text from public.profiles where role = 'member' and anonymized_at is null and not (is_board or is_treasurer or is_maintenance or is_chief_pilot or is_compliance or is_secretary or is_instructor) order by email limit 1), false);
select set_config('t.m2', (select id::text from public.profiles where role = 'member' and anonymized_at is null and not (is_board or is_treasurer or is_maintenance or is_chief_pilot or is_compliance or is_secretary or is_instructor) order by email offset 1 limit 1), false);

set role authenticated;
-- Un membre propose une activité : il en est l'organisateur et peut y mettre une affiche
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
select set_config('t.o', (public.save_outing(null, 'Barbecue', 'Club-house', null, null, now() + interval '9 days', null, null,
         null, null, 'evenement', null) ->> 'outing_id'), false);
select set_config('t.url', 'https://x.supabase.co/storage/v1/object/public/documents/events/' || current_setting('t.o') || '/1.jpg', false);
do $$ begin
  assert (public.get_outing(current_setting('t.o')::uuid) ->> 'poster_url') is null, 'pas d''affiche par défaut';
  perform public.set_outing_poster(current_setting('t.o')::uuid, current_setting('t.url'));
  assert (public.get_outing(current_setting('t.o')::uuid) ->> 'poster_url') = current_setting('t.url'), 'affiche enregistrée';
  -- une image qui n'est pas celle de cet événement est refusée
  begin perform public.set_outing_poster(current_setting('t.o')::uuid, 'https://ailleurs.fr/pub.jpg'); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%invalide%', sqlerrm; end;
  -- dépôt du fichier autorisé dans le dossier de son événement
  insert into storage.objects (bucket_id, name) values ('documents', 'events/' || current_setting('t.o') || '/1.jpg');
end $$;

-- Un autre membre ne peut ni changer l'affiche, ni déposer de fichier pour cet événement
select set_config('request.jwt.claim.sub', current_setting('t.m2'), false);
do $$ begin
  begin perform public.set_outing_poster(current_setting('t.o')::uuid, null); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%organisateur%', sqlerrm; end;
  begin insert into storage.objects (bucket_id, name) values ('documents', 'events/' || current_setting('t.o') || '/2.jpg'); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;

-- L'organisateur retire l'affiche
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  perform public.set_outing_poster(current_setting('t.o')::uuid, null);
  assert (public.get_outing(current_setting('t.o')::uuid) ->> 'poster_url') is null, 'affiche retirée';
end $$;
reset role;
delete from storage.objects where name like 'events/' || current_setting('t.o') || '/%';
delete from public.outings where id = current_setting('t.o')::uuid;
select 'TEST MIGRATION 41 OK';
