// Masse et centrage : calculs communs (serveur et navigateur).
/**
 * Poste de chargement. `fuel` : réservoir supplémentaire saisi en litres (max = capacité en L).
 * `wing` : charge placée dans l'aile (casier), exclue de la masse « sans charge en aile ».
 */
export type Station = { label: string; arm: number; max: number | null; fuel?: boolean; wing?: boolean };
export type EnvPoint = { arm: number; mass: number };
export type MbData = {
  aircraft_id: string;
  serial: string | null;
  empty_mass: number | null;
  empty_moment: number | null;
  mtow: number | null;
  mlw: number | null;
  mzfw?: number | null;
  fuel_arm: number | null;
  fuel_density: number;
  fuel_capacity_l: number | null;
  stations: Station[];
  envelope: EnvPoint[];
  source: string | null;
  updated_at: string;
};

/** Ce qui manque pour pouvoir calculer. */
export function missingFields(d: MbData | null): string[] {
  if (!d) return ["toutes les données"];
  const m: string[] = [];
  if (!d.empty_mass) m.push("masse à vide");
  if (d.empty_moment == null) m.push("moment à vide");
  if (!d.mtow) m.push("masse maximale au décollage");
  if (d.fuel_arm == null) m.push("bras du carburant");
  if (!d.stations.length) m.push("postes de chargement");
  if (d.envelope.length < 3) m.push("domaine de centrage (au moins 3 points)");
  return m;
}

/** Point dans le polygone (lancer de rayon). */
export function inEnvelope(p: EnvPoint, poly: EnvPoint[]) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const a = poly[i];
    const b = poly[j];
    const cross = a.mass > p.mass !== b.mass > p.mass && p.arm < ((b.arm - a.arm) * (p.mass - a.mass)) / (b.mass - a.mass) + a.arm;
    if (cross) inside = !inside;
  }
  // tolérance : un point exactement sur le bord est accepté
  if (!inside) {
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      const a = poly[i];
      const b = poly[j];
      const cross = (b.arm - a.arm) * (p.mass - a.mass) - (b.mass - a.mass) * (p.arm - a.arm);
      const within =
        Math.min(a.arm, b.arm) - 1e-9 <= p.arm &&
        p.arm <= Math.max(a.arm, b.arm) + 1e-9 &&
        Math.min(a.mass, b.mass) - 1e-9 <= p.mass &&
        p.mass <= Math.max(a.mass, b.mass) + 1e-9;
      if (within && Math.abs(cross) < 1e-6) return true;
    }
  }
  return inside;
}

export type MbPoint = { mass: number; moment: number; cg: number };
export type MbResult = {
  to: MbPoint;
  ldg: MbPoint;
  zf: MbPoint; // sans carburant (centrage le plus arrière en cas de consommation totale)
  zeroWing: number; // masse sans carburant ni charge en aile
  problems: string[];
  ok: boolean;
};

const f1 = (n: number) => n.toLocaleString("fr-FR", { maximumFractionDigits: 1 });
const point = (mass: number, moment: number): MbPoint => ({ mass, moment, cg: moment / mass });

/**
 * loads : une valeur par poste (kg, ou litres pour un poste « carburant »).
 * fuelL / tripL : réservoir principal (litres) et délestage prévu, pris sur ce réservoir.
 */
