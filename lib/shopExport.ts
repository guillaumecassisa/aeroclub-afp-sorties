import ExcelJS from "exceljs";
import { CLUB_NAME } from "@/lib/email";
import {
  ACTIVE_STATUSES,
  MOVE_REASONS,
  ORDER_STATUS,
  itemVariants,
  type loadShopData,
  saleDate,
  variantKey,
  variantLabel,
  type StockMove,
} from "@/lib/shop";

export const NAVY = "FF14315C";
export const MONEY = '#,##0.00 "€"';
const DATE = "dd/mm/yyyy";
const DATETIME = "dd/mm/yyyy hh:mm";

/** Composantes d'une date à l'heure de Paris. */
export function paris(iso: string) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: "Europe/Paris",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(new Date(iso))
      .map((p) => [p.type, p.value]),
  );
  const day = `${parts.year}-${parts.month}-${parts.day}`;
  // Date « locale » pour Excel (Excel n'a pas de fuseau horaire)
  const excel = new Date(Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute));
  return { day, month: `${parts.year}-${parts.month}`, year: parts.year, excel };
}

const isDay = (v: string | null) => !!v && /^\d{4}-\d{2}-\d{2}$/.test(v);

export function period(sp: URLSearchParams, depuis = "Depuis l'ouverture du shop") {
  const today = paris(new Date().toISOString());
  const y = +today.year;
  switch (sp.get("periode")) {
    case "mois":
      return { from: `${today.month}-01`, to: today.day, label: `Mois de ${today.month}`, slug: today.month };
    case "annee-precedente":
      return { from: `${y - 1}-01-01`, to: `${y - 1}-12-31`, label: `Année ${y - 1}`, slug: String(y - 1) };
    case "tout":
      return { from: "2000-01-01", to: today.day, label: depuis, slug: "complet" };
    case "dates": {
      const du = sp.get("du"), au = sp.get("au");
      if (isDay(du) && isDay(au) && du! <= au!) return { from: du!, to: au!, label: `Du ${du} au ${au}`, slug: `${du}_${au}` };
      return { from: `${y}-01-01`, to: today.day, label: `Année ${y}`, slug: String(y) };
    }
    default:
      return { from: `${y}-01-01`, to: today.day, label: `Année ${y}`, slug: String(y) };
  }
}

export function styleSheet(ws: ExcelJS.Worksheet, headerRow: number, widths: number[]) {
  widths.forEach((w, i) => (ws.getColumn(i + 1).width = w));
  const row = ws.getRow(headerRow);
  row.font = { bold: true, color: { argb: "FFFFFFFF" } };
  row.fill = { type: "pattern", pattern: "solid", fgColor: { argb: NAVY } };
  row.alignment = { vertical: "middle", wrapText: true };
  row.height = 22;
  ws.views = [{ state: "frozen", ySplit: headerRow }];
  if (ws.rowCount > headerRow) {
    ws.autoFilter = { from: { row: headerRow, column: 1 }, to: { row: headerRow, column: widths.length } };
  }
}

export function totalRow(ws: ExcelJS.Worksheet, values: (string | number | null)[], moneyCols: number[] = []) {
  const r = ws.addRow(values);
  r.font = { bold: true };
  r.border = { top: { style: "thin" } };
  moneyCols.forEach((c) => (r.getCell(c).numFmt = MONEY));
}

