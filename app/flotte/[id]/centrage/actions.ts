"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { parseEnvelope, parseStations } from "@/lib/mb";

function back(id: string, key: "ok" | "erreur", msg: string): never {
  revalidatePath(`/flotte/${id}/centrage`);
  redirect(`/flotte/${id}/centrage?${key}=${encodeURIComponent(msg)}#donnees`);
}

const num = (v: FormDataEntryValue | null) => {
  const s = String(v ?? "").trim().replace(",", ".");
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : NaN;
};

export async function saveMb(aircraftId: string, formData: FormData) {
  const stations = parseStations(String(formData.get("stations") ?? ""));
  if (typeof stations === "string") back(aircraftId, "erreur", stations);
  const envelope = parseEnvelope(String(formData.get("envelope") ?? ""));
  if (typeof envelope === "string") back(aircraftId, "erreur", envelope);
  const values = {
    serial: String(formData.get("serial") ?? "").trim().slice(0, 40) || null,
    empty_mass: num(formData.get("empty_mass")),
    empty_moment: num(formData.get("empty_moment")),
    mtow: num(formData.get("mtow")),
    mlw: num(formData.get("mlw")),
    mzfw: num(formData.get("mzfw")),
    fuel_arm: num(formData.get("fuel_arm")),
    fuel_density: num(formData.get("fuel_density")) ?? 0.72,
    fuel_capacity_l: num(formData.get("fuel_capacity_l")),
    source: String(formData.get("source") ?? "").trim().slice(0, 300) || null,
    stations,
    envelope,
    updated_at: new Date().toISOString(),
  };
  for (const [k, v] of Object.entries(values)) {
    if (typeof v === "number" && Number.isNaN(v)) back(aircraftId, "erreur", `Valeur numérique invalide (${k}).`);
  }
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("aircraft_mb")
    .upsert({ aircraft_id: aircraftId, ...values })
    .select("aircraft_id");
  if (error) back(aircraftId, "erreur", error.message);
  if (!data?.length) back(aircraftId, "erreur", "Modification réservée aux administrateurs et responsables maintenance.");
  back(aircraftId, "ok", "Données de masse et centrage enregistrées.");
}

/** Reprend les données « type » (postes, domaine, carburant, MTOW) d'un autre avion. */
export async function copyTypeData(aircraftId: string, formData: FormData) {
  const from = String(formData.get("from") ?? "");
  if (!from) back(aircraftId, "erreur", "Choisissez l'avion à copier.");
  const supabase = await createClient();
  const { data: src } = await supabase.from("aircraft_mb").select("*").eq("aircraft_id", from).maybeSingle();
  if (!src) back(aircraftId, "erreur", "Cet avion n'a pas de données à copier.");
  const { data: cur } = await supabase.from("aircraft_mb").select("serial, empty_mass, empty_moment").eq("aircraft_id", aircraftId).maybeSingle();
  const { data, error } = await supabase
    .from("aircraft_mb")
    .upsert({
      aircraft_id: aircraftId,
      serial: cur?.serial ?? null,
      empty_mass: cur?.empty_mass ?? null,
      empty_moment: cur?.empty_moment ?? null,
      mtow: src.mtow,
      mlw: src.mlw,
      mzfw: src.mzfw ?? null,
      fuel_arm: src.fuel_arm,
      fuel_density: src.fuel_density,
      fuel_capacity_l: src.fuel_capacity_l,
      stations: src.stations,
      envelope: src.envelope,
      source: src.source,
      updated_at: new Date().toISOString(),
    })
    .select("aircraft_id");
  if (error) back(aircraftId, "erreur", error.message);
  if (!data?.length) back(aircraftId, "erreur", "Modification réservée aux administrateurs et responsables maintenance.");
  back(aircraftId, "ok", "Données du type copiées. Vérifiez la masse et le moment à vide de CET avion (fiche de pesée).");
}
