import Link from "next/link";
import type { Metadata } from "next";
import { requireTreasurer } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { currentMonthKey, euros, isMonthKey, monthLabel, shiftMonth } from "@/lib/money";
import { Banner } from "@/components/Banner";
import { Avatar } from "@/components/Avatar";
import { SubmitButton } from "@/components/ui";
import { BAR_SECTIONS, type BarMonthSummary } from "@/lib/types";
import { barMonth, lineTotal, loadBarData, unpaidPastMonths } from "@/lib/bar";
import { setPaid } from "../actions";
import { AddProductForm, ProductRow } from "./ProductsEditor";

export const metadata: Metadata = { title: "Gestion du bar" };
export const dynamic = "force-dynamic";

const TABS = [
  { key: "tableau", label: "Tableau de bord", icon: "📊" },
  { key: "ardoises", label: "Ardoises du mois", icon: "🧾" },
  { key: "impayes", label: "À relancer", icon: "⏳" },
  { key: "carte", label: "Carte et prix", icon: "🍺" },
] as const;

type Data = Awaited<ReturnType<typeof loadBarData>>;

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  await requireTreasurer();
  const sp = await searchParams;
  const supabase = await createClient();
  const current = currentMonthKey();
  const tab = TABS.find((t) => t.key === sp.onglet)?.key ?? (isMonthKey(sp.mois) ? "ardoises" : "tableau");
  // 2 ans d'historique suffisent pour le tableau de bord et les relances (l'export Excel lit tout)
  const data = await loadBarData(supabase, shiftMonth(current, -24));
  const unpaid = unpaidPastMonths(data, current);

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur ?? data.error ?? undefined} />
      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">🍺 Gestion du bar</h1>
          <p className="text-sm text-muted">Consommations, encaissements, carte et chiffre d&apos;affaires.</p>
        </div>
        <Link href="/bar" className="btn-secondary text-sm">Voir le bar côté membre</Link>
      </div>

      <nav className="mb-6 flex flex-wrap gap-2" aria-label="Sections">
        {TABS.map((t) => (
          <Link
            key={t.key}
            href={`/bar/tresorerie?onglet=${t.key}`}
            aria-current={tab === t.key ? "page" : undefined}
            className={`pill text-sm ${tab === t.key ? "bg-navy-2 text-white" : "bg-white text-navy-2"}`}
          >
            <span aria-hidden>{t.icon}</span> {t.label}
            {t.key === "impayes" && unpaid.length > 0 && (
              <span className={`ml-1 rounded-full px-1.5 text-xs ${tab === t.key ? "bg-white/25" : "bg-wait-soft text-wait"}`}>
                {new Set(unpaid.map((u) => u.user_id)).size}
              </span>
            )}
          </Link>
        ))}
      </nav>

      {tab === "tableau" && <Dashboard data={data} unpaid={unpaid} current={current} />}
      {tab === "ardoises" && <Slates month={isMonthKey(sp.mois) ? sp.mois : current} />}
      {tab === "impayes" && <Unpaid data={data} unpaid={unpaid} />}
      {tab === "carte" && <Menu data={data} current={current} />}
    </>
  );
}

