"use server";

import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import type { FormState } from "@/lib/types";

async function siteUrl() {
  if (process.env.NEXT_PUBLIC_SITE_URL) return process.env.NEXT_PUBLIC_SITE_URL.replace(/\/$/, "");
  const h = await headers();
  const host = h.get("x-forwarded-host") ?? h.get("host");
  const proto = h.get("x-forwarded-proto") ?? "https";
  return `${proto}://${host}`;
}

function safeNext(next: FormDataEntryValue | null) {
  const n = typeof next === "string" ? next : "";
  return n.startsWith("/") && !n.startsWith("//") ? n : "/";
}

function translate(message: string) {
  const m = message.toLowerCase();
  if (m.includes("invalid login")) return "Email ou mot de passe incorrect.";
  if (m.includes("email not confirmed")) return "Confirmez d'abord votre adresse email (lien reçu par email).";
  if (m.includes("already registered")) return "Un compte existe déjà avec cet email.";
  if (m.includes("password should be")) return "Mot de passe trop court (8 caractères minimum).";
  if (m.includes("rate limit")) return "Trop de tentatives, réessayez dans quelques minutes.";
  return message;
}

export async function login(_: FormState, formData: FormData): Promise<FormState> {
  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({
    email: String(formData.get("email") ?? "").trim(),
    password: String(formData.get("password") ?? ""),
  });
  if (error) return { error: translate(error.message) };
  redirect(safeNext(formData.get("next")));
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

export async function signup(_: FormState, formData: FormData): Promise<FormState> {
  const full_name = formatFullName(String(formData.get("full_name") ?? ""));
  const phone = String(formData.get("phone") ?? "").trim();
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  if (!full_name) return { error: "Indiquez vos nom et prénom." };
  if (password.length < 8) return { error: "Mot de passe trop court (8 caractères minimum)." };
  if (formData.get("consent") !== "on")
    return { error: "Merci d'accepter la politique de confidentialité pour créer votre compte." };

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      // Preuve du consentement (date + version de la politique acceptée)
      data: { full_name, phone, privacy_accepted_at: new Date().toISOString(), privacy_version: "2026-09" },
      emailRedirectTo: `${await siteUrl()}/auth/confirm`,
    },
  });
  if (error) return { error: translate(error.message) };
  if (data.session) redirect("/"); // confirmation email désactivée côté Supabase
  return {
    ok: "Compte créé ! Cliquez sur le lien reçu par email pour confirmer votre adresse. Un administrateur du club validera ensuite votre compte.",
  };
}

export async function forgotPassword(_: FormState, formData: FormData): Promise<FormState> {
  const supabase = await createClient();
  const { error } = await supabase.auth.resetPasswordForEmail(String(formData.get("email") ?? "").trim(), {
    redirectTo: `${await siteUrl()}/auth/confirm?next=/compte/mot-de-passe`,
  });
  if (error) return { error: translate(error.message) };
  return { ok: "Si un compte existe pour cette adresse, un email de réinitialisation vient d'être envoyé." };
}

export async function updatePassword(_: FormState, formData: FormData): Promise<FormState> {
  const password = String(formData.get("password") ?? "");
  if (password.length < 8) return { error: "Mot de passe trop court (8 caractères minimum)." };
  if (password !== String(formData.get("confirm") ?? "")) return { error: "Les deux mots de passe diffèrent." };
  const supabase = await createClient();
  const { error } = await supabase.auth.updateUser({ password });
  if (error) return { error: translate(error.message) };
  return { ok: "Mot de passe mis à jour." };
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/connexion");
}
