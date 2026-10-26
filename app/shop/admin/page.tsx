import Link from "next/link";
import type { Metadata } from "next";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { euros } from "@/lib/money";
import { formatShort } from "@/lib/dates";
import {
  ACTIVE_STATUSES,
  MOVE_REASONS,
  NEXT_STEP,
  ORDER_STATUS,
  itemVariants,
  loadShopData,
  loadShopSettings,
  parisYearMonth,
  saleDate,
  variantKey,
  variantLabel,
  type ShopItem,
  type ShopOrder,
  type ShopSettings,
  type StockMove,
} from "@/lib/shop";
import { setComingSoon, stockAdd, stockSet, updateOrderStatus } from "../actions";
import { ShopCatalogue } from "./ShopCatalogue";

export const metadata: Metadata = { title: "Gestion du shop" };
export const dynamic = "force-dynamic";

const TABS = [
  { key: "tableau", label: "Tableau de bord", icon: "📊" },
  { key: "commandes", label: "Commandes", icon: "📦" },
  { key: "stock", label: "Stock", icon: "🗃️" },
  { key: "catalogue", label: "Catalogue", icon: "🏷️" },
] as const;

type Data = Awaited<ReturnType<typeof loadShopData>>;

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  await requireAdmin();
  const sp = await searchParams;
  const supabase = await createClient();
  const [data, settings] = await Promise.all([loadShopData(supabase), loadShopSettings(supabase)]);
  const tab = TABS.find((t) => t.key === sp.onglet)?.key ?? "tableau";
  const activeCount = data.orders.filter((o) => (ACTIVE_STATUSES as readonly string[]).includes(o.status)).length;

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur ?? data.error ?? undefined} />

      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">🛍️ Gestion du shop</h1>
          <p className="text-sm text-muted">Commandes, stock, catalogue et chiffre d&apos;affaires.</p>
        </div>
        <Link href="/shop" className="btn-secondary text-sm">Voir le shop côté membre</Link>
      </div>

      <ComingSoonCard settings={settings} ret={`/shop/admin?onglet=${tab}`} />

      <nav className="mb-6 flex flex-wrap gap-2" aria-label="Sections">
        {TABS.map((t) => (
          <Link
            key={t.key}
            href={`/shop/admin?onglet=${t.key}`}
            aria-current={tab === t.key ? "page" : undefined}
            className={`pill text-sm ${tab === t.key ? "bg-navy-2 text-white" : "bg-white text-navy-2"}`}
          >
            <span aria-hidden>{t.icon}</span> {t.label}
            {t.key === "commandes" && activeCount > 0 && (
              <span className={`ml-1 rounded-full px-1.5 text-xs ${tab === t.key ? "bg-white/25" : "bg-wait-soft text-wait"}`}>
                {activeCount}
              </span>
            )}
          </Link>
        ))}
      </nav>

      {tab === "tableau" && <Dashboard data={data} />}
      {tab === "commandes" && <Orders data={data} filter={sp.statut} />}
      {tab === "stock" && <Stock data={data} />}
      {tab === "catalogue" && <ShopCatalogue items={data.items} />}
    </>
  );
}

