/**
 * Dossier de vol (PDF A4) : masse et centrage + performances décollage / atterrissage d'un avion,
 * généré dans le navigateur. Les deux pages enregistrent leur dernier calcul dans le navigateur
 * (par immatriculation) : le PDF reprend les deux parties si elles ont été remplies le même jour.
 */
import { CLUB_NAME } from "@/lib/club";

export type MbSnapshot = {
  model: string;
  stations: { label: string; arm: number; load: number; unit: string; kg: number }[];
  fuel: { mainL: number | null; tripL: number; density: number; arm: number };
  to: { mass: number; cg: number; moment: number };
  ldg: { mass: number; cg: number; moment: number };
  zf: { mass: number; cg: number; moment: number };
  hasTrip: boolean;
  empty: { mass: number; moment: number };
  mtow: number | null;
  mlw: number | null;
  mzfw: number | null;
  envelope: { arm: number; mass: number }[];
  ok: boolean;
  problems: string[];
  source: string | null;
};

export type PerfPhase = {
  masse: number;
  max: number;
  roll: number;
  d15: number;
  avail: number | null;
  availSrc: string;
  margin: number | null;
  speeds: [string, string][];
  xwLimit: number;
  warnings: string[];
};

export type PerfSnapshot = {
  aircraftId: string;
  label: string;
  terrain: string | null;
  runway: string | null;
  vacCycle: string | null;
  conditions: {
    altiTerrain: number;
    qnh: number;
    alti: number;
    temp: number;
    qfu: number;
    ventDir: number;
    ventForce: number;
    headwind: number;
    crosswind: number;
    piste: string;
  };
  phases: { deco: PerfPhase; atter: PerfPhase };
  dataNote: string;
};

type Stored = { mb?: MbSnapshot & { at: string }; perf?: PerfSnapshot & { at: string } };

const KEY = (reg: string) => `dossier-vol:${reg.toUpperCase()}`;
const parisDay = (d: Date) => d.toLocaleDateString("fr-CA", { timeZone: "Europe/Paris" });

function read(reg: string): Stored {
  try {
    return JSON.parse(localStorage.getItem(KEY(reg)) || "{}") as Stored;
  } catch {
    return {};
  }
}

export function saveDossierPart(reg: string, part: "mb", data: MbSnapshot): void;
export function saveDossierPart(reg: string, part: "perf", data: PerfSnapshot): void;
export function saveDossierPart(reg: string, part: "mb" | "perf", data: MbSnapshot | PerfSnapshot) {
  try {
    const s = read(reg);
    (s as Record<string, unknown>)[part] = { ...data, at: new Date().toISOString() };
    localStorage.setItem(KEY(reg), JSON.stringify(s));
  } catch {
    /* navigateur sans stockage : le PDF ne contiendra que la page en cours */
  }
}

/** Partie enregistrée aujourd'hui pour cet avion (sinon null : un calcul d'un autre jour n'est pas repris). */
export function loadDossierPart<P extends "mb" | "perf">(reg: string, part: P): NonNullable<Stored[P]> | null {
  const p = read(reg)[part];
  return p && parisDay(new Date(p.at)) === parisDay(new Date()) ? (p as NonNullable<Stored[P]>) : null;
}

// ── PDF ──────────────────────────────────────────────────────────────────────────────────

const NAVY: [number, number, number] = [0, 33, 87];
const RED: [number, number, number] = [228, 0, 43];
const GREY: [number, number, number] = [95, 107, 125];
const LINE: [number, number, number] = [210, 215, 224];
const OK: [number, number, number] = [29, 107, 69];
const WARN: [number, number, number] = [154, 91, 10];
const BAD: [number, number, number] = [180, 0, 30];

// Les polices standard du PDF ne connaissent pas certains symboles : on les remplace
const t = (s: string) =>
  String(s)
    .replace(/[≥]/g, ">=")
    .replace(/[≤]/g, "<=")
    .replace(/[≈]/g, "~")
    .replace(/[→]/g, "->")
    .replace(/[−]/g, "-")
    .replace(/[’]/g, "'")
    .replace(/[^\x20-\x7E\xA0-\xFF—–€…«»]/g, "");
const n = (v: number, d = 0) => v.toLocaleString("fr-FR", { minimumFractionDigits: d, maximumFractionDigits: d }).replace(/ | /g, " ");

type DossierOpts = { registration: string; model: string; mb: MbSnapshot | null; perf: PerfSnapshot | null };

