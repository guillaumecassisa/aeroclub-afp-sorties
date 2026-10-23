"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireFleetManager } from "@/lib/auth";
import type { FormState } from "@/lib/types";

export async function addAircraft(_: FormState, formData: FormData): Promise<FormState> {
  try { await requireFleetManager(); } catch { return { error: "Accès réservé aux administrateurs et responsables maintenance." }; }
  const registration = String(formData.get("registration") ?? "").trim().toUpperCase();
  const model = String(formData.get("model") ?? "").trim();
  const seats = Number(formData.get("seats"));
  const type = normalizeType(String(formData.get("type") ?? "")) || typeFromModel(model);
  if (!registration || !model) return { error: "Immatriculation et modèle obligatoires." };
  if (!Number.isInteger(seats) || seats < 1 || seats > 9) return { error: "Nombre de places : entre 1 et 9." };

  const supabase = await createClient();
  const { error } = await supabase.from("aircraft").insert({ registration, model, seats, type });
  if (error) {
    return { error: error.code === "23505" ? `${registration} existe déjà.` : error.message };
  }
  revalidatePath("/maintenance");
  return { ok: `${registration} ajouté à la flotte.` };
}

/** "dr 400" -> "DR400" ; vide si rien de saisi */
function normalizeType(t: string) {
  return t.trim().toUpperCase().replace(/\s+/g, "");
}

/** "DR400-180" -> "DR400", "PS28 Cruiser" -> "PS28" */
function typeFromModel(model: string) {
  return (model.trim().split(/[\s-]+/)[0] ?? model).toUpperCase();
}

function back(key: "ok" | "erreur", msg: string): never {
  revalidatePath("/maintenance");
  revalidatePath("/");
  redirect(`/maintenance?${key}=${encodeURIComponent(msg)}`);
}

export async function updateAircraftType(id: string, formData: FormData) {
  await requireFleetManager();
  const type = normalizeType(String(formData.get("type") ?? ""));
  if (!type) back("erreur", "Indiquez un type.");
  const supabase = await createClient();
  const { data, error } = await supabase.from("aircraft").update({ type }).eq("id", id).select("id");
  if (error) back("erreur", error.message);
  if (!data?.length) back("erreur", "Modification refusée : réservé aux administrateurs et responsables maintenance.");
  revalidatePath("/compte");
  back("ok", "Type mis à jour.");
}

export async function toggleAircraft(id: string, active: boolean) {
  await requireFleetManager();
  const supabase = await createClient();
  const { data, error } = await supabase.from("aircraft").update({ active }).eq("id", id).select("id");
  if (error) back("erreur", error.message);
  if (!data?.length) back("erreur", "Modification refusée : réservé aux administrateurs et responsables maintenance.");
  back("ok", active ? "Avion réactivé." : "Avion désactivé.");
}

export async function setAvailability(id: string, available: boolean, formData?: FormData) {
  await requireFleetManager();
  const reason = available ? null : String(formData?.get("reason") ?? "").trim().slice(0, 120) || null;
  const day = (k: string) => {
    const v = String(formData?.get(k) ?? "");
    return /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null;
  };
  const from = available ? null : day("from");
  const until = available ? null : day("until");
  if (from && until && until < from) back("erreur", "La date de fin doit être après la date de début.");
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_aircraft_availability", {
    p_id: id,
    p_available: available,
    p_reason: reason,
    p_from: from,
    p_until: until,
  });
  if (error) {
    // Fonction pas encore visible par l'API : on tente la mise à jour directe
    const { data, error: e2 } = await supabase
      .from("aircraft")
      .update({ available, unavailable_reason: reason, unavailable_from: from, unavailable_until: until })
      .eq("id", id)
      .select("id");
    if (e2) back("erreur", `Impossible de modifier la disponibilité : ${e2.message} (${error.message})`);
    if (!data?.length) back("erreur", `Modification refusée : ${error.message}`);
  }
  back("ok", available ? "Avion remis en service." : "Avion marqué indisponible.");
}
