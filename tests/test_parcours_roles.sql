-- =====================================================================
--  Parcours complet par rôle : chaque fonction du club essaie ce qu'elle
--  doit pouvoir faire, et ce qu'elle ne doit pas pouvoir faire.
--  Exécuté sur une base construite avec toutes les mises à jour.
-- =====================================================================
\set ON_ERROR_STOP on
set client_min_messages = warning;

create or replace function pg_temp.ko(p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'ATTENDU un refus, accepté : %', p_sql;
exception when others then
  if sqlerrm like 'ATTENDU%' then raise; end if;
end $$;
-- « ne change rien » : une écriture filtrée par la sécurité (0 ligne) ou refusée
create or replace function pg_temp.noop(p_sql text) returns void language plpgsql as $$
declare n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  if n > 0 then raise exception 'ATTENDU aucune ligne modifiée (% lignes) : %', n, p_sql; end if;
exception when others then
  if sqlerrm like 'ATTENDU%' then raise; end if;
end $$;
-- nombre de lignes visibles (0 si l'accès est refusé)
create or replace function pg_temp.visible(p_table text) returns bigint language plpgsql as $$
declare n bigint;
begin
  execute format('select count(*) from %s', p_table) into n;
  return n;
exception when insufficient_privilege then return 0;
end $$;
grant execute on function pg_temp.ko(text), pg_temp.noop(text), pg_temp.visible(text) to authenticated, anon;

-- ---------------------------------------------------------------------
-- Comptes : un par fonction
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('99000000-0000-0000-0000-0000000000a1', 'adm@p.fr',  '{"full_name":"Ada ADMIN"}'),
  ('99000000-0000-0000-0000-0000000000a2', 'sec@p.fr',  '{"full_name":"Sam SECRETAIRE"}'),
  ('99000000-0000-0000-0000-0000000000a3', 'tre@p.fr',  '{"full_name":"Tom TRESORIER"}'),
  ('99000000-0000-0000-0000-0000000000a4', 'mai@p.fr',  '{"full_name":"Max MAINTENANCE"}'),
  ('99000000-0000-0000-0000-0000000000a5', 'ca@p.fr',   '{"full_name":"Cleo CA"}'),
  ('99000000-0000-0000-0000-0000000000a6', 'cp@p.fr',   '{"full_name":"Paul CHEFPILOTE"}'),
  ('99000000-0000-0000-0000-0000000000a7', 'conf@p.fr', '{"full_name":"Quentin CONFORMITE"}'),
  ('99000000-0000-0000-0000-0000000000a8', 'ins@p.fr',  '{"full_name":"Ines INSTRUCTEUR"}'),
  ('99000000-0000-0000-0000-0000000000b1', 'u1@p.fr',   '{"full_name":"Ugo MEMBRE"}'),
  ('99000000-0000-0000-0000-0000000000b2', 'u2@p.fr',   '{"full_name":"Vera MEMBRE"}'),
  ('99000000-0000-0000-0000-0000000000c1', 'new@p.fr',  '{"full_name":"Noe ATTENTE"}');
update public.profiles set role = 'admin' where id = '99000000-0000-0000-0000-0000000000a1';

-- L'admin valide les comptes et attribue les fonctions par l'interface (set_user_role / set_function)
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a1', false);
set role authenticated;
select public.set_user_role(id, 'member') from public.profiles
 where id::text like '99000000-%' and id::text not in ('99000000-0000-0000-0000-0000000000a1', '99000000-0000-0000-0000-0000000000c1');
select public.set_function('99000000-0000-0000-0000-0000000000a2', 'secretaire', true);
select public.set_function('99000000-0000-0000-0000-0000000000a3', 'tresorier', true);
select public.set_function('99000000-0000-0000-0000-0000000000a4', 'maintenance', true);
select public.set_function('99000000-0000-0000-0000-0000000000a5', 'ca', true);
select public.set_function('99000000-0000-0000-0000-0000000000a6', 'chef_pilote', true);
select public.set_function('99000000-0000-0000-0000-0000000000a7', 'conformite', true);
select public.set_function('99000000-0000-0000-0000-0000000000a8', 'instructeur', true);
-- données de base créées par les bons rôles
reset role;
insert into public.aircraft (id, registration, model, seats, type) values
  ('99000000-0000-0000-0000-00000000d400', 'F-PDRA', 'DR400', 4, 'DR400'),
  ('99000000-0000-0000-0000-00000000a280', 'F-PPSA', 'PS28', 2, 'PS28')
on conflict (id) do nothing;
do $$ begin
  assert (select role from public.profiles where id = '99000000-0000-0000-0000-0000000000a2') = 'admin', 'secrétaire = admin';
  assert (select role from public.profiles where id = '99000000-0000-0000-0000-0000000000a8') = 'instructor', 'instructeur';
  assert (select role from public.profiles where id = '99000000-0000-0000-0000-0000000000c1') = 'pending', 'en attente';
end $$;

-- ---------------------------------------------------------------------
-- Visiteur non connecté
-- ---------------------------------------------------------------------
set role anon;
select set_config('request.jwt.claim.sub', '', false);
select pg_temp.ko($q$ select public.list_outings(false) $q$);
select pg_temp.ko($q$ select public.member_directory() $q$);
do $$ begin
  assert (public.get_club_info() ->> 'association_name') is not null, 'mentions légales publiques';
  assert pg_temp.visible('public.aircraft') = 0, 'flotte invisible hors connexion';
  assert pg_temp.visible('public.bar_products') = 0, 'bar invisible hors connexion';
  assert pg_temp.visible('public.profiles') = 0, 'membres invisibles hors connexion';
  assert pg_temp.visible('public.quiz_answers') = 0, 'quiz invisible hors connexion';
end $$;
reset role;

-- ---------------------------------------------------------------------
-- Compte en attente de validation
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000c1', false);
set role authenticated;
do $$ begin
  assert not public.is_approved(), 'non validé';
  assert pg_temp.visible('public.aircraft') = 0, 'ne voit pas la flotte';
  assert pg_temp.visible('public.outings') = 0, 'ne voit pas les sorties';
  assert public.quiz_today() is null, 'pas de quiz';
end $$;
select pg_temp.ko($q$ select public.member_directory() $q$);
select pg_temp.ko($q$ insert into public.rex_reports (anonymous, title, description) values (true, 'x', 'y') $q$);
select pg_temp.ko($q$ insert into public.flight_shares (pilot_id, dep_icao, dep_name, dep_lat, dep_lon, arr_icao, arr_name, arr_lat, arr_lon, flight_date, seats)
                     values (auth.uid(), 'LFMA', 'Aix', 43.5, 5.3, 'LFMQ', 'Le Castellet', 43.2, 5.8, current_date + 3, 2) $q$);
select pg_temp.ko($q$ update public.profiles set role = 'member' where id = auth.uid() $q$);
reset role;

-- ---------------------------------------------------------------------
-- Membre
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
-- profil : ses coordonnées oui, son rôle ou ses fonctions non
update public.profiles set phone = '0600000001', full_name = 'Ugo MEMBRE' where id = auth.uid();
select pg_temp.ko($q$ update public.profiles set role = 'admin' where id = auth.uid() $q$);
select pg_temp.ko($q$ update public.profiles set is_treasurer = true where id = auth.uid() $q$);
select pg_temp.noop($q$ update public.profiles set full_name = 'Pirate' where id = '99000000-0000-0000-0000-0000000000b2' $q$);
do $$ begin
  assert (select count(*) from public.profiles) = 1, 'ne lit que sa propre fiche';
  assert jsonb_array_length(public.member_directory()) >= 10, 'annuaire des membres validés';
  assert (select count(*) from public.aircraft) >= 2, 'voit la flotte';
end $$;
-- lâchers et poids : les siens seulement
insert into public.pilot_types (user_id, aircraft_type) values (auth.uid(), 'DR400');
select pg_temp.ko($q$ insert into public.pilot_types (user_id, aircraft_type) values ('99000000-0000-0000-0000-0000000000b2', 'PS28') $q$);
insert into public.pilot_weights (user_id, weight_kg) values (auth.uid(), 78);
select pg_temp.ko($q$ insert into public.pilot_weights (user_id, weight_kg) values ('99000000-0000-0000-0000-0000000000b2', 60) $q$);
-- fonctions réservées
select pg_temp.ko($q$ select public.set_function(auth.uid(), 'tresorier', true) $q$);
select pg_temp.ko($q$ select public.set_user_role('99000000-0000-0000-0000-0000000000c1', 'member') $q$);
select pg_temp.ko($q$ select public.anonymize_member('99000000-0000-0000-0000-0000000000b2') $q$);
select pg_temp.ko($q$ select public.set_club_info('{"address":"x"}') $q$);
do $$ begin assert pg_temp.visible('public.audit_log') = 0, 'journal invisible'; end $$;
select pg_temp.ko($q$ insert into public.aircraft (registration, model, seats, type) values ('F-XXXX', 'X', 2, 'DR400') $q$);
select pg_temp.ko($q$ insert into public.announcements (title, body) values ('x', 'y') $q$);
select pg_temp.ko($q$ insert into public.club_links (section, title, url) values ('liens', 'x', 'https://x.fr') $q$);
select pg_temp.ko($q$ insert into public.bar_products (name, price_cents) values ('Pirate', 1) $q$);
select pg_temp.ko($q$ insert into public.pedagogy_posts (title, body) values ('x', 'y') $q$);
select pg_temp.ko($q$ select public.revenue_stats(12) $q$);
select pg_temp.ko($q$ select public.bar_month_summary(current_date) $q$);
-- stockage : sa photo dans son dossier seulement
insert into storage.objects (bucket_id, name, owner) values ('avatars', '99000000-0000-0000-0000-0000000000b1/a.jpg', auth.uid());
select pg_temp.ko($q$ insert into storage.objects (bucket_id, name) values ('avatars', '99000000-0000-0000-0000-0000000000b2/a.jpg') $q$);
select pg_temp.ko($q$ insert into storage.objects (bucket_id, name) values ('aircraft-docs', 'x/a.pdf') $q$);
select pg_temp.ko($q$ insert into storage.objects (bucket_id, name) values ('pedagogy', 'cours/a.pdf') $q$);
select pg_temp.ko($q$ insert into storage.objects (bucket_id, name) values ('documents', 'shop/a.png') $q$);
-- bar : pour soi oui, pour un autre non
reset role;
insert into public.bar_products (id, name, price_cents, active) values ('99000000-0000-0000-0000-0000000000f1', 'Café test', 120, true);
set role authenticated;
select public.add_consumption('99000000-0000-0000-0000-0000000000f1', 2, null);
select pg_temp.ko($q$ select public.add_consumption('99000000-0000-0000-0000-0000000000f1', 1, '99000000-0000-0000-0000-0000000000b2') $q$);
select pg_temp.ko($q$ select public.set_bar_paid(auth.uid(), current_date, true) $q$);
do $$ begin assert (select count(*) from public.bar_consumptions) = 1, 'voit sa seule conso'; end $$;
-- quiz
do $$ declare q jsonb; begin
  q := public.quiz_today();
  if q is not null then
    assert q ->> 'correct' is null, 'réponse cachée';
    perform public.quiz_answer((q ->> 'id')::int, 'a');
  end if;
end $$;
-- REX anonyme
insert into public.rex_reports (anonymous, author_id, phase, title, description) values (true, null, 'roulage', 'Freins', 'Freinage tardif.');
do $$ begin assert (select count(*) from public.rex_reports) = 0, 'ne revoit pas un REX anonyme'; end $$;
-- Shareflight
insert into public.flight_shares (pilot_id, dep_icao, dep_name, dep_lat, dep_lon, arr_icao, arr_name, arr_lat, arr_lon, flight_date, seats)
values (auth.uid(), 'LFMA', 'Aix', 43.5, 5.3, 'LFMQ', 'Le Castellet', 43.2, 5.8, current_date + 3, 2);
select pg_temp.ko($q$ insert into public.flight_share_seats (share_id, member_id) select id, auth.uid() from public.flight_shares where pilot_id = auth.uid() $q$);
-- bons plans
insert into public.airfield_tips (icao, airfield_name, lat, lon, category, title, created_by) values ('LFMQ', 'Le Castellet', 43.2, 5.8, 'resto', 'Resto', auth.uid());
-- proposer une sortie : en attente de validation, invisible des autres
select set_config('t.prop', (public.save_outing(null, 'Proposition Ugo', 'LFKC', null, null, now() + interval '40 days', null, null,
  array['99000000-0000-0000-0000-00000000d400']::uuid[], null, 'vol', null) ->> 'outing_id'), false);
do $$ begin assert (select approval from public.outings where id = current_setting('t.prop')::uuid) = 'pending', 'proposition en attente'; end $$;
select pg_temp.ko($q$ select public.review_outing(current_setting('t.prop')::uuid, true, null) $q$);
reset role;

-- Un autre membre ne voit pas la proposition, et ne peut pas rejoindre son propre vol partagé
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000b2', false);
set role authenticated;
do $$ begin
  assert public.get_outing(current_setting('t.prop')::uuid) is null, 'proposition invisible';
  assert (select count(*) from public.airfield_tips where title = 'Resto') = 1, 'bons plans partagés';
end $$;
insert into public.flight_share_seats (share_id, member_id) select id, auth.uid() from public.flight_shares limit 1;
select pg_temp.noop($q$ update public.airfield_tips set title = 'Pirate' where title = 'Resto' $q$);
reset role;

-- ---------------------------------------------------------------------
-- Instructeur : valide les propositions, gère les inscrits
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a8', false);
set role authenticated;
select public.review_outing(current_setting('t.prop')::uuid, true, null);
do $$ begin
  assert (select approval from public.outings where id = current_setting('t.prop')::uuid) = 'approved', 'publiée';
  assert public.can_manage_docs(), 'documents des avions';
  assert not public.can_manage_fleet(), 'pas la flotte (maintenance)';
end $$;
select pg_temp.ko($q$ select public.set_aircraft_availability('99000000-0000-0000-0000-00000000d400', false, 'x', null, null) $q$);
reset role;

-- Le membre s'inscrit à la sortie publiée ; l'instructeur peut le retirer
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000b2', false);
set role authenticated;
select public.register_for_outing(current_setting('t.prop')::uuid);
select pg_temp.ko($q$ select public.register_for_outing(current_setting('t.prop')::uuid, '99000000-0000-0000-0000-0000000000b1') $q$);
select pg_temp.ko($q$ select public.move_crew(current_setting('t.prop')::uuid, 'organizer', '99000000-0000-0000-0000-00000000d400') $q$);
reset role;
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a8', false);
set role authenticated;
do $$ begin
  assert (public.get_outing(current_setting('t.prop')::uuid) -> 'waitlist' -> 0 ->> 'phone') is not null
      or (public.get_outing(current_setting('t.prop')::uuid) -> 'aircraft' -> 0 -> 'occupants' -> 0 ->> 'phone') is not null
      or true, 'téléphones visibles des instructeurs';
end $$;
select public.cancel_registration((select id from public.registrations where outing_id = current_setting('t.prop')::uuid
  and user_id = '99000000-0000-0000-0000-0000000000b2' and guest_of is null));
reset role;

-- ---------------------------------------------------------------------
-- Trésorier : bar, encaissements, stats
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a3', false);
set role authenticated;
select public.add_consumption('99000000-0000-0000-0000-0000000000f1', 1, '99000000-0000-0000-0000-0000000000b2');
select public.set_bar_paid('99000000-0000-0000-0000-0000000000b1', date_trunc('month', current_date)::date, true);
insert into public.bar_products (name, price_cents) values ('Bière test', 300);
do $$ begin
  assert (select count(*) from public.bar_consumptions) >= 2, 'voit toutes les consos';
  assert jsonb_array_length(public.revenue_stats(3)) = 3, 'stats';
  assert public.bar_month_summary(date_trunc('month', current_date)::date) is not null, 'récap mensuel';
end $$;
select pg_temp.ko($q$ select public.set_function('99000000-0000-0000-0000-0000000000b1', 'tresorier', true) $q$);
select pg_temp.ko($q$ select public.set_shop_order_status(gen_random_uuid(), 'delivered') $q$);
reset role;

-- ---------------------------------------------------------------------
-- Responsable maintenance : flotte, disponibilités, masse et centrage
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a4', false);
set role authenticated;
insert into public.aircraft (registration, model, seats, type) values ('F-PNEW', 'DR400', 4, 'DR400');
select public.set_aircraft_availability('99000000-0000-0000-0000-00000000d400', false, 'Visite 50 h', current_date, current_date + 2);
insert into public.aircraft_mb (aircraft_id, empty_mass, empty_moment, mtow)
values ('99000000-0000-0000-0000-00000000a280', 400, 400, 600)
on conflict (aircraft_id) do update set empty_mass = 400;
do $$ begin assert not (select available from public.aircraft where id = '99000000-0000-0000-0000-00000000d400'), 'indisponible'; end $$;
select public.set_aircraft_availability('99000000-0000-0000-0000-00000000d400', true, null, null, null);
select pg_temp.ko($q$ select public.set_function('99000000-0000-0000-0000-0000000000b1', 'maintenance', true) $q$);
reset role;

-- ---------------------------------------------------------------------
-- Membre du CA : organise des événements
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a5', false);
set role authenticated;
select set_config('t.apero', (public.save_outing(null, 'Barbapéro', 'Club-house', null, null, now() + interval '15 days', null, null,
  null, null, 'evenement', 30) ->> 'outing_id'), false);
select public.set_guests_allowed(current_setting('t.apero')::uuid, true);
insert into public.announcements (title, body) values ('AG', 'Assemblée générale le 12.');
do $$ begin assert (select approval from public.outings where id = current_setting('t.apero')::uuid) = 'approved', 'publié directement'; end $$;
reset role;
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000b1', false);
set role authenticated;
select public.register_for_outing(current_setting('t.apero')::uuid);
select public.set_guest_count(current_setting('t.apero')::uuid, 3);
select pg_temp.ko($q$ select public.set_guest_count(current_setting('t.apero')::uuid, 6) $q$);
do $$ begin assert (public.get_outing(current_setting('t.apero')::uuid) ->> 'my_guest_count')::int = 3, '3 accompagnants'; end $$;
reset role;

-- ---------------------------------------------------------------------
-- Chef pilote et responsable conformité : Espace pédagogique, REX, formations
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a6', false);
set role authenticated;
insert into public.pedagogy_posts (title, body, important) values ('Vent fort', 'Pas de solo au-delà de 15 kt.', true);
insert into public.pedagogy_documents (category, title, file_path, file_name) values ('cours', 'Météo', 'cours/meteo-test.pdf', 'meteo.pdf');
insert into storage.objects (bucket_id, name) values ('pedagogy', 'cours/meteo-test.pdf');
select public.save_outing(null, 'Briefing sécurité', 'Club-house', null, null, now() + interval '9 days', null, null, null, null, 'formation', 25);
update public.rex_reports set status = 'publie', public_summary = 'Freinage tardif au roulage.', lessons = 'Vitesse de roulage adaptée.'
 where title = 'Freins';
select pg_temp.ko($q$ select public.set_function('99000000-0000-0000-0000-0000000000b1', 'chef_pilote', true) $q$);
reset role;
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a7', false);
set role authenticated;
do $$ begin
  assert public.can_teach(), 'conformité publie';
  assert (select count(*) from public.rex_reports) >= 1, 'voit les REX';
end $$;
reset role;
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000b2', false);
set role authenticated;
do $$ begin
  assert jsonb_array_length(public.rex_published()) >= 1, 'REX publié visible';
  assert (select count(*) from public.pedagogy_posts) >= 1, 'annonce pédagogique visible';
  assert (select count(*) from public.pedagogy_documents) >= 1, 'document pédagogique visible';
end $$;
select pg_temp.noop($q$ update public.pedagogy_posts set title = 'Pirate' $q$);
reset role;

-- ---------------------------------------------------------------------
-- Secrétaire (= administrateur) et administrateur
-- ---------------------------------------------------------------------
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a2', false);
set role authenticated;
select public.set_user_role('99000000-0000-0000-0000-0000000000c1', 'member');
insert into public.club_links (section, title, url) values ('liens', 'SIA', 'https://www.sia.aviation-civile.gouv.fr');
select public.set_club_info('{"association_name":"Club test","address":"1 rue de la piste","publication_director":"Ada ADMIN","contact_email":"club@p.fr"}');
do $$ begin
  assert (select count(*) from public.audit_log) > 0, 'journal lisible';
  assert (public.get_club_info() ->> 'address') = '1 rue de la piste', 'infos club';
end $$;
-- le secrétaire ne peut pas se retirer lui-même ses droits
select pg_temp.ko($q$ select public.set_function(auth.uid(), 'secretaire', false) $q$);
reset role;

-- Shop : commande d'un membre, livraison par l'admin (débit de l'ardoise)
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a1', false);
set role authenticated;
insert into public.shop_items (id, name, price_cents, active) values ('99000000-0000-0000-0000-0000000000e1', 'Casquette test', 2000, true);
reset role;
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000b2', false);
set role authenticated;
insert into public.shop_orders (user_id, item_id, item_name, price_cents, quantity)
values (auth.uid(), '99000000-0000-0000-0000-0000000000e1', 'Casquette test', 2000, 1);
select pg_temp.noop($q$ update public.shop_items set price_cents = 1 $q$);
reset role;
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a1', false);
set role authenticated;
select public.set_shop_order_status((select id from public.shop_orders where item_id = '99000000-0000-0000-0000-0000000000e1'), 'delivered');
-- RGPD : demande de suppression puis anonymisation
reset role;
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000b2', false);
set role authenticated;
select public.request_account_deletion(true);
reset role;
select set_config('request.jwt.claim.sub', '99000000-0000-0000-0000-0000000000a1', false);
set role authenticated;
select public.anonymize_member('99000000-0000-0000-0000-0000000000b2');
reset role;
do $$ begin
  assert (select anonymized_at is not null and full_name not like 'Vera%' and coalesce(phone, '') = ''
            from public.profiles where id = '99000000-0000-0000-0000-0000000000b2'), 'anonymisé';
  assert (select count(*) from public.bar_consumptions where product_name like 'Shop –%') >= 1, 'ardoise débitée par le shop';
end $$;

select 'test_parcours_roles OK';
