"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { AERODROMES, TIP_CATEGORIES } from "@/lib/aerodromes";
import { requireMember, requireAdmin } from "@/lib/auth";

function back(key: "ok" | "erreur", msg: string, icao?: string): never {
  revalidatePath("/bons-plans");
  redirect(`/bons-plans?${key}=${encodeURIComponent(msg)}${icao ? `&ad=${icao}` : ""}`);
}

/** Lien web ou numéro de téléphone ; tout le reste est refusé. */
function cleanContact(raw: string) {
  let c = raw.trim().slice(0, 200);
  if (!c) return null;
  if (/^[0-9 +().-]{6,25}$/.test(c)) return c;
  if (!/^https?:\/\//i.test(c)) c = `https://${c}`;
  try {
    const u = new URL(c);
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : undefined;
  } catch {
    return undefined;
  }
}

export async function addTip(formData: FormData) {
  await requireMember();
  const code = String(formData.get("icao") ?? "").trim().toUpperCase().slice(0, 4);
  const ad = AERODROMES.find((a) => a.icao === code);
  if (!ad) back("erreur", "Choisissez un aérodrome de la liste (code OACI, ex. LFMA).");
  const category = String(formData.get("category") ?? "resto");
  if (!TIP_CATEGORIES.some((c) => c.key === category)) back("erreur", "Catégorie inconnue.");
  const title = String(formData.get("title") ?? "").trim().slice(0, 80);
  if (!title) back("erreur", "Donnez un nom au bon plan.");
  const description = String(formData.get("description") ?? "").trim().slice(0, 1000) || null;
  const contact = cleanContact(String(formData.get("contact") ?? ""));
  if (contact === undefined) back("erreur", "Lien ou téléphone invalide.");
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) back("erreur", "Vous devez être connecté.");
  const { error } = await supabase.from("airfield_tips").insert({
    icao: ad.icao,
    airfield_name: ad.name,
    lat: ad.lat,
    lon: ad.lon,
    category,
    title,
    description,
    on_field: formData.get("on_field") === "on",
    contact,
    created_by: user?.id,
  });
  if (error) back("erreur", error.message);
  back("ok", `« ${title} » ajouté sur ${ad.icao}. Merci !`, ad.icao);
}

export async function archiveTip(id: string, icao: string) {
  await requireAdmin();
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("airfield_tips")
    .update({ archived_at: new Date().toISOString(), updated_at: new Date().toISOString() })
    .eq("id", id)
    .select("id");
  if (error) back("erreur", error.message, icao);
  if (!data?.length) back("erreur", "Seul l'auteur ou un administrateur peut retirer ce bon plan.", icao);
  back("ok", "Bon plan retiré.", icao);
}
