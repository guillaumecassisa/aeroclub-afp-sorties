\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.m', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email limit 1), false);
select set_config('t.m2', (select id::text from public.profiles where role = 'member' and anonymized_at is null order by email offset 1 limit 1), false);
select set_config('t.adm', (select id::text from public.profiles where role = 'admin' order by email limit 1), false);
select set_config('t.p', (select id::text from public.profiles where role = 'pending' limit 1), false);

set role authenticated;
-- Un membre dépose ses photos dans son dossier et les enregistre
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
insert into storage.objects (bucket_id, name) values ('documents', 'photos/' || current_setting('t.m') || '/1.jpg');
insert into public.flight_photos (path, url, caption)
values ('photos/' || current_setting('t.m') || '/1.jpg', 'https://x.supabase.co/storage/v1/object/public/documents/photos/1.jpg', 'Calanques');
do $$ begin
  -- pas dans le dossier d'un autre
  begin insert into storage.objects (bucket_id, name) values ('documents', 'photos/' || current_setting('t.m2') || '/x.jpg'); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
  begin insert into public.flight_photos (path, url) values ('photos/' || current_setting('t.m2') || '/x.jpg', 'https://x/y.jpg'); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
  -- ni au nom d'un autre
  begin insert into public.flight_photos (user_id, path, url) values (current_setting('t.m2')::uuid, 'photos/' || current_setting('t.m') || '/2.jpg', 'https://x/y.jpg'); raise exception 'ATTENDU';
  exception when insufficient_privilege then null; end;
end $$;

-- Un autre membre la voit mais ne peut pas la supprimer
select set_config('request.jwt.claim.sub', current_setting('t.m2'), false);
do $$ begin
  assert (select count(*) from public.flight_photos where caption = 'Calanques') = 1, 'visible des membres';
  delete from public.flight_photos where caption = 'Calanques';
  assert (select count(*) from public.flight_photos where caption = 'Calanques') = 1, 'pas supprimée par un autre';
end $$;

-- Un compte non validé ne voit rien
select set_config('request.jwt.claim.sub', current_setting('t.p'), false);
do $$ begin assert (select count(*) from public.flight_photos) = 0, 'invisible si non validé'; end $$;

-- L'administrateur peut la retirer
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
delete from public.flight_photos where caption = 'Calanques';
do $$ begin assert (select count(*) from public.flight_photos where caption = 'Calanques') = 0, 'retirée par l''admin'; end $$;
reset role;
delete from storage.objects where name like 'photos/%';
do $$ begin
  assert position('flight_photos' in pg_get_functiondef('public._anonymize_profile(uuid)'::regprocedure)) > 0, 'anonymisation : photos';
end $$;
select 'TEST MIGRATION 44 OK';
