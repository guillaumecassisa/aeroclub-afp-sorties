"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireMember, requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { loadShopSettings } from "@/lib/shop";

// ── Passer une commande ──────────────────────────────────────────────────────

export async function placeOrder(formData: FormData) {
  const me = await requireMember();
  const supabase = await createClient();

  const item_id = formData.get("item_id") as string;
  const quantity = Math.max(1, parseInt(formData.get("quantity") as string, 10) || 1);
  const size = (formData.get("size") as string) || null;
  const color = (formData.get("color") as string) || null;
  const note = (formData.get("note") as string) || null;

  if (!item_id) redirect("/shop?erreur=Article+manquant");
  if ((await loadShopSettings(supabase)).coming_soon) {
    redirect(`/shop?erreur=${encodeURIComponent("Le shop ouvre bientôt : les commandes ne sont pas encore possibles.")}`);
  }

  const { data: items, error: ie } = await supabase
    .from("shop_items")
    .select("id, name, price_cents, active, sizes, colors")
    .eq("id", item_id)
    .limit(1);

  const item = items?.[0] ?? null;

  if (ie) redirect(`/shop?erreur=${encodeURIComponent(ie.message)}`);
  if (!item) redirect("/shop?erreur=Article+introuvable");
  if (!item.active) redirect("/shop?erreur=Article+non+disponible");

  // sizes/colors stored as CSV string — check if selection required
  const hasSizes = item.sizes && item.sizes.trim().length > 0;
  const hasColors = item.colors && item.colors.trim().length > 0;

  if (hasSizes && !size) redirect(`/shop?erreur=Veuillez+choisir+une+taille`);
  if (hasColors && !color) redirect(`/shop?erreur=Veuillez+choisir+une+couleur`);

  const itemName = item.name ?? "Article";

  const { error } = await supabase.from("shop_orders").insert({
    user_id: me.id,
    item_id: item.id,
    item_name: itemName,
    price_cents: item.price_cents,
    quantity,
    size: size || null,
    color: color || null,
    note: note || null,
  });

  if (error) redirect(`/shop?erreur=${encodeURIComponent(error.message)}`);

  revalidatePath("/shop");
  redirect("/shop?ok=Commande+enregistree+!+Le+tresorier+vous+contactera+pour+la+suite");
}

// ── Annuler ma commande ──────────────────────────────────────────────────────

export async function cancelOrder(orderId: string) {
  await requireMember();
  const supabase = await createClient();
  // La base vérifie que la commande est bien la vôtre et encore « en attente »
  const { error } = await supabase.rpc("cancel_shop_order", { p_id: orderId });
  if (error) redirect(`/shop?erreur=${encodeURIComponent(error.message)}`);

  revalidatePath("/shop");
  revalidatePath("/shop/admin");
  redirect("/shop?ok=Commande+annulee");
}

// ── Admin : mettre à jour le statut d'une commande ──────────────────────────
// « delivered » débite l'ardoise du membre (une seule fois), dans la même opération.

export async function updateOrderStatus(orderId: string, status: string, formData?: FormData) {
  await requireAdmin();
  const supabase = await createClient();
  const back = adminBack(formData, "commandes");
  const { data, error } = await supabase.rpc("set_shop_order_status", { p_id: orderId, p_status: status });
  if (error) redirect(`${back}&erreur=${encodeURIComponent(error.message)}`);

  revalidateShop();
  const charged = (data as { charged?: boolean } | null)?.charged;
  const msg =
    status === "delivered"
      ? charged
        ? "Commande remise : montant ajouté à l'ardoise du membre et sorti du stock."
        : "Commande remise et sortie du stock."
      : "Statut mis à jour.";
  redirect(`${back}&ok=${encodeURIComponent(msg)}`);
}

/** Retour vers l'onglet d'origine de la gestion du shop (filtre de commandes conservé). */
function adminBack(fd: FormData | undefined, tab: string) {
  const ret = String(fd?.get("ret") ?? "");
  return /^\/shop\/admin\?onglet=[a-z]+(&statut=[a-z]+)?$/.test(ret) ? ret : `/shop/admin?onglet=${tab}`;
}

function revalidateShop() {
  revalidatePath("/shop");
  revalidatePath("/shop/admin");
  revalidatePath("/bar");
  revalidatePath("/bar/tresorerie");
}

const cents = (raw: FormDataEntryValue | null) => {
  const v = String(raw ?? "").trim().replace(",", ".");
  if (!v) return null;
  const n = Math.round(parseFloat(v) * 100);
  return Number.isFinite(n) && n >= 0 ? n : null;
};

// ── Admin : mode « Bientôt en ligne » ─────────────────────────────────────────

export async function setComingSoon(on: boolean, formData: FormData) {
  await requireAdmin();
  const supabase = await createClient();
  const message = String(formData.get("message") ?? "").trim().slice(0, 300) || null;
  const { error } = await supabase.rpc("set_shop_coming_soon", { p_on: on, p_message: message });
  const back = adminBack(formData, "tableau");
  if (error) redirect(`${back}&erreur=${encodeURIComponent(error.message)}`);
  revalidateShop();
  redirect(
    `${back}&ok=${encodeURIComponent(
      on
        ? "Filigrane « Bientôt en ligne » activé : les membres voient le catalogue mais ne peuvent plus commander."
        : "Shop ouvert : les membres peuvent commander.",
    )}`,
  );
}

