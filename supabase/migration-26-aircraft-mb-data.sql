-- =====================================================================
--  Mise à jour n°26 : données masse & centrage depuis les manuels de vol
--  et fiches de pesée de chaque appareil.
--  « Base toi sur les manuels de vol de chaque avion, n'invente rien. »
-- =====================================================================

-- Données d'exemple : posées une seule fois, à la première installation.
-- Relancer ce fichier plus tard ne les recrée pas et ne touche pas aux données saisies sur le site.
create table if not exists public._seeds (name text primary key, done_at timestamptz not null default now());
alter table public._seeds enable row level security;
revoke all on public._seeds from public, anon, authenticated;
create or replace function public._seed_once(p_name text)
returns boolean language plpgsql set search_path = '' as $fn$
begin
  insert into public._seeds (name) values (p_name) on conflict (name) do nothing;
  return found;
end;
$fn$;
revoke execute on function public._seed_once(text) from public, anon, authenticated;

-- -------------------------------------------------------------------------
-- PS-28 Cruiser × 5  (F-HNLR, F-HSAC, F-HUIT, F-HPSA, F-HSAA)
--
-- Sources : Manuel de vol PS-28 Cruiser (Czech Sport Aircraft)
--           + fiches de pesée individuelles
-- MTOW : 600 kg — MLW : 600 kg (avion LSA)
-- Datum : Rib #4 (nervure n°4) — d'après POH section 6.4
-- Réservoir principal : 2 × 57 L (total 114 L), bras 0.180 m
-- Postes (d'après tableau de chargement du POH) :
--   Pilote           0.700 m  max 115 kg
--   Passager         0.700 m  max 115 kg
--   Bagages coffre   1.310 m  max 18 kg
--   Casiers d'aile   0.600 m  max 20 kg  (10 kg par aile × 2, dans l'aile → exclus du MZFW)
--   Carburant        0.180 m  max 114 L  (fuel, density 0.72)
-- Domaine : rectangle 0.420–0.525 m × 400–600 kg
-- -------------------------------------------------------------------------

do $seed$ begin
  if not public._seed_once('centrage-26') then return; end if;
-- F-HNLR
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,             -- numéro de série non disponible dans les documents fournis
  386.5,            -- fiche de pesée F-HNLR
  164.2625,         -- fiche de pesée F-HNLR
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HNLR',
  now()
from public.aircraft a
where a.registration = 'F-HNLR'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HSAC
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  393.0,            -- fiche de pesée F-HSAC
  170.022,          -- fiche de pesée F-HSAC
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HSAC',
  now()
from public.aircraft a
where a.registration = 'F-HSAC'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HUIT
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  387.5,            -- fiche de pesée F-HUIT
  173.212,          -- fiche de pesée F-HUIT
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HUIT',
  now()
from public.aircraft a
where a.registration = 'F-HUIT'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HPSA
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  402.7,            -- fiche de pesée F-HPSA
  173.3057,         -- fiche de pesée F-HPSA
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HPSA',
  now()
from public.aircraft a
where a.registration = 'F-HPSA'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- F-HSAA  (remplace l'entrée partielle de la migration-20)
insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  'C0502',          -- numéro de série (figurait dans la migration-20)
  393.5,            -- fiche de pesée F-HSAA
  169.789,          -- fiche de pesée F-HSAA (169.8 arrondi précédent, valeur exacte)
  600, 600,
  0.180, 0.72, 114,
  '[
    {"label":"Pilote",         "arm":0.700,"max":115},
    {"label":"Passager",       "arm":0.700,"max":115},
    {"label":"Bagages coffre", "arm":1.310,"max":18},
    {"label":"Casiers aile",   "arm":0.600,"max":20, "wing":true},
    {"label":"Carburant",      "arm":0.180,"max":114,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":0.420,"mass":400},
    {"arm":0.420,"mass":600},
    {"arm":0.525,"mass":600},
    {"arm":0.525,"mass":400}
  ]'::jsonb,
  'Manuel de vol PS-28 Cruiser (Czech Sport Aircraft) + fiche de pesée F-HSAA',
  now()
from public.aircraft a
where a.registration = 'F-HSAA'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- Diamond DA40 (F-HXAF)
--
-- Sources : DA40 POH + fiche de pesée F-HXAF
-- MTOW : 1200 kg — MLW : 1150 kg — MZFW : 1150 kg (valeurs F-HXAF confirmées par le club)
-- Datum : bord d'attaque intrados (standard Diamond)
-- Réservoir : 2 × 64 L = 128 L usable, bras 2.630 m
-- Postes :
--   Sièges avant           2.300 m  pas de max individuel (limite structurelle combinée)
--   Sièges arrière         3.250 m  idem
--   Bagages standard       3.650 m  max 30 kg
--   Bagages tube            4.320 m  max 5 kg
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw, mzfw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  774.5,            -- fiche de pesée F-HXAF
  1878.16,          -- fiche de pesée F-HXAF  (en kg.m)
  1200, 1150, 1150,
  2.630, 0.72, 128,
  '[
    {"label":"Sièges avant",      "arm":2.300,"max":null},
    {"label":"Sièges arrière",    "arm":3.250,"max":null},
    {"label":"Bagages standard",  "arm":3.650,"max":30},
    {"label":"Bagages tube",      "arm":4.320,"max":5}
  ]'::jsonb,
  '[
    {"arm":2.40,"mass":780},
    {"arm":2.40,"mass":980},
    {"arm":2.46,"mass":1150},
    {"arm":2.59,"mass":1150},
    {"arm":2.59,"mass":780}
  ]'::jsonb,
  'Manuel de vol Diamond DA40 + fiche de pesée F-HXAF',
  now()
