import Link from "next/link";
import type { Metadata } from "next";
import { canManageDocs, canManageFleet, requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import type { Aircraft } from "@/lib/types";

export const metadata: Metadata = { title: "Flotte" };

export default async function Page() {
  const me = await requireMember();
  const supabase = await createClient();
  const [{ data: fleet }, { data: docs }] = await Promise.all([
    supabase.from("aircraft").select("*").eq("active", true).order("type").order("registration"),
    supabase.from("aircraft_documents").select("aircraft_id").is("archived_at", null),
  ]);
  const counts = new Map<string, number>();
  for (const d of docs ?? []) counts.set(d.aircraft_id as string, (counts.get(d.aircraft_id as string) ?? 0) + 1);
  const aircraft = (fleet ?? []) as Aircraft[];

  return (
    <>
      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">Flotte du club</h1>
          <p className="text-sm text-muted">Choisissez un avion pour consulter sa documentation : manuel de vol, check-lists, centrage…</p>
        </div>
        <div className="flex flex-wrap gap-2">
          {canManageDocs(me) && (
            <Link href="/flotte/import" className="btn-primary">
              Importer des documents
            </Link>
          )}
          {canManageFleet(me) && (
            <Link href="/maintenance" className="btn-secondary">
              Flotte (maintenance)
            </Link>
          )}
        </div>
      </div>

      {aircraft.length === 0 ? (
        <div className="card p-8 text-center text-muted">Aucun avion enregistré.</div>
      ) : (
        <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {aircraft.map((a) => {
            const n = counts.get(a.id) ?? 0;
            const down = a.available === false;
            return (
              <li key={a.id}>
                <Link href={`/flotte/${a.id}`} className="card group block overflow-hidden transition hover:border-navy-2/40 hover:shadow-md">
                  <div className="relative overflow-hidden bg-navy-2 px-4 py-4 text-white">
                    <span aria-hidden className="pointer-events-none absolute -top-4 right-6 h-24 w-3 skew-x-[-28deg] bg-red" />
                    <p className="font-mono text-xl font-bold tracking-wider">{a.registration}</p>
                    <p className="text-sm text-white/80">{a.model}</p>
                  </div>
                  <div className="flex flex-wrap items-center gap-2 px-4 py-3">
                    <span className="pill bg-sky-soft text-navy-2">{a.type}</span>
                    <span className="pill bg-line text-ink">{a.seats} places</span>
                    <span className={`pill ${down ? "bg-danger-soft text-danger" : "bg-ok-soft text-ok"}`}>
                      {down ? "Indisponible" : "Disponible"}
                    </span>
                    <span className="ml-auto text-sm font-semibold text-sky group-hover:underline">
                      {n} document{n > 1 ? "s" : ""} →
                    </span>
                  </div>
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </>
  );
}
