/**
 * Import d'un export CSV de vols (Aerogest ou tableur) dans le carnet de vol.
 * Lecture tolérante : séparateur ; , ou tabulation, guillemets, en-têtes français reconnus
 * par synonymes, dates JJ/MM/AAAA ou AAAA-MM-JJ, durées 1:35, 1h35, 1,5 ou 95 (minutes).
 */
import { blockMinutes, parseDuration } from "./carnet";

export type ImportField =
  | "date"
  | "dep_place"
  | "dep_time"
  | "arr_place"
  | "arr_time"
  | "aircraft_model"
  | "aircraft_reg"
  | "total"
  | "landings_day"
  | "landings_night"
  | "night"
  | "ifr"
  | "pic_name"
  | "function"
  | "pic"
  | "dual"
  | "instructor"
  | "remarks";

export const IMPORT_FIELDS: { value: ImportField; label: string }[] = [
  { value: "date", label: "Date du vol" },
  { value: "dep_place", label: "Départ : lieu" },
  { value: "dep_time", label: "Départ : heure" },
  { value: "arr_place", label: "Arrivée : lieu" },
  { value: "arr_time", label: "Arrivée : heure" },
  { value: "aircraft_model", label: "Type / modèle d'appareil" },
  { value: "aircraft_reg", label: "Immatriculation" },
  { value: "total", label: "Durée du vol" },
  { value: "landings_day", label: "Atterrissages (jour)" },
  { value: "landings_night", label: "Atterrissages de nuit" },
  { value: "night", label: "Temps de nuit" },
  { value: "ifr", label: "Temps IFR" },
  { value: "pic_name", label: "Nom du commandant de bord" },
  { value: "function", label: "Fonction à bord (CDB, élève, instructeur…)" },
  { value: "pic", label: "Temps CDB" },
  { value: "dual", label: "Temps double commande" },
  { value: "instructor", label: "Temps instructeur" },
  { value: "remarks", label: "Remarques / nature du vol" },
];

/** Synonymes d'en-têtes (minuscules, sans accents ni ponctuation), du plus précis au plus large */
const SYNONYMS: [ImportField, RegExp][] = [
  ["landings_night", /^(nb |nombre )?(atterrissages?|att|aterrissages?|ldg|landings?) (de )?nuit$|^att nuit$/],
  ["night", /^(temps|duree|heures?|hdv) (de )?nuit$|^nuit$|^vol de nuit$/],
  ["dep_time", /^(heure|h|hr) (de )?(depart|decollage|dep)$|^(bloc|block|cale) off$|^off ?block$|^depart heure$|^heure debut$|^debut$|^decollage$/],
  ["arr_time", /^(heure|h|hr) (d )?(arrivee|atterrissage|arr)$|^(bloc|block|cale) on$|^on ?block$|^arrivee heure$|^heure fin$|^fin$/],
  ["dep_place", /^(lieu|terrain|aerodrome|ad|oaci) (de )?(depart|dep)$|^depart( lieu)?$|^de$|^from$|^origine$|^provenance$|^terrain$/],
  ["arr_place", /^(lieu|terrain|aerodrome|ad|oaci) (d )?(arrivee|arr|destination)$|^arrivee( lieu)?$|^a$|^to$|^destination$/],
  ["aircraft_reg", /^immat(riculation)?s?$|^(immat|immatriculation) (avion|appareil)$|^registration$|^reg$|^indicatif$/],
  ["aircraft_model", /^(type|modele)( (d )?(avion|appareil|aeronef|machine))?$|^aeronef$|^appareil$|^avion$|^machine$/],
  ["instructor", /^(temps |heures? |duree )?instructeur$|^inst$|^fi$/],
  ["dual", /^(temps |heures? |duree )?(en )?(double( commande)?|dc|instruction|eleve)$/],
  ["pic", /^(temps |heures? |duree )(cdb|commandant de bord|pic)$|^pic$/],
  ["pic_name", /^(nom (du )?)?(commandant de bord|cdb)$|^(nom )?pilote$|^pilote cdb$/],
  ["function", /^fonction( a bord)?$|^qualite$|^role$|^type de vol$|^nature( du vol)?$|^categorie$/],
  ["ifr", /^(temps |duree )?ifr$/],
  ["landings_day", /^(nb |nombre (d )?)?(atterrissages?|att|aterrissages?|atterro|ldg|landings?)( jour)?$|^atterrissages? de jour$/],
  ["total", /^(duree|temps)( (de )?vol| totale?| bloc| reel)?$|^total( vol)?$|^(heures?|hdv)( de vol)?$|^tdv$/],
  ["date", /^date( (du )?vol)?$|^jour$|^date debut$/],
  ["remarks", /^remarques?$|^observations?$|^commentaires?$|^motif$|^objet$|^description$/],
];

export const norm = (s: string) =>
  s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();

