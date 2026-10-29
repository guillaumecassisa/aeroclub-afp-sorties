import type { Metadata } from "next";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { DEFAULT_LICENCE, ENTRY_COLUMNS, computeRecap, type LicenceSettings, type LogEntry } from "@/lib/carnet";
import { RecapBand } from "./RecapBand";
import { CarnetClient } from "./CarnetClient";
import { LicenceForm } from "./LicenceForm";

export const metadata: Metadata = { title: "Mon carnet de vol" };

export default async function Page() {
  const me = await requireMember();
  const supabase = await createClient();
  const [{ data: rows }, { data: settings }, { data: fleet }] = await Promise.all([
    supabase.from("logbook_entries").select(ENTRY_COLUMNS).order("flight_date", { ascending: false }).order("dep_time", { ascending: false, nullsFirst: false }),
    supabase.from("logbook_settings").select("licence_type, licence_number, licence_issued, night_rating, sep_expiry").maybeSingle(),
    supabase.from("aircraft").select("registration, model").eq("active", true).order("registration"),
  ]);
  const entries = (rows ?? []) as LogEntry[];
  const today = new Date().toLocaleDateString("fr-CA", { timeZone: "Europe/Paris" });
  const licence: LicenceSettings = { ...DEFAULT_LICENCE, ...((settings ?? {}) as Partial<LicenceSettings>) };
  const r = computeRecap(entries, licence, today);

  return (
    <>
      <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">📒 Mon carnet de vol</h1>
          <p className="text-sm text-muted">
            Vos vols et votre expérience récente pour garder les privilèges de votre licence. Carnet personnel : vous seul y avez accès.
          </p>
        </div>
        {entries.length > 0 && (
          <a href="/carnet/export" className="btn-secondary">
            Exporter (Excel)
          </a>
        )}
      </div>

      <RecapBand r={r} licenceForm={<LicenceForm licence={licence} />} />

      <CarnetClient
        entries={entries}
        fleet={(fleet ?? []) as { registration: string; model: string }[]}
        myName={me.full_name || ""}
        today={today}
      />
    </>
  );
}
