/**
 * Carnet de vol personnel (colonnes du carnet EASA, FCL.050) et récapitulatif d'expérience :
 * expérience récente pour l'emport de passagers (FCL.060) et prorogation de la qualification
 * de classe SEP par l'expérience (FCL.740.A). Durées en minutes.
 */

export type LogEntry = {
  id: string;
  kind: "vol" | "report";
  flight_date: string; // AAAA-MM-JJ
  dep_place: string | null;
  dep_time: string | null; // HH:MM(:SS)
  arr_place: string | null;
  arr_time: string | null;
  aircraft_model: string | null;
  aircraft_reg: string | null;
  se_min: number;
  me_min: number;
  multi_pilot_min: number;
  total_min: number;
  pic_name: string | null;
  landings_day: number;
  landings_night: number;
  ifr_approaches: number;
  night_min: number;
  ifr_min: number;
  pic_min: number;
  copilot_min: number;
  dual_min: number;
  instructor_min: number;
  sim_date: string | null;
  sim_type: string | null;
  sim_min: number;
  remarks: string | null;
};

export const ENTRY_COLUMNS =
  "id, kind, flight_date, dep_place, dep_time, arr_place, arr_time, aircraft_model, aircraft_reg, se_min, me_min, multi_pilot_min, total_min, pic_name, landings_day, landings_night, ifr_approaches, night_min, ifr_min, pic_min, copilot_min, dual_min, instructor_min, sim_date, sim_type, sim_min, remarks";

