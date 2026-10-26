import type { SupabaseClient } from "@supabase/supabase-js";
import { fetchAll, parisYearMonth } from "@/lib/shop";
import type { BarProduct } from "@/lib/types";

export type BarConsumptionRow = {
  id: string;
  user_id: string;
  product_id: string | null;
  product_name: string;
  unit_price_cents: number;
  quantity: number;
  created_at: string;
};
export type BarSettlementRow = { user_id: string; month: string; paid_at: string | null };
export type BarMember = { id: string; full_name: string | null; email: string | null; avatar_url: string | null };

/** Mois de consommation (heure de Paris), au format AAAA-MM, comme bar_month_of() dans la base. */
export const barMonth = (iso: string) => parisYearMonth(iso).month;
export const lineTotal = (c: Pick<BarConsumptionRow, "unit_price_cents" | "quantity">) => c.unit_price_cents * c.quantity;

/** Toutes les données du bar pour la trésorerie et l'export (réservé au trésorier par la base). */
export async function loadBarData(supabase: SupabaseClient, sinceMonth?: string) {
  const since = sinceMonth ? `${sinceMonth}-01T00:00:00+02:00` : null;
  const [cons, settl, prods, people] = await Promise.all([
    fetchAll<BarConsumptionRow>((a, b) => {
      let q = supabase
        .from("bar_consumptions")
        .select("id, user_id, product_id, product_name, unit_price_cents, quantity, created_at")
        .order("created_at");
      if (since) q = q.gte("created_at", since);
      return q.range(a, b);
    }),
    fetchAll<BarSettlementRow>((a, b) => supabase.from("bar_settlements").select("user_id, month, paid_at").range(a, b)),
    supabase.from("bar_products").select("*").order("position").order("name"),
    fetchAll<BarMember>((a, b) => supabase.rpc("bar_members").range(a, b)),
  ]);
  // Mois réglés par membre (clé « membre|AAAA-MM »)
  const paid = new Set(settl.rows.map((s) => `${s.user_id}|${s.month.slice(0, 7)}`));
  return {
    consumptions: since ? cons.rows.filter((c) => barMonth(c.created_at) >= sinceMonth!) : cons.rows,
    settlements: settl.rows,
    paid,
    products: (prods.data ?? []) as BarProduct[],
    members: new Map(people.rows.map((m) => [m.id, m])),
    error: cons.error ?? settl.error ?? prods.error?.message ?? people.error,
  };
}

/** Ardoises non réglées des mois terminés : membre × mois, du plus ancien au plus récent. */
export function unpaidPastMonths(data: Awaited<ReturnType<typeof loadBarData>>, currentMonth: string) {
  const sums = new Map<string, { user_id: string; month: string; total_cents: number }>();
  for (const c of data.consumptions) {
    const month = barMonth(c.created_at);
    if (month >= currentMonth) continue;
    const k = `${c.user_id}|${month}`;
    if (data.paid.has(k)) continue;
    const e = sums.get(k) ?? { user_id: c.user_id, month, total_cents: 0 };
    e.total_cents += lineTotal(c);
    sums.set(k, e);
  }
  return [...sums.values()].filter((e) => e.total_cents > 0).sort((a, b) => a.month.localeCompare(b.month));
}
