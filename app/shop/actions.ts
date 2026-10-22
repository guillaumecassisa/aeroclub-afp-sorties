"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireMember, requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

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

export async function updateOrderStatus(orderId: string, status: string) {
  await requireAdmin();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_shop_order_status", { p_id: orderId, p_status: status });
  if (error) redirect(`/shop/admin?erreur=${encodeURIComponent(error.message)}`);

  revalidatePath("/shop");
  revalidatePath("/shop/admin");
  revalidatePath("/bar");
  revalidatePath("/bar/tresorerie");
  const charged = (data as { charged?: boolean } | null)?.charged;
  redirect(`/shop/admin?ok=${encodeURIComponent(charged ? "Commande livrée : montant ajouté à l'ardoise du membre." : "Statut mis à jour.")}`);
}

// ── Admin : créer/modifier un article ───────────────────────────────────────

export async function upsertItem(formData: FormData) {
  await requireAdmin();
  const supabase = await createClient();

  const id = (formData.get("id") as string) || undefined;
  const name = formData.get("name") as string;
  const description = (formData.get("description") as string) || null;
  const price_str = (formData.get("price") as string).replace(",", ".");
  const price_cents = Math.round(parseFloat(price_str || "0") * 100);
  const category = (formData.get("category") as string) || null;
  // sizes/colors stored as CSV string
  const sizes = (formData.get("sizes") as string) || null;
  const colors = (formData.get("colors") as string) || null;
  const image_url = (formData.get("image_url") as string) || null;
  const active = formData.get("active") === "true" || formData.get("active") === "on";

  if (!name) redirect("/shop/admin?erreur=Nom+requis");

  const payload = {
    name,
    description,
    price_cents,
    category,
    sizes: sizes?.trim() || null,
    colors: colors?.trim() || null,
    image_url,
    active,
  };

  const { error } = id
    ? await supabase.from("shop_items").update(payload).eq("id", id)
    : await supabase.from("shop_items").insert(payload);
  if (error) redirect(`/shop/admin?erreur=${encodeURIComponent(error.message)}`);

  revalidatePath("/shop");
  revalidatePath("/shop/admin");
  redirect("/shop/admin?ok=Article+enregistre");
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
    redirect("/shop/admin?erreur=Cet+article+a+des+commandes+en+cours");
  }

  await supabase.from("shop_items").update({ active: false }).eq("id", itemId);

  revalidatePath("/shop");
  revalidatePath("/shop/admin");
  redirect("/shop/admin?ok=Article+desactive");
}
