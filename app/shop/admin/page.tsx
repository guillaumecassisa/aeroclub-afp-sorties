import type { Metadata } from "next";
import Link from "next/link";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { upsertItem, deleteItem, updateOrderStatus } from "../actions";

export const metadata: Metadata = { title: "Shop — Administration" };
export const dynamic = "force-dynamic";

const STATUS_OPTIONS = [
  { value: "pending",   label: "En attente" },
  { value: "confirmed", label: "Confirmée" },
  { value: "ready",     label: "Prête à livrer" },
  { value: "delivered", label: "Livrée" },
  { value: "cancelled", label: "Annulée" },
];

const STATUS_COLORS: Record<string, string> = {
  pending:   "text-wait bg-wait-soft",
  confirmed: "text-sky bg-sky-soft",
  ready:     "text-ok bg-ok-soft",
  delivered: "text-muted bg-paper",
  cancelled: "text-muted bg-paper",
};

function euros(cents: number) {
  return cents === 0 ? "Sur devis" : new Intl.NumberFormat("fr-FR", { style: "currency", currency: "EUR" }).format(cents / 100);
}

type ShopItem = {
  id: string;
  name: string;
  description: string | null;
  price_cents: number;
  category: string;
  image_url: string | null;
  sizes: string[] | null;
  colors: string[] | null;
  active: boolean;
  position: number;
};

type ShopOrder = {
  id: string;
  user_id: string;
  item_name: string;
  price_cents: number;
  quantity: number;
  size: string | null;
  color: string | null;
  note: string | null;
  status: string;
  created_at: string;
  profiles: { full_name: string; email: string } | { full_name: string; email: string }[] | null;
};