// ── Tableau de bord ──────────────────────────────────────────────────────────────
function Dashboard({ data, unpaid, current }: { data: Data; unpaid: ReturnType<typeof unpaidPastMonths>; current: string }) {
  const year = current.slice(0, 4);
  const byMonth = new Map<string, number>();
  for (const c of data.consumptions) byMonth.set(barMonth(c.created_at), (byMonth.get(barMonth(c.created_at)) ?? 0) + lineTotal(c));
  const monthCons = data.consumptions.filter((c) => barMonth(c.created_at) === current);
  const yearCons = data.consumptions.filter((c) => barMonth(c.created_at).startsWith(year));
  const caMonth = byMonth.get(current) ?? 0;
  const prevMonth = byMonth.get(shiftMonth(current, -1)) ?? 0;
  const caYear = yearCons.reduce((t, c) => t + lineTotal(c), 0);
  const paidMonth = monthCons.filter((c) => data.paid.has(`${c.user_id}|${current}`)).reduce((t, c) => t + lineTotal(c), 0);
  const drinkersMonth = new Set(monthCons.map((c) => c.user_id)).size;
  const unpaidTotal = unpaid.reduce((t, u) => t + u.total_cents, 0);

  const months = Array.from({ length: 12 }, (_, i) => {
    const key = shiftMonth(current, i - 11);
    const [y, m] = key.split("-").map(Number);
    return {
      key,
      label: new Date(Date.UTC(y, m - 1, 15)).toLocaleDateString("fr-FR", { month: "short", timeZone: "UTC" }),
      total: byMonth.get(key) ?? 0,
    };
  });
  const max = Math.max(1, ...months.map((m) => m.total));

  const sectionOf = new Map(data.products.map((p) => [p.id, p.category ?? "boissons"]));
  const top = new Map<string, { name: string; qty: number; ca: number }>();
  const bySection = new Map<string, number>();
  for (const c of yearCons) {
    const t = top.get(c.product_name) ?? { name: c.product_name, qty: 0, ca: 0 };
    t.qty += c.quantity;
    t.ca += lineTotal(c);
    top.set(c.product_name, t);
    const s = (c.product_id && sectionOf.get(c.product_id)) || "boissons";
    bySection.set(s, (bySection.get(s) ?? 0) + lineTotal(c));
  }
  const topList = [...top.values()].sort((a, b) => b.qty - a.qty || b.ca - a.ca).slice(0, 6);
  const diff = prevMonth ? Math.round(((caMonth - prevMonth) / prevMonth) * 100) : null;

  return (
    <div className="space-y-6">
      <section>
        <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">{monthLabel(current)}</h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Kpi value={euros(caMonth)} label={diff === null ? "consommé ce mois-ci" : `consommé ce mois-ci (${diff >= 0 ? "+" : ""}${diff} % vs mois dernier)`} />
          <Kpi value={euros(caMonth - paidMonth)} label="reste à encaisser ce mois-ci" accent={caMonth - paidMonth > 0} />
          <Kpi value={String(monthCons.reduce((t, c) => t + c.quantity, 0))} label={`consommations · ${drinkersMonth} membre${drinkersMonth > 1 ? "s" : ""}`} />
          <Link href="/bar/tresorerie?onglet=impayes" className="card p-4 transition hover:shadow-md">
            <p className={`text-2xl font-bold ${unpaidTotal > 0 ? "text-red" : "text-navy-2"}`}>{euros(unpaidTotal)}</p>
            <p className="mt-1 text-xs text-muted">impayé sur les mois précédents →</p>
          </Link>
        </div>
      </section>

      <section>
        <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">Année {year}</h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Kpi value={euros(caYear)} label={`chiffre d'affaires ${year}`} />
          <Kpi value={String(yearCons.reduce((t, c) => t + c.quantity, 0))} label="consommations" />
          {BAR_SECTIONS.map((s) => (
            <Kpi key={s.key} value={euros(bySection.get(s.key) ?? 0)} label={s.label.toLowerCase()} />
          ))}
        </div>
      </section>

      <div className="grid gap-6 lg:grid-cols-3">
        <section className="card p-5 lg:col-span-2">
          <h2 className="mb-4 font-bold text-navy-2">Consommations des 12 derniers mois</h2>
          <div className="flex h-40 items-end gap-1.5" role="img" aria-label="Chiffre d'affaires mensuel du bar">
            {months.map((m) => (
              <Link
                key={m.key}
                href={`/bar/tresorerie?onglet=ardoises&mois=${m.key}`}
                className="flex h-full flex-1 flex-col items-center justify-end gap-1"
                title={`${monthLabel(m.key)} : ${euros(m.total)}`}
              >
                {m.total > 0 && <span className="text-[10px] text-muted">{Math.round(m.total / 100)} €</span>}
                <div
                  className={`w-full rounded-t ${m.key === current ? "bg-navy-2" : "bg-sky-400/70"}`}
                  style={{ height: `${Math.max(m.total > 0 ? 4 : 1, (m.total / max) * 100)}%` }}
                />
                <span className="text-[10px] text-muted">{m.label}</span>
              </Link>
            ))}
          </div>
        </section>

        <section className="card overflow-hidden">
          <h2 className="border-b border-line px-4 py-3 font-bold text-navy-2">Les plus consommés en {year}</h2>
          {topList.length === 0 ? (
            <p className="px-4 py-6 text-sm text-muted">Aucune consommation cette année.</p>
          ) : (
            <ul className="divide-y divide-line text-sm">
              {topList.map((t, i) => (
                <li key={t.name} className="flex items-center gap-3 px-4 py-2.5">
                  <span className="w-5 text-center font-bold text-muted">{i + 1}</span>
                  <span className="min-w-0 flex-1 truncate">{t.name}</span>
                  <span className="text-xs text-muted">× {t.qty}</span>
                  <span className="font-semibold text-navy-2">{euros(t.ca)}</span>
                </li>
              ))}
            </ul>
          )}
        </section>
      </div>

      <ExportCard />
    </div>
  );
}

function Kpi({ value, label, accent }: { value: string; label: string; accent?: boolean }) {
  return (
    <div className="card p-4">
      <p className={`text-2xl font-bold ${accent ? "text-red" : "text-navy-2"}`}>{value}</p>
      <p className="mt-1 text-xs text-muted">{label}</p>
    </div>
  );
}

