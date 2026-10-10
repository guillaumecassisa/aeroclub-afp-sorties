\set ON_ERROR_STOP on
select set_config('t.nb', (select count(*)::text from public.profiles where role <> 'pending'), false);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000105', false);
set role authenticated;
do $$ declare d jsonb; begin
  d := public.member_directory();
  assert jsonb_array_length(d) = current_setting('t.nb')::int, 'tous les validés';
  assert (select e->'types' from jsonb_array_elements(d) e where e->>'id' = '00000000-0000-0000-0000-000000000104') = '["DR400"]'::jsonb, 'types';
  assert not exists (select 1 from jsonb_array_elements(d) e where e ? 'address' or e ? 'emergency_phone'), 'pas d''adresse';
end $$;
reset role;
\echo '=== TESTS ANNUAIRE PASSÉS ==='
