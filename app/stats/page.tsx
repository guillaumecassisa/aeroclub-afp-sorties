import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { getCurrentProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { euros, monthLabel, currentMonthKey, shiftMonth } from "@/lib/money";
import { Banner } from "@/components/Banner";

export const metadata: Metadata = { title: "Stats – Bar & Shop" };
export const dynamic = "force-dynamic";

const NB_MONTHS = 12;

export default async function StatsPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const profile = await getCurrentProfile();
  if (!profile || (profile.role !== "admin" && !profile.is_treasurer)) {
    redirect("/?erreur=Acces+reserve+aux+administrateurs+et+au+tresorier");
  }

  const sp = await searchParams;
  const supabase = await createClient();

  // Générer les 12 derniers mois
  const now = currentMonthKey();
  const months: string[] = [];
  for (let i = 0; i < NB_MONTHS; i++) {
    months.unshift(shiftMonth(now, -i));
  }

  // Chiffres calculés par la base (réservé admin / trésorier) : bar = consommations des produits du bar,
  // shop = commandes livrées (leur débit sur l'ardoise n'est pas recompté côté bar)
  const { data: statsRaw, error } = await supabase.rpc("revenue_stats", { p_months: NB_MONTHS });
  const rows = (statsRaw ?? []) as { month: string; bar: number; shop: number }[];
  const barByMonth: Record<string, number> = Object.fromEntries(rows.map((r) => [r.month, Number(r.bar)]));
  const shopByMonth: Record<string, number> = Object.fromEntries(rows.map((r) => [r.month, Number(r.shop)]));

  const totalBar = Object.values(barByMonth).reduce((a, b) => a + b, 0);
  const totalShop = Object.values(shopByMonth).reduce((a, b) => a + b, 0);

  // Max pour les barres
  const maxVal = Math.max(
    ...months.map((m) => (barByMonth[m] ?? 0) + (shopByMonth[m] ?? 0)),
    1
  );

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur ?? error?.message} />

      <div className="mb-6">
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">📊 Stats – Bar & Shop</h1>
        <p className="text-sm text-muted">Chiffre d&apos;affaires des 12 derniers mois.</p>
      </div>

      {/* Totaux */}
      <div className="mb-8 grid gap-3 sm:grid-cols-3">
        <div className="card p-5">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted">Bar (12 mois)</p>
          <p className="mt-1 text-2xl font-bold text-navy-2">{euros(totalBar)}</p>
        </div>
        <div className="card p-5">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted">Shop (12 mois)</p>
          <p className="mt-1 text-2xl font-bold text-navy-2">{euros(totalShop)}</p>
        </div>
        <div className="card p-5">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted">Total (12 mois)</p>
          <p className="mt-1 text-2xl font-bold text-sky">{euros(totalBar + totalShop)}</p>
        </div>
      </div>

      {/* Tableau mois par mois */}
      <section className="card overflow-hidden">
        <div className="border-b border-line px-5 py-3">
          <p className="font-bold text-navy-2">Détail mois par mois</p>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-line bg-paper text-left text-xs font-semibold uppercase tracking-wide text-muted">
                <th className="px-5 py-2 min-w-[140px]">Mois</th>
                <th className="px-4 py-2 text-right">Bar</th>
                <th className="px-4 py-2 text-right">Shop</th>
                <th className="px-4 py-2 text-right font-bold">Total</th>
                <th className="px-4 py-2 w-full"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {[...months].reverse().map((m) => {
                const bar = barByMonth[m] ?? 0;
                const shop = shopByMonth[m] ?? 0;
                const total = bar + shop;
                const barPct = Math.round((bar / maxVal) * 100);
                const shopPct = Math.round((shop / maxVal) * 100);
                const isCurrentMonth = m === now;
                return (
                  <tr key={m} className={isCurrentMonth ? "bg-sky-soft/30" : "hover:bg-paper/50"}>
                    <td className="px-5 py-3 font-medium text-ink whitespace-nowrap">
                      {monthLabel(m)}
                      {isCurrentMonth && (
                        <span className="ml-2 text-[10px] font-semibold uppercase tracking-wide text-sky">
                          en cours
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums text-muted">
                      {bar > 0 ? euros(bar) : "—"}
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums text-muted">
                      {shop > 0 ? euros(shop) : "—"}
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums font-semibold text-navy-2">
                      {total > 0 ? euros(total) : "—"}
                    </td>
                    <td className="px-4 py-3">
                      {total > 0 && (
                        <div className="flex h-4 min-w-24 overflow-hidden rounded-full bg-paper border border-line">
                          {bar > 0 && (
                            <div
                              className="bg-sky h-full"
                              style={{ width: `${barPct}%` }}
                              title={`Bar : ${euros(bar)}`}
                            />
                          )}
                          {shop > 0 && (
                            <div
                              className="bg-ok h-full"
                              style={{ width: `${shopPct}%` }}
                              title={`Shop : ${euros(shop)}`}
                            />
                          )}
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
            <tfoot>
              <tr className="border-t-2 border-line bg-paper">
                <td className="px-5 py-3 font-bold text-navy-2">Total</td>
                <td className="px-4 py-3 text-right tabular-nums font-semibold text-navy-2">{euros(totalBar)}</td>
                <td className="px-4 py-3 text-right tabular-nums font-semibold text-navy-2">{euros(totalShop)}</td>
                <td className="px-4 py-3 text-right tabular-nums font-bold text-sky">{euros(totalBar + totalShop)}</td>
                <td className="px-4 py-3">
                  <div className="flex gap-3 text-xs text-muted">
                    <span className="flex items-center gap-1"><span className="inline-block h-2.5 w-2.5 rounded-sm bg-sky" /> Bar</span>
                    <span className="flex items-center gap-1"><span className="inline-block h-2.5 w-2.5 rounded-sm bg-ok" /> Shop</span>
                  </div>
                </td>
              </tr>
            </tfoot>
          </table>
        </div>
      </section>
    </>
  );
}
