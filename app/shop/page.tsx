import type { Metadata } from "next";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { euros } from "@/lib/money";
import { formatShort } from "@/lib/dates";
import { loadShopSettings } from "@/lib/shop";
import { placeOrder, cancelOrder } from "./actions";

export const metadata: Metadata = { title: "Le shop" };
export const dynamic = "force-dynamic";

type ShopItem = {
  id: string;
  name: string;
  description: string | null;
  price_cents: number;
  category: string | null;
  sizes: string | null;
  colors: string | null;
  active: boolean;
  image_url: string | null;
  track_stock?: boolean;
};

type ShopOrder = {
  id: string;
  item_id: string;
  size: string | null;
  color: string | null;
  quantity: number;
  note: string | null;
  status: string;
  created_at: string;
  item: { name: string; price_cents: number } | null;
};

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

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const me = await requireMember();
  const sp = await searchParams;
  const supabase = await createClient();

  const [{ data: itemsRaw }, { data: ordersRaw }, { data: stockRaw }, settings] = await Promise.all([
    supabase.from("shop_items").select("*").eq("active", true).order("category").order("name"),
    supabase
      .from("shop_orders")
      .select("*, item:item_id(name, price_cents)")
      .eq("user_id", me.id)
      .order("created_at", { ascending: false }),
    supabase.from("shop_stock").select("item_id, quantity"),
    loadShopSettings(supabase),
  ]);
  const comingSoon = settings.coming_soon;
  // Indication de disponibilité : quantité en stock par article (toutes tailles et couleurs)
  const stockByItem = new Map<string, number>();
  for (const s of (stockRaw ?? []) as { item_id: string; quantity: number }[])
    stockByItem.set(s.item_id, (stockByItem.get(s.item_id) ?? 0) + Math.max(0, s.quantity));

  const items = (itemsRaw ?? []) as ShopItem[];
  const orders = (ordersRaw ?? []) as ShopOrder[];
  const activeOrders = orders.filter((o) => !["delivered", "cancelled"].includes(o.status));
  const historyOrders = orders.filter((o) => ["delivered", "cancelled"].includes(o.status));

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />

      <div className="mb-6 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">🛍️ Le shop</h1>
          <p className="text-sm text-muted">
            Vêtements et accessoires aux couleurs du club. Commandez, récupérez au club.
          </p>
        </div>
      </div>

      {comingSoon && (
        <div className="card mb-5 border-l-4 border-l-wait bg-wait-soft p-4">
          <p className="font-bold text-navy-2">🚧 Le shop sera bientôt disponible</p>
          <p className="text-sm text-ink">
            {settings.message ?? "Découvrez déjà les articles : les commandes ouvriront très prochainement."}
          </p>
        </div>
      )}

      {items.length === 0 ? (
        <div className="card p-8 text-center text-muted">Le catalogue est vide pour le moment.</div>
      ) : (
        <div className="relative">
        {comingSoon && <ComingSoonWatermark />}
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {items.map((item) => {
                    const sizeOptions = item.sizes
                      ? item.sizes.split(",").map((s) => s.trim()).filter(Boolean)
                      : [];
                    const colorOptions = item.colors
                      ? item.colors.split(",").map((c) => c.trim()).filter(Boolean)
                      : [];
                    return (
                      <div key={item.id} className="card overflow-hidden">
                        {item.image_url && (
                          <div className="aspect-video bg-paper">
                            {/* eslint-disable-next-line @next/next/no-img-element */}
                            <img
                              src={item.image_url}
                              alt={item.name}
                              className="h-full w-full object-cover"
                            />
                          </div>
                        )}
                        <div className="p-4">
                          <p className="font-semibold text-ink">{item.name}</p>
                          {item.description && (
                            <p className="mt-1 text-sm text-muted">{item.description}</p>
                          )}
                          <div className="mt-2 flex items-center justify-between gap-2">
                            <p className="text-xl font-bold text-navy-2">{euros(item.price_cents)}</p>
                            {item.track_stock !== false && stockRaw && (
                              (stockByItem.get(item.id) ?? 0) > 0 ? (
                                <span className="pill bg-ok-soft text-ok">En stock</span>
                              ) : (
                                <span className="pill bg-paper text-muted">Sur commande</span>
                              )
                            )}
                          </div>

                          {comingSoon ? (
                            <p className="mt-3 rounded-lg bg-paper px-3 py-2 text-center text-sm font-semibold text-muted">
                              Bientôt disponible
                            </p>
                          ) : (
                          <form action={placeOrder} className="mt-3 space-y-2">
                            <input type="hidden" name="item_id" value={item.id} />
                            {sizeOptions.length > 0 && (
                              <div>
                                <label className="mb-1 block text-xs font-medium text-muted">Taille</label>
                                <select name="size" className="field" required>
                                  <option value="">Choisir une taille</option>
                                  {sizeOptions.map((s) => (
                                    <option key={s} value={s}>{s}</option>
                                  ))}
                                </select>
                              </div>
                            )}
                            {colorOptions.length > 0 && (
                              <div>
                                <label className="mb-1 block text-xs font-medium text-muted">Couleur</label>
                                <select name="color" className="field" required>
                                  <option value="">Choisir une couleur</option>
                                  {colorOptions.map((c) => (
                                    <option key={c} value={c}>{c}</option>
                                  ))}
                                </select>
                              </div>
                            )}
                            <div>
                              <label className="mb-1 block text-xs font-medium text-muted">Quantité</label>
                              <select name="quantity" className="field w-20">
                                {[1, 2, 3, 4, 5].map((n) => (
                                  <option key={n} value={n}>{n}</option>
                                ))}
                              </select>
                            </div>
                            <div>
                              <label className="mb-1 block text-xs font-medium text-muted">Note (optionnel)</label>
                              <input name="note" className="field" placeholder="Personnalisation, précision…" />
                            </div>
                            <SubmitButton className="btn-primary w-full" pending="Commande…">
                              Commander
                            </SubmitButton>
                          </form>
                          )}
                        </div>
                      </div>
                    );
          })}
        </div>
        </div>
      )}

      {/* Mes commandes actives */}
      {activeOrders.length > 0 && (
        <section className="mt-8">
          <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Mes commandes en cours</h2>
          <div className="card overflow-hidden">
            <ul className="divide-y divide-line">
              {activeOrders.map((o) => (
                <li key={o.id} className="flex flex-wrap items-center gap-3 px-4 py-3">
                  <div className="flex-1">
                    <p className="font-medium text-ink">
                      {o.quantity}× {o.item?.name ?? "Article"}
                    </p>
                    <p className="text-xs text-muted">
                      {[o.size, o.color].filter(Boolean).join(" · ")}
                      {o.note && ` · ${o.note}`}
                    </p>
                    <p className="text-xs text-muted">{formatShort(o.created_at)}</p>
                  </div>
                  <div className="flex items-center gap-3">
                    <span className={`pill ${STATUS_COLORS[o.status] ?? "bg-paper text-muted"}`}>
                      {STATUS_LABELS[o.status] ?? o.status}
                    </span>
                    {o.status === "pending" && (
                      <form action={cancelOrder.bind(null, o.id)}>
                        <SubmitButton
                          className="text-xs text-danger hover:underline"
                          pending="…"
                          confirm="Annuler cette commande ?"
                        >
                          Annuler
                        </SubmitButton>
                      </form>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          </div>
        </section>
      )}

      {/* Historique */}
      {historyOrders.length > 0 && (
        <section className="mt-6">
          <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Historique</h2>
          <div className="card overflow-hidden">
            <ul className="divide-y divide-line">
              {historyOrders.map((o) => (
                <li key={o.id} className="flex flex-wrap items-center gap-3 px-4 py-3 opacity-70">
                  <div className="flex-1">
                    <p className="font-medium text-ink">
                      {o.quantity}× {o.item?.name ?? "Article"}
                    </p>
                    <p className="text-xs text-muted">
                      {[o.size, o.color].filter(Boolean).join(" · ")}
                    </p>
                    <p className="text-xs text-muted">{formatShort(o.created_at)}</p>
                  </div>
                  <span className={`pill ${STATUS_COLORS[o.status] ?? "bg-paper text-muted"}`}>
                    {STATUS_LABELS[o.status] ?? o.status}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        </section>
      )}
    </>
  );
}

/** Filigrane diagonal répété par-dessus le catalogue (ne bloque pas le défilement). */
function ComingSoonWatermark() {
  return (
    <div aria-hidden className="pointer-events-none absolute inset-0 z-10 overflow-hidden rounded-xl">
      <div className="absolute -inset-1/2 flex -rotate-[24deg] flex-col items-center justify-center gap-24">
        {Array.from({ length: 14 }, (_, i) => (
          <p
            key={i}
            className={`whitespace-nowrap text-5xl font-black tracking-[0.3em] text-navy-2/15 uppercase select-none sm:text-6xl ${
              i % 2 ? "translate-x-40" : ""
            }`}
          >
            Bientôt disponible · Bientôt disponible · Bientôt disponible
          </p>
        ))}
      </div>
    </div>
  );
}
