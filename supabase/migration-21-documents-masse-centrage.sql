-- =====================================================================
--  Mise à jour n°21
--   1. Nouvelle catégorie de documents « Équipements & avionique »
--   2. Masse et centrage : masse max sans carburant (MZFW) et postes
--      « carburant » (réservoir supplémentaire en litres) / « aile »
--   3. Données de masse et centrage de la flotte, relevées dans les manuels
--      de vol et les fiches de pesée fournis (Inside, export du 25/09/2026)
-- =====================================================================

-- 1. Catégorie « equipements »
alter table public.aircraft_documents drop constraint if exists aircraft_documents_category_check;
alter table public.aircraft_documents add constraint aircraft_documents_category_check
  check (category in ('manuel','checklist','masse_centrage','performances','procedures','administratif','maintenance','equipements','autre'));

-- 2. Masse max sans carburant (ou sans carburant ni charge en aile)
alter table public.aircraft_mb add column if not exists mzfw numeric(7,2) check (mzfw is null or mzfw > 0);

-- 3. Données par avion. Ne remplace que des fiches jamais retouchées à la main
--    (vides, pré-remplies depuis Inside, ou issues de ce même import).
with src (reg, serial, empty_mass, empty_moment, mtow, mlw, mzfw, fuel_arm, fuel_capacity_l, stations, envelope, source) as (
  values
  -- PS-28 Cruiser : manuel de vol PS-POH-1-1-11 §2 et §6 ; domaine 420–525 mm (28–35 % MAC)
  ('F-HSAA', 'C0502', 393.5, 169.789, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée du 03/08/2026 [import 2026-09-25]'),
  ('F-HNLR', 'C0435', 386.5, 164.2625, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée du 16/10/2024 (S/N C0435) [import 2026-09-25]'),
  ('F-HUIT', 'C0409', 387.5, 173.212, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — rapport de pesée du 15/12/2017 [import 2026-09-25]'),
  ('F-HSAC', 'C0531', 393.0, 170.0222, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée du 12/05/2015 [import 2026-09-25]'),
  ('F-HPSA', 'C0658', 402.7, 173.3057, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée PS-28 N Cruiser du 23/03/2022 [import 2026-09-25]'),
  ('F-HSAG', 'C0602', null, null, 600, 600, null, 0.180, 113,
   '[{"label":"Pilote","arm":0.70,"max":115},{"label":"Passager","arm":0.70,"max":115},{"label":"Bagages (coffre arrière)","arm":1.31,"max":18},{"label":"Casier aile gauche","arm":0.60,"max":10,"wing":true},{"label":"Casier aile droite","arm":0.60,"max":10,"wing":true}]',
   '[{"arm":0.420,"mass":300},{"arm":0.420,"mass":600},{"arm":0.525,"mass":600},{"arm":0.525,"mass":300}]',
   'Manuel de vol PS-28 Cruiser (PS-POH-1-1-11) §2 et §6 — fiche de pesée non fournie : masse et moment à vide à saisir [import 2026-09-25]'),
  -- WT9 Dynamic LSA/Club : POH AS-POH-10-508 §2.4, §6.4 (fig. 6-2) et §6.5 ; masse à vide de base (carburant inutilisable inclus)
  ('F-HVXD', 'DY-508/2014 LSA', 344.6, 911.16, 600, 600, null, 2.580, 119,
   '[{"label":"Pilote","arm":3.130,"max":120},{"label":"Passager","arm":3.130,"max":120},{"label":"Bagages (2 × 20 kg max)","arm":3.795,"max":40}]',
   '[{"arm":2.704,"mass":405},{"arm":2.704,"mass":542.5},{"arm":2.748,"mass":600},{"arm":2.824,"mass":600},{"arm":2.824,"mass":465.3},{"arm":2.810,"mass":445},{"arm":2.713,"mass":405}]',
   'POH WT9 Dynamic LSA/Club §2.4 et §6 (fig. 6-2) — pesée du 24/03/2020, masse à vide de base [import 2026-09-25]'),
  -- Bristell B23-915 : AFM ADXC-73-003 §2.7–2.8 et §6 ; MAC 1,343 m, bord d'attaque MAC 1,377 m
  ('F-HUFA', '0077', 469.5, 800.8, 750, 750, 660, 1.600, 112,
   '[{"label":"Pilote","arm":2.085,"max":null},{"label":"Passager","arm":2.085,"max":null},{"label":"Bagages arrière (bas)","arm":2.520,"max":15},{"label":"Bagages arrière (haut)","arm":2.800,"max":1},{"label":"Casier aile gauche","arm":2.025,"max":20,"wing":true},{"label":"Casier aile droite","arm":2.025,"max":20,"wing":true}]',
   '[{"arm":1.7128,"mass":519},{"arm":1.7128,"mass":600},{"arm":1.7934,"mass":750},{"arm":1.8403,"mass":750},{"arm":1.8403,"mass":600},{"arm":1.8067,"mass":519}]',
   'AFM Bristell B23-915 (ADXC-73-003) §2.7, §2.8 et §6 — pesée du 25/01/2023 ; MZFW = masse max sans carburant ni charge en aile [import 2026-09-25]'),
  -- Robin DR400/180 : manuel de vol éd. 20 §2 (plan de chargement) et §6 ; limites de la fiche de pesée (12 % à 25 % / 33 % de 1,71 m)
  ('F-HCLI', null, 644, 211.876, 1100, 1045, null, 1.120, 109,
   '[{"label":"Pilote (siège avant, bras moyen)","arm":0.41,"max":null},{"label":"Passager avant (bras moyen)","arm":0.41,"max":null},{"label":"Passagers arrière (total)","arm":1.19,"max":null},{"label":"Bagages","arm":1.90,"max":60},{"label":"Réservoirs d''ailes","arm":0.10,"max":80,"fuel":true}]',
   '[{"arm":0.2052,"mass":600},{"arm":0.2052,"mass":750},{"arm":0.428,"mass":1100},{"arm":0.564,"mass":1100},{"arm":0.564,"mass":600}]',
   'Manuel de vol DR400/180 éd. 20 §2 et §6 — rapport de pesée du 20/04/2018 ; catégorie Normale [import 2026-09-25]'),
  -- Diamond DA40 : AFM 6.01.01-E §2.7, §6.4 ; réservoirs standard. MTOW 1150 kg tant que la modification
  -- MÄM 40-227 (1200 kg) n'est pas confirmée : la case n'est pas cochée dans le manuel fourni.
  ('F-HXAF', null, 774.5, 1878.16, 1150, 1092, 1150, 2.630, 151,
   '[{"label":"Pilote","arm":2.30,"max":null},{"label":"Passager avant","arm":2.30,"max":null},{"label":"Passagers arrière (total)","arm":3.25,"max":null},{"label":"Bagages (compartiment standard)","arm":3.65,"max":30},{"label":"Tube à bagages (si installé)","arm":4.32,"max":5}]',
   '[{"arm":2.40,"mass":780},{"arm":2.40,"mass":980},{"arm":2.46,"mass":1150},{"arm":2.59,"mass":1150},{"arm":2.59,"mass":780}]',
   'AFM DA 40 (6.01.01-E rév. 8) §2.7 et §6.4 — rapport de pesée (correctif n°1) du 16/02/2018 ; MTOW 1150 kg (1200 kg seulement si MÄM 40-227 appliquée) ; MLW 1092 kg (jambe de train d''origine) [import 2026-09-25]')
)
insert into public.aircraft_mb as m
  (aircraft_id, serial, empty_mass, empty_moment, mtow, mlw, mzfw, fuel_arm, fuel_density, fuel_capacity_l, stations, envelope, source, updated_at, updated_by)
select a.id, s.serial, s.empty_mass::numeric, s.empty_moment::numeric, s.mtow::numeric, s.mlw::numeric, s.mzfw::numeric,
       s.fuel_arm::numeric, 0.72, s.fuel_capacity_l::numeric, s.stations::jsonb, s.envelope::jsonb, s.source, now(), null
from src s
join public.aircraft a on upper(a.registration) = s.reg
on conflict (aircraft_id) do update set
  serial          = coalesce(excluded.serial, m.serial),
  empty_mass      = coalesce(excluded.empty_mass, m.empty_mass),
  empty_moment    = coalesce(excluded.empty_moment, m.empty_moment),
  mtow = excluded.mtow, mlw = excluded.mlw, mzfw = excluded.mzfw,
  fuel_arm = excluded.fuel_arm, fuel_density = excluded.fuel_density, fuel_capacity_l = excluded.fuel_capacity_l,
  stations = excluded.stations, envelope = excluded.envelope, source = excluded.source, updated_at = now()
where m.source is null
   or m.source like 'Repris de l''outil Inside%'
   or m.source like '%[import 2026-09-25]';

notify pgrst, 'reload schema';