// ── Admin : stock ─────────────────────────────────────────────────────────────

/** Réception de marchandise (quantité positive) ou correction (négative). */
export async function stockAdd(formData: FormData) {
  await requireAdmin();
  const supabase = await createClient();
  const qty = parseInt(String(formData.get("qty") ?? ""), 10);
  if (!Number.isFinite(qty) || qty === 0) redirect("/shop/admin?onglet=stock&erreur=Indiquez+une+quantit%C3%A9");
  const { error } = await supabase.rpc("shop_stock_add", {
    p_item: String(formData.get("item_id") ?? ""),
    p_size: String(formData.get("size") ?? ""),
    p_color: String(formData.get("color") ?? ""),
    p_qty: qty,
    p_unit_cost_cents: cents(formData.get("cost")),
    p_note: String(formData.get("note") ?? "").slice(0, 300) || null,
  });
  if (error) redirect(`/shop/admin?onglet=stock&erreur=${encodeURIComponent(error.message)}`);
  revalidateShop();
  redirect(`/shop/admin?onglet=stock&ok=${encodeURIComponent(qty > 0 ? `${qty} article(s) entré(s) en stock.` : "Stock corrigé.")}`);
}

/** Inventaire : fixe la quantité comptée. */
export async function stockSet(formData: FormData) {
  await requireAdmin();
  const supabase = await createClient();
  const qty = parseInt(String(formData.get("qty") ?? ""), 10);
  if (!Number.isFinite(qty) || qty < 0) redirect("/shop/admin?onglet=stock&erreur=Quantit%C3%A9+invalide");
  const { error } = await supabase.rpc("shop_stock_set", {
    p_item: String(formData.get("item_id") ?? ""),
    p_size: String(formData.get("size") ?? ""),
    p_color: String(formData.get("color") ?? ""),
    p_qty: qty,
    p_note: null,
  });
  if (error) redirect(`/shop/admin?onglet=stock&erreur=${encodeURIComponent(error.message)}`);
  revalidateShop();
  redirect("/shop/admin?onglet=stock&ok=Inventaire+enregistr%C3%A9");
}

// ── Admin : créer/modifier un article ───────────────────────────────────────

export async function upsertItem(formData: FormData) {
  await requireAdmin();
  const supabase = await createClient();

  const id = (formData.get("id") as string) || undefined;
  const name = formData.get("name") as string;
  const description = (formData.get("description") as string) || null;
  const price_cents = cents(formData.get("price")) ?? 0;
  const category = (formData.get("category") as string) || null;
  // sizes/colors stored as CSV string
  const sizes = (formData.get("sizes") as string) || null;
  const colors = (formData.get("colors") as string) || null;
  const image_url = (formData.get("image_url") as string) || null;
  const active = formData.get("active") === "true" || formData.get("active") === "on";
  const cost_cents = cents(formData.get("cost"));
  const track_stock = formData.get("track_stock") === "true" || formData.get("track_stock") === "on";
  const low_stock_alert = Math.max(0, Math.min(1000, parseInt(String(formData.get("low_stock_alert") ?? "2"), 10) || 0));

  if (!name) redirect("/shop/admin?onglet=catalogue&erreur=Nom+requis");

  const payload = {
    name,
    description,
    price_cents,
    category,
    sizes: sizes?.trim() || null,
    colors: colors?.trim() || null,
    image_url,
    active,
    cost_cents,
    track_stock,
    low_stock_alert,
  };

  const { error } = id
    ? await supabase.from("shop_items").update(payload).eq("id", id)
    : await supabase.from("shop_items").insert(payload);
  if (error) redirect(`/shop/admin?onglet=catalogue&erreur=${encodeURIComponent(error.message)}`);

  revalidatePath("/shop");
  revalidatePath("/shop/admin");
  redirect("/shop/admin?onglet=catalogue&ok=Article+enregistr%C3%A9");
}

// ── Admin : supprimer un article ─────────────────────────────────────────────

export async function deleteItem(itemId: string) {
  await requireAdmin();
  const supabase = await createClient();

  // Vérifier qu'il n'y a pas de commandes actives
  const { data: active } = await supabase
    .from("shop_orders")
    .select("id")
    .eq("item_id", itemId)
    .not("status", "in", '("cancelled","delivered")')
    .limit(1);

  if (active && active.length > 0) {
    redirect("/shop/admin?onglet=catalogue&erreur=Cet+article+a+des+commandes+en+cours");
  }

  await supabase.from("shop_items").update({ active: false }).eq("id", itemId);

  revalidatePath("/shop");
  revalidatePath("/shop/admin");
  redirect("/shop/admin?onglet=catalogue&ok=Article+d%C3%A9sactiv%C3%A9");
}
