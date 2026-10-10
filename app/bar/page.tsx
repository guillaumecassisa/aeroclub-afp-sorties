import Link from "next/link";
import type { Metadata } from "next";
import { requireMember, isTreasurer } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { currentMonthKey, euros, monthLabel } from "@/lib/money";
import { formatShort } from "@/lib/dates";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { BAR_SECTIONS, type BarConsumption, type BarProduct } from "@/lib/types";
import { addConsumption, cancelConsumption } from "./actions";

export const metadata: Metadata = { title: "Bar" };

const CANCEL_WINDOW_MS = 30 * 60 * 1000;

function monthKeyOf(iso: string) {
  return currentMonthKey(new Date(iso));
}

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const me = await requireMember();
  const sp = await searchParams;
  const supabase = await createClient();

  const since = new Date();
  since.setUTCMonth(since.getUTCMonth() - 12);
  const [{ data: prods }, { data: cons }, { data: settl }] = await Promise.all([
    supabase.from("bar_products").select("*").eq("active", true).order("position").order("name"),
    supabase
      .from("bar_consumptions")
      .select("id, user_id, product_name, unit_price_cents, quantity, created_at")
      .eq("user_id", me.id)
      .gte("created_at", since.toISOString())
      .order("created_at", { ascending: false }),
    supabase.from("bar_settlements").select("month").eq("user_id", me.id),
  ]);
  const products = (prods ?? []) as BarProduct[];
  const consumptions = (cons ?? []) as BarConsumption[];
  const paidMonths = new Set((settl ?? []).map((s) => String(s.month).slice(0, 7)));

  const nowKey = currentMonthKey();
  const thisMonth = consumptions.filter((c) => monthKeyOf(c.created_at) === nowKey);
  const monthTotal = thisMonth.reduce((s, c) => s + c.unit_price_cents * c.quantity, 0);

  const previous = new Map<string, number>();
  for (const c of consumptions) {
    const k = monthKeyOf(c.created_at);
    if (k === nowKey) continue;
    previous.set(k, (previous.get(k) ?? 0) + c.unit_price_cents * c.quantity);
  }
  const now = Date.now();

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />
      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">Bar du club</h1>
          <p className="text-sm text-muted">Choisissez une boisson ou un snack pour l&apos;ajouter à votre ardoise. Réglée chaque mois auprès du trésorier.</p>
        </div>
        {isTreasurer(me) && (
          <Link href="/bar/tresorerie" className="btn-secondary">
            Trésorerie
          </Link>
        )}
      </div>

      {/* Carte */}
      {products.length === 0 ? (
        <div className="card p-8 text-center text-muted">La carte est vide pour le moment.</div>
      ) : (
        <div className="space-y-6">
          {BAR_SECTIONS.map((sec) => ({ ...sec, items: products.filter((p) => (p.category ?? "boissons") === sec.key) }))
            .filter((section) => section.items.length > 0)
            .map((section) => (
              <section key={section.key}>
                <h2 className="mb-3 flex items-center gap-2 text-lg font-bold tracking-tight text-navy-2">
                  <span aria-hidden>{section.key === "snacks" ? "🍫" : "🥤"}</span> {section.label}
                </h2>
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                  {section.items.map((p) => (
                    <form key={p.id} action={addConsumption.bind(null, p.id, p.name)} className="card flex flex-col p-4">
                      <span aria-hidden className="text-3xl leading-none">
                        {productIcon(p.name, p.category)}
                      </span>
                      <p className="mt-2 text-lg font-bold text-navy-2">{p.name}</p>
                      <p className="text-2xl font-bold tracking-tight text-ink">{euros(p.price_cents)}</p>
                      <div className="mt-3 flex items-center gap-2">
                        <select name="quantity" defaultValue="1" aria-label={`Quantité de ${p.name}`} className="field w-16 px-2 py-2">
                          {[1, 2, 3, 4, 5, 6].map((n) => (
                            <option key={n} value={n}>
                              {n}
                            </option>
                          ))}
                        </select>
                        <SubmitButton className="btn-primary flex-1 px-3" pending="…">
                          Ajouter
                        </SubmitButton>
                      </div>
                    </form>
                  ))}
                </div>
              </section>
            ))}
        </div>
      )}

      {/* Ardoise du mois */}
      <section className="card mt-6 overflow-hidden">
        <div className="flex flex-wrap items-baseline justify-between gap-2 border-b border-line px-5 py-4">
          <h2 className="font-bold text-navy-2">Mon ardoise · {monthLabel(nowKey)}</h2>
          <p className="text-sm">
            Total <span className="text-xl font-bold text-navy-2">{euros(monthTotal)}</span>
            {paidMonths.has(nowKey) && <span className="pill ml-2 bg-ok-soft text-ok">Réglé</span>}
          </p>
        </div>
        {thisMonth.length === 0 ? (
          <p className="px-5 py-6 text-sm text-muted">Aucune consommation ce mois-ci.</p>
        ) : (
          <ul className="divide-y divide-line">
            {thisMonth.map((c) => {
              const cancellable = now - new Date(c.created_at).getTime() < CANCEL_WINDOW_MS && !paidMonths.has(nowKey);
              return (
                <li key={c.id} className="flex items-center justify-between gap-3 px-5 py-2.5 text-sm">
                  <span className="min-w-0">
                    <span className="font-medium text-ink">
                      {c.quantity} × {c.product_name}
                    </span>
                    <span className="ml-2 text-xs text-muted">{formatShort(c.created_at)}</span>
                  </span>
                  <span className="flex shrink-0 items-center gap-3">
                    <span className="font-semibold text-ink">{euros(c.unit_price_cents * c.quantity)}</span>
                    {cancellable && (
                      <form action={cancelConsumption.bind(null, c.id, "/bar")}>
                        <SubmitButton
                          className="rounded-full px-2 py-1 text-xs font-semibold text-danger hover:bg-danger-soft"
                          pending="…"
                          confirm={`Annuler ${c.quantity} × ${c.product_name} ?`}
                        >
                          Annuler
                        </SubmitButton>
                      </form>
                    )}
                  </span>
                </li>
              );
            })}
          </ul>
        )}
        <p className="border-t border-line bg-paper px-5 py-2 text-xs text-muted">
          Une erreur ? Vous pouvez annuler une saisie pendant 30 minutes. Au-delà, voyez le trésorier.
        </p>
      </section>

      {previous.size > 0 && (
        <section className="card mt-4 p-5">
          <h2 className="mb-3 font-bold text-navy-2">Mois précédents</h2>
          <ul className="divide-y divide-line text-sm">
            {[...previous.entries()]
              .sort(([a], [b]) => b.localeCompare(a))
              .map(([k, total]) => (
                <li key={k} className="flex items-center justify-between py-2">
                  <span>{monthLabel(k)}</span>
                  <span className="flex items-center gap-2">
                    <span className="font-semibold">{euros(total)}</span>
                    {paidMonths.has(k) ? (
                      <span className="pill bg-ok-soft text-ok">Réglé</span>
                    ) : (
                      <span className="pill bg-wait-soft text-wait">À régler</span>
                    )}
                  </span>
                </li>
              ))}
          </ul>
        </section>
      )}
    </>
  );
}

/** Pictogramme d'un produit de la carte, d'après son nom. */
function productIcon(name: string, category?: string) {
  const n = name.toLowerCase();
  if (/caf[eé]|th[eé]|infusion|chocolat chaud/.test(n)) return "☕";
  if (/glace|esquimau|cornet/.test(n)) return "🍦";
  if (/coca|ice tea|soda|orangina|schweppes|limonade|jus|sprite|fanta/.test(n)) return "🥤";
  if (/^eau|perrier|badoit/.test(n)) return "💧";
  if (category === "snacks") return "🍫";
  return "🍺";
}
