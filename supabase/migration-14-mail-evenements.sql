-- =====================================================================
--  Mise à jour n°14 : email à tous les membres quand un événement est
--  publié (chacun peut se désabonner dans « Mon compte »).
-- =====================================================================
alter table public.profiles add column if not exists notify_events boolean not null default true;

-- Destinataires : membres validés, abonnés, sauf la personne qui publie.
-- Réservé aux organisateurs, et seulement pour un événement publié.
create or replace function public.event_mail_recipients(p_outing uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.can_organize() then
    raise exception 'Action réservée aux organisateurs.';
  end if;
  if not exists (select 1 from public.outings where id = p_outing and approval = 'approved' and status = 'open') then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('email', p.email, 'full_name', p.full_name))
    from public.profiles p
    where p.role <> 'pending' and p.notify_events and coalesce(p.email, '') <> ''
      and p.id is distinct from auth.uid()), '[]'::jsonb);
end;
$$;
revoke execute on function public.event_mail_recipients(uuid) from public, anon;
grant execute on function public.event_mail_recipients(uuid) to authenticated;

create or replace function public.set_event_notifications(p_value boolean)
returns void
language sql security definer set search_path = ''
as $$
  update public.profiles set notify_events = p_value where id = auth.uid();
$$;
revoke execute on function public.set_event_notifications(boolean) from public, anon;
grant execute on function public.set_event_notifications(boolean) to authenticated;

notify pgrst, 'reload schema';
