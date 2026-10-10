"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export async function setEventEmails(value: boolean) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_event_notifications", { p_value: value });
  revalidatePath("/compte");
  if (error) redirect(`/compte?erreur=${encodeURIComponent(error.message)}#emails`);
  redirect(
    `/compte?ok=${encodeURIComponent(
      value ? "Vous recevrez un email à chaque nouvel événement." : "Vous ne recevrez plus d'email pour les nouveaux événements.",
    )}#emails`,
  );
}
