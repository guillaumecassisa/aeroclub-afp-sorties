"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { parisLocalToISO } from "@/lib/dates";
import { requireMember, canOrganize } from "@/lib/auth";

function back(key: "ok" | "erreur", msg: string): never {
  revalidatePath("/");
  redirect(`/?${key}=${encodeURIComponent(msg)}#annonces`);
}

export async function createAnnouncement(formData: FormData) {
  const me = await requireMember();
  if (!canOrganize(me)) back("erreur", "Publier une annonce est réservé aux personnes ayant une fonction au club.");
  const title = String(formData.get("title") ?? "").trim().slice(0, 120);
  const body = String(formData.get("body") ?? "").trim().slice(0, 2000) || null;
  const important = formData.get("important") === "on";
  const expires = parisLocalToISO(String(formData.get("expires_at") ?? ""));
  if (!title) back("erreur", "Le titre de l'annonce est obligatoire.");
  const supabase = await createClient();
  const { error } = await supabase.from("announcements").insert({ title, body, important, expires_at: expires });
  if (error)
    back(
      "erreur",
      /row-level security|permission/i.test(error.message)
        ? "Publier une annonce est réservé aux personnes ayant une fonction au club."
        : error.message,
    );
  back("ok", "Annonce publiée.");
}

export async function deleteAnnouncement(id: string) {
  const me = await requireMember();
  if (!canOrganize(me)) back("erreur", "Supprimer une annonce est réservé aux personnes ayant une fonction au club.");
  const supabase = await createClient();
  const { error } = await supabase.from("announcements").delete().eq("id", id);
  if (error) back("erreur", error.message);
  back("ok", "Annonce supprimée.");
}
