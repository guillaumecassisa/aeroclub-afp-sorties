"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { AERODROMES } from "@/lib/aerodromes";
import { requireMember } from "@/lib/auth";

function back(key: "ok" | "erreur", msg: string): never {
  revalidatePath("/shareflight");
  redirect(`/shareflight?${key}=${encodeURIComponent(msg)}`);
}

/** Publier un vol partagé */
export async function publishFlight(formData: FormData) {
  const me = await requireMember();

  const depCode = String(formData.get("dep_icao") ?? "").trim().toUpperCase().slice(0, 4);
  const arrCode = String(formData.get("arr_icao") ?? "").trim().toUpperCase().slice(0, 4);
  const dep = AERODROMES.find((a) => a.icao === depCode);
  const arr = AERODROMES.find((a) => a.icao === arrCode);
  if (!dep) back("erreur", "Aérodrome de départ non reconnu.");
  if (!arr) back("erreur", "Aérodrome d'arrivée non reconnu.");
  if (dep.icao === arr.icao) back("erreur", "Le départ et l'arrivée doivent être différents.");

  const dateStr = String(formData.get("flight_date") ?? "").trim();
  if (!dateStr || !/^\d{4}-\d{2}-\d{2}$/.test(dateStr)) back("erreur", "Date invalide.");
  if (dateStr < new Date().toISOString().slice(0, 10)) back("erreur", "La date doit être aujourd'hui ou dans le futur.");

  const seats = Math.max(1, Math.min(5, Number(formData.get("seats") ?? 1) || 1));
  const aircraft = String(formData.get("aircraft") ?? "").trim().slice(0, 40) || null;
  const comment = String(formData.get("comment") ?? "").trim().slice(0, 600) || null;

  const supabase = await createClient();
  const { error } = await supabase.from("flight_shares").insert({
    pilot_id: me.id,
    dep_icao: dep.icao,
    dep_name: dep.name,
    dep_lat: dep.lat,
    dep_lon: dep.lon,
    arr_icao: arr.icao,
    arr_name: arr.name,
    arr_lat: arr.lat,
    arr_lon: arr.lon,
    flight_date: dateStr,
    seats,
    aircraft,
    comment,
  });
  if (error) back("erreur", error.message);
  back("ok", `Votre vol ${dep.icao} → ${arr.icao} le ${fmtDate(dateStr)} est publié !`);
}

/** Rejoindre un vol (s'inscrire comme passager) */
export async function joinFlight(shareId: string, message: string) {
  const me = await requireMember();
  const supabase = await createClient();

  // Vérifications métier (la RLS les double côté base)
  const { data: share } = await supabase
    .from("flight_shares")
    .select("id, status, pilot_id, seats")
    .eq("id", shareId)
    .single();
  if (!share) back("erreur", "Vol introuvable.");
  if (share.status !== "open") back("erreur", "Ce vol n'est plus ouvert.");
  if (share.pilot_id === me.id) back("erreur", "Vous êtes le pilote de ce vol.");

  const { count } = await supabase
    .from("flight_share_seats")
    .select("id", { count: "exact", head: true })
    .eq("share_id", shareId);
  if ((count ?? 0) >= share.seats) back("erreur", "Plus de places disponibles.");

  const { error } = await supabase.from("flight_share_seats").insert({
    share_id: shareId,
    member_id: me.id,
    message: message.trim().slice(0, 300) || null,
  });
  if (error?.code === "23505") back("erreur", "Vous êtes déjà inscrit sur ce vol.");
  if (error) back("erreur", error.message);
  back("ok", "Vous êtes inscrit sur ce vol !");
}

/** Quitter un vol (passager se désinscrit) */
export async function leaveFlight(shareId: string) {
  const me = await requireMember();
  const supabase = await createClient();
  const { error } = await supabase
    .from("flight_share_seats")
    .delete()
    .eq("share_id", shareId)
    .eq("member_id", me.id);
  if (error) back("erreur", error.message);
  back("ok", "Vous êtes désinscrit du vol.");
}

/** Clore ou annuler un vol (pilote ou admin) */
export async function closeFlight(shareId: string, action: "closed" | "cancelled") {
  await requireMember();
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("flight_shares")
    .update({ status: action, closed_at: new Date().toISOString(), updated_at: new Date().toISOString() })
    .eq("id", shareId)
    .select("id");
  if (error) back("erreur", error.message);
  if (!data?.length) back("erreur", "Opération non autorisée.");
  back("ok", action === "cancelled" ? "Vol annulé." : "Vol clôturé.");
}

function fmtDate(iso: string) {
  return new Date(iso + "T12:00:00").toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" });
}
