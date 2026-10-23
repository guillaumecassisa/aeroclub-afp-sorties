"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { parseEuros } from "@/lib/money";
import type { FormState } from "@/lib/types";
import { isTreasurer, requireMember, requireTreasurer } from "@/lib/auth";

function back(path: string, key: "ok" | "erreur", msg: string): never {
  // uniquement une page du site (jamais une adresse extérieure)
  if (!path.startsWith("/") || path.startsWith("//")) path = "/bar";
  revalidatePath("/bar");
  revalidatePath("/bar/tresorerie");
  const sep = path.includes("?") ? "&" : "?";
  redirect(`${path}${sep}${key}=${encodeURIComponent(msg)}`);
}

export async function addConsumption(productId: string, productName: string, formData: FormData) {
  await requireMember();
  const quantity = Math.max(1, Math.min(20, Number(formData.get("quantity") ?? 1) || 1));
  const supabase = await createClient();
  const { error } = await supabase.rpc("add_consumption", { p_product: productId, p_quantity: quantity });
  if (error) back("/bar", "erreur", error.message);
  back("/bar", "ok", `${quantity} × ${productName} ajouté${quantity > 1 ? "s" : ""} à votre ardoise. Santé !`);
}

export async function cancelConsumption(id: string, returnTo: string) {
  await requireMember();
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_consumption", { p_id: id });
  if (error) back(returnTo, "erreur", error.message);
  back(returnTo, "ok", "Consommation annulée.");
}

// ---- Trésorier -------------------------------------------------------------

export async function setPaid(userId: string, month: string, paid: boolean) {
  await requireTreasurer();
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_bar_paid", { p_user: userId, p_month: `${month}-01`, p_paid: paid });
  const path = `/bar/tresorerie?mois=${month}`;
  if (error) back(path, "erreur", error.message);
  revalidatePath("/bar/tresorerie");
  redirect(path);
}

export async function saveProduct(id: string, _: FormState, formData: FormData): Promise<FormState> {
  if (!isTreasurer(await requireMember())) return { error: "Réservé au trésorier." };
  const name = String(formData.get("name") ?? "").trim();
  const price = parseEuros(String(formData.get("price") ?? ""));
  const active = formData.get("active") === "on";
  const category = formData.get("category") === "snacks" ? "snacks" : "boissons";
  if (!name) return { error: "Nom obligatoire." };
  if (price === null) return { error: "Prix invalide." };
  const supabase = await createClient();
  const { error } = await supabase.from("bar_products").update({ name, price_cents: price, active, category }).eq("id", id);
  if (error) return { error: error.message };
  revalidatePath("/bar");
  revalidatePath("/bar/tresorerie");
  return { ok: "Enregistré." };
}

export async function addProduct(_: FormState, formData: FormData): Promise<FormState> {
  if (!isTreasurer(await requireMember())) return { error: "Réservé au trésorier." };
  const name = String(formData.get("name") ?? "").trim();
  const price = parseEuros(String(formData.get("price") ?? ""));
  const category = formData.get("category") === "snacks" ? "snacks" : "boissons";
  if (!name) return { error: "Nom obligatoire." };
  if (price === null) return { error: "Prix invalide (ex. 2,50)." };
  const supabase = await createClient();
  const { data: last } = await supabase
    .from("bar_products")
    .select("position")
    .order("position", { ascending: false })
    .limit(1);
  const position = ((last?.[0]?.position as number | undefined) ?? 0) + 1;
  const { error } = await supabase.from("bar_products").insert({ name, price_cents: price, position, category });
  if (error) return { error: error.message };
  revalidatePath("/bar");
  revalidatePath("/bar/tresorerie");
  return { ok: `${name} ajouté à la carte.` };
}
