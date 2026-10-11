import type { Metadata } from "next";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { euros } from "@/lib/money";
import { formatShort } from "@/lib/dates";
import { updateOrderStatus, upsertItem, deleteItem } from "../actions";

export const metadata: Metadata = { title: "Admin – Le shop" };
export const dynamic = "force-dynamic";

const STATUS_LABELS: Record<string, string> = {
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

const STATUS_FLOW = ["pending", "confirmed", "ready", "delivered", "cancelled"];

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

  const editId = sp.edit ?? null;
  const editItem = editId ? items.find((i) => i.id === editId) : null;

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />

      <div className="mb-6">
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">🛍️ Admin – Le shop</h1>
      </div>

      {/* Commandes en cours */}
      <section className="mb-8">
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
                        {formatShort(o.created_at)} · {item ? euros(item.price_cents * o.quantity) : ""}
                      </p>
                    </div>
                    <div className="flex flex-wrap items-center gap-2">
                      <span className={`pill ${STATUS_COLORS[o.status] ?? "bg-paper text-muted"}`}>
                        {STATUS_LABELS[o.status] ?? o.status}
                      </span>
                      {STATUS_FLOW.filter((s) => s !== o.status).map((s) => (
                        <form key={s} action={updateOrderStatus.bind(null, o.id, s)}>
                          <SubmitButton className="text-xs text-navy-2 hover:underline" pending="…">
                            → {STATUS_LABELS[s]}
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

      {/* Catalogue */}
      <section>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-lg font-bold tracking-tight text-navy-2">Catalogue</h2>
          <a href="/shop/admin?edit=new" className="btn-primary text-sm">
            + Ajouter un article
          </a>
        </div>

        {/* Form add/edit */}
        {(editId === "new" || editItem) && (
          <div className="card mb-4 p-5">
            <h3 className="mb-4 font-semibold text-navy-2">
              {editItem ? "Modifier l'article" : "Nouvel article"}
            </h3>
            <form action={upsertItem} className="space-y-3">
              {editItem && <input type="hidden" name="id" value={editItem.id} />}
              <div className="grid gap-3 sm:grid-cols-2">
                <div>
                  <label className="mb-1 block text-xs font-medium text-muted">Nom *</label>
                  <input name="name" className="field" required defaultValue={editItem?.name ?? ""} />
                </div>
                <div>
                  <label className="mb-1 block text-xs font-medium text-muted">Catégorie</label>
                  <input name="category" className="field" defaultValue={editItem?.category ?? ""} placeholder="ex: Vêtements" />
                </div>
                <div>
                  <label className="mb-1 block text-xs font-medium text-muted">Prix (€) *</label>
                  <input
                    name="price"
                    type="number"
                    step="0.01"
                    min="0"
                    className="field"
                    required
                    defaultValue={editItem ? (editItem.price_cents / 100).toFixed(2) : ""}
                  />
                </div>
                <div>
                  <label className="mb-1 block text-xs font-medium text-muted">URL image</label>
                  <input name="image_url" className="field" defaultValue={editItem?.image_url ?? ""} placeholder="https://…" />
                </div>
                <div className="sm:col-span-2">
                  <label className="mb-1 block text-xs font-medium text-muted">Description</label>
                  <textarea name="description" className="field" rows={2} defaultValue={editItem?.description ?? ""} />
                </div>
                <div>
                  <label className="mb-1 block text-xs font-medium text-muted">Tailles (séparées par virgule)</label>
                  <input name="sizes" className="field" defaultValue={editItem?.sizes ?? ""} placeholder="XS, S, M, L, XL" />
                </div>
                <div>
                  <label className="mb-1 block text-xs font-medium text-muted">Couleurs (séparées par virgule)</label>
                  <input name="colors" className="field" defaultValue={editItem?.colors ?? ""} placeholder="Blanc, Marine, Rouge" />
                </div>
              </div>
              <div className="flex items-center gap-4">
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    name="active"
                    value="true"
                    defaultChecked={editItem ? editItem.active : true}
                    onChange={(e) => {
                      const hidden = e.currentTarget.form?.querySelector<HTMLInputElement>('input[name="active"][type="hidden"]');
                      if (hidden) hidden.value = e.currentTarget.checked ? "true" : "false";
                    }}
                  />
                  Article actif (visible dans le shop)
                </label>
              </div>
              <div className="flex gap-3">
                <SubmitButton className="btn-primary" pending="Enregistrement…">
                  {editItem ? "Modifier" : "Ajouter"}
                </SubmitButton>
                <a href="/shop/admin" className="btn-secondary">
                  Annuler
                </a>
              </div>
            </form>
          </div>
        )}

        <div className="card overflow-hidden">
          {items.length === 0 ? (
            <p className="p-6 text-center text-muted">Aucun article dans le catalogue.</p>
          ) : (
            <ul className="divide-y divide-line">
              {items.map((item) => (
                <li key={item.id} className="flex flex-wrap items-center gap-3 px-4 py-3">
                  <div className="flex-1 min-w-0">
                    <p className="font-medium text-ink">
                      {item.name}
                      {!item.active && (
                        <span className="ml-2 text-xs text-muted">(inactif)</span>
                      )}
                    </p>
                    <p className="text-xs text-muted">
                      {item.category && `${item.category} · `}
                      {euros(item.price_cents)}
                      {item.sizes && ` · Tailles : ${item.sizes}`}
                      {item.colors && ` · Couleurs : ${item.colors}`}
                    </p>
                  </div>
                  <div className="flex gap-2">
                    <a href={`/shop/admin?edit=${item.id}`} className="btn-secondary text-xs">
                      Modifier
                    </a>
                    <form action={deleteItem.bind(null, item.id)}>
                      <SubmitButton
                        className="text-xs text-danger hover:underline"
                        pending="…"
                        confirm={`Désactiver « ${item.name} » ?`}
                      >
                        Désactiver
                      </SubmitButton>
                    </form>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>
    </>
  );
}
