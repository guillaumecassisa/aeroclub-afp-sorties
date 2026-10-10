\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.admin', (select id::text from public.profiles where role='admin' limit 1), false);
select set_config('t.a', (select id::text from public.aircraft where registration = 'F-HUIT'), false);
update public.profiles set role='member', is_instructor=false, is_board=false, is_treasurer=false, is_secretary=false, is_maintenance=false
 where id in ('00000000-0000-0000-0000-000000000105','00000000-0000-0000-0000-000000000106','00000000-0000-0000-0000-000000000110');

create or replace function pg_temp.n(q text) returns int language plpgsql as $$
declare c int;
begin
  execute q; get diagnostics c = row_count; return c;
exception when insufficient_privilege then return 0;
end $$;
-- 1. Visiteur non connecté : aucune fonction sauf les infos légales
do $$ begin
  assert not has_function_privilege('anon', 'public.set_function(uuid,text,boolean)', 'execute'), 'anon set_function';
  assert not has_function_privilege('anon', 'public.anonymize_member(uuid)', 'execute'), 'anon anonymize';
  assert not has_function_privilege('anon', 'public.member_directory()', 'execute'), 'anon annuaire';
  assert not has_function_privilege('anon', 'public.is_approved()', 'execute'), 'anon helper';
  assert has_function_privilege('anon', 'public.get_club_info()', 'execute'), 'anon infos légales';
  assert has_function_privilege('authenticated', 'public.is_approved()', 'execute'), 'membre helper';
  assert not has_table_privilege('authenticated', 'public.outings', 'truncate'), 'truncate interdit';
end $$;

-- 2. Simple membre (105) : ne peut rien effacer
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
set role authenticated;
do $$ declare n int; begin
  assert pg_temp.n($q$delete from public.aircraft$q$) = 0, 'avions';
  assert pg_temp.n($q$delete from public.bar_products$q$) = 0, 'carte';
  assert pg_temp.n($q$delete from public.aircraft_documents$q$) = 0, 'documents';
  assert pg_temp.n($q$delete from public.outings$q$) = 0, 'sorties';
  assert pg_temp.n($q$delete from public.registrations$q$) = 0, 'inscriptions';
  assert pg_temp.n($q$delete from public.bar_consumptions$q$) = 0, 'consos';
  assert pg_temp.n($q$delete from public.profiles$q$) = 0, 'profils';
  assert pg_temp.n($q$delete from public.announcements$q$) = 0, 'annonces';
  assert pg_temp.n($q$update public.profiles set full_name = 'pirate' where id <> auth.uid()$q$) = 0, 'profil d''un autre';
  assert (select count(*) from public.audit_log) = 0, 'journal invisible';
end $$;
do $$ begin
  begin update public.profiles set role = 'admin' where id = auth.uid(); assert false, 'rôle modifiable !';
  exception when insufficient_privilege then null; end;
  begin perform public.archive_document(gen_random_uuid(), true); assert false;
  exception when raise_exception then null; end;
  begin perform public.anonymize_member('00000000-0000-0000-0000-000000000106'); assert false;
  exception when raise_exception then null; end;
  begin perform public.set_club_info('{"address":"x"}'); assert false;
  exception when raise_exception then null; end;
end $$;
reset role;

-- 3. Trésorier : ne peut pas supprimer un produit
update public.profiles set is_treasurer = true where id = '00000000-0000-0000-0000-000000000105';
set role authenticated;
do $$ declare n int; begin
  assert pg_temp.n($q$delete from public.bar_products$q$) = 0, 'trésorier supprime la carte';
  assert pg_temp.n($q$update public.bar_products set active = active where name = 'Tourtel'$q$) = 1, 'trésorier modifie';
end $$;
reset role;
update public.profiles set is_treasurer = false where id = '00000000-0000-0000-0000-000000000105';

-- 4. Documents : archivés (pas effacés), cachés des membres
insert into public.aircraft_documents (aircraft_id, category, title, file_path, file_name)
values (current_setting('t.a')::uuid, 'manuel', 'Doc test', 'z/doc.pdf', 'doc.pdf');
update public.profiles set is_board = true where id = '00000000-0000-0000-0000-000000000106';
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
select public.archive_document((select id from public.aircraft_documents where file_path = 'z/doc.pdf'), true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
set role authenticated;
do $$ begin assert not exists (select 1 from public.aircraft_documents where file_path = 'z/doc.pdf'), 'archivé caché'; end $$;
reset role;
do $$ begin assert exists (select 1 from public.aircraft_documents where file_path = 'z/doc.pdf' and archived_at is not null), 'toujours en base'; end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000106', false);
select public.archive_document((select id from public.aircraft_documents where file_path = 'z/doc.pdf'), false);
do $$ begin assert (select archived_at is null from public.aircraft_documents where file_path = 'z/doc.pdf'), 'restauré'; end $$;

-- 5. Journal : alimenté, lisible par les admins seulement, inaltérable
do $$ begin assert (select count(*) from public.audit_log where table_name = 'aircraft_documents') >= 3, 'journal docs'; end $$;
do $$ begin
  begin delete from public.audit_log; assert false, 'journal effaçable';
  exception when raise_exception then null; end;
  begin update public.audit_log set action = 'x'; assert false;
  exception when raise_exception then null; end;
end $$;
select set_config('request.jwt.claim.sub', current_setting('t.admin'), false);
set role authenticated;
do $$ begin assert (select count(*) from public.audit_log) > 0, 'admin lit le journal'; end $$;
reset role;

-- 6. Annuaire : téléphone masqué
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000110', false);
update public.profiles set phone = '0600000000' where id = '00000000-0000-0000-0000-000000000110';
select public.set_phone_visibility(false);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
do $$ begin
  assert (select e->>'phone' from jsonb_array_elements(public.member_directory()) e
          where e->>'id' = '00000000-0000-0000-0000-000000000110') is null, 'téléphone masqué';
end $$;

-- 7. Demande de suppression puis anonymisation par un admin
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000110', false);
select public.request_account_deletion(true);
do $$ begin assert (select deletion_requested_at is not null from public.profiles where id = auth.uid()), 'demande'; end $$;
select set_config('request.jwt.claim.sub', current_setting('t.admin'), false);
do $$ begin
  begin perform public.anonymize_member(auth.uid()); assert false, 'auto-anonymisation';
  exception when raise_exception then null; end;
end $$;
select public.anonymize_member('00000000-0000-0000-0000-000000000110');
do $$ declare p public.profiles; begin
  select * into p from public.profiles where id = '00000000-0000-0000-0000-000000000110';
  assert p.full_name = 'Ancien membre' and p.phone is null and p.address is null and p.avatar_url is null, 'données effacées';
  assert p.role = 'pending' and p.anonymized_at is not null, 'accès coupé';
  assert not exists (select 1 from public.pilot_weights where user_id = p.id), 'poids effacé';
  assert not exists (select 1 from jsonb_array_elements(public.member_directory()) e where e->>'id' = p.id::text), 'hors annuaire';
  assert exists (select 1 from public.audit_log where table_name = 'profiles' and row_id = p.id::text and details ? 'anonymized_at'), 'journalisé';
  assert not exists (select 1 from public.audit_log where details::text like '%0600000000%'), 'pas de donnée perso dans le journal';
end $$;

-- 8. Infos légales
select public.set_club_info('{"address":"Aérodrome de Marseille Provence","publication_director":"Le président"}');
do $$ begin assert public.get_club_info()->>'address' = 'Aérodrome de Marseille Provence', 'infos légales'; end $$;
select 'test_migration16 OK';
