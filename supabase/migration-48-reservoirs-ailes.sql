-- =====================================================================
--  Mise à jour n°48 : masse et centrage — réservoirs d'aile gauche et droite
--  Le carburant se saisit réservoir par réservoir, comme dans l'avion :
--    PS28 (2 × 57 L), B23 (2 × 60 L), DA40 (2 × 64 L) : aile gauche + aile droite
--    DR400 : réservoir principal + aile gauche + aile droite (2 × 40 L)
--  Supprime le doublon « réservoir principal + poste Carburant » des PS28 et B23.
--  Le WT9 (réservoir unique) ne change pas.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================
do $$
declare
  r record;
  keep jsonb;
  wing_arm numeric;
  per_side numeric;
  tanks jsonb;
begin
  for r in
    select m.aircraft_id, upper(a.type) as type, m.stations, m.fuel_capacity_l, m.fuel_arm
    from public.aircraft_mb m join public.aircraft a on a.id = m.aircraft_id
  loop
    -- déjà converti
    if r.stations::text ilike '%réservoir aile gauche%' then continue; end if;

    if r.type in ('PS28', 'B23', 'DA40') then
      -- capacité totale : réservoir principal, sinon poste carburant existant
      per_side := coalesce(
        nullif(r.fuel_capacity_l, 0),
        (select max((s->>'max')::numeric) from jsonb_array_elements(r.stations) s where (s->>'fuel')::boolean)
      ) / 2;
      wing_arm := coalesce(
        (select (s->>'arm')::numeric from jsonb_array_elements(r.stations) s where (s->>'fuel')::boolean limit 1),
        r.fuel_arm
      );
      if per_side is null or wing_arm is null then continue; end if;
      select coalesce(jsonb_agg(s), '[]'::jsonb) into keep
        from jsonb_array_elements(r.stations) s where not coalesce((s->>'fuel')::boolean, false);
      tanks := jsonb_build_array(
        jsonb_build_object('label', 'Réservoir aile gauche', 'arm', wing_arm, 'max', per_side, 'fuel', true, 'wing', true),
        jsonb_build_object('label', 'Réservoir aile droite', 'arm', wing_arm, 'max', per_side, 'fuel', true, 'wing', true)
      );
      update public.aircraft_mb
         set stations = keep || tanks, fuel_capacity_l = null, fuel_arm = wing_arm, updated_at = now()
       where aircraft_id = r.aircraft_id;

    elsif r.type = 'DR400' then
      -- réservoir(s) d'aile en un seul poste -> gauche + droite ; le réservoir principal reste
      select (s->>'arm')::numeric, (s->>'max')::numeric / 2 into wing_arm, per_side
        from jsonb_array_elements(r.stations) s
       where (s->>'fuel')::boolean and coalesce((s->>'wing')::boolean, false) limit 1;
      if wing_arm is null then continue; end if;
      select coalesce(jsonb_agg(s), '[]'::jsonb) into keep
        from jsonb_array_elements(r.stations) s
       where not ((s->>'fuel')::boolean and coalesce((s->>'wing')::boolean, false));
      tanks := jsonb_build_array(
        jsonb_build_object('label', 'Réservoir aile gauche', 'arm', wing_arm, 'max', per_side, 'fuel', true, 'wing', true),
        jsonb_build_object('label', 'Réservoir aile droite', 'arm', wing_arm, 'max', per_side, 'fuel', true, 'wing', true)
      );
      update public.aircraft_mb set stations = keep || tanks, updated_at = now() where aircraft_id = r.aircraft_id;
    end if;
  end loop;
end $$;

-- Vérification : plus aucun avion avec à la fois un réservoir principal et un poste carburant
select 'MISE A JOUR 48 OK' as resultat,
       (select count(*) from public.aircraft_mb m
         where coalesce(m.fuel_capacity_l, 0) > 0
           and exists (select 1 from jsonb_array_elements(m.stations) s where (s->>'fuel')::boolean)) as doublons_carburant;