/** 95 -> « 1:35 » (heures:minutes, comme dans un carnet de vol) */
export function hm(min: number | null | undefined): string {
  const m = Math.max(0, Math.round(min ?? 0));
  return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, "0")}`;
}

/** « 1:35 », « 1h35 », « 1,5 » (heures décimales) ou « 95 » (minutes) -> minutes ; null si illisible */
export function parseDuration(v: string | null | undefined): number | null {
  const s = String(v ?? "").trim().toLowerCase().replace(/\s+/g, "");
  if (!s) return 0;
  let m: RegExpMatchArray | null;
  if ((m = s.match(/^(\d{1,5})[:h](\d{1,2})?(?:min)?$/))) {
    const mm = Number(m[2] ?? 0);
    return mm < 60 ? Number(m[1]) * 60 + mm : null;
  }
  if ((m = s.match(/^(\d{1,5})[,.](\d{1,2})$/))) return Math.round(Number(`${m[1]}.${m[2]}`) * 60);
  if ((m = s.match(/^(\d{1,5})(?:min|mn|m)?$/))) return Number(m[1]);
  return null;
}

/** Durée entre deux heures « HH:MM » (passage de minuit compris) */
export function blockMinutes(dep: string | null | undefined, arr: string | null | undefined): number | null {
  const p = (t: string | null | undefined) => {
    const m = String(t ?? "").match(/^(\d{1,2}):(\d{2})/);
    return m ? Number(m[1]) * 60 + Number(m[2]) : null;
  };
  const a = p(dep), b = p(arr);
  if (a == null || b == null) return null;
  return (b - a + 1440) % 1440;
}

const DAY = 86400000;
const iso = (d: Date) => d.toISOString().slice(0, 10);
const addDays = (isoDate: string, n: number) => iso(new Date(Date.parse(isoDate + "T12:00:00Z") + n * DAY));
const addMonths = (isoDate: string, n: number) => {
  const d = new Date(isoDate + "T12:00:00Z");
  d.setUTCMonth(d.getUTCMonth() + n);
  return iso(d);
};

export type Window = { from: string; to: string; total: number; pic: number; dual: number; landings: number; nightLandings: number; flights: number };

function sumWindow(entries: LogEntry[], from: string, to: string): Window {
  const w: Window = { from, to, total: 0, pic: 0, dual: 0, landings: 0, nightLandings: 0, flights: 0 };
  for (const e of entries) {
    if (e.kind !== "vol" || e.flight_date < from || e.flight_date > to) continue;
    w.total += e.total_min;
    w.pic += e.pic_min;
    w.dual += e.dual_min;
    w.landings += e.landings_day + e.landings_night;
    w.nightLandings += e.landings_night;
    w.flights += 1;
  }
  return w;
}

export type Recap = {
  today: string;
  totals: { total: number; pic: number; dual: number; instructor: number; night: number; landings: number; nightLandings: number; flights: number; sim: number };
  last90: Window;
  last12m: Window;
  /** Emport de passagers : 3 décollages et atterrissages dans les 90 jours (FCL.060 b) */
  passengers: { ok: boolean; landings: number; validUntil: string | null; nightOk: boolean; nightValidUntil: string | null };
  /** Prorogation SEP par l'expérience, dans les 12 mois précédant l'échéance (FCL.740.A b 1) */
  sep: {
    expiry: string | null;
    window: Window;
    checks: { label: string; done: number; need: number; unit: "h" | "n" }[];
    ok: boolean;
  };
  byType: { model: string; total: number; pic: number; landings: number; last: string | null; last90: number }[];
  lastFlight: string | null;
};

export function computeRecap(entries: LogEntry[], sepExpiry: string | null, today = iso(new Date())): Recap {
  const totals = { total: 0, pic: 0, dual: 0, instructor: 0, night: 0, landings: 0, nightLandings: 0, flights: 0, sim: 0 };
  for (const e of entries) {
    totals.total += e.total_min;
    totals.pic += e.pic_min;
    totals.dual += e.dual_min;
    totals.instructor += e.instructor_min;
    totals.night += e.night_min;
    totals.landings += e.landings_day + e.landings_night;
    totals.nightLandings += e.landings_night;
    totals.sim += e.sim_min;
    if (e.kind === "vol") totals.flights += 1;
  }
  const last90 = sumWindow(entries, addDays(today, -89), today);
  const last12m = sumWindow(entries, addMonths(today, -12), today);

  // Validité de l'emport de passagers : jusqu'à 90 jours après le 3e atterrissage le plus récent
  const flights = entries.filter((e) => e.kind === "vol").sort((a, b) => (a.flight_date < b.flight_date ? 1 : -1));
  const nthLanding = (n: number, night: boolean) => {
    let c = 0;
    for (const e of flights) {
      c += night ? e.landings_night : e.landings_day + e.landings_night;
      if (c >= n) return e.flight_date;
    }
    return null;
  };
  const third = nthLanding(3, false);
  const validUntil = third ? addDays(third, 89) : null;
  const firstNight = nthLanding(1, true);
  const nightValidUntil = firstNight ? addDays(firstNight, 89) : null;

  // SEP : 12 mois précédant l'échéance (ou 12 derniers mois si elle n'est pas renseignée)
  const sepTo = sepExpiry && sepExpiry < today ? sepExpiry : today;
  const sepFrom = sepExpiry ? addMonths(sepExpiry, -12) : addMonths(today, -12);
  const w = sumWindow(entries, sepFrom, sepTo);
  const checks: Recap["sep"]["checks"] = [
    { label: "Heures de vol", done: w.total, need: 12 * 60, unit: "h" },
    { label: "dont commandant de bord", done: w.pic, need: 6 * 60, unit: "h" },
    { label: "Décollages et atterrissages", done: w.landings, need: 12, unit: "n" },
    { label: "Vol d'entraînement avec instructeur", done: w.dual, need: 60, unit: "h" },
  ];

  const types = new Map<string, Recap["byType"][number]>();
  for (const e of entries) {
    const model = (e.aircraft_model || (e.kind === "report" ? "Report antérieur" : "Non précisé")).trim();
    const t = types.get(model) ?? { model, total: 0, pic: 0, landings: 0, last: null, last90: 0 };
    t.total += e.total_min;
    t.pic += e.pic_min;
    t.landings += e.landings_day + e.landings_night;
    if (e.kind === "vol") {
      if (!t.last || e.flight_date > t.last) t.last = e.flight_date;
      if (e.flight_date >= last90.from && e.flight_date <= today) t.last90 += e.total_min;
    }
    types.set(model, t);
  }

  return {
    today,
    totals,
    last90,
    last12m,
    passengers: {
      ok: !!validUntil && validUntil >= today,
      landings: last90.landings,
      validUntil,
      nightOk: !!nightValidUntil && nightValidUntil >= today,
      nightValidUntil,
    },
    sep: { expiry: sepExpiry, window: w, checks, ok: checks.every((c) => c.done >= c.need) },
    byType: [...types.values()].sort((a, b) => b.total - a.total),
    lastFlight: flights[0]?.flight_date ?? null,
  };
}

export const FUNCTIONS = [
  { value: "cdb", label: "Commandant de bord (CDB)" },
  { value: "dc", label: "Double commande (élève, DC)" },
  { value: "inst", label: "Instructeur (INST)" },
  { value: "copi", label: "Copilote (COPI)" },
] as const;
export type Fn = (typeof FUNCTIONS)[number]["value"];

/** Fonction à bord déduite des durées d'une ligne */
export function entryFunction(e: Pick<LogEntry, "pic_min" | "dual_min" | "instructor_min" | "copilot_min">): Fn {
  if (e.instructor_min > 0) return "inst";
  if (e.dual_min > 0 && e.pic_min === 0) return "dc";
  if (e.copilot_min > 0 && e.pic_min === 0) return "copi";
  return "cdb";
}
