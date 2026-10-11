"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { parisLocalToISO } from "@/lib/dates";
import { requireMember, canOrganize, requireStaff } from "@/lib/auth";
import type { FormState, OutingKind } from "@/lib/types";

function back(id: string, key: "ok" | "erreur", msg: string): never {
  revalidatePath("/sorties");
  revalidatePath(`/sorties/${id}`);
  redirect(`/sorties/${id}?${key}=${encodeURIComponent(msg)}`);
}

export async function saveOuting(_prev: FormState, formData: FormData): Promise<FormState> {
  const me = await requireMember();
  if (!canOrganize(me)) return { error: "Réservé aux instructeurs et fonctions du club." };

  const id = String(formData.get("id") ?? "").trim() || null;
  const kind = (String(formData.get("kind") ?? "vol")) as OutingKind;
  const title = String(formData.get("title") ?? "").trim();
  const destination = String(formData.get("destination") ?? "").trim() || null;
  const meeting_point = String(formData.get("meeting_point") ?? "").trim() || null;
  const description = String(formData.get("description") ?? "").trim() || null;
  const departure_at = parisLocalToISO(String(formData.get("departure_at") ?? ""));
  const return_at = parisLocalToISO(String(formData.get("return_at") ?? "")) || null;
  const registration_deadline = parisLocalToISO(String(formData.get("registration_deadline") ?? "")) || null;
  const instructor_aircraft_id = String(formData.get("instructor_aircraft") ?? "").trim() || null;
  const max_participants = formData.get("max_participants") ? Number(formData.get("max_participants")) : null;

  if (!title) return { error: "Le titre est obligatoire." };
  if (!departure_at) return { error: "La date de départ est obligatoire." };

  const aircraft_ids = formData.getAll("aircraft").map(String).filter(Boolean);

  const supabase = await createClient();

  if (id) {
    const { error } = await supabase
      .from("outings")
      .update({ kind, title, destination, meeting_point, description, departure_at, return_at, registration_deadline, instructor_aircraft_id, max_participants })
      .eq("id", id);
    if (error) return { error: error.message };

    await supabase.from("outing_aircraft").delete().eq("outing_id", id);
    if (aircraft_ids.length > 0) {
      await supabase.from("outing_aircraft").insert(aircraft_ids.map((aircraft_id, position) => ({ outing_id: id, aircraft_id, position })));
    }
    revalidatePath("/sorties");
    revalidatePath(`/sorties/${id}`);
    redirect(`/sorties/${id}?ok=${encodeURIComponent("Sortie modifiée.")}`);
  } else {
    const { data, error } = await supabase
      .from("outings")
      .insert({ kind, title, destination, meeting_point, description, departure_at, return_at, registration_deadline, instructor_id: me.id, instructor_aircraft_id, max_participants })
      .select("id")
      .single();
    if (error) return { error: error.message };

    if (aircraft_ids.length > 0) {
      await supabase.from("outing_aircraft").insert(aircraft_ids.map((aircraft_id, position) => ({ outing_id: data.id, aircraft_id, position })));
    }
    revalidatePath("/sorties");
    redirect(`/sorties/${data.id}?ok=${encodeURIComponent("Sortie créée.")}`);
  }
}

export async function registerForOuting(outingId: string, formData: FormData) {
  const me = await requireMember();
  const aircraft_id = String(formData.get("aircraft_id") ?? "").trim() || null;
  const supabase = await createClient();

  const { data: existing } = await supabase
    .from("registrations")
    .select("id, status")
    .eq("outing_id", outingId)
    .eq("user_id", me.id)
    .neq("status", "cancelled")
    .maybeSingle();

  if (existing) {
    back(outingId, "erreur", "Vous êtes déjà inscrit à cette sortie.");
  }

  const { error } = await supabase.from("registrations").insert({
    outing_id: outingId,
    user_id: me.id,
    status: "confirmed",
    aircraft_id,
  });

  if (error) back(outingId, "erreur", error.message);
  back(outingId, "ok", "Inscription confirmée !");
}

export async function cancelRegistration(registrationId: string, outingId: string) {
  const me = await requireMember();
  const supabase = await createClient();

  const { error } = await supabase
    .from("registrations")
    .update({ status: "cancelled", cancelled_at: new Date().toISOString() })
    .eq("id", registrationId)
    .eq("user_id", me.id);

  if (error) back(outingId, "erreur", error.message);
  back(outingId, "ok", "Inscription annulée.");
}

export async function cancelOuting(outingId: string) {
  await requireStaff();
  const supabase = await createClient();
  const { error } = await supabase.from("outings").update({ status: "cancelled" }).eq("id", outingId);
  if (error) back(outingId, "erreur", error.message);
  revalidatePath("/sorties");
  back(outingId, "ok", "Sortie annulée.");
}

export async function moveParticipant(
  registrationId: string,
  outingId: string,
  newAircraftId: string | null,
): Promise<void> {
  await requireStaff();
  const supabase = await createClient();
  const { error } = await supabase
    .from("registrations")
    .update({ aircraft_id: newAircraftId })
    .eq("id", registrationId);
  if (error) back(outingId, "erreur", error.message);
  revalidatePath(`/sorties/${outingId}`);
}