/** Télécharge le dossier de vol en PDF (A4). */
export async function downloadDossierVol(opts: DossierOpts) {
  const doc = await buildDossierVol(opts);
  const day = new Date().toLocaleDateString("fr-CA", { timeZone: "Europe/Paris" });
  doc.save(`dossier-de-vol-${opts.registration}-${day}.pdf`);
}

export async function buildDossierVol(opts: DossierOpts) {
  const { jsPDF } = await import("jspdf");
  const doc = new jsPDF({ unit: "mm", format: "a4" });
  const W = 210, M = 12, CW = W - 2 * M;
  const now = new Date();
  const dateLong = now.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: "Europe/Paris" });
  const heure = now.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit", timeZone: "Europe/Paris" });

  const color = (c: [number, number, number]) => doc.setTextColor(c[0], c[1], c[2]);
  const font = (size: number, style: "normal" | "bold" = "normal", c: [number, number, number] = [20, 24, 32]) => {
    doc.setFont("helvetica", style);
    doc.setFontSize(size);
    color(c);
  };
  const text = (s: string, x: number, y: number, o?: { align?: "left" | "right" | "center"; maxWidth?: number }) =>
    doc.text(t(s), x, y, o as never);

  // En-tête
  doc.setFillColor(...NAVY);
  doc.rect(0, 0, W, 26, "F");
  doc.setFillColor(...RED);
  doc.rect(0, 26, W, 1.2, "F");
  font(8, "bold", [190, 200, 220]);
  text(CLUB_NAME.toUpperCase(), M, 9);
  font(18, "bold", [255, 255, 255]);
  text("Dossier de vol", M, 18);
  font(20, "bold", [255, 255, 255]);
  text(opts.registration, W - M, 14, { align: "right" });
  font(9, "normal", [210, 218, 232]);
  text(opts.model, W - M, 20, { align: "right" });

  // Bandeau d'identification
  let y = 34;
  const cells: [string, string][] = [
    ["Date", dateLong.charAt(0).toUpperCase() + dateLong.slice(1)],
    ["Immatriculation", opts.registration],
    ["Type", opts.model],
    ["Établi à", heure],
  ];
  const cw = [70, 40, 46, 30];
  let x = M;
  cells.forEach(([k, v], i) => {
    font(7, "bold", GREY);
    text(k.toUpperCase(), x, y);
    font(10, "bold");
    text(v, x, y + 5);
    x += cw[i];
  });
  y += 9;
  doc.setDrawColor(...LINE);
  doc.line(M, y, W - M, y);
  y += 6;

  const section = (title: string) => {
    font(10, "bold", NAVY);
    doc.setFillColor(...RED);
    doc.rect(M, y - 2.6, 4, 0.8, "F");
    text(title.toUpperCase(), M + 6, y);
    y += 4;
  };

  type Col = { w: number; align?: "left" | "right" | "center" };
  const table = (cols: Col[], rows: string[][], o: { head?: boolean; x?: number; bold?: number[]; rowH?: number; size?: number } = {}) => {
    const x0 = o.x ?? M;
    const rh = o.rowH ?? 5.2;
    const totalW = cols.reduce((a, c) => a + c.w, 0);
    rows.forEach((r, ri) => {
      const isHead = o.head && ri === 0;
      if (isHead) {
        doc.setFillColor(238, 241, 247);
        doc.rect(x0, y - 3.7, totalW, rh, "F");
      }
      let cx = x0;
      r.forEach((cell, ci) => {
        const c = cols[ci];
        font(isHead ? 7 : (o.size ?? 8.5), isHead || o.bold?.includes(ri) ? "bold" : "normal", isHead ? GREY : [20, 24, 32]);
        const tx = c.align === "right" ? cx + c.w - 1.5 : c.align === "center" ? cx + c.w / 2 : cx + 1.5;
        text(isHead ? cell.toUpperCase() : cell, tx, y, { align: c.align ?? "left" });
        cx += c.w;
      });
      doc.setDrawColor(...LINE);
      doc.line(x0, y + rh - 3.7, x0 + totalW, y + rh - 3.7);
      y += rh;
    });
  };

  const bullet = (s: string, c: [number, number, number], x0 = M) => {
    font(8, "normal", c);
    const lines = doc.splitTextToSize(t(s), CW - (x0 - M) - 4) as string[];
    text("•", x0, y);
    lines.forEach((l) => {
      doc.text(l, x0 + 3, y);
      y += 3.8;
    });
  };

  // ── 1. Masse et centrage
  section("1. Masse et centrage");
  const mb = opts.mb;
  if (!mb) {
    font(9, "normal", GREY);
    text("Non renseigné aujourd'hui pour cet avion : remplissez la page « Masse et centrage » puis téléchargez à nouveau le dossier.", M, y + 1, { maxWidth: CW });
    y += 10;
  } else {
    const top = y;
    const rows: string[][] = [["Poste", "Bras (m)", "Charge", "Masse (kg)", "Moment (kg.m)"]];
    rows.push(["Avion à vide", n(mb.empty.moment / mb.empty.mass, 3), "", n(mb.empty.mass, 1), n(mb.empty.moment, 1)]);
    for (const s of mb.stations) rows.push([s.label, n(s.arm, 3), s.load ? `${n(s.load, 1)} ${s.unit}` : "-", n(s.kg, 1), n(s.kg * s.arm, 1)]);
    if (mb.fuel.mainL != null) {
      const kg = mb.fuel.mainL * mb.fuel.density;
      rows.push(["Carburant (réservoir principal)", n(mb.fuel.arm, 3), `${n(mb.fuel.mainL, 0)} L`, n(kg, 1), n(kg * mb.fuel.arm, 1)]);
    }
    rows.push(["Délestage prévu (trip fuel)", "", mb.fuel.tripL ? `${n(mb.fuel.tripL, 0)} L` : "-", mb.fuel.tripL ? `-${n(mb.fuel.tripL * mb.fuel.density, 1)}` : "-", ""]);
    const cols: Col[] = [{ w: 44 }, { w: 15, align: "right" }, { w: 17, align: "right" }, { w: 18, align: "right" }, { w: 22, align: "right" }];
    table(cols, rows, { head: true, size: 8 });
    y += 2;
    const res: string[][] = [
      ["Point", "Masse (kg)", "Maximum", "CG (m)", "Moment"],
      ["Décollage", n(mb.to.mass, 1), mb.mtow ? `${mb.mtow} kg` : "-", n(mb.to.cg, 3), n(mb.to.moment, 1)],
      ["Atterrissage", mb.hasTrip ? n(mb.ldg.mass, 1) : "délestage non saisi", mb.mlw ? `${mb.mlw} kg` : "-", mb.hasTrip ? n(mb.ldg.cg, 3) : "-", mb.hasTrip ? n(mb.ldg.moment, 1) : "-"],
      ["Sans carburant", n(mb.zf.mass, 1), mb.mzfw ? `${mb.mzfw} kg` : "-", n(mb.zf.cg, 3), n(mb.zf.moment, 1)],
    ];
    table(cols, res, { head: true, bold: [1], size: 8 });
    const leftEnd = y;

    // Diagramme de centrage (à droite)
    const gx = M + 122, gw = CW - 122, gy = top - 2, gh = 62;
    const env = mb.envelope;
    const pts = [...env, { arm: mb.to.cg, mass: mb.to.mass }, { arm: mb.zf.cg, mass: mb.zf.mass }, ...(mb.hasTrip ? [{ arm: mb.ldg.cg, mass: mb.ldg.mass }] : [])];
    const a0 = Math.min(...pts.map((p) => p.arm)) - 0.01, a1 = Math.max(...pts.map((p) => p.arm)) + 0.01;
    const m0 = Math.floor((Math.min(...pts.map((p) => p.mass)) - 40) / 50) * 50;
    const m1 = Math.ceil((Math.max(...pts.map((p) => p.mass), mb.mtow ?? 0) + 30) / 50) * 50;
    const L = 12, B = 8;
    const px = (a: number) => gx + L + ((a - a0) / (a1 - a0)) * (gw - L - 2);
    const py = (m: number) => gy + (1 - (m - m0) / (m1 - m0)) * (gh - B);
    doc.setFillColor(247, 248, 251);
    doc.rect(gx, gy, gw, gh, "F");
    font(6, "normal", GREY);
    const mStep = m1 - m0 > 500 ? 100 : 50;
    for (let m = m0; m <= m1; m += mStep) {
      doc.setDrawColor(225, 229, 236);
      doc.line(gx + L, py(m), gx + gw - 2, py(m));
      text(`${m}`, gx + L - 1, py(m) + 1, { align: "right" });
    }
    const aStep = [0.02, 0.05, 0.1, 0.2].find((s) => (a1 - a0) / s <= 6) ?? 0.5;
    for (let a = Math.ceil(a0 / aStep) * aStep; a <= a1; a += aStep) {
      doc.setDrawColor(225, 229, 236);
      doc.line(px(a), gy + 1, px(a), gy + gh - B);
      text(n(a, 2), px(a), gy + gh - B + 3.5, { align: "center" });
    }
    text("Bras (m)  /  masse (kg)", gx + gw / 2, gy + gh - 1, { align: "center" });
    doc.setDrawColor(...NAVY);
    doc.setLineWidth(0.5);
    doc.setLineDashPattern([1.5, 1], 0);
    env.forEach((p, i) => {
      const q = env[(i + 1) % env.length];
      doc.line(px(p.arm), py(p.mass), px(q.arm), py(q.mass));
    });
    doc.setLineDashPattern([], 0);
    if (mb.mtow) {
      doc.setDrawColor(...RED);
      doc.setLineWidth(0.2);
      doc.line(gx + L, py(mb.mtow), gx + gw - 2, py(mb.mtow));
      font(5.5, "normal", RED);
      text(`MTOW ${mb.mtow}`, gx + gw - 3, py(mb.mtow) - 0.8, { align: "right" });
    }
    const dot = (p: { cg: number; mass: number }, c: [number, number, number], label: string, dy: number) => {
      doc.setDrawColor(...c);
      doc.setFillColor(255, 255, 255);
      doc.setLineWidth(0.7);
      doc.circle(px(p.cg), py(p.mass), 1.3, "FD");
      font(6, "bold", c);
      text(label, px(p.cg) + 2, py(p.mass) + dy);
    };
    doc.setLineWidth(0.2);
    if (Math.abs(mb.zf.mass - mb.to.mass) > 0.05) dot(mb.zf, GREY, "ZF", 1);
    if (mb.hasTrip) dot(mb.ldg, WARN, "LDG", 3);
    dot(mb.to, OK, "TO", -1);
    doc.setLineWidth(0.2);

    y = Math.max(leftEnd, gy + gh + 4) + 1;
    // Verdict
    if (mb.ok) {
      doc.setFillColor(231, 244, 236);
      doc.rect(M, y - 3.8, CW, 6, "F");
      font(9, "bold", OK);
      text(`Dans les limites : ${mb.hasTrip ? "décollage et atterrissage" : "décollage (délestage non saisi)"}.`, M + 2, y);
      y += 7;
    } else {
      font(9, "bold", BAD);
      text("Hors limites :", M, y);
      y += 4.5;
      mb.problems.forEach((p) => bullet(p, BAD));
      y += 1;
    }
    if (mb.source) {
      font(6.5, "normal", GREY);
      text(`Données avion : ${mb.source}`, M, y, { maxWidth: CW });
      y += 4;
    }
  }

  y += 2;
  // Beaucoup d'alertes en masse et centrage : les performances passent sur une 2e page
  if (y > 297 - 26 - 100) {
    doc.addPage();
    y = 18;
  }
  // ── 2. Performances
  section("2. Performances décollage / atterrissage");
  const pf = opts.perf;
  if (!pf) {
    font(9, "normal", GREY);
    text("Non renseigné aujourd'hui pour cet avion : remplissez la page « Performances » puis téléchargez à nouveau le dossier.", M, y + 1, { maxWidth: CW });
    y += 10;
  } else {
    const c = pf.conditions;
    const cond: [string, string][] = [
      ["Terrain", pf.terrain ? `${pf.terrain}${pf.runway ? ` — piste ${pf.runway}` : ""}` : "non choisi"],
      ["QFU", `${n(c.qfu)}°`],
      ["Altitude terrain", `${n(c.altiTerrain)} ft`],
      ["QNH", `${n(c.qnh)} hPa`],
      ["Altitude pression", `${n(c.alti)} ft`],
      ["Température (OAT)", `${n(c.temp)} °C`],
      ["Vent", c.ventForce ? `${String(Math.round(c.ventDir)).padStart(3, "0")}° / ${n(c.ventForce)} kt` : "calme"],
      ["Composantes", c.ventForce ? `${c.headwind >= 0 ? "face" : "arrière"} ${Math.abs(c.headwind)} kt · travers ${c.crosswind} kt` : "-"],
      ["État de piste", c.piste === "herbe" ? "herbe sèche" : "dur sec"],
      ["Données de", pf.label],
    ];
    const half = CW / 2;
    for (let i = 0; i < cond.length; i += 2) {
      [cond[i], cond[i + 1]].forEach((kv, j) => {
        if (!kv) return;
        const x0 = M + j * half;
        font(7, "bold", GREY);
        text(kv[0], x0, y);
        font(8.5, "bold");
        text(kv[1], x0 + 30, y, { maxWidth: half - 32 });
      });
      y += 4.6;
    }
    y += 1.5;
    const d = pf.phases.deco, a = pf.phases.atter;
    const margin = (p: PerfPhase) =>
      p.margin == null ? "distance disponible non saisie" : `${p.margin >= 0 ? "+" : ""}${n(p.margin)} m (${n((p.margin / (p.avail || 1)) * 100)} %)`;
    const avail = (p: PerfPhase, k: string) => (p.avail ? `${n(p.avail)} m ${k}${p.availSrc ? ` (${p.availSrc})` : ""}` : "-");
    const sp = (p: PerfPhase, i: number) => (p.speeds[i] ? `${p.speeds[i][0]} : ${p.speeds[i][1]}` : "");
    const rows: string[][] = [
      ["", "Décollage", "Atterrissage"],
      ["Masse", `${n(d.masse)} kg (max ${n(d.max)})`, `${n(a.masse)} kg (max ${n(a.max)})`],
      ["Distance de roulement", `${n(d.roll)} m`, `${n(a.roll)} m`],
      ["Distance passage 15 m (50 ft)", `${n(d.d15)} m`, `${n(a.d15)} m`],
      ["Distance disponible", avail(d, "TORA"), avail(a, "LDA")],
      ["Marge", margin(d), margin(a)],
      ["Vitesses (manuel de vol)", sp(d, 0), sp(a, 0)],
      ["", sp(d, 1), sp(a, 1)],
      ["Traversier démontré", `${d.xwLimit} kt`, `${a.xwLimit} kt`],
    ];
    const cols: Col[] = [{ w: 58 }, { w: (CW - 58) / 2 }, { w: (CW - 58) / 2 }];
    table(cols, rows, { head: true, bold: [3, 5], size: 8 });
    // Alertes
    const alerts: [string, [number, number, number]][] = [];
    for (const [k, p] of [["Décollage", d], ["Atterrissage", a]] as const) {
      if (p.margin != null && p.margin < 0) alerts.push([`${k} : distance nécessaire supérieure à la distance disponible.`, BAD]);
      else if (p.margin != null && p.avail && p.margin / p.avail < 0.2) alerts.push([`${k} : marge inférieure à 20 %.`, WARN]);
      if (c.crosswind >= p.xwLimit) alerts.push([`${k} : vent traversier ${c.crosswind} kt >= limite démontrée ${p.xwLimit} kt.`, BAD]);
    }
    const warn = Array.from(new Set([...d.warnings, ...a.warnings]));
    if (alerts.length || warn.length) {
      y += 1;
      alerts.forEach(([s, col]) => bullet(s, col));
      warn.forEach((s) => bullet(s, WARN));
    }
    y += 1;
    font(6.5, "normal", GREY);
    const note = doc.splitTextToSize(t(`Données : ${pf.dataNote}${pf.vacCycle ? ` Distances déclarées : carte VAC SIA, cycle ${pf.vacCycle}.` : ""}`), CW) as string[];
    note.slice(0, 4).forEach((l) => {
      doc.text(l, M, y);
      y += 3;
    });
  }

  // Pied de page : visa et avertissement
  const fy = 297 - 26;
  // Place restante : cadre de notes (carburant, NOTAM, fréquences…)
  if (fy - y > 22) {
    y += 3;
    font(7, "bold", GREY);
    text("NOTES (CARBURANT, NOTAM, FRÉQUENCES, ROUTE…)", M, y);
    doc.setDrawColor(...LINE);
    doc.rect(M, y + 2, CW, fy - y - 6);
    for (let ly = y + 9; ly < fy - 5; ly += 7) doc.line(M + 3, ly, W - M - 3, ly);
  }
  doc.setDrawColor(...LINE);
  doc.line(M, fy, W - M, fy);
  font(8, "bold", NAVY);
  text("Commandant de bord", M, fy + 6);
  text("Signature", M + 95, fy + 6);
  doc.setDrawColor(150, 158, 172);
  doc.line(M + 32, fy + 6.5, M + 88, fy + 6.5);
  doc.line(M + 112, fy + 6.5, W - M, fy + 6.5);
  font(6.5, "normal", GREY);
  text(
    "Document d'aide à la préparation du vol, établi à partir des manuels de vol et des fiches de pesée enregistrés sur le site du club. Il ne remplace pas le manuel de vol de l'avion ni le jugement du commandant de bord, seul responsable de la préparation du vol.",
    M,
    fy + 12,
    { maxWidth: CW },
  );
  font(6.5, "normal", GREY);
  text(`${CLUB_NAME} — dossier de vol ${opts.registration} du ${now.toLocaleDateString("fr-FR", { timeZone: "Europe/Paris" })}`, M, 297 - 6);

  return doc;
}
