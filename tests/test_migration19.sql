\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.admin', (select id::text from public.profiles where role='admin' limit 1), false);
-- flotte complète
do $$ begin assert (select count(*) from public.aircraft where registration in
  ('F-HSAA','F-HNLR','F-HUIT','F-HSAC','F-HPSA','F-HSAG','F-HVXD','F-HUFA','F-HCLI','F-HXAF')) = 10, 'flotte'; end $$;
-- indispo avec période
select set_config('request.jwt.claim.sub', current_setting('t.admin'), false);
select public.set_aircraft_availability((select id from public.aircraft where registration='F-HSAC'), false, 'Nouvelle peinture', '2026-09-07', '2026-10-19');
do $$ begin assert (select unavailable_until = '2026-10-19' and unavailable_reason = 'Nouvelle peinture' from public.aircraft where registration='F-HSAC'); end $$;
do $$ begin
  begin perform public.set_aircraft_availability((select id from public.aircraft where registration='F-HSAC'), false, 'x', '2026-10-19', '2026-09-07'); assert false;
  exception when raise_exception then null; end;
end $$;
select public.set_aircraft_availability((select id from public.aircraft where registration='F-HSAC'), true);
do $$ begin assert (select available and unavailable_until is null from public.aircraft where registration='F-HSAC'); end $$;
-- stats + classement
do $$ begin assert (public.club_stats()->>'active_members')::int > 0, 'membres actifs'; end $$;
update public.profiles set show_in_bar_ranking = true;
insert into public.bar_consumptions (user_id, product_id, product_name, unit_price_cents, quantity)
select '00000000-0000-0000-0000-000000000105', id, name, price_cents, 9 from public.bar_products where active limit 1;
do $$ declare r jsonb := public.bar_ranking(); begin
  assert jsonb_array_length(r) between 1 and 3, 'classement';
  assert r->0->>'name' is not null and (r->0->>'consos')::int > 0 and not (r->0 ? 'total_cents'), 'pas de montant';
end $$;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
select public.set_bar_ranking_visibility(false);
do $$ begin assert not exists (select 1 from jsonb_array_elements(public.bar_ranking()) e
  where e->>'name' like split_part((select full_name from public.profiles where id='00000000-0000-0000-0000-000000000105'),' ',1) || '%'
    and (e->>'consos')::int >= 9), 'retrait du classement'; end $$;
select public.set_bar_ranking_visibility(true);
-- liens : lecture membres, écriture admin
set role authenticated;
do $$ begin assert (select count(*) from public.club_links) >= 9, 'liens visibles'; end $$;
do $$ begin
  begin insert into public.club_links (section, title, url) values ('liens', 'pirate', 'https://x.fr'); assert false;
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'test_migration19 OK';