from public.aircraft a
where a.registration = 'F-HXAF'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  mzfw             = excluded.mzfw,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- Robin DR400-180 (F-HCLI)
--
-- Sources : Manuel de vol Robin DR400-180 + fiche de pesée F-HCLI
-- MTOW : 1100 kg — MLW : 1045 kg
-- Datum : bord d'attaque de la voilure rectangulaire
-- Pas de réservoir principal central (fuel_capacity_l = null) :
--   les réservoirs sont 2 postes de chargement en litres.
--   Le bras de référence carburant (fuel_arm) est celui du réservoir principal
--   utilisé comme bras par défaut pour le trip fuel.
-- Postes :
--   Sièges avant      0.410 m  max 154 kg (2 places)
--   Sièges arrière    1.190 m  max 154 kg (2 places)
--   Réservoir princ.  1.120 m  max 110 L  (fuel) — 78 kg / 0.72 = 108.3 L ≈ 110 L (fiche pesée confirme 79.2 kg = 110 L)
--   Réservoir ailes   0.100 m  max 80 L   (fuel, dans l'aile → wing)
--   Bagages           1.900 m  max 60 kg
-- Domaine : trapèze (d'après diagramme manuel DR400)
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow, mlw,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  644.0,            -- fiche de pesée F-HCLI
  211.876,          -- fiche de pesée F-HCLI  (en kg.m)
  1100, 1045,
  1.120, 0.72, null,   -- pas de réservoir central ; bras = réservoir principal
  '[
    {"label":"Sièges avant",          "arm":0.410,"max":154},
    {"label":"Sièges arrière",        "arm":1.190,"max":154},
    {"label":"Réservoir principal",   "arm":1.120,"max":110,"fuel":true},
    {"label":"Réservoir ailes",       "arm":0.100,"max":80, "fuel":true,"wing":true},
    {"label":"Bagages",               "arm":1.900,"max":60}
  ]'::jsonb,
  '[
    {"arm":0.205,"mass":750},
    {"arm":0.328,"mass":1100},
    {"arm":0.564,"mass":1100},
    {"arm":0.428,"mass":750}
  ]'::jsonb,
  'Manuel de vol Robin DR400-180 + fiche de pesée F-HCLI',
  now()
from public.aircraft a
where a.registration = 'F-HCLI'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = excluded.mlw,
  mzfw             = null,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- Bristell B23-915 (F-HUFA)