function ExportCard() {
  const year = new Date().getFullYear();
  return (
    <section className="card p-5">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="max-w-md">
          <h2 className="font-bold text-navy-2">📥 Export Excel</h2>
          <p className="mt-1 text-sm text-muted">
            Synthèse et CA par mois, ardoises par membre et par mois (réglé ou non), ventes par produit, détail de
            toutes les consommations, impayés.
          </p>
        </div>
        <form action="/bar/tresorerie/export" method="get" className="flex flex-wrap items-end gap-3">
          <input type="hidden" name="format" value="xlsx" />
          <div>
            <label htmlFor="periode" className="label">Période</label>
            <select id="periode" name="periode" className="field" defaultValue="annee">
              <option value="mois">Mois en cours</option>
              <option value="annee">Année {year}</option>
              <option value="annee-precedente">Année {year - 1}</option>
              <option value="tout">Depuis l&apos;ouverture du bar</option>
              <option value="dates">Dates choisies</option>
            </select>
          </div>
          <div>
            <label htmlFor="du" className="label">Du</label>
            <input id="du" name="du" type="date" className="field" />
          </div>
          <div>
            <label htmlFor="au" className="label">Au</label>
            <input id="au" name="au" type="date" className="field" />
          </div>
          <button className="btn-primary">Télécharger</button>
        </form>
      </div>
    </section>
  );
}