// ── Tableau de bord ─────────────────────────────────────────────────────────────
function Dashboard({ data }: { data: Data }) {
  const now = parisYearMonth(new Date().toISOString());
  const count = (s: string) => data.orders.filter((o) => o.status === s).length;
  const delivered = data.orders.filter((o) => o.status === "delivered");
  const costOf = new Map(data.items.map((i) => [i.id, i.cost_cents]));
  const sum = (list: ShopOrder[]) => list.reduce((t, o) => t + o.price_cents * o.quantity, 0);
  const thisYear = delivered.filter((o) => parisYearMonth(saleDate(o)).year === now.year);
  const thisMonth = delivered.filter((o) => parisYearMonth(saleDate(o)).month === now.month);
  const caYear = sum(thisYear);
  const unitsYear = thisYear.reduce((t, o) => t + o.quantity, 0);
  const withCost = thisYear.filter((o) => costOf.get(o.item_id) != null);
  const marginYear = withCost.reduce((t, o) => t + (o.price_cents - (costOf.get(o.item_id) ?? 0)) * o.quantity, 0);
  const pendingAmount = sum(data.orders.filter((o) => (ACTIVE_STATUSES as readonly string[]).includes(o.status)));

  // CA des 12 derniers mois
  const months: { key: string; label: string; total: number }[] = [];
  const d = new Date();
  for (let i = 11; i >= 0; i--) {
    const m = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - i, 15));
    const key = parisYearMonth(m.toISOString()).month;
    months.push({
      key,
      label: m.toLocaleDateString("fr-FR", { month: "short", timeZone: "Europe/Paris" }),
      total: sum(delivered.filter((o) => parisYearMonth(saleDate(o)).month === key)),
    });
  }
  const max = Math.max(1, ...months.map((m) => m.total));

  // Meilleures ventes de l'année
  const top = new Map<string, { name: string; qty: number; ca: number }>();
  for (const o of thisYear) {
    const t = top.get(o.item_name) ?? { name: o.item_name, qty: 0, ca: 0 };
    t.qty += o.quantity;
    t.ca += o.price_cents * o.quantity;
    top.set(o.item_name, t);
  }
  const topList = [...top.values()].sort((a, b) => b.qty - a.qty || b.ca - a.ca).slice(0, 5);
  const alerts = stockLines(data).filter((l) => l.tracked && l.active && l.available <= l.alert);

  return (
    <div className="space-y-6">
      {/* Commandes en cours */}
      <section>
        <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">Commandes en cours</h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {(["pending", "confirmed", "ready"] as const).map((s) => (
            <Link key={s} href={`/shop/admin?onglet=commandes&statut=${s}`} className="card p-4 transition hover:shadow-md">
              <p className="text-3xl font-bold text-navy-2">{count(s)}</p>
              <p className="mt-1 text-sm">
                <span className={`pill ${ORDER_STATUS[s].color}`}>{ORDER_STATUS[s].label}</span>
              </p>
            </Link>
          ))}
          <div className="card p-4">
            <p className="text-3xl font-bold text-navy-2">{euros(pendingAmount)}</p>
            <p className="mt-1 text-sm text-muted">à encaisser sur les commandes en cours</p>
          </div>
        </div>
      </section>

      {/* Chiffre d'affaires */}
      <section>
        <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">Ventes (articles remis)</h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Kpi value={euros(sum(thisMonth))} label="CA du mois" />
          <Kpi value={euros(caYear)} label={`CA ${now.year}`} />
          <Kpi value={String(unitsYear)} label={`articles vendus en ${now.year}`} />
          <Kpi
            value={withCost.length ? euros(marginYear) : "—"}
            label={withCost.length ? `marge ${now.year} (articles avec prix d'achat)` : "marge : renseignez les prix d'achat"}
          />
        </div>
      </section>

      <div className="grid gap-6 lg:grid-cols-3">
        <section className="card p-5 lg:col-span-2">
          <h2 className="mb-4 font-bold text-navy-2">CA des 12 derniers mois</h2>
          <div className="flex h-40 items-end gap-1.5" role="img" aria-label="Chiffre d'affaires mensuel du shop">
            {months.map((m) => (
              <div key={m.key} className="flex h-full flex-1 flex-col items-center justify-end gap-1">
                {m.total > 0 && <span className="text-[10px] text-muted">{Math.round(m.total / 100)} €</span>}
                <div
                  className={`w-full rounded-t ${m.key === now.month ? "bg-navy-2" : "bg-sky-400/70"}`}
                  style={{ height: `${Math.max(m.total > 0 ? 4 : 1, (m.total / max) * 100)}%` }}
                  title={`${m.label} : ${euros(m.total)}`}
                />
                <span className="text-[10px] text-muted">{m.label}</span>
              </div>
            ))}
          </div>
        </section>

        <section className="card overflow-hidden">
          <h2 className="border-b border-line px-4 py-3 font-bold text-navy-2">Meilleures ventes {now.year}</h2>
          {topList.length === 0 ? (
            <p className="px-4 py-6 text-sm text-muted">Aucune vente cette année.</p>
          ) : (
            <ul className="divide-y divide-line text-sm">
              {topList.map((t, i) => (
                <li key={t.name} className="flex items-center gap-3 px-4 py-2.5">
                  <span className="w-5 text-center font-bold text-muted">{i + 1}</span>
                  <span className="min-w-0 flex-1 truncate">{t.name}</span>
                  <span className="text-xs text-muted">{t.qty} vendu{t.qty > 1 ? "s" : ""}</span>
                  <span className="font-semibold text-navy-2">{euros(t.ca)}</span>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <section className="card overflow-hidden">
          <div className="flex items-center justify-between border-b border-line px-4 py-3">
            <h2 className="font-bold text-navy-2">⚠️ Stock bas ou en rupture</h2>
            <Link href="/shop/admin?onglet=stock" className="text-xs font-medium text-sky-600 hover:underline">Gérer le stock →</Link>
          </div>
          {alerts.length === 0 ? (
            <p className="px-4 py-6 text-sm text-muted">Aucune alerte de stock.</p>
          ) : (
            <ul className="divide-y divide-line text-sm">
              {alerts.slice(0, 8).map((l) => (
                <li key={l.key} className="flex items-center gap-3 px-4 py-2.5">
                  <span className="min-w-0 flex-1 truncate">
                    {l.item.name} <span className="text-muted">· {variantLabel(l.size, l.color)}</span>
                  </span>
                  <span className={`pill ${l.available <= 0 ? "bg-danger-soft text-danger" : "bg-wait-soft text-wait"}`}>
                    {l.available <= 0 ? "Rupture" : `${l.available} dispo`}
                  </span>
                </li>
              ))}
              {alerts.length > 8 && <li className="px-4 py-2 text-xs text-muted">… et {alerts.length - 8} autre(s)</li>}
            </ul>
          )}
        </section>

        <ExportCard />
      </div>
    </div>
  );
}

function Kpi({ value, label }: { value: string; label: string }) {
  return (
    <div className="card p-4">
      <p className="text-2xl font-bold text-navy-2">{value}</p>
      <p className="mt-1 text-xs text-muted">{label}</p>
    </div>
  );
}

function ExportCard() {
  const year = new Date().getFullYear();
  return (
    <section className="card p-5">
      <h2 className="font-bold text-navy-2">📥 Export Excel</h2>
      <p className="mt-1 text-sm text-muted">
        Synthèse et CA par mois, détail des ventes, CA et marge par article, toutes les commandes, état du stock et
        mouvements.
      </p>
      <form action="/shop/admin/export" method="get" className="mt-4 space-y-3">
        <div>
          <label htmlFor="periode" className="label">Période</label>
          <select id="periode" name="periode" className="field" defaultValue="annee">
            <option value="mois">Mois en cours</option>
            <option value="annee">Année {year}</option>
            <option value="annee-precedente">Année {year - 1}</option>
            <option value="tout">Depuis l&apos;ouverture du shop</option>
            <option value="dates">Dates choisies ci-dessous</option>
          </select>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label htmlFor="du" className="label">Du</label>
            <input id="du" name="du" type="date" className="field" />
          </div>
          <div>
            <label htmlFor="au" className="label">Au</label>
            <input id="au" name="au" type="date" className="field" />
          </div>
        </div>
        <button className="btn-primary w-full">Télécharger le fichier Excel</button>
      </form>
    </section>
  );
}

// ── Commandes ───────────────────────────────────────────────────────────────────
function Orders({ data, filter }: { data: Data; filter?: string }) {
  const f = filter && (filter in ORDER_STATUS || filter === "toutes") ? filter : "a-traiter";
  const shown = data.orders.filter((o) =>
    f === "toutes" ? true : f === "a-traiter" ? (ACTIVE_STATUSES as readonly string[]).includes(o.status) : o.status === f,
  );
  const items = new Map(data.items.map((i) => [i.id, i]));
  const ret = `/shop/admin?onglet=commandes${f !== "a-traiter" ? `&statut=${f}` : ""}`;
  const pills = [
    { key: "a-traiter", label: "À traiter", n: data.orders.filter((o) => (ACTIVE_STATUSES as readonly string[]).includes(o.status)).length },
    ...Object.entries(ORDER_STATUS).map(([k, v]) => ({ key: k, label: v.label, n: data.orders.filter((o) => o.status === k).length })),
    { key: "toutes", label: "Toutes", n: data.orders.length },
  ];

  // À commander chez le fournisseur : commandes en attente / confirmées non couvertes par le stock
  const need = new Map<string, { name: string; size: string; color: string; ordered: number; stock: number }>();
  for (const o of data.orders) {
    if (o.status !== "pending" && o.status !== "confirmed") continue;
    const k = variantKey(o.item_id, o.size, o.color);
    const n = need.get(k) ?? { name: o.item_name, size: o.size ?? "", color: o.color ?? "", ordered: 0, stock: data.stockMap.get(k) ?? 0 };
    n.ordered += o.quantity;
    need.set(k, n);
  }
  const toBuy = [...need.values()].map((n) => ({ ...n, missing: Math.max(0, n.ordered - Math.max(0, n.stock)) }));

  return (
    <div className="space-y-6">
      <nav className="flex flex-wrap gap-2 text-sm" aria-label="Filtrer les commandes">
        {pills.map((p) => (
          <Link
            key={p.key}
            href={`/shop/admin?onglet=commandes${p.key !== "a-traiter" ? `&statut=${p.key}` : ""}`}
            className={`pill ${f === p.key ? "bg-navy-2 text-white" : "bg-white text-navy-2"}`}
          >
            {p.label} ({p.n})
          </Link>
        ))}
      </nav>

      {shown.length === 0 ? (
        <div className="card p-6 text-center text-muted">Aucune commande dans cette liste.</div>
      ) : (
        <ul className="space-y-3">
          {shown.map((o) => {
            const next = NEXT_STEP[o.status];
            const item = items.get(o.item_id);
            const k = variantKey(o.item_id, o.size, o.color);
            const stock = data.stockMap.get(k) ?? 0;
            const tracked = item?.track_stock ?? true;
            return (
              <li key={o.id} className="card p-4">
                <div className="flex flex-wrap items-start gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="font-semibold text-ink">
                      {o.quantity} × {o.item_name}
                      <span className="font-normal text-muted"> · {variantLabel(o.size, o.color)}</span>
                    </p>
                    <p className="text-sm text-muted">
                      {o.member?.full_name ?? "Membre"} · commandé le {formatShort(o.created_at)}
                      {o.status === "delivered" && o.delivered_at && ` · remis le ${formatShort(o.delivered_at)}`}
                    </p>
                    {o.note && <p className="mt-1 text-sm italic text-muted">« {o.note} »</p>}
                    {tracked && (ACTIVE_STATUSES as readonly string[]).includes(o.status) && (
                      <p className={`mt-1 text-xs ${stock >= o.quantity ? "text-ok" : "text-danger"}`}>
                        {stock >= o.quantity ? `✓ En stock (${stock})` : stock > 0 ? `Stock insuffisant (${stock})` : "Pas en stock : à commander"}
                      </p>
                    )}
                  </div>
                  <div className="text-right">
                    <p className="font-bold text-navy-2">{euros(o.price_cents * o.quantity)}</p>
                    <span className={`pill ${ORDER_STATUS[o.status]?.color ?? "bg-paper text-muted"}`}>
                      {ORDER_STATUS[o.status]?.label ?? o.status}
                    </span>
                  </div>
                </div>
                {o.status !== "delivered" && o.status !== "cancelled" ? (
                  <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-line pt-3">
                    {next && (
                      <form action={updateOrderStatus.bind(null, o.id, next.status)}>
                        <input type="hidden" name="ret" value={ret} />
                        <SubmitButton
                          className="btn-primary text-sm"
                          pending="…"
                          confirm={
                            next.status === "delivered"
                              ? `Remettre la commande à ${o.member?.full_name ?? "ce membre"} ? ${euros(o.price_cents * o.quantity)} seront ajoutés à son ardoise.`
                              : undefined
                          }
                        >
                          {next.status === "delivered" ? "✓ " : "→ "}
                          {next.label}
                        </SubmitButton>
                      </form>
                    )}
                    <form action={updateOrderStatus.bind(null, o.id, "cancelled")}>
                      <input type="hidden" name="ret" value={ret} />
                      <SubmitButton className="text-sm text-danger hover:underline" pending="…" confirm="Annuler cette commande ?">
                        Annuler
                      </SubmitButton>
                    </form>
                    <OtherStatuses o={o} ret={ret} />
                  </div>
                ) : (
                  <div className="mt-2 flex justify-end">
                    <OtherStatuses o={o} ret={ret} />
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}

      {toBuy.length > 0 && (
        <section>
          <h2 className="mb-3 text-lg font-bold text-navy-2">🧾 À commander chez le fournisseur</h2>
          <p className="mb-3 text-sm text-muted">Commandes en attente ou confirmées, comparées au stock disponible.</p>
          <div className="card overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-line bg-paper text-left text-xs font-semibold tracking-wide text-muted uppercase">
                  <th className="px-4 py-2">Article</th>
                  <th className="px-4 py-2">Variante</th>
                  <th className="px-4 py-2 text-center">Commandé</th>
                  <th className="px-4 py-2 text-center">En stock</th>
                  <th className="px-4 py-2 text-center">À commander</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {toBuy.map((n) => (
                  <tr key={`${n.name}|${n.size}|${n.color}`}>
                    <td className="px-4 py-2.5 font-medium">{n.name}</td>
                    <td className="px-4 py-2.5 text-muted">{variantLabel(n.size, n.color)}</td>
                    <td className="px-4 py-2.5 text-center">{n.ordered}</td>
                    <td className="px-4 py-2.5 text-center">{n.stock}</td>
                    <td className={`px-4 py-2.5 text-center font-bold ${n.missing > 0 ? "text-danger" : "text-ok"}`}>
                      {n.missing > 0 ? n.missing : "✓"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}
    </div>
  );
}

function OtherStatuses({ o, ret }: { o: ShopOrder; ret: string }) {
  return (
    <details className="relative ml-auto text-sm">
      <summary className="cursor-pointer list-none text-xs text-muted hover:text-ink">Autre statut ▾</summary>
      <div className="absolute right-0 z-10 mt-1 w-48 rounded-xl border border-line bg-white p-1 shadow-lg">
        {Object.entries(ORDER_STATUS)
          .filter(([k]) => k !== o.status)
          .map(([k, v]) => (
            <form key={k} action={updateOrderStatus.bind(null, o.id, k)}>
              <input type="hidden" name="ret" value={ret} />
              <SubmitButton className="w-full rounded-lg px-3 py-1.5 text-left text-sm hover:bg-paper" pending="…">
                {v.label}
              </SubmitButton>
            </form>
          ))}
      </div>
    </details>
  );
}

// ── Stock ───────────────────────────────────────────────────────────────────────
function stockLines(data: Data) {
  const lines: {
    key: string;
    item: ShopItem;
    size: string;
    color: string;
    stock: number;
    reserved: number;
    available: number;
    alert: number;
    tracked: boolean;
    active: boolean;
  }[] = [];
  for (const item of data.items) {
    const variants = itemVariants(item);
    // variantes présentes en stock mais retirées de la fiche article
    for (const s of data.stockRows)
      if (s.item_id === item.id && !variants.some((v) => v.size === s.size && v.color === s.color) && s.quantity !== 0)
        variants.push({ size: s.size, color: s.color });
    for (const v of variants) {
      const key = variantKey(item.id, v.size, v.color);
      const stock = data.stockMap.get(key) ?? 0;
      const reserved = data.reserved.get(key) ?? 0;
      lines.push({
        key, item, size: v.size, color: v.color, stock, reserved,
        available: stock - reserved,
        alert: item.low_stock_alert ?? 2,
        tracked: item.track_stock ?? true,
        active: item.active,
      });
    }
  }
  return lines;
}

async function Stock({ data }: { data: Data }) {
  const supabase = await createClient();
  const { data: movesRaw } = await supabase
    .from("shop_stock_moves")
    .select("*, author:created_by(full_name)")
    .order("created_at", { ascending: false })
    .limit(40);
  const moves = (movesRaw ?? []) as StockMove[];
  const names = new Map(data.items.map((i) => [i.id, i.name]));
  const lines = stockLines(data).filter((l) => l.tracked);
  const byItem = new Map<string, typeof lines>();
  for (const l of lines) byItem.set(l.item.id, [...(byItem.get(l.item.id) ?? []), l]);
  const value = lines.reduce((t, l) => t + Math.max(0, l.stock) * (l.item.cost_cents ?? 0), 0);
  const units = lines.reduce((t, l) => t + Math.max(0, l.stock), 0);

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Kpi value={String(units)} label="articles en stock" />
        <Kpi value={euros(value)} label="valeur du stock (prix d'achat)" />
        <Kpi
          value={String(lines.filter((l) => l.active && l.available <= l.alert).length)}
          label="variantes en stock bas ou rupture"
        />
      </div>

      <p className="text-sm text-muted">
        <b>Réservé</b> : quantités des commandes en cours (pas encore remises). Le stock baisse automatiquement quand une
        commande est remise au membre. Utilisez <b>Entrée</b> à la réception d&apos;une livraison et <b>Inventaire</b>{" "}
        pour corriger après un comptage.
      </p>

      {[...byItem.entries()].map(([id, rows]) => {
        const item = rows[0].item;
        return (
          <section key={id} className={`card overflow-hidden ${item.active ? "" : "opacity-70"}`}>
            <div className="flex flex-wrap items-center justify-between gap-2 border-b border-line px-4 py-3">
              <h2 className="font-bold text-navy-2">
                {item.name} {!item.active && <span className="pill bg-paper text-muted">inactif</span>}
              </h2>
              <span className="text-xs text-muted">
                Vente {euros(item.price_cents)}
                {item.cost_cents != null && ` · achat ${euros(item.cost_cents)}`} · alerte à {item.low_stock_alert}
              </span>
            </div>
            <ul className="divide-y divide-line">
              {rows.map((l) => (
                <li key={l.key} className="flex flex-wrap items-center gap-3 px-4 py-3 text-sm">
                  <span className="w-32 shrink-0 font-medium">{variantLabel(l.size, l.color)}</span>
                  <span className="w-20 text-center">
                    <b className="text-lg text-navy-2">{l.stock}</b>
                    <span className="block text-[10px] text-muted uppercase">stock</span>
                  </span>
                  <span className="w-20 text-center">
                    <b>{l.reserved}</b>
                    <span className="block text-[10px] text-muted uppercase">réservé</span>
                  </span>
                  <span className="w-24 text-center">
                    <span
                      className={`pill ${l.available <= 0 ? "bg-danger-soft text-danger" : l.available <= l.alert ? "bg-wait-soft text-wait" : "bg-ok-soft text-ok"}`}
                    >
                      {l.available} dispo
                    </span>
                  </span>
                  <div className="ml-auto flex flex-wrap gap-2">
                    <form action={stockAdd} className="flex items-center gap-1">
                      <input type="hidden" name="item_id" value={item.id} />
                      <input type="hidden" name="size" value={l.size} />
                      <input type="hidden" name="color" value={l.color} />
                      <label className="sr-only" htmlFor={`in-${l.key}`}>Quantité reçue</label>
                      <input id={`in-${l.key}`} name="qty" type="number" min={1} max={10000} placeholder="Qté" className="field w-20! py-1.5!" required />
                      <label className="sr-only" htmlFor={`cost-${l.key}`}>Prix d&apos;achat unitaire</label>
                      <input id={`cost-${l.key}`} name="cost" type="number" min={0} step="0.01" placeholder="€ achat" className="field w-24! py-1.5!" />
                      <SubmitButton className="btn-secondary py-1.5! text-xs" pending="…">+ Entrée</SubmitButton>
                    </form>
                    <form action={stockSet} className="flex items-center gap-1">
                      <input type="hidden" name="item_id" value={item.id} />
                      <input type="hidden" name="size" value={l.size} />
                      <input type="hidden" name="color" value={l.color} />
                      <label className="sr-only" htmlFor={`inv-${l.key}`}>Quantité comptée</label>
                      <input id={`inv-${l.key}`} name="qty" type="number" min={0} max={100000} defaultValue={Math.max(0, l.stock)} className="field w-20! py-1.5!" required />
                      <SubmitButton className="btn-secondary py-1.5! text-xs" pending="…">Inventaire</SubmitButton>
                    </form>
                  </div>
                </li>
              ))}
            </ul>
          </section>
        );
      })}
      {byItem.size === 0 && (
        <div className="card p-6 text-center text-muted">
          Aucun article suivi en stock. Activez le suivi dans le catalogue (« Suivre le stock de cet article »).
        </div>
      )}

      <section className="card overflow-hidden">
        <h2 className="border-b border-line px-4 py-3 font-bold text-navy-2">Derniers mouvements</h2>
        {moves.length === 0 ? (
          <p className="px-4 py-6 text-sm text-muted">Aucun mouvement de stock pour le moment.</p>
        ) : (
          <ul className="divide-y divide-line text-sm">
            {moves.map((m) => (
              <li key={m.id} className="flex items-start gap-3 px-4 py-2.5">
                <span className={`w-10 shrink-0 pt-0.5 text-right font-bold ${m.delta > 0 ? "text-ok" : "text-danger"}`}>
                  {m.delta > 0 ? `+${m.delta}` : m.delta}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                    <span>
                      {names.get(m.item_id) ?? "Article"} <span className="text-muted">· {variantLabel(m.size, m.color)}</span>
                    </span>
                    <span className="pill bg-paper text-muted">{MOVE_REASONS[m.reason] ?? m.reason}</span>
                  </div>
                  <p className="mt-0.5 text-xs text-muted">
                    {formatShort(m.created_at)}
                    {m.author?.full_name && ` · par ${m.author.full_name}`}
                    {m.note && <span className="italic"> · {m.note}</span>}
                  </p>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

/** Filigrane « Bientôt disponible » : visible sur tous les onglets, un seul bouton. */
function ComingSoonCard({ settings, ret }: { settings: ShopSettings; ret: string }) {
  const on = settings.coming_soon;
  return (
    <section
      className={`card mb-5 flex flex-wrap items-center gap-3 border-l-4 p-4 ${on ? "border-l-wait bg-wait-soft" : "border-l-ok"}`}
    >
      <div className="min-w-0 flex-1">
        <p className="font-bold text-navy-2">
          {on ? "🚧 Filigrane « Bientôt disponible » actif" : "✅ Shop ouvert aux commandes"}
        </p>
        <p className="text-sm text-muted">
          {on
            ? "Les membres voient le catalogue avec le filigrane, mais aucune commande n'est possible."
            : "Activez le filigrane pour présenter le catalogue sans permettre d'acheter (préparation, rupture, inventaire…)."}
        </p>
      </div>
      <form action={setComingSoon.bind(null, !on)} className="flex flex-wrap items-center gap-2">
        <input type="hidden" name="ret" value={ret} />
        {!on && (
          <input
            name="message"
            className="field w-64! py-1.5 text-sm"
            maxLength={300}
            defaultValue={settings.message ?? ""}
            placeholder="Message aux membres (facultatif)"
          />
        )}
        <SubmitButton
          className={on ? "btn-primary text-sm" : "btn-secondary text-sm"}
          pending="…"
          confirm={on ? "Ouvrir le shop aux commandes ?" : "Activer le filigrane « Bientôt disponible » ? Les commandes seront bloquées."}
        >
          {on ? "Ouvrir le shop" : "Activer « Bientôt disponible »"}
        </SubmitButton>
      </form>
    </section>
  );
}
