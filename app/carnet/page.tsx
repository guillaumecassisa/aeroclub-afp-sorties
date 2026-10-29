import type { Metadata } from "next";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { ENTRY_COLUMNS, computeRecap, type LogEntry } from "@/lib/carnet";
import { RecapBand } from "./RecapBand";
import { CarnetClient } from "./CarnetClient";
import { SepExpiryForm } from "./SepExpiryForm";

export const metadata: Metadata = { title: "Mon carnet de vol" };

export default async function Page() {
  const me = await requireMember();
  const supabase = await createClient();
  const [{ data: rows }, { data: settings }, { data: fleet }] = await Promise.all([
    supabase.from("logbook_entries").select(ENTRY_COLUMNS).order("flight_date", { ascending: false }).order("dep_time", { ascending: false, nullsFirst: false }),
    supabase.from("logbook_settings").select("sep_expiry").maybeSingle(),
    supabase.from("aircraft").select("registration, model").eq("active", true).order("registration"),
  ]);
  const entries = (rows ?? []) as LogEntry[];
  const today = new Date().toLocaleDateString("fr-CA", { timeZone: "Europe/Paris" });
  const r = computeRecap(entries, settings?.sep_expiry ?? null, today);

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

      <RecapBand r={r} sepForm={<SepExpiryForm value={settings?.sep_expiry ?? ""} />} />

      <CarnetClient
        entries={entries}
        fleet={(fleet ?? []) as { registration: string; model: string }[]}
        myName={me.full_name || ""}
        today={today}
      />
    </>
  );
}