// ── Ardoises du mois ─────────────────────────────────────────────────────────────
async function Slates({ month }: { month: string }) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("bar_month_summary", { p_month: `${month}-01` });
  const s = (data ?? { month, total_cents: 0, products: [], members: [] }) as BarMonthSummary;
  const paidTotal = s.members.filter((m) => m.paid).reduce((t, m) => t + m.total_cents, 0);
  const current = currentMonthKey();
  const ret = `/bar/tresorerie?onglet=ardoises&mois=${month}`;
  const members = [...s.members].sort((a, b) => Number(a.paid) - Number(b.paid) || b.total_cents - a.total_cents);

  return (
    <div className="space-y-5">
      {error && <p className="text-sm text-danger">{error.message}</p>}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-1">
          <Link href={`/bar/tresorerie?onglet=ardoises&mois=${shiftMonth(month, -1)}`} className="btn-secondary px-3" aria-label="Mois précédent">
            ←
          </Link>
          <span className="min-w-40 text-center font-semibold text-navy-2">{monthLabel(month)}</span>
          {month < current ? (
            <Link href={`/bar/tresorerie?onglet=ardoises&mois=${shiftMonth(month, 1)}`} className="btn-secondary px-3" aria-label="Mois suivant">
              →
            </Link>
          ) : (
            <span className="btn-secondary pointer-events-none px-3 opacity-40">→</span>
          )}
        </div>
        {s.members.length > 0 && (
          <a href={`/bar/tresorerie/export?mois=${month}`} className="btn-secondary py-1.5 text-sm">
            Export du mois (CSV)
          </a>
        )}
      </div>

      <div className="grid grid-cols-3 gap-3">
        <Kpi value={euros(s.total_cents)} label="total du mois" />
        <Kpi value={euros(paidTotal)} label="déjà réglé" />
        <Kpi value={euros(s.total_cents - paidTotal)} label="reste à encaisser" accent={s.total_cents - paidTotal > 0} />
      </div>

      <section className="card overflow-hidden">
        {members.length === 0 ? (
          <p className="px-5 py-6 text-sm text-muted">Aucune consommation ce mois-ci.</p>
        ) : (
          <ul className="divide-y divide-line">
            {members.map((m) => (
              <li key={m.user_id} className="flex flex-wrap items-center gap-x-4 gap-y-2 px-5 py-3">
                <Avatar url={m.avatar_url} name={m.full_name || m.email} size="md" />
                <div className="min-w-0 flex-1">
                  <p className="truncate font-semibold text-ink">{m.full_name || m.email}</p>
                  <p className="truncate text-xs text-muted">
                    {Object.entries(m.items)
                      .map(([name, q]) => `${q} ${name}`)
                      .join(" · ")}
                  </p>
                </div>
                <span className="text-lg font-bold text-navy-2">{euros(m.total_cents)}</span>
                <form action={setPaid.bind(null, m.user_id, month, !m.paid)}>
                  <input type="hidden" name="ret" value={ret} />
                  <SubmitButton
                    className={m.paid ? "btn px-3 py-1.5 bg-ok-soft text-ok hover:bg-ok-soft/70" : "btn-primary px-3 py-1.5"}
                    pending="…"
                  >
                    {m.paid ? "✓ Réglé" : "Marquer réglé"}
                  </SubmitButton>
                </form>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

// ── À relancer : ardoises non réglées des mois terminés ──────────────────────────
function Unpaid({ data, unpaid }: { data: Data; unpaid: ReturnType<typeof unpaidPastMonths> }) {
  const byMember = new Map<string, { user_id: string; total: number; months: { month: string; total_cents: number }[] }>();
  for (const u of unpaid) {
    const e = byMember.get(u.user_id) ?? { user_id: u.user_id, total: 0, months: [] };
    e.total += u.total_cents;
    e.months.push({ month: u.month, total_cents: u.total_cents });
    byMember.set(u.user_id, e);
  }
  const list = [...byMember.values()].sort((a, b) => b.total - a.total);
  return (
    <section className="card overflow-hidden">
      <div className="border-b border-line px-5 py-3">
        <h2 className="font-bold text-navy-2">Ardoises non réglées des mois terminés</h2>
        <p className="text-sm text-muted">Le mois en cours n&apos;y figure pas. « Marquer réglé » enregistre l&apos;encaissement de ce mois-là.</p>
      </div>
      {list.length === 0 ? (
        <p className="px-5 py-6 text-sm text-ok">✓ Tout est réglé : aucune ardoise en retard.</p>
      ) : (
        <ul className="divide-y divide-line">
          {list.map((e) => {
            const m = data.members.get(e.user_id);
            const name = m?.full_name || m?.email || "Membre";
            return (
              <li key={e.user_id} className="px-5 py-3">
                <div className="flex flex-wrap items-center gap-3">
                  <Avatar url={m?.avatar_url ?? null} name={name} size="md" />
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-semibold text-ink">{name}</p>
                    {m?.email && (
                      <a href={`mailto:${m.email}?subject=${encodeURIComponent("Ardoise du bar")}`} className="text-xs text-sky hover:underline">
                        {m.email}
                      </a>
                    )}
                  </div>
                  <span className="text-lg font-bold text-red">{euros(e.total)}</span>
                </div>
                <ul className="mt-2 flex flex-wrap gap-2 pl-14">
                  {e.months.map((mm) => (
                    <li key={mm.month} className="flex items-center gap-2 rounded-lg border border-line bg-paper px-2.5 py-1 text-sm">
                      <Link href={`/bar/tresorerie?onglet=ardoises&mois=${mm.month}`} className="hover:underline">
                        {monthLabel(mm.month)} · <strong>{euros(mm.total_cents)}</strong>
                      </Link>
                      <form action={setPaid.bind(null, e.user_id, mm.month, true)}>
                        <input type="hidden" name="ret" value="/bar/tresorerie?onglet=impayes" />
                        <SubmitButton className="text-xs font-semibold text-ok hover:underline" pending="…">
                          ✓ Marquer réglé
                        </SubmitButton>
                      </form>
                    </li>
                  ))}
                </ul>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

// ── Carte et prix ────────────────────────────────────────────────────────────────
function Menu({ data, current }: { data: Data; current: string }) {
  const sold = new Map<string, number>();
  for (const c of data.consumptions)
    if (c.product_id && barMonth(c.created_at) === current) sold.set(c.product_id, (sold.get(c.product_id) ?? 0) + c.quantity);
  const active = data.products.filter((p) => p.active);
  const removed = data.products.filter((p) => !p.active);
  return (
    <div className="space-y-5">
      <section className="card p-5">
        <h2 className="mb-3 font-bold text-navy-2">Ajouter un produit</h2>
        <AddProductForm />
      </section>

      {BAR_SECTIONS.map((s) => {
        const list = active.filter((p) => (p.category ?? "boissons") === s.key);
        return (
          <section key={s.key} className="card overflow-hidden">
            <h2 className="border-b border-line px-4 py-3 font-bold text-navy-2">
              {s.label} <span className="text-sm font-normal text-muted">({list.length})</span>
            </h2>
            {list.length === 0 ? (
              <p className="px-4 py-5 text-sm text-muted">Aucun produit dans cette section.</p>
            ) : (
              <ul className="divide-y divide-line">
                {list.map((p) => (
                  <ProductRow key={p.id} product={p} sold={sold.get(p.id) ?? 0} />
                ))}
              </ul>
            )}
          </section>
        );
      })}

      {removed.length > 0 && (
        <section className="card overflow-hidden opacity-80">
          <h2 className="border-b border-line px-4 py-3 font-bold text-muted">Retirés de la carte ({removed.length})</h2>
          <ul className="divide-y divide-line">
            {removed.map((p) => (
              <ProductRow key={p.id} product={p} />
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
