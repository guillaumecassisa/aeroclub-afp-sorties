"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

function back(key: "ok" | "erreur", msg: string): never {
  revalidatePath("/compte");
  redirect(`/compte?${key}=${encodeURIComponent(msg)}#donnees`);
}

export async function setPhoneVisibility(value: boolean) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_phone_visibility", { p_value: value });
  if (error) back("erreur", error.message);
  revalidatePath("/annuaire");
  back("ok", value ? "Votre téléphone est visible dans l'annuaire." : "Votre téléphone est masqué dans l'annuaire.");
}

export async function requestDeletion(value: boolean) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("request_account_deletion", { p_value: value });
  if (error) back("erreur", error.message);
  revalidatePath("/droits");
  back(
    "ok",
    value
      ? "Demande de suppression envoyée. Un administrateur effacera vos données personnelles (délai maximum : 1 mois)."
      : "Demande de suppression annulée.",
  );
}

export async function setBarRankingVisibility(value: boolean) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_bar_ranking_visibility", { p_value: value });
  if (error) back("erreur", error.message);
  revalidatePath("/");
  back("ok", value ? "Vous apparaissez dans l'Équipage de l'année." : "Vous n'apparaissez plus dans l'Équipage de l'année.");
}
