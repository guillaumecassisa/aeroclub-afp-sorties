"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

const FIELDS = [
  "association_name",
  "legal_form",
  "address",
  "registration_number",
  "publication_director",
  "contact_email",
  "contact_phone",
] as const;

export async function saveClubInfo(formData: FormData) {
  await requireAdmin();
  const info = Object.fromEntries(FIELDS.map((f) => [f, String(formData.get(f) ?? "").trim().slice(0, 300)]));
  if (info.contact_email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(info.contact_email))
    redirect(`/infos-club?erreur=${encodeURIComponent("Adresse email de contact invalide.")}`);
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_club_info", { p_info: info });
  if (error) redirect(`/infos-club?erreur=${encodeURIComponent(error.message)}`);
  revalidatePath("/mentions-legales");
  revalidatePath("/confidentialite");
  redirect(`/infos-club?ok=${encodeURIComponent("Informations enregistrées : mentions légales et politique de confidentialité mises à jour.")}`);
}
