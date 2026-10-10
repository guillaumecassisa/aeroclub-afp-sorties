"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

function back(key: "ok" | "erreur", msg: string): never {
  revalidatePath("/");
  revalidatePath("/liens");
  redirect(`/liens?${key}=${encodeURIComponent(msg)}`);
}

function read(formData: FormData) {
  const section = formData.get("section") === "liens" ? "liens" : "outils";
  const title = String(formData.get("title") ?? "").trim().slice(0, 60);
  const subtitle = String(formData.get("subtitle") ?? "").trim().slice(0, 80) || null;
  let url = String(formData.get("url") ?? "").trim();
  if (url && !/^https?:\/\//i.test(url)) url = `https://${url}`;
  const icon = String(formData.get("icon") ?? "").trim().slice(0, 8) || null;
  const position = Math.max(0, Math.min(99, Number(formData.get("position") ?? 0) || 0));
  return { section, title, subtitle, url, icon, position };
}

export async function addLink(formData: FormData) {
  const v = read(formData);
  if (!v.title || !v.url) back("erreur", "Titre et adresse obligatoires.");
  const supabase = await createClient();
  const { error } = await supabase.from("club_links").insert(v);
  if (error) back("erreur", error.message);
  back("ok", `« ${v.title} » ajouté.`);
}

export async function updateLink(id: string, formData: FormData) {
  const v = read(formData);
  if (!v.title || !v.url) back("erreur", "Titre et adresse obligatoires.");
  const supabase = await createClient();
  const { data, error } = await supabase.from("club_links").update(v).eq("id", id).select("id");
  if (error) back("erreur", error.message);
  if (!data?.length) back("erreur", "Modification réservée aux administrateurs.");
  back("ok", `« ${v.title} » enregistré.`);
}

export async function deleteLink(id: string) {
  const supabase = await createClient();
  const { error } = await supabase.from("club_links").delete().eq("id", id);
  if (error) back("erreur", error.message);
  back("ok", "Lien retiré.");
}