/** Texte d'un fichier : UTF-8, ou Windows-1252 (exports Excel français) si l'UTF-8 est invalide */
export function decodeFile(buf: ArrayBuffer): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(buf).replace(/^﻿/, "");
  } catch {
    return new TextDecoder("windows-1252").decode(buf);
  }
}

/** Lecture CSV (guillemets, retours à la ligne dans les champs), séparateur détecté sur la 1re ligne */
export function parseCsv(text: string): string[][] {
  const firstLine = text.split(/\r?\n/).find((l) => l.trim()) ?? "";
  const count = (c: string) => firstLine.split(c).length - 1;
  const sep = [";", "\t", ","].sort((a, b) => count(b) - count(a))[0];
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          cell += '"';
          i++;
        } else q = false;
      } else cell += ch;
    } else if (ch === '"') q = true;
    else if (ch === sep) {
      row.push(cell);
      cell = "";
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(cell);
      if (row.some((c) => c.trim())) rows.push(row.map((c) => c.trim()));
      row = [];
      cell = "";
    } else cell += ch;
  }
  row.push(cell);
  if (row.some((c) => c.trim())) rows.push(row.map((c) => c.trim()));
  return rows;
}

const REG_RE = /^[A-Z]{1,2}-?[A-Z0-9]{3,5}$/;
const looksReg = (v: string) => REG_RE.test(v.toUpperCase().replace(/\s/g, "")) && /^(F-?[A-Z]{4}|[A-Z]{1,2}-[A-Z0-9]{3,5})$/.test(v.toUpperCase());

/** Ligne d'en-tête : la première des 10 premières lignes qui reconnaît au moins une date et une durée */
export function guessMapping(rows: string[][]): { headerRow: number; mapping: (ImportField | "")[] } {
  let best = { headerRow: 0, mapping: [] as (ImportField | "")[], score: -1 };
  for (let h = 0; h < Math.min(10, rows.length); h++) {
    const used = new Set<ImportField>();
    const mapping = rows[h].map((cell) => {
      const n = norm(cell);
      for (const [f, re] of SYNONYMS) if (!used.has(f) && re.test(n)) return used.add(f), f;
      return "" as const;
    });
    const score = used.size + (used.has("date") ? 5 : 0) + (used.has("total") ? 3 : 0);
    if (score > best.score) best = { headerRow: h, mapping, score };
  }
  // Colonne « Appareil » qui contient en fait des immatriculations
  const data = rows.slice(best.headerRow + 1, best.headerRow + 30);
  best.mapping.forEach((f, i) => {
    if (f !== "aircraft_model" || best.mapping.includes("aircraft_reg")) return;
    const vals = data.map((r) => r[i] ?? "").filter(Boolean);
    if (vals.length && vals.filter(looksReg).length / vals.length > 0.6) {
      best.mapping[i] = "aircraft_reg";
      const typeCol = rows[best.headerRow].findIndex((c, j) => !best.mapping[j] && /^(type|modele)\b/.test(norm(c)));
      if (typeCol >= 0) best.mapping[typeCol] = "aircraft_model";
    }
  });
  return { headerRow: best.headerRow, mapping: best.mapping };
}

