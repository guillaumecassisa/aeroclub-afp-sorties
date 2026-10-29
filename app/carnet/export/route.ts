import ExcelJS from "exceljs";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { ENTRY_COLUMNS, type LogEntry } from "@/lib/carnet";

export const runtime = "nodejs";

const NAVY = "FF002157";
const days = (m: number) => (m ? m / 1440 : null); // durée Excel (fraction de jour), affichée [h]:mm

/** Carnet de vol complet au format Excel, colonnes du carnet EASA (FCL.050) */
export async function GET() {
  const me = await requireMember();
  const supabase = await createClient();
  const { data } = await supabase.from("logbook_entries").select(ENTRY_COLUMNS).order("flight_date").order("dep_time", { nullsFirst: true });
  const rows = (data ?? []) as LogEntry[];

  const wb = new ExcelJS.Workbook();
  wb.creator = "Aéroclub — carnet de vol";
  const ws = wb.addWorksheet("Carnet de vol", { views: [{ state: "frozen", ySplit: 3 }], pageSetup: { orientation: "landscape", paperSize: 9, fitToPage: true, fitToWidth: 1, fitToHeight: 0 } });

  const cols: { h: string; sub?: string; w: number; get: (e: LogEntry) => unknown; fmt?: string }[] = [
    { h: "Date", w: 11, get: (e) => new Date(e.flight_date + "T12:00:00Z"), fmt: "dd/mm/yyyy" },
    { h: "Départ", sub: "Lieu", w: 9, get: (e) => (e.kind === "report" ? "REPORT" : e.dep_place) },
    { h: "", sub: "Heure", w: 7, get: (e) => e.dep_time?.slice(0, 5) ?? null },
    { h: "Arrivée", sub: "Lieu", w: 9, get: (e) => e.arr_place },
    { h: "", sub: "Heure", w: 7, get: (e) => e.arr_time?.slice(0, 5) ?? null },
    { h: "Aéronef", sub: "Modèle", w: 12, get: (e) => e.aircraft_model },
    { h: "", sub: "Immat", w: 9, get: (e) => e.aircraft_reg },
    { h: "Mono-pilote", sub: "SE", w: 8, get: (e) => days(e.se_min), fmt: "[h]:mm" },
    { h: "", sub: "ME", w: 8, get: (e) => days(e.me_min), fmt: "[h]:mm" },
    { h: "Multi-pilote", w: 9, get: (e) => days(e.multi_pilot_min), fmt: "[h]:mm" },
    { h: "Durée totale", w: 9, get: (e) => days(e.total_min), fmt: "[h]:mm" },
    { h: "Commandant de bord", w: 18, get: (e) => e.pic_name },
    { h: "Atterrissages", sub: "Jour", w: 7, get: (e) => e.landings_day || null },
    { h: "", sub: "Nuit", w: 7, get: (e) => e.landings_night || null },
    { h: "IFR APCH", w: 7, get: (e) => e.ifr_approaches || null },
    { h: "Conditions", sub: "Nuit", w: 8, get: (e) => days(e.night_min), fmt: "[h]:mm" },
    { h: "", sub: "IFR", w: 8, get: (e) => days(e.ifr_min), fmt: "[h]:mm" },
    { h: "Pilote en fonction", sub: "CDB", w: 8, get: (e) => days(e.pic_min), fmt: "[h]:mm" },
    { h: "", sub: "COPI", w: 8, get: (e) => days(e.copilot_min), fmt: "[h]:mm" },
    { h: "", sub: "DC", w: 8, get: (e) => days(e.dual_min), fmt: "[h]:mm" },
    { h: "", sub: "INST", w: 8, get: (e) => days(e.instructor_min), fmt: "[h]:mm" },
    { h: "Simulateur", sub: "Type", w: 10, get: (e) => e.sim_type },
    { h: "", sub: "Durée", w: 8, get: (e) => days(e.sim_min), fmt: "[h]:mm" },
    { h: "Remarques et appositions", w: 40, get: (e) => (e.kind === "report" ? `Report des heures antérieures${e.remarks ? ` — ${e.remarks}` : ""}` : e.remarks) },
  ];

  ws.mergeCells(1, 1, 1, cols.length);
  const title = ws.getCell(1, 1);
  title.value = `Carnet de vol — ${me.full_name || me.email} — exporté le ${new Date().toLocaleDateString("fr-FR", { timeZone: "Europe/Paris" })}`;
  title.font = { bold: true, size: 13, color: { argb: NAVY } };
  const h = ws.getRow(2), s = ws.getRow(3);
  cols.forEach((c, i) => {
    ws.getColumn(i + 1).width = c.w;
    h.getCell(i + 1).value = c.h;
    s.getCell(i + 1).value = c.sub ?? "";
  });
  for (const r of [h, s]) {
    r.font = { bold: true, color: { argb: "FFFFFFFF" }, size: 9 };
    r.alignment = { horizontal: "center", vertical: "middle", wrapText: true };
    r.eachCell((cell) => (cell.fill = { type: "pattern", pattern: "solid", fgColor: { argb: NAVY } }));
  }
  h.height = 28;

  for (const e of rows) {
    const row = ws.addRow(cols.map((c) => c.get(e)));
    cols.forEach((c, i) => c.fmt && (row.getCell(i + 1).numFmt = c.fmt));
    if (e.kind === "report") row.font = { italic: true };
  }
  const first = 4, lastRow = ws.rowCount;
  const total = ws.addRow(cols.map((c, i) => {
    if (i === 0) return "TOTAL";
    const L = ws.getColumn(i + 1).letter;
    return c.fmt === "[h]:mm" || ["Jour", "Nuit"].includes(c.sub ?? "") || c.h === "IFR APCH"
      ? (rows.length ? { formula: `SUM(${L}${first}:${L}${lastRow})` } : 0)
      : null;
  }));
  total.font = { bold: true };
  cols.forEach((c, i) => c.fmt === "[h]:mm" && (total.getCell(i + 1).numFmt = c.fmt));
  total.eachCell((cell) => (cell.border = { top: { style: "medium", color: { argb: NAVY } } }));
  ws.addRow([]);
  ws.addRow(["Je certifie que les informations de ce carnet sont exactes.", ...Array(15).fill(null), "Signature :"]);

  const buf = await wb.xlsx.writeBuffer();
  return new Response(buf, {
    headers: {
      "content-type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "content-disposition": `attachment; filename="carnet-de-vol-${new Date().toISOString().slice(0, 10)}.xlsx"`,
      "cache-control": "no-store",
    },
  });
}
