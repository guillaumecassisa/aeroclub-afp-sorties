\set ON_ERROR_STOP on
set client_min_messages = warning;

select set_config('t.adm', (select id::text from public.profiles where role = 'admin' order by email limit 1), false);
select set_config('t.cp', (select id::text from public.profiles where role = 'member' order by email limit 1), false);
select set_config('t.m', (select id::text from public.profiles where role = 'member' order by email limit 1 offset 1), false);

-- L'admin nomme un chef pilote
select set_config('request.jwt.claim.sub', current_setting('t.adm'), false);
select public.set_function(current_setting('t.cp')::uuid, 'chef_pilote', true);
do $$ begin
  assert (select is_chief_pilot from public.profiles where id = current_setting('t.cp')::uuid), 'chef pilote nommé';
  assert (select role from public.profiles where id = current_setting('t.cp')::uuid) = 'member', 'reste membre';
end $$;

-- Rôles : le chef pilote publie, un simple membre non
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.cp'), false);
do $$ begin
  assert public.can_teach(), 'chef pilote publie';
  assert public.can_organize(), 'chef pilote organise des formations';
end $$;
insert into public.pedagogy_posts (title, body, important) values ('Consigne vent fort', 'Pas de solo au-delà de 15 kt.', true);
insert into public.pedagogy_documents (category, title, file_path, file_name) values ('cours', 'Cours météo', 'cours/meteo.pdf', 'meteo.pdf');
select public.save_outing(null, 'Briefing facteurs humains', 'Club-house', null, null, now() + interval '10 days',
       null, null, null, null, 'formation', 20);

select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  assert not public.can_teach(), 'membre ne publie pas';
  assert (select count(*) from public.pedagogy_posts) = 1, 'membre lit les annonces';
  assert (select count(*) from public.pedagogy_documents) = 1, 'membre lit les documents';
  begin
    insert into public.pedagogy_posts (title, body) values ('x', 'y');
    raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; end;
end $$;

-- REX : un membre en dépose un anonyme et un signé
insert into public.rex_reports (anonymous, author_id, phase, title, description)
values (true, null, 'atterrissage', 'Remise de gaz tardive', 'Vent de travers plus fort que prévu.');
insert into public.rex_reports (anonymous, author_id, phase, title, description)
values (false, current_setting('t.m')::uuid, 'radio', 'Mauvaise fréquence', 'J''ai appelé sur la fréquence précédente.');
do $$ begin
  -- il ne voit que le sien (l'anonyme n'est plus rattaché à lui)
  assert (select count(*) from public.rex_reports) = 1, 'membre ne voit que son REX signé';
  -- impossible de se faire passer pour quelqu'un d'autre ou de publier soi-même
  begin
    insert into public.rex_reports (anonymous, author_id, title, description, status, public_summary)
    values (false, current_setting('t.m')::uuid, 'x', 'y', 'publie', 'z');
    raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; end;
  assert jsonb_array_length(public.rex_published()) = 0, 'rien de publié';
end $$;

-- Le chef pilote voit tout, ne peut pas publier sans résumé, puis publie
select set_config('request.jwt.claim.sub', current_setting('t.cp'), false);
do $$ begin
  assert (select count(*) from public.rex_reports) = 2, 'chef pilote voit tous les REX';
  assert (select author_id from public.rex_reports where anonymous) is null, 'anonymat';
  begin
    update public.rex_reports set status = 'publie' where anonymous;
    raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%résumé%', sqlerrm; end;
end $$;
update public.rex_reports
   set status = 'publie', public_summary = 'Remise de gaz par vent de travers fort.', lessons = 'Annoncer tôt la remise de gaz.',
       description = 'texte modifié', author_id = current_setting('t.cp')::uuid
 where anonymous;
do $$ begin
  assert (select description from public.rex_reports where anonymous) = 'Vent de travers plus fort que prévu.', 'récit intact';
  assert (select author_id from public.rex_reports where anonymous) is null, 'auteur non modifiable';
end $$;

-- Tous les membres voient le REX publié, sans auteur ni récit
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  assert jsonb_array_length(public.rex_published()) = 1, 'REX publié visible';
  assert not (public.rex_published() -> 0 ? 'description'), 'récit d''origine non exposé';
  assert jsonb_array_length(public.rex_reviewers()) >= 1, 'destinataires';
end $$;
reset role;

select 'test_migration29 OK';
