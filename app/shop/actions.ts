"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireMember, requireAdmin } from "@/lib/auth";

export async function placeOrder(formData: FormData) {
  const me = await requireMember();
  const supabase = await createClient();

  const item_id = String(formData.get("item_id") ?? "").trim();
  const size = String(formData.get("size") ?? "").trim() || null;
  const color = String(formData.get("color") ?? "").trim() || null;
  const quantity = Math.max(1, Number(formData.get("quantity") ?? 1));
  const note = String(formData.get("note") ?? "").trim() || null;

  if (!item_id) redirect("/shop?erreur=" + encodeURIComponent("Article introuvable."));

  const { error } = await supabase.from("shop_orders").insert({
    user_id: me.id,
    item_id,
    size,
    color,
    quantity,
    note,
    status: "pending",
  });

  if (error) redirect("/shop?erreur=" + encodeURIComponent(error.message));
  revalidatePath("/shop");
  redirect("/shop?ok=" + encodeURIComponent("Commande passée !"));
}

export async function cancelOrder(orderId: string) {
  const me = await requireMember();
  const supabase = await createClient();

  const { error } = await supabase
    .from("shop_orders")
    .update({ status: "cancelled" })
    .eq("id", orderId)
    .eq("user_id", me.id)
    .eq("status", "pending");

  if (error) redirect("/shop?erreur=" + encodeURIComponent(error.message));
  revalidatePath("/shop");
  redirect("/shop?ok=" + encodeURIComponent("Commande annulée."));
}

export async function updateOrderStatus(orderId: string, status: string) {
  await requireAdmin();
  const supabase = await createClient();

  const { error } = await supabase
    .from("shop_orders")
    .update({ status })
    .eq("id", orderId);

  if (error) redirect("/shop/admin?erreur=" + encodeURIComponent(error.message));
  revalidatePath("/shop/admin");
  redirect("/shop/admin?ok=" + encodeURIComponent("Statut mis à jour."));
}

export async function upsertItem(formData: FormData) {
  await requireAdmin();
  const supabase = await createClient();

  const id = String(formData.get("id") ?? "").trim() || null;
  const name = String(formData.get("name") ?? "").trim();
  const description = String(formData.get("description") ?? "").trim() || null;
  const price_cents = Math.round(Number(String(formData.get("price") ?? "0").replace(",", ".")) * 100);
  const category = String(formData.get("category") ?? "").trim() || null;
  const sizes = String(formData.get("sizes") ?? "").trim() || null;
  const colors = String(formData.get("colors") ?? "").trim() || null;
  const active = formData.get("active") !== "false";
  const image_url = String(formData.get("image_url") ?? "").trim() || null;

  if (!name) redirect("/shop/admin?erreur=" + encodeURIComponent("Le nom est obligatoire."));

  if (id) {
    const { error } = await supabase
      .from("shop_items")
      .update({ name, description, price_cents, category, sizes, colors, active, image_url })
      .eq("id", id);
    if (error) redirect("/shop/admin?erreur=" + encodeURIComponent(error.message));
  } else {
    const { error } = await supabase
      .from("shop_items")
      .insert({ name, description, price_cents, category, sizes, colors, active, image_url });
    if (error) redirect("/shop/admin?erreur=" + encodeURIComponent(error.message));
  }

  revalidatePath("/shop");
  revalidatePath("/shop/admin");
  redirect("/shop/admin?ok=" + encodeURIComponent(id ? "Article modifié." : "Article ajouté."));
}

export async function deleteItem(itemId: string) {
  await requireAdmin();
  const supabase = await createClient();

  const { error } = await supabase.from("shop_items").update({ active: false }).eq("id", itemId);
  if (error) redirect("/shop/admin?erreur=" + encodeURIComponent(error.message));
  revalidatePath("/shop");
  revalidatePath("/shop/admin");
  redirect("/shop/admin?ok=" + encodeURIComponent("Article désactivé."));
}