export default async function ShopAdminPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  await requireAdmin();
  const sp = await searchParams;
  const supabase = await createClient();
  const editId = sp.edit ?? null;

  const [{ data: itemsRaw }, { data: ordersRaw }] = await Promise.all([
    supabase.from("shop_items").select("*").order("position").order("name"),
    supabase
      .from("shop_orders")
      .select("id, user_id, item_name, price_cents, quantity, size, color, note, status, created_at, profiles(full_name, email)")
      .not("status", "in", '("cancelled","delivered")')
      .order("created_at", { ascending: true }),
  ]);

  const items = (itemsRaw ?? []) as ShopItem[];
  const orders = (ordersRaw ?? []) as ShopOrder[];
  const editItem = editId ? items.find((i) => i.id === editId) : null;

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />

      <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">⚙️ Shop — Administration</h1>
          <p className="text-sm text-muted">Gérez les articles et suivez les commandes.</p>
        </div>
        <Link href="/shop" className="btn-secondary text-sm">← Voir le shop</Link>
      </div>

      {/* Commandes en cours */}
      <section className="card mb-8 overflow-hidden p-0">
        <div className="border-b border-line px-5 py-3">
          <p className="font-bold text-navy-2">📦 Commandes en cours</p>
        </div>
        {orders.length === 0 ? (
          <p className="px-5 py-4 text-sm text-muted">Aucune commande en attente.</p>
        ) : (
          <ul className="divide-y divide-line">
            {orders.map((o) => (
              <li key={o.id} className="flex flex-wrap items-center gap-3 px-5 py-4">
                <span className="min-w-0 flex-1">
                  <span className="block font-semibold text-ink">
                    {o.quantity > 1 ? `${o.quantity}× ` : ""}{o.item_name}
                    {o.price_cents > 0 && <span className="ml-2 text-sm text-muted">({euros(o.price_cents * o.quantity)})</span>}
                  </span>
                  <span className="block text-xs text-muted">
                    {(Array.isArray(o.profiles) ? o.profiles[0]?.full_name : o.profiles?.full_name) ?? "—"} · {[o.size, o.color].filter(Boolean).join(" / ")}
                    {o.note && ` · "${o.note}"`}
                  </span>
                  <span className="block text-[11px] text-muted/70">
                    {new Date(o.created_at).toLocaleDateString("fr-FR", { day: "numeric", month: "long" })}
                  </span>
                </span>
                <span className={`pill text-[11px] font-semibold ${STATUS_COLORS[o.status] ?? ""}`}>
                  {STATUS_OPTIONS.find((s) => s.value === o.status)?.label ?? o.status}
                </span>
                <form action={updateOrderStatus}>
                  <input type="hidden" name="order_id" value={o.id} />
                  <select name="status" defaultValue={o.status} className="field py-1 text-sm" onChange={() => {}} required>
                    {STATUS_OPTIONS.map((s) => (
                      <option key={s.value} value={s.value}>{s.label}</option>
                    ))}
                  </select>
                  <SubmitButton className="btn-primary ml-2 px-3 py-1.5 text-xs" pending="…">OK</SubmitButton>
                </form>
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* Articles */}
      <section className="card mb-8 overflow-hidden p-0">
        <div className="flex items-center justify-between border-b border-line px-5 py-3">
          <p className="font-bold text-navy-2">🛍️ Articles ({items.length})</p>
        </div>
        {items.length === 0 ? (
          <p className="px-5 py-4 text-sm text-muted">Aucun article.</p>
        ) : (
          <ul className="divide-y divide-line">
            {items.map((item) => (
              <li key={item.id} className="flex flex-wrap items-center gap-3 px-5 py-3">
                <span className="text-2xl">{item.category === "vetement" ? "👕" : "🎁"}</span>
                <span className="min-w-0 flex-1">
                  <span className={`block font-semibold ${item.active ? "text-ink" : "text-muted line-through"}`}>
                    {item.name}
                  </span>
                  <span className="block text-xs text-muted">
                    {euros(item.price_cents)} ·{" "}
                    {[item.sizes?.join(", "), item.colors?.join(", ")].filter(Boolean).join(" — ")}
                  </span>
                </span>
                {!item.active && <span className="pill bg-paper text-muted text-[11px]">Inactif</span>}
                <Link href={`/shop/admin?edit=${item.id}`} className="btn-secondary px-3 py-1.5 text-xs">
                  Modifier
                </Link>
                <form action={deleteItem.bind(null, item.id)}>
                  <SubmitButton
                    className="rounded px-2 py-1.5 text-xs text-muted hover:bg-danger-soft hover:text-danger"
                    pending="…"
                    confirm={`Désactiver "${item.name}" ?`}
                  >
                    Désactiver
                  </SubmitButton>
                </form>
              </li>
            ))}
          </ul>
        )}
      </section>

      {/* Formulaire ajout / modification */}
      <section className="card p-5">
        <p className="mb-4 font-bold text-navy-2">{editItem ? `✏️ Modifier : ${editItem.name}` : "➕ Ajouter un article"}</p>
        <form action={upsertItem} className="space-y-4">
          {editItem && <input type="hidden" name="id" value={editItem.id} />}

          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label className="label" htmlFor="name">Nom *</label>
              <input id="name" name="name" className="field" defaultValue={editItem?.name ?? ""} required maxLength={100} />
            </div>
            <div>
              <label className="label" htmlFor="category">Catégorie</label>
              <select id="category" name="category" className="field" defaultValue={editItem?.category ?? "vetement"}>
                <option value="vetement">Vêtement</option>
                <option value="accessoire">Accessoire</option>
              </select>
            </div>
          </div>

          <div>
            <label className="label" htmlFor="description">Description</label>
            <textarea id="description" name="description" className="field min-h-16" maxLength={500}
              defaultValue={editItem?.description ?? ""} />
          </div>

          <div className="grid gap-4 sm:grid-cols-3">
            <div>
              <label className="label" htmlFor="price">Prix (€, 0 = sur devis)</label>
              <input id="price" name="price" type="number" min={0} step={0.01} className="field"
                defaultValue={editItem ? (editItem.price_cents / 100).toFixed(2) : "0"} />
            </div>
            <div>
              <label className="label" htmlFor="position">Position</label>
              <input id="position" name="position" type="number" min={0} className="field"
                defaultValue={editItem?.position ?? 0} />
            </div>
            <div className="flex items-end pb-1">
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" name="active" className="h-4 w-4 accent-sky"
                  defaultChecked={editItem?.active ?? true} />
                Article visible
              </label>
            </div>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label className="label" htmlFor="sizes">Tailles (séparées par des virgules)</label>
              <input id="sizes" name="sizes" className="field" placeholder="XS, S, M, L, XL, XXL"
                defaultValue={editItem?.sizes?.join(", ") ?? ""} />
            </div>
            <div>
              <label className="label" htmlFor="colors">Couleurs (séparées par des virgules)</label>
              <input id="colors" name="colors" className="field" placeholder="Blanc, Marine, Rouge"
                defaultValue={editItem?.colors?.join(", ") ?? ""} />
            </div>
          </div>

          <div>
            <label className="label" htmlFor="image_url">URL de l&apos;image (facultatif)</label>
            <input id="image_url" name="image_url" type="url" className="field" placeholder="https://…"
              defaultValue={editItem?.image_url ?? ""} />
          </div>

          <div className="flex gap-3">
            <SubmitButton className="btn-primary" pending="Enregistrement…">
              {editItem ? "Mettre à jour" : "Ajouter l'article"}
            </SubmitButton>
            {editItem && (
              <Link href="/shop/admin" className="btn-secondary">Annuler</Link>
            )}
          </div>
        </form>
      </section>
    </>
  );
}
