"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { DOC_BUCKET, DOC_CATEGORIES } from "@/lib/docs";
import { canManageDocs, canManageFleet, requireMember } from "@/lib/auth";
import { wingTankChange } from "@/lib/mbTanks";
import type { MbData } from "@/lib/mb";

async function docManager() {
  return canManageDocs(await requireMember());
}

type NewDoc = {
  aircraftId: string;
  category: string;
  title: string;
  path: string;
  fileName: string;
  mime: string | null;
  size: number | null;
};

/** Enregistre un document déjà envoyé dans le stockage par le navigateur. */
export async function registerDocument(doc: NewDoc): Promise<{ error?: string }> {
  if (!(await docManager())) return { error: "Réservé aux instructeurs et aux fonctions du club." };
  const category = DOC_CATEGORIES.some((c) => c.key === doc.category) ? doc.category : "autre";
  const title = (doc.title || doc.fileName).trim().slice(0, 200);
  if (!doc.path.startsWith(`${doc.aircraftId}/`)) return { error: "Chemin de fichier invalide." };
  const supabase = await createClient();
  const { error } = await supabase.from("aircraft_documents").insert({
    aircraft_id: doc.aircraftId,
    category,
    title,
    file_path: doc.path,
    file_name: doc.fileName.slice(0, 200),
    mime_type: doc.mime,
    size_bytes: doc.size,
  });
  if (error) {
    await supabase.storage.from(DOC_BUCKET).remove([doc.path]);
    return { error: error.message };
  }
  revalidatePath(`/flotte/${doc.aircraftId}`);
  revalidatePath("/flotte");
  return {};
}

export async function updateDocument(id: string, aircraftId: string, formData: FormData): Promise<void> {
  if (!(await docManager())) return;
  const title = String(formData.get("title") ?? "").trim().slice(0, 200);
  const category = String(formData.get("category") ?? "");
  if (!title || !DOC_CATEGORIES.some((c) => c.key === category)) return;
  const supabase = await createClient();
  const { error } = await supabase.from("aircraft_documents").update({ title, category }).eq("id", id);
  if (error) { console.error("[updateDocument]", error.message); return; }
  revalidatePath(`/flotte/${aircraftId}`);
}

export async function deleteDocument(id: string, aircraftId: string): Promise<void> {
  if (!(await docManager())) return;
  // Pas d'effacement : le document est archivé (récupérable, fichier conservé, action journalisée)
  const supabase = await createClient();
  const { error } = await supabase.rpc("archive_document", { p_id: id, p_archive: true });
  if (error) { console.error("[deleteDocument]", error.message); return; }
  revalidatePath(`/flotte/${aircraftId}`);
  revalidatePath("/flotte");
}

export async function restoreDocument(id: string, aircraftId: string): Promise<void> {
  if (!(await docManager())) return;
  const supabase = await createClient();
  const { error } = await supabase.rpc("archive_document", { p_id: id, p_archive: false });
  if (error) { console.error("[restoreDocument]", error.message); return; }
  revalidatePath(`/flotte/${aircraftId}`);
  revalidatePath("/flotte");
}

/** Masse et centrage : réservoirs d'aile gauche et droite sur les avions concernés (mise à jour n°48) */
export async function convertWingTanks(): Promise<{ ok?: string; error?: string }> {
  if (!canManageFleet(await requireMember())) return { error: "Réservé aux administrateurs et responsables maintenance." };
  const supabase = await createClient();
  const { data, error } = await supabase.from("aircraft_mb").select("aircraft_id, stations, fuel_capacity_l, fuel_arm, aircraft:aircraft_id (registration, type)");
  if (error) return { error: "Lecture impossible : " + error.message };
  const done: string[] = [];
  for (const row of data ?? []) {
    const ac = row.aircraft as unknown as { registration: string; type: string } | null;
    const change = ac ? wingTankChange(ac.type, row as unknown as MbData) : null;
    if (!change) continue;
    const { error: e } = await supabase
      .from("aircraft_mb")
      .update({ ...change, updated_at: new Date().toISOString() })
      .eq("aircraft_id", row.aircraft_id);
    if (e) return { error: `${ac!.registration} : ${e.message}` };
    done.push(ac!.registration);
  }
  revalidatePath("/flotte");
  revalidatePath("/centrage");
  return { ok: done.length ? `Réservoirs gauche / droite en place sur ${done.join(", ")}.` : "Rien à mettre à jour : c'était déjà fait." };
}
