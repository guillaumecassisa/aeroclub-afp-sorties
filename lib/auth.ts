import { redirect } from "next/navigation";
import { cache } from "react";
import { createClient } from "@/lib/supabase/server";
import type { Profile } from "@/lib/types";

/** Profil de l'utilisateur connecté (null si non connecté). Mis en cache pour la requête. */
export const getCurrentProfile = cache(async (): Promise<Profile | null> => {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const { data } = await supabase
    .from("profiles")
    .select("*")
    .eq("id", user.id)
    .single();
  return (data as Profile) ?? null;
});

export function isStaff(p: Profile | null) {
  return p?.role === "instructor" || p?.role === "admin";
}

/** Membre validé (redirige sinon). */
export async function requireMember(): Promise<Profile> {
  const profile = await getCurrentProfile();
  if (!profile) redirect("/connexion");
  if (profile.role === "pending") redirect("/en-attente");
  return profile;
}

export async function requireStaff(): Promise<Profile> {
  const profile = await requireMember();
  if (!isStaff(profile)) redirect("/?erreur=" + encodeURIComponent("Accès réservé aux instructeurs."));
  return profile;
}

/** Peut créer et gérer des événements : instructeurs, administrateurs et fonctions du club. */
export function canOrganize(p: Profile | null) {
  if (!p || p.role === "pending") return false;
  return (
    p.role === "instructor" ||
    p.role === "admin" ||
    !!p.is_board ||
    !!p.is_chief_pilot ||
    !!p.is_compliance ||
    !!p.is_treasurer ||
    !!p.is_secretary ||
    !!p.is_maintenance
  );
}

export async function requireAdmin(): Promise<Profile> {
  const profile = await requireMember();
  if (profile.role !== "admin") redirect("/?erreur=" + encodeURIComponent("Accès réservé aux administrateurs."));
  return profile;
}

/** Publie dans l'Espace pédagogique : administrateurs, chef pilote, responsable conformité. */
export function canTeach(p: Profile | null) {
  return !!p && (p.role === "admin" || (p.role !== "pending" && (!!p.is_chief_pilot || !!p.is_compliance)));
}

export async function requireTeacher(): Promise<Profile> {
  const profile = await requireMember();
  if (!canTeach(profile)) redirect("/pedagogie?erreur=" + encodeURIComponent("Réservé au chef pilote et au responsable conformité."));
  return profile;
}

export function canManageFleet(p: Profile | null) {
  return !!p && (p.role === "admin" || (p.role !== "pending" && !!p.is_maintenance));
}

/** Ajoute / modifie les documents des avions : toute personne ayant une fonction au club. */
export function canManageDocs(p: Profile | null) {
  return canOrganize(p) || !!p?.is_instructor;
}

export async function requireFleetManager(): Promise<Profile> {
  const profile = await requireMember();
  if (!canManageFleet(profile))
    redirect("/?erreur=" + encodeURIComponent("Flotte réservée aux administrateurs et aux responsables maintenance."));
  return profile;
}

export function isTreasurer(p: Profile | null) {
  return !!p && p.role !== "pending" && !!p.is_treasurer;
}

export async function requireTreasurer(): Promise<Profile> {
  const profile = await requireMember();
  if (!isTreasurer(profile)) redirect("/bar?erreur=" + encodeURIComponent("Accès réservé au trésorier."));
  return profile;
}
