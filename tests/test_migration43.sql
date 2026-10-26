\set ON_ERROR_STOP on
set client_min_messages = warning;
select set_config('t.m', (select id::text from public.profiles where role = 'member' and anonymized_at is null and not is_treasurer order by email limit 1), false);
select set_config('t.tr', (select id::text from public.profiles where is_treasurer and role <> 'pending' order by email limit 1), false);
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.m'), false);
do $$ begin
  begin perform * from public.bar_members(); raise exception 'ATTENDU';
  exception when others then if sqlerrm = 'ATTENDU' then raise; end if; assert sqlerrm like '%trésorier%', sqlerrm; end;
end $$;
select set_config('request.jwt.claim.sub', current_setting('t.tr'), false);
do $$ begin
  assert (select count(*) from public.bar_members()) >= 1, 'le trésorier voit les membres ayant une ardoise';
  assert not exists (select 1 from public.bar_members() b join public.profiles p on p.id = b.id where p.anonymized_at is not null and b.email is not null), 'pas d''email des anciens membres';
end $$;
reset role;
select 'TEST MIGRATION 43 OK';