export function parseDate(v: string): string | null {
  const s = v.trim();
  let m: RegExpMatchArray | null;
  if ((m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/))) return iso(+m[1], +m[2], +m[3]);
  if ((m = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})/))) {
    const y = m[3].length === 2 ? 2000 + +m[3] - (+m[3] > 50 ? 100 : 0) : +m[3];
    return iso(y, +m[2], +m[1]);
  }
  // Date Excel (nombre de jours depuis 1899-12-30)
  if (/^\d{5}([.,]\d+)?$/.test(s)) {
    const d = new Date(Date.UTC(1899, 11, 30) + Math.floor(Number(s.replace(",", "."))) * 86400000);
    return d.toISOString().slice(0, 10);
  }
  return null;
}
const iso = (y: number, mo: number, d: number) => {
  if (y < 1900 || y > 2100 || mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  const dt = new Date(Date.UTC(y, mo - 1, d));
  return dt.getUTCDate() === d ? dt.toISOString().slice(0, 10) : null;
};

export function parseTime(v: string): string | null {
  const s = v.trim().replace(/\s/g, "");
  const m = s.match(/(\d{1,2})[:hH](\d{2})/) ?? s.match(/^(\d{1,2})(\d{2})$/);
  if (!m) return null;
  const h = +m[1], mi = +m[2];
  return h < 24 && mi < 60 ? `${String(h).padStart(2, "0")}:${String(mi).padStart(2, "0")}` : null;
}

/** Durée : accepte aussi « 01:20:00 » (hh:mm:ss) */
export function parseDur(v: string): number | null {
  const s = v.trim();
  if (!s) return 0;
  const m = s.match(/^(\d{1,5}):(\d{2}):(\d{2})$/);
  if (m) return +m[1] * 60 + +m[2] + (+m[3] >= 30 ? 1 : 0);
  return parseDuration(s);
}

export type Fn = "cdb" | "dc" | "inst";

export function parseFunction(v: string): Fn | null {
  const n = norm(v);
  if (!n) return null;
  if (/instructeur|^fi\b|^inst$/.test(n)) return "inst";
  if (/eleve|double|^dc\b|instruction|ecole|formation|lecon|lache|solo supervise/.test(n)) return "dc";
  if (/cdb|commandant|pilote|pic|solo|local|nav|voyage|perso|prive|loisir/.test(n)) return "cdb";
  return null;
}

export type ImportRow = {
  line: number;
  flight_date: string;
  dep_place: string | null;
  dep_time: string | null;
  arr_place: string | null;
  arr_time: string | null;
  aircraft_model: string | null;
  aircraft_reg: string | null;
  total_min: number;
  landings_day: number;
  landings_night: number;
  night_min: number;
  ifr_min: number;
  pic_name: string | null;
  pic_min: number;
  dual_min: number;
  instructor_min: number;
  remarks: string | null;
};

export type ImportResult = { rows: ImportRow[]; errors: { line: number; message: string }[] };

/** Transforme les lignes du CSV en lignes de carnet. Fonction par défaut si la colonne n'existe pas. */
export function buildRows(rows: string[][], headerRow: number, mapping: (ImportField | "")[], defaultFn: Fn): ImportResult {
  const col = (f: ImportField) => mapping.indexOf(f);
  const out: ImportRow[] = [];
  const errors: ImportResult["errors"] = [];
  const cut = (v: string | undefined, n: number) => (v ?? "").trim().slice(0, n) || null;

  rows.slice(headerRow + 1).forEach((r, k) => {
    const line = headerRow + k + 2;
    const get = (f: ImportField) => (col(f) >= 0 ? (r[col(f)] ?? "").trim() : "");
    const rawDate = get("date");
    if (!rawDate || /^total/i.test(rawDate) || /^total/i.test(r[0] ?? "")) return; // lignes de total
    const date = parseDate(rawDate);
    if (!date) return void errors.push({ line, message: `date illisible « ${rawDate} »` });

    const dep_time = parseTime(get("dep_time")) ?? (/\d{1,2}:\d{2}/.test(rawDate) && col("dep_time") < 0 ? parseTime(rawDate.split(/\s+/)[1] ?? "") : null);
    const arr_time = parseTime(get("arr_time"));
    let total = parseDur(get("total"));
    if (total == null) return void errors.push({ line, message: `durée illisible « ${get("total")} »` });
    if (!total) total = blockMinutes(dep_time, arr_time) ?? 0;
    if (!total) return void errors.push({ line, message: "durée du vol absente" });

    const num = (f: ImportField) => Math.max(0, Math.min(999, Math.round(Number(get(f).replace(",", ".")) || 0)));
    const dur = (f: ImportField) => Math.min(total!, parseDur(get(f)) ?? 0);

    let pic = dur("pic"), dual = dur("dual"), inst = dur("instructor");
    if (!pic && !dual && !inst) {
      const fn = parseFunction(get("function")) ?? defaultFn;
      if (fn === "inst") pic = inst = total;
      else if (fn === "dc") dual = total;
      else pic = total;
    }

    let model = cut(get("aircraft_model"), 40);
    let reg = cut(get("aircraft_reg"), 20)?.toUpperCase().replace(/^F([A-Z]{4})$/, "F-$1") ?? null;
    if (!reg && model && looksReg(model)) [reg, model] = [model.toUpperCase(), null];

    out.push({
      line,
      flight_date: date,
      dep_place: cut(get("dep_place"), 40)?.toUpperCase() ?? null,
      dep_time,
      arr_place: cut(get("arr_place"), 40)?.toUpperCase() ?? null,
      arr_time,
      aircraft_model: model,
      aircraft_reg: reg,
      total_min: total,
      landings_day: col("landings_day") >= 0 ? num("landings_day") : 1,
      landings_night: num("landings_night"),
      night_min: dur("night"),
      ifr_min: dur("ifr"),
      pic_name: cut(get("pic_name"), 80),
      pic_min: pic,
      dual_min: dual,
      instructor_min: inst,
      remarks: cut(get("remarks"), 500),
    });
  });
  return { rows: out, errors };
}

/** Clé de doublon : même date, même avion, même heure de départ (ou même durée) */
export const dupKey = (e: { flight_date: string; aircraft_reg: string | null; dep_time: string | null; total_min: number }) =>
  [e.flight_date, (e.aircraft_reg ?? "").toUpperCase(), e.dep_time ? e.dep_time.slice(0, 5) : `d${e.total_min}`].join("|");