export function compute(d: MbData, loads: number[], fuelL: number, tripL: number): MbResult {
  const problems: string[] = [];
  const kg = (s: Station, v: number) => (s.fuel ? v * d.fuel_density : v);
  d.stations.forEach((s, i) => {
    const v = loads[i] ?? 0;
    if (s.max != null && v > s.max)
      problems.push(`${s.label} : ${f1(v)} ${s.fuel ? "L" : "kg"} dépasse le maximum de ${s.max} ${s.fuel ? "L" : "kg"}.`);
  });
  if (d.fuel_capacity_l && fuelL > d.fuel_capacity_l) problems.push(`Carburant : ${f1(fuelL)} L dépasse la capacité de ${d.fuel_capacity_l} L.`);
  if (tripL > fuelL) problems.push("Le délestage prévu dépasse le carburant embarqué.");

  const fa = Number(d.fuel_arm);
  let payloadMass = 0, payloadMoment = 0, extraFuelMass = 0, extraFuelMoment = 0, wingMass = 0;
  d.stations.forEach((s, i) => {
    const m = kg(s, loads[i] ?? 0);
    if (s.fuel) {
      extraFuelMass += m;
      extraFuelMoment += m * s.arm;
    } else {
      payloadMass += m;
      payloadMoment += m * s.arm;
      if (s.wing) wingMass += m;
    }
  });
  const zfMass = Number(d.empty_mass) + payloadMass;
  const zfMoment = Number(d.empty_moment) + payloadMoment;
  const fuelKg = fuelL * d.fuel_density;
  const tripKg = Math.min(tripL, fuelL) * d.fuel_density;

  const zf = point(zfMass, zfMoment);
  const to = point(zfMass + extraFuelMass + fuelKg, zfMoment + extraFuelMoment + fuelKg * fa);
  const ldg = point(to.mass - tripKg, to.moment - tripKg * fa);
  const zeroWing = zfMass - wingMass;

  if (d.mtow && to.mass > Number(d.mtow) + 1e-9) problems.push(`Masse au décollage ${f1(to.mass)} kg > MTOW ${d.mtow} kg.`);
  if (d.mlw && ldg.mass > Number(d.mlw) + 1e-9)
    problems.push(
      tripL > 0
        ? `Masse à l'atterrissage ${f1(ldg.mass)} kg > masse max atterrissage ${d.mlw} kg.`
        : `Masse au décollage au-dessus de la masse max à l'atterrissage (${d.mlw} kg) : indiquez le délestage prévu pour vérifier l'atterrissage.`,
    );
  if (d.mzfw && zeroWing > Number(d.mzfw) + 1e-9)
    problems.push(`Masse sans carburant${wingMass || d.stations.some((s) => s.wing) ? " ni charge en aile" : ""} ${f1(zeroWing)} kg > maximum ${d.mzfw} kg.`);
  if (!inEnvelope({ arm: to.cg, mass: to.mass }, d.envelope)) problems.push("Décollage hors du domaine de centrage.");
  if (tripL > 0 && !inEnvelope({ arm: ldg.cg, mass: ldg.mass }, d.envelope)) problems.push("Atterrissage hors du domaine de centrage.");
  if (payloadMass > 0 && !inEnvelope({ arm: zf.cg, mass: zf.mass }, d.envelope))
    problems.push("Sans carburant (réservoirs vides), le centrage sort du domaine.");

  return { to, ldg, zf, zeroWing, problems, ok: problems.length === 0 };
}

/** « Pilote ; 0,70 ; 115 » par ligne -> postes */
export function parseStations(text: string): Station[] | string {
  const out: Station[] = [];
  for (const [n, raw] of text.split("\n").entries()) {
    const line = raw.trim();
    if (!line) continue;
    const [label, arm, max, opts = ""] = line.split(/[;|\t]/).map((x) => x.trim());
    const a = Number(String(arm ?? "").replace(",", "."));
    const m = max ? Number(max.replace(",", ".")) : null;
    if (!label || !Number.isFinite(a) || (m !== null && !(Number.isFinite(m) && m > 0)))
      return `Ligne ${n + 1} des postes invalide : « ${line} » (format : Libellé ; bras en m ; max en kg ; options)`;
    const o = opts.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
    const st: Station = { label: label.slice(0, 40), arm: a, max: m };
    if (/carbu|fuel|essence|\blitres?\b|^l$/.test(o)) st.fuel = true;
    if (/aile|wing/.test(o)) st.wing = true;
    out.push(st);
  }
  return out;
}

/** « 0,420 ; 400 » par ligne -> points du domaine */
export function parseEnvelope(text: string): EnvPoint[] | string {
  const out: EnvPoint[] = [];
  for (const [n, raw] of text.split("\n").entries()) {
    const line = raw.trim();
    if (!line) continue;
    const [arm, mass] = line.split(/[;|\t]/).map((x) => Number(x.trim().replace(",", ".")));
    if (!Number.isFinite(arm) || !Number.isFinite(mass) || mass <= 0)
      return `Ligne ${n + 1} du domaine invalide : « ${line} » (format : bras en m ; masse en kg)`;
    out.push({ arm, mass });
  }
  return out;
}

export function stationsToText(s: Station[]) {
  return s
    .map((x) => {
      const opts = [x.fuel ? "carburant" : "", x.wing ? "aile" : ""].filter(Boolean).join(" ");
      return `${x.label} ; ${x.arm} ; ${x.max ?? ""}${opts ? ` ; ${opts}` : ""}`;
    })
    .join("\n");
}
export function envelopeToText(e: EnvPoint[]) {
  return e.map((p) => `${p.arm} ; ${p.mass}`).join("\n");
}
