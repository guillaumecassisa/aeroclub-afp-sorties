"use server";

import { after } from "next/server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireMember, requireTeacher } from "@/lib/auth";
import { PEDA_BUCKET, PEDA_CATEGORIES, REX_PHASES, REX_STATUS } from "@/lib/pedagogie";
import { notifyRexSubmitted } from "@/lib/email";

function back(tab: string, key: "ok" | "erreur", msg: string): never {
  revalidatePath("/pedagogie");
  redirect(`/pedagogie?onglet=${tab}&${key}=${encodeURIComponent(msg)}`);
}

const text = (fd: FormData, k: string, max: number) => String(fd.get(k) ?? "").trim().slice(0, max);

// ── Annonces ────────────────────────────────────────────────────────────────

export async function createPost(formData: FormData) {
  await requireTeacher();
  const title = text(formData, "title", 200);
  const body = text(formData, "body", 5000);
  if (!title || !body) back("annonces", "erreur", "Titre et texte obligatoires.");
  const supabase = await createClient();
  const { error } = await supabase
    .from("pedagogy_posts")
    .insert({ title, body, important: formData.get("important") === "on" });
  if (error) back("annonces", "erreur", error.message);
  back("annonces", "ok", "Annonce publiée.");
}

export async function archivePost(id: string) {
  await requireTeacher();
  const supabase = await createClient();
  const { error } = await supabase.from("pedagogy_posts").update({ archived_at: new Date().toISOString() }).eq("id", id);
  if (error) back("annonces", "erreur", error.message);
  back("annonces", "ok", "Annonce retirée.");
}

// ── Documents ───────────────────────────────────────────────────────────────

type NewDoc = { category: string; title: string; path: string; fileName: string; mime: string | null; size: number | null };

/** Enregistre un document déjà envoyé dans le stockage par le navigateur. */
export async function registerPedaDocument(doc: NewDoc): Promise<{ error?: string }> {
  await requireTeacher();
  const category = PEDA_CATEGORIES.some((c) => c.key === doc.category) ? doc.category : "autre";
  const title = (doc.title || doc.fileName).trim().slice(0, 200);
  if (!/^[a-z]+\/[A-Za-z0-9._-]+$/.test(doc.path)) return { error: "Chemin de fichier invalide." };
  const supabase = await createClient();
  const { error } = await supabase.from("pedagogy_documents").insert({
    category,
    title,
    file_path: doc.path,
    file_name: doc.fileName.slice(0, 200),
    mime_type: doc.mime,
    size_bytes: doc.size,
  });
  if (error) {
    await supabase.storage.from(PEDA_BUCKET).remove([doc.path]);
    return { error: error.message };
  }
  revalidatePath("/pedagogie");
  return {};
}

export async function archivePedaDocument(id: string) {
  await requireTeacher();
  const supabase = await createClient();
  const { error } = await supabase
    .from("pedagogy_documents")
    .update({ archived_at: new Date().toISOString() })
    .eq("id", id);
  if (error) back("documents", "erreur", error.message);
  back("documents", "ok", "Document retiré (conservé dans les archives).");
}

export async function restorePedaDocument(id: string) {
  await requireTeacher();
  const supabase = await createClient();
  const { error } = await supabase.from("pedagogy_documents").update({ archived_at: null }).eq("id", id);
  if (error) back("documents", "erreur", error.message);
  back("documents", "ok", "Document remis en ligne.");
}

// ── Retours d'expérience ────────────────────────────────────────────────────

export async function submitRex(formData: FormData) {
  const me = await requireMember();
  const anonymous = formData.get("anonymous") === "on";
  const phase = String(formData.get("phase") ?? "autre");
  const title = text(formData, "title", 200);
  const description = text(formData, "description", 5000);
  const occurred = String(formData.get("occurred_on") ?? "").trim();
  if (!title || !description) back("rex", "erreur", "Indiquez un titre et décrivez ce qui s'est passé.");
  if (occurred && !/^\d{4}-\d{2}-\d{2}$/.test(occurred)) back("rex", "erreur", "Date invalide.");

  const supabase = await createClient();
  const { error } = await supabase.from("rex_reports").insert({
    anonymous,
    author_id: anonymous ? null : me.id,
    phase: REX_PHASES.some((p) => p.key === phase) ? phase : "autre",
    title,
    description,
    occurred_on: occurred || null,
  });
  if (error) back("rex", "erreur", error.message);

  const { data: reviewers } = await supabase.rpc("rex_reviewers");
  const list = (reviewers ?? []) as { email: string; full_name: string }[];
  after(() => notifyRexSubmitted(list, title, anonymous ? null : me.full_name));
  back(
    "rex",
    "ok",
    anonymous
      ? "Merci ! Votre REX anonyme est transmis au chef pilote et au responsable conformité."
      : "Merci ! Votre REX est transmis au chef pilote et au responsable conformité ; vous suivez son statut ci-dessous.",
  );
}

export async function reviewRex(id: string, formData: FormData) {
  await requireTeacher();
  const status = String(formData.get("status") ?? "");
  if (!REX_STATUS[status]) back("rex", "erreur", "Statut inconnu.");
  const public_summary = text(formData, "public_summary", 5000) || null;
  const lessons = text(formData, "lessons", 5000) || null;
  const supabase = await createClient();
  const { error } = await supabase.from("rex_reports").update({ status, public_summary, lessons }).eq("id", id);
  if (error) back("rex", "erreur", error.message);
  back("rex", "ok", status === "publie" ? "REX publié pour tous les membres." : "REX mis à jour.");
}
