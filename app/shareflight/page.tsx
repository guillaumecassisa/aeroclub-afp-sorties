import type { Metadata } from "next";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { FlightBoard, type FlightShare } from "./FlightBoard";

export const metadata: Metadata = { title: "Shareflight — vols partagés" };

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const me = await requireMember();
  const sp = await searchParams;
  const supabase = await createClient();

  // Avions du club actifs (non archivés)
  const { data: aircraftRows } = await supabase
    .from("aircraft")
    .select("registration, model")
    .eq("active", true)
    .order("registration");
  const clubAircraft = (aircraftRows ?? []) as { registration: string; model: string }[];

  // Charger les vols + passagers inscrits + noms via join profiles
  const { data } = await supabase
    .from("flight_shares")
    .select(
      `id, pilot_id, dep_icao, dep_name, dep_lat, dep_lon,
       arr_icao, arr_name, arr_lat, arr_lon,
       flight_date, seats, aircraft, comment, status,
       profiles!pilot_id ( full_name, avatar_url ),
       flight_share_seats (
         member_id,
         profiles!member_id ( full_name )
       )`,
    )
    .order("flight_date", { ascending: true })
    .order("created_at", { ascending: false });

  const flights: FlightShare[] = ((data ?? []) as unknown[]).map((r: unknown) => {
    const row = r as {
      id: string;
      pilot_id: string;
      dep_icao: string; dep_name: string; dep_lat: string; dep_lon: string;
      arr_icao: string; arr_name: string; arr_lat: string; arr_lon: string;
      flight_date: string;
      seats: number;
      aircraft: string | null;
      comment: string | null;
      status: "open" | "closed" | "cancelled";
      profiles: { full_name: string | null; avatar_url: string | null } | null;
      flight_share_seats: { member_id: string; profiles: { full_name: string | null } | null }[];
    };
    const passengers = (row.flight_share_seats ?? []).map((s) => ({
      member_id: s.member_id,
      member_name: s.profiles?.full_name ?? "Membre",
    }));
    return {
      id: row.id,
      pilot_id: row.pilot_id,
      pilot_name: row.profiles?.full_name ?? "Pilote",
      pilot_avatar: row.profiles?.avatar_url ?? null,
      dep_icao: row.dep_icao,
      dep_name: row.dep_name,
      dep_lat: Number(row.dep_lat),
      dep_lon: Number(row.dep_lon),
      arr_icao: row.arr_icao,
      arr_name: row.arr_name,
      arr_lat: Number(row.arr_lat),
      arr_lon: Number(row.arr_lon),
      flight_date: row.flight_date,
      seats: row.seats,
      aircraft: row.aircraft,
      comment: row.comment,
      status: row.status,
      seats_taken: passengers.length,
      passengers,
    };
  });

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />
      {/* FlightBoard prend toute la hauteur dispo — on annule le padding du layout */}
      <div className="-mx-4 -my-6 -mb-10">
        <FlightBoard flights={flights} meId={me.id} admin={me.role === "admin"} clubAircraft={clubAircraft} />
      </div>
    </>
  );
}