--
-- Sources : Manuel de vol Bristell B23-915 (ADXC-73-003-AFM, Rév.B3, 24.11.2023)
--           + fiche de pesée F-HUFA (BRM-211, 07.07.2022)
-- MTOW : 750 kg (LSA)
-- S/N : 0077
-- Datum : flasque hélice (Propeller Flange)
-- Conversion %MAC → mètres : bras_m = MAC_LE + (%MAC/100) × MAC = 1.377 + (%MAC/100) × 1.343
-- Réservoir (§2.13) : 2 réservoirs × 60 L = 120 L total ; utilisable 2×56 = 112 L
--   Carburant approuvé : UL95/SP95, AVGAS UL91, AVGAS 100LL
--   bras : 1.600 m (§6.5 — "FUEL weight = qty×0.72 kg/liter, arm 1.600")
-- Postes (§6.5) :
--   Pilote & Passager           2.085 m  max 2×120 kg (voir §6.4 ; min 55 kg pilote)
--   Bagages derrière sièges     2.520 m  max 16 kg (lower 15 kg + upper 1 kg, §2.7)
--   Casiers aile (wing lockers) 2.025 m  max 40 kg (2×20 kg/côté, §2.7) — dans l'aile
--   Carburant                   1.600 m  max 120 L total (fuel)
-- Domaine CG (§2.8 — graphique en %MAC converti en mètres) :
--   %MAC 25%→34.5% (operating CG range)
--   Points clés :  (1.713,530) (1.713,600) (1.753,660) (1.793,750) (1.834,750) (1.840,600) (1.834,530)
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  '0077',
  469.5,            -- fiche de pesée F-HUFA (07.07.2022)
  800.8,            -- fiche de pesée F-HUFA  (en kg.m)
  750,
  1.600, 0.72, 120,   -- §2.13 : 2×60 L = 120 L total
  '[
    {"label":"Pilote & Passager",       "arm":2.085,"max":240},
    {"label":"Bagages derrière sièges", "arm":2.520,"max":16},
    {"label":"Casiers aile",            "arm":2.025,"max":40,"wing":true},
    {"label":"Carburant",               "arm":1.600,"max":120,"fuel":true}
  ]'::jsonb,
  '[
    {"arm":1.713,"mass":530},
    {"arm":1.713,"mass":600},
    {"arm":1.753,"mass":660},
    {"arm":1.793,"mass":750},
    {"arm":1.834,"mass":750},
    {"arm":1.840,"mass":600},
    {"arm":1.834,"mass":530}
  ]'::jsonb,
  'Manuel de vol Bristell B23-915 (ADXC-73-003-AFM Rév.B3) + fiche de pesée F-HUFA (BRM-211 07.07.2022)',
  now()
from public.aircraft a
where a.registration = 'F-HUFA'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = null,
  mzfw             = null,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();

-- -------------------------------------------------------------------------
-- WT9 Dynamic LSA (F-HVXD)
--
-- Sources : Manuel de vol WT9 Dynamic LSA (aerodynamika Žilina)
--           + fiche de pesée F-HVXD
-- MTOW : 600 kg (LSA)
-- Datum : 1.975 m en avant de la face intérieure du pare-feu (firewall)
-- Réservoir : 80 L usable, bras 2.580 m, densité 0.72
-- Postes (tableau Section 6 du POH) :
--   Pilote / Passager   3.130 m  max 120 kg combiné
--   Bagages             3.795 m  max 40 kg (2 × 20 kg)
-- Domaine CG (Section 6 du POH, graphique de centrage) :
--   polygone à 8 points lus sur le diagramme
-- Masse à vide : fiche de pesée F-HVXD (339.6 kg / 898.26 kg.m)
--   NB : le W&B Record du POH indique 344.6 kg / 911.16 kg.m après SB SBLSA-916-2019
--        (mars 2020) — la fiche de pesée individuelle fait foi.
-- -------------------------------------------------------------------------

insert into public.aircraft_mb (
  aircraft_id, serial,
  empty_mass, empty_moment,
  mtow,
  fuel_arm, fuel_density, fuel_capacity_l,
  stations, envelope, source, updated_at
)
select
  a.id,
  null,
  339.6,            -- fiche de pesée F-HVXD
  898.26,           -- fiche de pesée F-HVXD  (en kg.m)
  600,
  2.580, 0.72, 80,
  '[
    {"label":"Pilote / Passager", "arm":3.130,"max":120},
    {"label":"Bagages",           "arm":3.795,"max":40}
  ]'::jsonb,
  '[
    {"arm":2.704,"mass":405.0},
    {"arm":2.713,"mass":405.0},
    {"arm":2.730,"mass":412.0},
    {"arm":2.810,"mass":445.0},
    {"arm":2.824,"mass":465.3},
    {"arm":2.824,"mass":600.0},
    {"arm":2.748,"mass":600.0},
    {"arm":2.704,"mass":542.5}
  ]'::jsonb,
  'Manuel de vol WT9 Dynamic LSA (aerodynamika Žilina) + fiche de pesée F-HVXD',
  now()
from public.aircraft a
where a.registration = 'F-HVXD'
on conflict (aircraft_id) do update set
  serial           = excluded.serial,
  empty_mass       = excluded.empty_mass,
  empty_moment     = excluded.empty_moment,
  mtow             = excluded.mtow,
  mlw              = null,
  mzfw             = null,
  fuel_arm         = excluded.fuel_arm,
  fuel_density     = excluded.fuel_density,
  fuel_capacity_l  = excluded.fuel_capacity_l,
  stations         = excluded.stations,
  envelope         = excluded.envelope,
  source           = excluded.source,
  updated_at       = now();
end $seed$;

notify pgrst, 'reload schema';
