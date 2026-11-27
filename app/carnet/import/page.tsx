import type { Metadata } from "next";
import Link from "next/link";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { dupKey } from "@/lib/carnetImport";
import { ImportClient } from "./ImportClient";

export const metadata: Metadata = { title: "Importer mes vols" };

export default async function Page() {
  await requireMember();
  const supabase = await createClient();
  const [{ data }, { data: fleet }] = await Promise.all([
    supabase.from("logbook_entries").select("flight_date, aircraft_reg, dep_time, total_min"),
    supabase.from("aircraft").select("registration, model"),
  ]);
  const models = Object.fromEntries((fleet ?? []).map((a) => [String(a.registration).toUpperCase(), String(a.model ?? "")]));
  const existing = (data ?? []).map((e) => dupKey(e as Parameters<typeof dupKey>[0]));

  return (
    <>
      <div className="mb-4">
        <Link href="/carnet" className="text-sm text-muted hover:text-navy-2">
          ← Mon carnet de vol
        </Link>
        <h1 className="mt-1 text-2xl font-bold tracking-tight text-navy-2">📥 Importer mes vols</h1>
        <p className="text-sm text-muted">
          Ajoutez d&apos;un coup tous vos vols exportés d&apos;Aerogest (ou d&apos;un tableur) au format CSV. Vous vérifiez les colonnes et
          l&apos;aperçu avant l&apos;import ; les vols déjà présents dans votre carnet sont ignorés.
        </p>
      </div>
      <ImportClient existing={existing} models={models} />
    </>
  );
}
