import type { Metadata } from "next";
import { requireFleetManager } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { addAircraft } from "./actions";
import { AircraftCard } from "./AircraftCard";
import { AddAircraftForm } from "./AddAircraftForm";

export const metadata: Metadata = { title: "Flotte – Maintenance" };
export const dynamic = "force-dynamic";

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  await requireFleetManager();
  const sp = await searchParams;
  const supabase = await createClient();

  const { data: aircraftRaw } = await supabase
    .from("aircraft")
    .select("id, registration, model, seats, type, active, available, unavailable_reason")
    .order("registration");

  const aircraft = aircraftRaw ?? [];
  const activeFleet = aircraft.filter((a) => a.active !== false);
  const inactiveFleet = aircraft.filter((a) => a.active === false);

  const addAircraftAction = addAircraft;

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />

      <div className="mb-6">
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">🔧 Flotte – Maintenance</h1>
        <p className="mt-1 text-sm text-muted">
          Gérez la disponibilité des avions. Les avions indisponibles n'apparaissent pas dans les réservations.
        </p>
      </div>

      {/* Avions actifs */}
      <section className="mb-10">
        <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Avions en flotte</h2>
        {activeFleet.length === 0 ? (
          <div className="card p-6 text-center text-muted">Aucun avion enregistré.</div>
        ) : (
          <div className="card overflow-hidden">
            <ul className="divide-y divide-line">
              {activeFleet.map((a) => (
                <AircraftCard
                  key={a.id}
                  aircraft={a as {
                    id: string;
                    registration: string;
                    model: string;
                    seats: number;
                    type: string | null;
                    active: boolean;
                    available: boolean;
                    unavailable_reason: string | null;
                  }}
                />
              ))}
            </ul>
          </div>
        )}
      </section>

      {/* Avions inactifs */}
      {inactiveFleet.length > 0 && (
        <section className="mb-10">
          <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2 text-muted">
            Avions retirés de la flotte
          </h2>
          <div className="card overflow-hidden">
            <ul className="divide-y divide-line">
              {inactiveFleet.map((a) => (
                <AircraftCard
                  key={a.id}
                  aircraft={a as {
                    id: string;
                    registration: string;
                    model: string;
                    seats: number;
                    type: string | null;
                    active: boolean;
                    available: boolean;
                    unavailable_reason: string | null;
                  }}
                />
              ))}
            </ul>
          </div>
        </section>
      )}

      {/* Ajouter un avion */}
      <section>
        <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Ajouter un avion</h2>
        <AddAircraftForm action={addAircraftAction} />
      </section>
    </>
  );
}
