"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireAdmin } from "@/lib/auth";
import type { Role } from "@/lib/types";

const ROLES: Role[] = ["pending", "member", "instructor", "admin"];

export async function setRole(userId: string, formData: FormData) {
  await requireAdmin();
  const role = String(formData.get("role")) as Role;
  if (!ROLES.includes(role)) return;
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_user_role", { p_user: userId, p_role: role });
  revalidatePath("/droits");
  if (error) redirect(`/droits?erreur=${encodeURIComponent(error.message)}`);
  redirect(`/droits?ok=${encodeURIComponent("Compte validé.")}`);
}

const FUNCTION_MSG: Record<string, [string, string]> = {
  admin: ["est maintenant administrateur.", "n'est plus administrateur."],
  instructeur: ["est maintenant instructeur.", "n'est plus instructeur."],
  tresorier: ["est maintenant trésorier.", "n'est plus trésorier."],
  secretaire: ["est maintenant secrétaire (droits administrateur complets).", "n'est plus secrétaire."],
  maintenance: ["est maintenant responsable maintenance.", "n'est plus responsable maintenance."],
  chef_pilote: ["est maintenant chef pilote.", "n'est plus chef pilote."],
  conformite: ["est maintenant responsable conformité.", "n'est plus responsable conformité."],
};

async function applyFunction(userId: string, fn: string, value: boolean) {
  await requireAdmin();
  if (!userId || !FUNCTION_MSG[fn]) redirect(`/droits?erreur=${encodeURIComponent("Choisissez un membre et une fonction.")}`);
  const supabase = await createClient();
  const { data: p } = await supabase.from("profiles").select("full_name, email").eq("id", userId).maybeSingle();
  const { error } = await supabase.rpc("set_function", { p_user: userId, p_function: fn, p_value: value });
  revalidatePath("/droits");
  revalidatePath("/", "layout");
  if (error) {
    const msg = /set_function|schema cache/i.test(error.message)
      ? "La base n'est pas à jour : exécutez le fichier « mise-a-jour-complete.sql » dans Supabase."
      : error.message;
    redirect(`/droits?erreur=${encodeURIComponent(msg)}`);
  }
  const name = p?.full_name || p?.email || "Le membre";
  redirect(`/droits?ok=${encodeURIComponent(`${name} ${FUNCTION_MSG[fn][value ? 0 : 1]}`)}`);
}

export async function assignFunction(formData: FormData) {
  await applyFunction(String(formData.get("user") ?? ""), String(formData.get("fn") ?? ""), true);
}

export async function removeFunction(userId: string, fn: string) {
  await applyFunction(userId, fn, false);
}

export async function anonymizeMember(userId: string) {
  await requireAdmin();
  const supabase = await createClient();
  const { data: p } = await supabase.from("profiles").select("full_name, avatar_url").eq("id", userId).maybeSingle();
  const { error } = await supabase.rpc("anonymize_member", { p_user: userId });
  revalidatePath("/droits");
  revalidatePath("/annuaire");
  if (error) redirect(`/droits?erreur=${encodeURIComponent(error.message)}`);
  // Photo de profil : effacée du stockage
  const { data: files } = await supabase.storage.from("avatars").list(userId);
  if (files?.length) await supabase.storage.from("avatars").remove(files.map((f) => `${userId}/${f.name}`));
  redirect(
    `/droits?ok=${encodeURIComponent(
      `Données personnelles de ${p?.full_name || "ce membre"} effacées. Dernière étape : supprimez son identifiant de connexion dans Supabase (Authentication → Users).`,
    )}`,
  );
}
