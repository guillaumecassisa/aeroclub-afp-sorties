import Link from "next/link";
import type { Metadata } from "next";
import { requireTreasurer } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { currentMonthKey, euros, isMonthKey, monthLabel, shiftMonth } from "@/lib/money";
import { Banner } from "@/components/Banner";
import { Avatar } from "@/components/Avatar";
import { SubmitButton } from "@/components/ui";
import type { BarMonthSummary, BarProduct } from "@/lib/types";
import { setPaid } from "../actions";
import { AddProductForm, ProductRow } from "./ProductsEditor";

export const metadata: Metadata = { title: "Trésorerie du bar" };

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  await requireTreasurer();
  const sp = await searchParams;
  const month = isMonthKey(sp.mois) ? sp.mois : currentMonthKey();
  const supabase = await createClient();

  const [{ data, error }, { data: prods }] = await Promise.all([
    supabase.rpc("bar_month_summary", { p_month: `${month}-01` }),
    supabase.from("bar_products").select("*").order("position").order("name"),
  ]);
  const s = (data ?? { month, total_cents: 0, products: [], members: [] }) as BarMonthSummary;
  const products = (prods ?? []) as BarProduct[];
  const paidTotal = s.members.filter((m) => m.paid).reduce((t, m) => t + m.total_cents, 0);
  const isFuture = month > currentMonthKey();

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur ?? error?.message} />
      <Link href="/bar" className="mb-3 inline-block text-sm text-sky hover:underline">
        ← Bar
      </Link>
      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">Trésorerie du bar</h1>
          <p className="text-sm text-muted">Total des consommations de chaque membre, mois par mois.</p>
        </div>
        <div className="flex items-center gap-1">
          <Link href={`/bar/tresorerie?mois=${shiftMonth(month, -1)}`} className="btn-secondary px-3" aria-label="Mois précédent">
            ←
          </Link>
          <span className="min-w-40 text-center font-semibold text-navy-2">{monthLabel(month)}</span>
          {!isFuture && month !== currentMonthKey() ? (
            <Link href={`/bar/tresorerie?mois=${shiftMonth(month, 1)}`} className="btn-secondary px-3" aria-label="Mois suivant">
              →
            </Link>
          ) : (
            <span className="btn-secondary pointer-events-none px-3 opacity-40">→</span>
          )}
        </div>
      </div>

      {/* Chiffres clés */}
      <div className="grid gap-3 sm:grid-cols-3">
        <Stat label="Total du mois" value={euros(s.total_cents)} />
        <Stat label="Déjà réglé" value={euros(paidTotal)} />
        <Stat label="Reste à encaisser" value={euros(s.total_cents - paidTotal)} accent={s.total_cents - paidTotal > 0} />
      </div>
      {s.products.length > 0 && (
        <p className="mt-3 text-sm text-muted">
          {s.products.map((p) => `${p.quantity} ${p.name} (${euros(p.total_cents)})`).join(" · ")}
        </p>
      )}

      {/* Par membre */}
      <section className="card mt-5 overflow-hidden">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-line px-5 py-3">
          <h2 className="font-bold text-navy-2">Par membre</h2>
          {s.members.length > 0 && (
            <a href={`/bar/tresorerie/export?mois=${month}`} className="btn-secondary py-1.5">
              Exporter (Excel / CSV)
            </a>
          )}
        </div>
        {s.members.length === 0 ? (
          <p className="px-5 py-6 text-sm text-muted">Aucune consommation ce mois-ci.</p>
        ) : (
          <ul className="divide-y divide-line">
            {s.members.map((m) => (
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

      {/* Carte */}
      <section className="card mt-5 p-5">
        <h2 className="font-bold text-navy-2">Carte et prix</h2>
        <p className="mb-4 text-sm text-muted">
          Un changement de prix ne s&apos;applique qu&apos;aux consommations suivantes. Décochez « En vente » pour retirer une
          boisson de la carte.
        </p>
        <div className="space-y-2">
          {products.map((p) => (
            <ProductRow key={p.id} product={p} />
          ))}
        </div>
        <div className="mt-5 border-t border-line pt-4">
          <AddProductForm />
        </div>
      </section>
    </>
  );
}

function Stat({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return (
    <div className="card p-4">
      <p className="text-xs font-semibold tracking-wide text-muted uppercase">{label}</p>
      <p className={`mt-1 text-2xl font-bold ${accent ? "text-red" : "text-navy-2"}`}>{value}</p>
    </div>
  );
}
