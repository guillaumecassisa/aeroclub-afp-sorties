import ExcelJS from "exceljs";
import { CLUB_NAME } from "@/lib/email";
import { MONEY, paris, type period, styleSheet, totalRow } from "@/lib/shopExport";
import { lineTotal, type loadBarData } from "@/lib/bar";

const DATETIME = "dd/mm/yyyy hh:mm";
// ExcelJS enregistre les textes comme du texte (jamais comme des formules) : rien à neutraliser
const safe = (v: string | null | undefined) => v ?? "";

/** Classeur Excel du bar (synthèse, ardoises, produits, détail, impayés) pour une période. */
export async function buildBarWorkbook(
  data: Awaited<ReturnType<typeof loadBarData>>,
  p: ReturnType<typeof period>,
  currentMonth: string,
): Promise<Buffer> {
  const rows = data.consumptions
    .map((c) => ({ ...c, d: paris(c.created_at) }))
    .filter((c) => c.d.day >= p.from && c.d.day <= p.to);
  const name = (id: string) => {
    const m = data.members.get(id);
    return safe(m?.full_name || m?.email || "Membre");
  };
  const section = new Map(data.products.map((pr) => [pr.id, pr.category === "snacks" ? "Snacks" : "Boissons"]));
  const wb = new ExcelJS.Workbook();
  wb.creator = CLUB_NAME;
  wb.created = new Date();

  // 1. Synthèse
  const total = rows.reduce((t, c) => t + lineTotal(c), 0);
  const paidSum = rows.filter((c) => data.paid.has(`${c.user_id}|${c.d.month}`)).reduce((t, c) => t + lineTotal(c), 0);
  const syn = wb.addWorksheet("Synthèse");
  syn.addRow([`${CLUB_NAME} — bar`]).font = { bold: true, size: 14 };
  syn.addRow([p.label]);
  syn.addRow([]);
  const kpis: [string, number | string][] = [
    ["Chiffre d'affaires", total / 100],
    ["Déjà réglé", paidSum / 100],
    ["Reste à encaisser", (total - paidSum) / 100],
    ["Consommations", rows.reduce((t, c) => t + c.quantity, 0)],
    ["Membres", new Set(rows.map((c) => c.user_id)).size],
  ];
  for (const [k, v] of kpis) {
    const r = syn.addRow([k, v]);
    if (typeof v === "number" && k !== "Consommations" && k !== "Membres") r.getCell(2).numFmt = MONEY;
  }
  syn.addRow([]);
  const hdr = syn.addRow(["Mois", "Chiffre d'affaires", "Réglé", "Reste à encaisser", "Consommations"]).number;
  const months = new Map<string, { ca: number; paid: number; qty: number }>();
  for (const c of rows) {
    const e = months.get(c.d.month) ?? { ca: 0, paid: 0, qty: 0 };
    e.ca += lineTotal(c);
    e.qty += c.quantity;
    if (data.paid.has(`${c.user_id}|${c.d.month}`)) e.paid += lineTotal(c);
    months.set(c.d.month, e);
  }
  for (const [m, e] of [...months.entries()].sort()) {
    const r = syn.addRow([m, e.ca / 100, e.paid / 100, (e.ca - e.paid) / 100, e.qty]);
    [2, 3, 4].forEach((i) => (r.getCell(i).numFmt = MONEY));
  }
  totalRow(syn, ["Total", total / 100, paidSum / 100, (total - paidSum) / 100, rows.reduce((t, c) => t + c.quantity, 0)], [2, 3, 4]);
  styleSheet(syn, hdr, [26, 20, 16, 20, 16]);
  syn.views = [];
  syn.autoFilter = undefined;

  // 2. Ardoises (membre × mois)
  const ard = wb.addWorksheet("Ardoises");
  ard.addRow(["Mois", "Membre", "Email", "Total", "Réglé", "Réglé le"]);
  const slates = new Map<string, { month: string; user: string; total: number }>();
  for (const c of rows) {
    const k = `${c.user_id}|${c.d.month}`;
    const e = slates.get(k) ?? { month: c.d.month, user: c.user_id, total: 0 };
    e.total += lineTotal(c);
    slates.set(k, e);
  }
  const paidAt = new Map(data.settlements.map((s) => [`${s.user_id}|${s.month.slice(0, 7)}`, s.paid_at]));
  for (const e of [...slates.values()].sort((a, b) => a.month.localeCompare(b.month) || name(a.user).localeCompare(name(b.user)))) {
    const k = `${e.user}|${e.month}`;
    const at = paidAt.get(k);
    const r = ard.addRow([e.month, name(e.user), safe(data.members.get(e.user)?.email), e.total / 100, data.paid.has(k) ? "oui" : "non", at ? paris(at).excel : null]);
    r.getCell(4).numFmt = MONEY;
    r.getCell(6).numFmt = DATETIME;
  }
  styleSheet(ard, 1, [10, 28, 30, 12, 8, 18]);

  // 3. Par produit
  const prod = wb.addWorksheet("Par produit");
  prod.addRow(["Produit", "Section", "Quantité", "Chiffre d'affaires", "Prix moyen"]);
  const byProd = new Map<string, { name: string; section: string; qty: number; ca: number }>();
  for (const c of rows) {
    const e = byProd.get(c.product_name) ?? { name: c.product_name, section: (c.product_id && section.get(c.product_id)) || "Boissons", qty: 0, ca: 0 };
    e.qty += c.quantity;
    e.ca += lineTotal(c);
    byProd.set(c.product_name, e);
  }
  for (const e of [...byProd.values()].sort((a, b) => b.ca - a.ca)) {
    const r = prod.addRow([safe(e.name), e.section, e.qty, e.ca / 100, e.qty ? e.ca / e.qty / 100 : 0]);
    [4, 5].forEach((i) => (r.getCell(i).numFmt = MONEY));
  }
  totalRow(prod, ["Total", "", rows.reduce((t, c) => t + c.quantity, 0), total / 100, null], [4]);
  styleSheet(prod, 1, [28, 12, 12, 18, 12]);

  // 4. Détail des consommations
  const det = wb.addWorksheet("Consommations");
  det.addRow(["Date", "Membre", "Produit", "Quantité", "Prix unitaire", "Total", "Mois réglé"]);
  for (const c of rows) {
    const r = det.addRow([c.d.excel, name(c.user_id), safe(c.product_name), c.quantity, c.unit_price_cents / 100, lineTotal(c) / 100, data.paid.has(`${c.user_id}|${c.d.month}`) ? "oui" : "non"]);
    r.getCell(1).numFmt = DATETIME;
    [5, 6].forEach((i) => (r.getCell(i).numFmt = MONEY));
  }
  styleSheet(det, 1, [18, 28, 26, 10, 14, 12, 12]);

  // 5. Impayés des mois terminés (dans la période)
  const imp = wb.addWorksheet("Impayés");
  imp.addRow(["Membre", "Email", "Mois", "Montant"]);
  const unpaid = [...slates.values()].filter((e) => e.month < currentMonth && !data.paid.has(`${e.user}|${e.month}`) && e.total > 0);
  for (const e of unpaid.sort((a, b) => name(a.user).localeCompare(name(b.user)) || a.month.localeCompare(b.month))) {
    imp.addRow([name(e.user), safe(data.members.get(e.user)?.email), e.month, e.total / 100]).getCell(4).numFmt = MONEY;
  }
  totalRow(imp, ["Total", "", "", unpaid.reduce((t, e) => t + e.total, 0) / 100], [4]);
  styleSheet(imp, 1, [28, 30, 10, 14]);

  return Buffer.from(await wb.xlsx.writeBuffer());
}
