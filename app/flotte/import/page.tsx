import Link from "next/link";
import { redirect } from "next/navigation";
import type { Metadata } from "next";
import { canManageDocs, requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { BulkImport } from "./BulkImport";

export const metadata: Metadata = { title: "Importer des documents" };

export default async function Page() {
  const me = await requireMember();
  if (!canManageDocs(me)) redirect("/flotte");
  const supabase = await createClient();
  const [{ data: fleet }, { data: docs }] = await Promise.all([
    supabase.from("aircraft").select("id, registration").order("registration"),
    supabase.from("aircraft_documents").select("aircraft_id, title").is("archived_at", null),
  ]);

  return (
    <>
      <Link href="/flotte" className="mb-3 inline-block text-sm text-sky hover:underline">
        ← Toute la flotte
      </Link>
      <h1 className="text-2xl font-bold tracking-tight text-navy-2">Importer des documents</h1>
      <p className="mb-5 text-sm text-muted">
        Déposez des archives .zip (par exemple l&apos;export « Documentation F-HSAA » d&apos;Inside) ou des fichiers dont le nom
        contient l&apos;immatriculation. Chaque fichier est rangé sur la fiche de son avion, dans la catégorie devinée d&apos;après son
        nom : vous pouvez la corriger avant l&apos;envoi. Un document déjà présent (même titre sur le même avion) est ignoré.
      </p>
      <BulkImport
        fleet={(fleet ?? []) as { id: string; registration: string }[]}
        existing={((docs ?? []) as { aircraft_id: string; title: string }[]).map((d) => `${d.aircraft_id}|${d.title.toLowerCase()}`)}
      />
    </>
  );
}