/** Construit le classeur Excel du shop (ventes, CA, commandes, stock, mouvements) pour une période. */
export async function buildShopWorkbook(
  data: Awaited<ReturnType<typeof loadShopData>>,
  moves: { rows: StockMove[] },
  p: ReturnType<typeof period>,
): Promise<Buffer> {
  const inPeriod = (iso: string) => {
    const d = paris(iso).day;
    return d >= p.from && d <= p.to;
  };
  const items = new Map(data.items.map((i) => [i.id, i]));
  const cost = (itemId: string) => items.get(itemId)?.cost_cents ?? null;
  const sales = data.orders
    .filter((o) => o.status === "delivered" && inPeriod(saleDate(o)))
    .sort((a, b) => saleDate(a).localeCompare(saleDate(b)));
  const ordersInPeriod = data.orders.filter((o) => inPeriod(o.created_at)).reverse();

  const wb = new ExcelJS.Workbook();
  wb.creator = CLUB_NAME;
  wb.created = new Date();

  // ── 1. Synthèse ──────────────────────────────────────────────────────────────
  const ca = sales.reduce((t, o) => t + o.price_cents * o.quantity, 0);
  const units = sales.reduce((t, o) => t + o.quantity, 0);
  const salesWithCost = sales.filter((o) => cost(o.item_id) != null);
  const margin = salesWithCost.reduce((t, o) => t + (o.price_cents - (cost(o.item_id) ?? 0)) * o.quantity, 0);
  const active = data.orders.filter((o) => (ACTIVE_STATUSES as readonly string[]).includes(o.status));
  const syn = wb.addWorksheet("Synthèse");
  syn.getColumn(1).width = 44;
  syn.getColumn(2).width = 20;
  syn.addRow([`${CLUB_NAME} — Shop : ventes et chiffre d'affaires`]).font = { bold: true, size: 14, color: { argb: NAVY } };
  syn.addRow([`Période : ${p.label}`]);
  syn.addRow([`Fichier généré le ${new Date().toLocaleString("fr-FR", { timeZone: "Europe/Paris" })}`]).font = { italic: true, color: { argb: "FF6B7280" } };
  syn.addRow([]);
  const kpis: [string, number, boolean][] = [
    ["Chiffre d'affaires (articles remis)", ca / 100, true],
    ["Commandes remises", sales.length, false],
    ["Articles vendus", units, false],
    ["Panier moyen", sales.length ? ca / sales.length / 100 : 0, true],
    ["Marge (articles avec prix d'achat renseigné)", margin / 100, true],
    ["Commandes passées sur la période", ordersInPeriod.length, false],
    ["Commandes annulées sur la période", ordersInPeriod.filter((o) => o.status === "cancelled").length, false],
    ["Commandes en cours aujourd'hui", active.length, false],
    ["Montant des commandes en cours", active.reduce((t, o) => t + o.price_cents * o.quantity, 0) / 100, true],
  ];
  for (const [label, value, money] of kpis) {
    const r = syn.addRow([label, value]);
    r.getCell(1).font = { bold: true };
    if (money) r.getCell(2).numFmt = MONEY;
  }
  syn.addRow([]);
  syn.addRow(["CA par mois"]).font = { bold: true, size: 12, color: { argb: NAVY } };
  const head = syn.addRow(["Mois", "Commandes", "Articles", "Chiffre d'affaires", "Marge"]);
  head.font = { bold: true, color: { argb: "FFFFFFFF" } };
  head.fill = { type: "pattern", pattern: "solid", fgColor: { argb: NAVY } };
  [3, 4, 5].forEach((c) => (syn.getColumn(c).width = 18));
  const byMonth = new Map<string, { n: number; u: number; ca: number; m: number }>();
  for (const o of sales) {
    const k = paris(saleDate(o)).month;
    const v = byMonth.get(k) ?? { n: 0, u: 0, ca: 0, m: 0 };
    v.n += 1;
    v.u += o.quantity;
    v.ca += o.price_cents * o.quantity;
    const c = cost(o.item_id);
    if (c != null) v.m += (o.price_cents - c) * o.quantity;
    byMonth.set(k, v);
  }
  for (const [k, v] of [...byMonth.entries()].sort()) {
    const r = syn.addRow([k, v.n, v.u, v.ca / 100, v.m / 100]);
    r.getCell(4).numFmt = MONEY;
    r.getCell(5).numFmt = MONEY;
  }
  totalRow(syn, ["Total", sales.length, units, ca / 100, margin / 100], [4, 5]);

  // ── 2. Ventes ────────────────────────────────────────────────────────────────
  const ws = wb.addWorksheet("Ventes");
  ws.addRow(["Date de remise", "Commande", "Membre", "Article", "Taille", "Couleur", "Qté", "Prix unitaire", "Total", "Prix d'achat unitaire", "Marge", "Débité sur l'ardoise"]);
  for (const o of sales) {
    const c = cost(o.item_id);
    const r = ws.addRow([
      paris(saleDate(o)).excel, o.id.slice(0, 8), o.member?.full_name ?? "", o.item_name, o.size ?? "", o.color ?? "",
      o.quantity, o.price_cents / 100, (o.price_cents * o.quantity) / 100,
      c != null ? c / 100 : null, c != null ? ((o.price_cents - c) * o.quantity) / 100 : null,
      o.ardoise_charged ? "oui" : "non",
    ]);
    r.getCell(1).numFmt = DATE;
    [8, 9, 10, 11].forEach((n) => (r.getCell(n).numFmt = MONEY));
  }
  styleSheet(ws, 1, [14, 11, 24, 26, 10, 12, 7, 13, 13, 16, 13, 12]);
  totalRow(ws, ["Total", null, null, null, null, null, units, null, ca / 100, null, margin / 100, null], [9, 11]);

  // ── 3. Par article ───────────────────────────────────────────────────────────
  const wa = wb.addWorksheet("Par article");
  wa.addRow(["Article", "Catégorie", "Quantité vendue", "Chiffre d'affaires", "Marge", "Part du CA"]);
  const byItem = new Map<string, { name: string; cat: string; q: number; ca: number; m: number | null }>();
  for (const o of sales) {
    const v = byItem.get(o.item_name) ?? { name: o.item_name, cat: items.get(o.item_id)?.category ?? "", q: 0, ca: 0, m: 0 };
    v.q += o.quantity;
    v.ca += o.price_cents * o.quantity;
    const c = cost(o.item_id);
    v.m = c != null && v.m != null ? v.m + (o.price_cents - c) * o.quantity : null;
    byItem.set(o.item_name, v);
  }
  for (const v of [...byItem.values()].sort((a, b) => b.ca - a.ca)) {
    const r = wa.addRow([v.name, v.cat, v.q, v.ca / 100, v.m != null ? v.m / 100 : null, ca ? v.ca / ca : 0]);
    r.getCell(4).numFmt = MONEY;
    r.getCell(5).numFmt = MONEY;
    r.getCell(6).numFmt = "0.0%";
  }
  styleSheet(wa, 1, [30, 16, 16, 18, 14, 12]);
  totalRow(wa, ["Total", null, units, ca / 100, margin / 100, ca ? 1 : 0], [4, 5]);

  // ── 4. Commandes (tous statuts) ──────────────────────────────────────────────
  const wc = wb.addWorksheet("Commandes");
  wc.addRow(["Date de commande", "Commande", "Statut", "Date de remise", "Membre", "E-mail", "Article", "Taille", "Couleur", "Qté", "Montant", "Note"]);
  for (const o of ordersInPeriod) {
    const r = wc.addRow([
      paris(o.created_at).excel, o.id.slice(0, 8), ORDER_STATUS[o.status]?.label ?? o.status,
      o.delivered_at ? paris(o.delivered_at).excel : null, o.member?.full_name ?? "", o.member?.email ?? "",
      o.item_name, o.size ?? "", o.color ?? "", o.quantity, (o.price_cents * o.quantity) / 100, o.note ?? "",
    ]);
    r.getCell(1).numFmt = DATETIME;
    r.getCell(4).numFmt = DATE;
    r.getCell(11).numFmt = MONEY;
  }
  styleSheet(wc, 1, [17, 11, 15, 14, 24, 28, 26, 10, 12, 7, 12, 30]);

  // ── 5. Stock (état actuel) ───────────────────────────────────────────────────
  const wsk = wb.addWorksheet("Stock");
  wsk.addRow(["Article", "Variante", "Stock", "Réservé", "Disponible", "Seuil d'alerte", "Prix d'achat", "Valeur du stock", "Prix de vente", "Actif"]);
  let stockValue = 0;
  for (const item of data.items.filter((i) => i.track_stock)) {
    const variants = itemVariants(item);
    for (const s of data.stockRows)
      if (s.item_id === item.id && !variants.some((v) => v.size === s.size && v.color === s.color) && s.quantity !== 0)
        variants.push({ size: s.size, color: s.color });
    for (const v of variants) {
      const k = variantKey(item.id, v.size, v.color);
      const qty = data.stockMap.get(k) ?? 0;
      const res = data.reserved.get(k) ?? 0;
      const val = item.cost_cents != null ? Math.max(0, qty) * item.cost_cents : null;
      if (val) stockValue += val;
      const r = wsk.addRow([
        item.name, variantLabel(v.size, v.color), qty, res, qty - res, item.low_stock_alert,
        item.cost_cents != null ? item.cost_cents / 100 : null, val != null ? val / 100 : null, item.price_cents / 100,
        item.active ? "oui" : "non",
      ]);
      [7, 8, 9].forEach((n) => (r.getCell(n).numFmt = MONEY));
      if (qty - res <= item.low_stock_alert) r.getCell(5).font = { bold: true, color: { argb: "FFB91C1C" } };
    }
  }
  styleSheet(wsk, 1, [28, 20, 9, 10, 12, 14, 13, 15, 13, 8]);
  totalRow(wsk, ["Valeur totale du stock", null, null, null, null, null, null, stockValue / 100, null, null], [8]);

  // ── 6. Mouvements de stock ───────────────────────────────────────────────────
  const wm = wb.addWorksheet("Mouvements de stock");
  wm.addRow(["Date", "Article", "Variante", "Quantité", "Motif", "Prix d'achat unitaire", "Commande", "Note", "Par"]);
  for (const m of moves.rows.filter((m) => inPeriod(m.created_at))) {
    const r = wm.addRow([
      paris(m.created_at).excel, items.get(m.item_id)?.name ?? "", variantLabel(m.size, m.color), m.delta,
      MOVE_REASONS[m.reason] ?? m.reason, m.unit_cost_cents != null ? m.unit_cost_cents / 100 : null,
      m.order_id ? m.order_id.slice(0, 8) : "", m.note ?? "", m.author?.full_name ?? "",
    ]);
    r.getCell(1).numFmt = DATETIME;
    r.getCell(6).numFmt = MONEY;
  }
  styleSheet(wm, 1, [17, 28, 20, 10, 16, 18, 11, 30, 20]);

  return Buffer.from(await wb.xlsx.writeBuffer());
}
