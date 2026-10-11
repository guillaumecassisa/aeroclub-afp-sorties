import type { Metadata } from "next";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { euros } from "@/lib/money";
import { formatShort } from "@/lib/dates";
import { updateOrderStatus } from "../actions";
import { ShopCatalogue } from "./ShopCatalogue";

export const metadata: Metadata = { title: "Admin – Le shop" };
export const dynamic = "force-dynamic";

const STATUS_LABELS: Record<string, string> = {
  pending: "En attente",
  confirmed: "Confirme",
  ready: "Pret a retirer",
  delivered: "Livre",
  cancelled: "Annule",
};

const STATUS_LABELS_FR: Record<string, string> = {
  pending: "En attente",
  confirmed: "Confirmé",
  ready: "Prêt à retirer",
  delivered: "Livré",
  cancelled: "Annulé",
};

const STATUS_COLORS: Record<string, string> = {
  pending: "bg-wait-soft text-wait",
  confirmed: "bg-sky-soft text-navy-2",
  ready: "bg-ok-soft text-ok",
  delivered: "bg-paper text-muted",
  cancelled: "bg-danger-soft text-danger",
};

// Statuts qui représentent des commandes "à traiter" (pas encore prêtes)
const STATUS_FLOW = ["pending", "confirmed", "ready", "delivered", "cancelled"];
const ACTIVE_STATUSES = ["pending", "confirmed", "ready"];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  await requireAdmin();
  const sp = await searchParams;
  const supabase = await createClient();

  const [{ data: ordersRaw }, { data: itemsRaw }] = await Promise.all([
    supabase
      .from("shop_orders")
      .select("*, item:item_id(name, price_cents), member:user_id(full_name)")
      .not("status", "in", '("delivered","cancelled")')
      .order("created_at", { ascending: false }),
    supabase.from("shop_items").select("*").order("category").order("name"),
  ]);

  const orders = ordersRaw ?? [];
  const items = itemsRaw ?? [];

  // ── Récapitulatif groupé par article + variante ──────────────────────────────
  type LineKey = string;
  type SummaryLine = {
    item_name: string;
    size: string | null;
    color: string | null;
    total_qty: number;
    members: string[];
    notes: string[];
  };

  const summaryMap = new Map<LineKey, SummaryLine>();

  for (const o of orders) {
    const item = o.item as { name: string; price_cents: number } | null;
    const member = o.member as { full_name: string } | null;
    const name = item?.name ?? o.item_name ?? "Article";
    const key = `${name}|${o.size ?? ""}|${o.color ?? ""}`;

    if (!summaryMap.has(key)) {
      summaryMap.set(key, {
        item_name: name,
        size: o.size ?? null,
        color: o.color ?? null,
        total_qty: 0,
        members: [],
        notes: [],
      });
    }
    const line = summaryMap.get(key)!;
    line.total_qty += o.quantity ?? 1;
    if (member?.full_name) line.members.push(member.full_name);
    if (o.note) line.notes.push(o.note);
  }

  const summaryLines = Array.from(summaryMap.values()).sort((a, b) =>
    a.item_name.localeCompare(b.item_name)
  );

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />

      <div className="mb-6">
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">🛍️ Admin – Le shop</h1>
      </div>

      {/* ── Récapitulatif à commander ─────────────────────────────────────────── */}
      {orders.length > 0 && (
        <section className="mb-8">
          <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">
            📋 Récapitulatif à commander
          </h2>
          <div className="card overflow-hidden">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-line bg-paper text-left text-xs font-semibold uppercase tracking-wide text-muted">
                  <th className="px-4 py-2">Article</th>
                  <th className="px-4 py-2">Taille</th>
                  <th className="px-4 py-2">Couleur</th>
                  <th className="px-4 py-2 text-center">Qté</th>
                  <th className="px-4 py-2">Membres</th>
                  <th className="px-4 py-2">Notes</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {summaryLines.map((line, i) => (
                  <tr key={i} className="hover:bg-paper/50">
                    <td className="px-4 py-2.5 font-medium text-ink">{line.item_name}</td>
                    <td className="px-4 py-2.5 text-muted">{line.size ?? "—"}</td>
                    <td className="px-4 py-2.5 text-muted">{line.color ?? "—"}</td>
                    <td className="px-4 py-2.5 text-center font-bold text-navy-2">{line.total_qty}</td>
                    <td className="px-4 py-2.5 text-xs text-muted">{line.members.join(", ")}</td>
                    <td className="px-4 py-2.5 text-xs text-muted italic">
                      {line.notes.length > 0 ? line.notes.join(" · ") : ""}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {/* ── Commandes en cours ───────────────────────────────────────────────── */}
      <section className="mb-10">
        <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Commandes en cours</h2>
        {orders.length === 0 ? (
          <div className="card p-6 text-center text-muted">Aucune commande en cours.</div>
        ) : (
          <div className="card overflow-hidden">
            <ul className="divide-y divide-line">
              {orders.map((o) => {
                const member = o.member as { full_name: string } | null;
                const item = o.item as { name: string; price_cents: number } | null;
                return (
                  <li key={o.id} className="flex flex-wrap items-center gap-3 px-4 py-3">
                    <div className="flex-1 min-w-0">
                      <p className="font-medium text-ink">
                        {member?.full_name ?? "—"} · {o.quantity}× {item?.name ?? "Article"}
                      </p>
                      <p className="text-xs text-muted">
                        {[o.size, o.color].filter(Boolean).join(" · ")}
                        {o.note && ` · ${o.note}`}
                      </p>
                      <p className="text-xs text-muted">
                        {formatShort(o.created_at)}
                        {item && ` · ${euros(item.price_cents * o.quantity)}`}
                      </p>
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      <span className={`pill ${STATUS_COLORS[o.status] ?? "bg-paper text-muted"}`}>
                        {STATUS_LABELS_FR[o.status] ?? o.status}
                      </span>
                      {STATUS_FLOW.filter((s) => s !== o.status).map((s) => (
                        <form key={s} action={updateOrderStatus.bind(null, o.id, s)}>
                          <SubmitButton className="text-xs text-navy-2 hover:underline" pending="…">
                            → {STATUS_LABELS_FR[s]}
                          </SubmitButton>
                        </form>
                      ))}
                    </div>
                  </li>
                );
              })}
            </ul>
          </div>
        )}
      </section>

      {/* ── Catalogue ────────────────────────────────────────────────────────── */}
      <ShopCatalogue items={items as Parameters<typeof ShopCatalogue>[0]["items"]} />
    </>
  );
}
