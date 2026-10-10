"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import type { FormState } from "@/lib/types";

const BUCKET = "avatars";

async function currentUser() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return { supabase, user };
}

function clean(v: FormDataEntryValue | null, max = 200) {
  const s = String(v ?? "").trim().slice(0, max);
  return s || null;
}

/** Formate "jean-pierre dupont" → "Jean-Pierre DUPONT" (dernier mot = nom en majuscules). */
function formatFullName(raw: string): string {
  const parts = raw.trim().split(/\s+/);
  if (parts.length === 0) return raw;
  const lastName = parts.at(-1)!.toUpperCase();
  const firstNames = parts.slice(0, -1).map((p) =>
    p.split("-").map((seg) => seg.charAt(0).toUpperCase() + seg.slice(1).toLowerCase()).join("-")
  );
  return [...firstNames, lastName].join(" ");
}

export async function updateProfile(_: FormState, formData: FormData): Promise<FormState> {
  const rawName = clean(formData.get("full_name"), 120);
  if (!rawName) return { error: "Le nom est obligatoire." };
  const full_name = formatFullName(rawName);
  const { supabase, user } = await currentUser();
  if (!user) return { error: "Session expirée, reconnectez-vous." };

  const { error } = await supabase
    .from("profiles")
    .update({
      full_name,
      phone: clean(formData.get("phone"), 40),
      address: clean(formData.get("address"), 300),
      emergency_name: clean(formData.get("emergency_name"), 120),
      emergency_phone: clean(formData.get("emergency_phone"), 40),
    })
    .eq("id", user.id);
  if (error) return { error: error.message };
  revalidatePath("/", "layout");
  return { ok: "Coordonnées enregistrées." };
}

/** Reçoit une image déjà redimensionnée par le navigateur (JPEG ~320 px). */
export async function uploadAvatar(_: FormState, formData: FormData): Promise<FormState> {
  const file = formData.get("avatar");
  if (!(file instanceof File) || file.size === 0) return { error: "Choisissez une photo." };
  if (!file.type.startsWith("image/")) return { error: "Le fichier doit être une image." };
  if (file.size > 2 * 1024 * 1024) return { error: "Image trop lourde (2 Mo maximum)." };

  const { supabase, user } = await currentUser();
  if (!user) return { error: "Session expirée, reconnectez-vous." };

  const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg";
  const path = `${user.id}/${Date.now()}.${ext}`;
  const { error: upErr } = await supabase.storage
    .from(BUCKET)
    .upload(path, file, { contentType: file.type, cacheControl: "31536000", upsert: false });
  if (upErr) return { error: `Envoi impossible : ${upErr.message}` };

  const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(path);
  const { error } = await supabase.from("profiles").update({ avatar_url: pub.publicUrl }).eq("id", user.id);
  if (error) return { error: error.message };

  await removeOldAvatars(supabase, user.id, path);
  revalidatePath("/", "layout");
  return { ok: "Photo mise à jour." };
}

export async function removeAvatar(): Promise<FormState> {
  const { supabase, user } = await currentUser();
  if (!user) return { error: "Session expirée, reconnectez-vous." };
  await supabase.from("profiles").update({ avatar_url: null }).eq("id", user.id);
  await removeOldAvatars(supabase, user.id, null);
  revalidatePath("/", "layout");
  return { ok: "Photo supprimée." };
}

async function removeOldAvatars(
  supabase: Awaited<ReturnType<typeof createClient>>,
  userId: string,
  keep: string | null,
) {
  const { data } = await supabase.storage.from(BUCKET).list(userId);
  const old = (data ?? []).map((f) => `${userId}/${f.name}`).filter((p) => p !== keep);
  if (old.length) await supabase.storage.from(BUCKET).remove(old);
}

/** Remplace la liste des types d'avions sur lesquels le membre est lâché. */
export async function saveReleases(_: FormState, formData: FormData): Promise<FormState> {
  const wanted = new Set(formData.getAll("type").map((t) => String(t).trim()).filter(Boolean));
  const { supabase, user } = await currentUser();
  if (!user) return { error: "Session expirée, reconnectez-vous." };

  const { data: current, error: readErr } = await supabase
    .from("pilot_types")
    .select("aircraft_type")
    .eq("user_id", user.id);
  if (readErr) return { error: readErr.message };
  const have = new Set((current ?? []).map((r) => r.aircraft_type as string));

  const toAdd = [...wanted].filter((id) => !have.has(id));
  const toRemove = [...have].filter((id) => !wanted.has(id));

  if (toRemove.length) {
    const { error } = await supabase
      .from("pilot_types")
      .delete()
      .eq("user_id", user.id)
      .in("aircraft_type", toRemove);
    if (error) return { error: error.message };
  }
  if (toAdd.length) {
    const { error } = await supabase
      .from("pilot_types")
      .insert(toAdd.map((aircraft_type) => ({ user_id: user.id, aircraft_type })));
    if (error) return { error: error.message };
  }
  revalidatePath("/compte");
  revalidatePath("/droits");
  return { ok: wanted.size ? `Lâché sur ${wanted.size} type${wanted.size > 1 ? "s" : ""} d'avion. Enregistré.` : "Enregistré." };
}

export async function updateWeight(_: FormState, formData: FormData): Promise<FormState> {
  const raw = String(formData.get("weight_kg") ?? "").trim().replace(",", ".");
  const { supabase, user } = await currentUser();
  if (!user) return { error: "Session expirée, reconnectez-vous." };
  if (!raw) {
    const { error } = await supabase.from("pilot_weights").delete().eq("user_id", user.id);
    if (error) return { error: error.message };
    return { ok: "Poids effacé." };
  }
  const w = Number(raw);
  if (!Number.isFinite(w) || w < 20 || w > 250) return { error: "Indiquez un poids entre 20 et 250 kg." };
  const { error } = await supabase
    .from("pilot_weights")
    .upsert({ user_id: user.id, weight_kg: Math.round(w * 10) / 10, updated_at: new Date().toISOString() });
  if (error) return { error: error.message };
  return { ok: "Poids enregistré." };
}
