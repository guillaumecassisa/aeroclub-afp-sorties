import type { SupabaseClient } from "@supabase/supabase-js";

/** Statuts d'une commande du shop, dans l'ordre du circuit normal. */
export const ORDER_STATUS: Record<string, { label: string; color: string }> = {
  pending: { label: "En attente", color: "bg-wait-soft text-wait" },
  confirmed: { label: "Confirmée", color: "bg-sky-soft text-navy-2" },
  ready: { label: "Prête à retirer", color: "bg-ok-soft text-ok" },
  delivered: { label: "Livrée", color: "bg-paper text-muted" },
  cancelled: { label: "Annulée", color: "bg-danger-soft text-danger" },
};
export const ACTIVE_STATUSES = ["pending", "confirmed", "ready"] as const;

/** Étape suivante proposée pour une commande (un seul bouton principal). */
export const NEXT_STEP: Record<string, { status: string; label: string } | undefined> = {
  pending: { status: "confirmed", label: "Confirmer" },
  confirmed: { status: "ready", label: "Prête à retirer" },
  ready: { status: "delivered", label: "Remettre au membre" },
};

export type ShopItem = {
  id: string;
  name: string;
  description: string | null;
  price_cents: number;
  cost_cents: number | null;
  category: string | null;
  sizes: string | null;
  colors: string | null;
  active: boolean;
  image_url: string | null;
  track_stock: boolean;
  low_stock_alert: number;
};

export type ShopOrder = {
  id: string;
  user_id: string;
  item_id: string;
  item_name: string;
  price_cents: number;
  quantity: number;
  size: string | null;
  color: string | null;
  note: string | null;
  status: string;
  created_at: string;
  updated_at: string;
  delivered_at: string | null;
  ardoise_charged: boolean;
  member?: { full_name: string | null; email?: string | null } | null;
};

export type StockRow = { item_id: string; size: string; color: string; quantity: number };
export type StockMove = {
  id: number;
  item_id: string;
  size: string;
  color: string;
  delta: number;
  reason: string;
  unit_cost_cents: number | null;
  order_id: string | null;
  note: string | null;
  created_at: string;
  author?: { full_name: string | null } | null;
};

export const MOVE_REASONS: Record<string, string> = {
  reception: "Réception",
  vente: "Vente",
  retour: "Retour en stock",
  inventaire: "Inventaire",
  correction: "Correction",
};

const list = (csv: string | null) => (csv ?? "").split(",").map((s) => s.trim()).filter(Boolean);

/** Variantes d'un article : toutes les combinaisons taille × couleur (chaîne vide si aucune). */
export function itemVariants(item: Pick<ShopItem, "sizes" | "colors">): { size: string; color: string }[] {
  const sizes = list(item.sizes);
  const colors = list(item.colors);
  const out: { size: string; color: string }[] = [];
  for (const s of sizes.length ? sizes : [""]) for (const c of colors.length ? colors : [""]) out.push({ size: s, color: c });
  return out;
}

export const variantKey = (itemId: string, size: string | null, color: string | null) =>
  `${itemId}|${size ?? ""}|${color ?? ""}`;

export function variantLabel(size: string | null, color: string | null) {
  return [size, color].filter(Boolean).join(" · ") || "Modèle unique";
}

/** Lit toutes les lignes d'une requête, par tranches de 1000 (limite de Supabase). */
export async function fetchAll<T>(
  build: (from: number, to: number) => PromiseLike<{ data: unknown; error: { message: string } | null }>,
): Promise<{ rows: T[]; error: string | null }> {
  const rows: T[] = [];
  for (let from = 0; from < 100000; from += 1000) {
    const { data, error } = await build(from, from + 999);
    if (error) return { rows, error: error.message };
    const page = (data ?? []) as T[];
    rows.push(...page);
    if (page.length < 1000) break;
  }
  return { rows, error: null };
}

/** Données complètes du shop pour l'administration et l'export. */
export async function loadShopData(supabase: SupabaseClient) {
  const [items, orders, stock] = await Promise.all([
    fetchAll<ShopItem>((a, b) => supabase.from("shop_items").select("*").order("category").order("name").range(a, b)),
    fetchAll<ShopOrder>((a, b) =>
      supabase
        .from("shop_orders")
        .select("*, member:user_id(full_name, email)")
        .order("created_at", { ascending: false })
        .range(a, b),
    ),
    fetchAll<StockRow>((a, b) => supabase.from("shop_stock").select("item_id, size, color, quantity").range(a, b)),
  ]);
  const stockMap = new Map<string, number>();
  for (const s of stock.rows) stockMap.set(variantKey(s.item_id, s.size, s.color), s.quantity);
  // Quantités réservées par les commandes en cours (pas encore remises)
  const reserved = new Map<string, number>();
  for (const o of orders.rows) {
    if (!(ACTIVE_STATUSES as readonly string[]).includes(o.status)) continue;
    const k = variantKey(o.item_id, o.size, o.color);
    reserved.set(k, (reserved.get(k) ?? 0) + o.quantity);
  }
  return {
    items: items.rows,
    orders: orders.rows,
    stockRows: stock.rows,
    stockMap,
    reserved,
    error: items.error ?? orders.error ?? stock.error,
  };
}

/** Date de vente d'une commande livrée (date de livraison, à défaut dernière mise à jour). */
export const saleDate = (o: ShopOrder) => o.delivered_at ?? o.updated_at;

export function parisYearMonth(iso: string) {
  const d = new Date(iso);
  const parts = new Intl.DateTimeFormat("fr-FR", { timeZone: "Europe/Paris", year: "numeric", month: "2-digit" }).formatToParts(d);
  const y = parts.find((p) => p.type === "year")?.value ?? "0000";
  const m = parts.find((p) => p.type === "month")?.value ?? "01";
  return { year: y, month: `${y}-${m}` };
}
