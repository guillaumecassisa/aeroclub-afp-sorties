-- =====================================================================
--  Mise à jour n°24 : déplacer un membre d'équipage d'un avion à l'autre
--  (glisser-déposer sur la page d'une sortie avion).
--  - Déposer sur un avion qui a une place libre : la personne y est déplacée.
--  - Déposer sur une personne d'un autre avion : les deux échangent leur place.
--  - L'organisateur à bord peut aussi être déplacé ou échangé.
--  Réservé aux organisateurs (instructeurs, CA, fonctions, admin) et à
--  l'organisateur de la sortie.
--  À exécuter une fois dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

create or replace function public.move_crew(
  p_outing   uuid,
  p_who      text,              -- id d'inscription, ou 'organizer'
  p_aircraft uuid,              -- avion de destination
  p_with     text default null  -- échange : id d'inscription, ou 'organizer'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_outing public.outings;
  v_from   uuid;              -- avion de départ
  v_reg    public.registrations;
  v_other  public.registrations;
  v_cap    int;
  v_used   int;
begin
  if v_uid is null then raise exception 'Vous devez être connecté.'; end if;
  if not public.is_approved() then raise exception 'Votre compte n''est pas encore validé.'; end if;

  select * into v_outing from public.outings where id = p_outing for update;
  if not found then raise exception 'Sortie introuvable.'; end if;
  if not (public.can_organize() or v_outing.instructor_id = v_uid) then
    raise exception 'Seul un organisateur peut répartir les équipages.';
  end if;
  if v_outing.status = 'cancelled' then raise exception 'Cette sortie est annulée.'; end if;
  if coalesce(v_outing.kind, 'vol') <> 'vol' then raise exception 'Cet événement n''a pas d''avions.'; end if;
  if not exists (select 1 from public.outing_aircraft where outing_id = p_outing and aircraft_id = p_aircraft) then
    raise exception 'Cet avion ne fait pas partie de la sortie.';
  end if;

  -- Qui bouge, et d'où ?
  if p_who = 'organizer' then
    if v_outing.instructor_aircraft_id is null then raise exception 'L''organisateur n''est pas à bord.'; end if;
    v_from := v_outing.instructor_aircraft_id;
  else
    select * into v_reg from public.registrations
     where id = p_who::uuid and outing_id = p_outing and status = 'confirmed' for update;
    if not found then raise exception 'Cette personne n''a pas de place confirmée dans cette sortie.'; end if;
    v_from := v_reg.aircraft_id;
  end if;
  if v_from = p_aircraft then return; end if;

  if p_with is null then
    -- Déplacement simple : il faut une place libre à l'arrivée
    select greatest(a.seats - case when v_outing.instructor_aircraft_id = a.id then 1 else 0 end, 0)
      into v_cap from public.aircraft a where a.id = p_aircraft;
    select count(*) into v_used from public.registrations
     where outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft;
    -- l'organisateur occupe un siège de plus
    if p_who = 'organizer' then v_cap := v_cap - 1; end if;
    if v_used >= v_cap then
      raise exception 'Cet avion est complet : déposez la personne sur un membre de l''équipage pour échanger leurs places.';
    end if;
    if p_who = 'organizer' then
      update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
    else
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    end if;
  else
    if p_with = p_who then return; end if;
    -- Échange de places avec quelqu'un de l'avion de destination
    if p_with = 'organizer' then
      if v_outing.instructor_aircraft_id is distinct from p_aircraft then
        raise exception 'L''organisateur n''est pas dans cet avion.';
      end if;
      update public.outings set instructor_aircraft_id = v_from where id = p_outing;
      update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
    else
      select * into v_other from public.registrations
       where id = p_with::uuid and outing_id = p_outing and status = 'confirmed' and aircraft_id = p_aircraft for update;
      if not found then raise exception 'Cette personne n''est pas dans cet avion.'; end if;
      update public.registrations set aircraft_id = v_from where id = v_other.id;
      if p_who = 'organizer' then
        update public.outings set instructor_aircraft_id = p_aircraft where id = p_outing;
      else
        update public.registrations set aircraft_id = p_aircraft where id = v_reg.id;
      end if;
    end if;
  end if;

  -- Contrôle final : aucun avion ne dépasse sa capacité
  if exists (
    select 1
    from public.outing_aircraft oa
    join public.aircraft a on a.id = oa.aircraft_id
    join public.outings o on o.id = oa.outing_id
    where oa.outing_id = p_outing
      and (select count(*) from public.registrations r
            where r.outing_id = p_outing and r.status = 'confirmed' and r.aircraft_id = oa.aircraft_id)
          > greatest(a.seats - case when o.instructor_aircraft_id = a.id then 1 else 0 end, 0)
  ) then
    raise exception 'Ce déplacement dépasserait le nombre de places d''un avion.';
  end if;
end;
$$;
revoke execute on function public.move_crew(uuid, text, uuid, text) from public, anon;
grant execute on function public.move_crew(uuid, text, uuid, text) to authenticated;

notify pgrst, 'reload schema';
