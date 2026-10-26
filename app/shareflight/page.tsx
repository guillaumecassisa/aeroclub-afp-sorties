import type { Metadata } from "next";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import Link from "next/link";
import { FlightBoard, type FlightShare } from "./FlightBoard";
import { PhotoGallery, type FlightPhoto } from "./PhotoGallery";
import { PhotoUploader } from "./PhotoUploader";

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

  // Noms et photos des membres : via l'annuaire (un membre ne peut pas lire les fiches des autres)
  const { data: dir } = await supabase.rpc("member_directory");
  const people = new Map(
    ((dir ?? []) as { id: string; full_name: string; avatar_url: string | null }[]).map((m) => [m.id, m]),
  );

  const tab = sp.onglet === "photos" ? "photos" : "vols";
  const tabs = (
    <nav className="flex gap-2 border-b border-line bg-white px-4 py-2" aria-label="Shareflight">
      {[
        { key: "vols", label: "✈️ Vols partagés", href: "/shareflight" },
        { key: "photos", label: "📷 Photos de vol", href: "/shareflight?onglet=photos" },
      ].map((t) => (
        <Link
          key={t.key}
          href={t.href}
          aria-current={tab === t.key ? "page" : undefined}
          className={`pill text-sm ${tab === t.key ? "bg-navy-2 text-white" : "bg-paper text-navy-2"}`}
        >
          {t.label}
        </Link>
      ))}
    </nav>
  );

  if (tab === "photos") {
    const { data: rows } = await supabase
      .from("flight_photos")
      .select("id, user_id, url, caption, route, aircraft, taken_on, created_at")
      .order("created_at", { ascending: false })
      .limit(300);
    const photos: FlightPhoto[] = ((rows ?? []) as Omit<FlightPhoto, "author" | "author_avatar">[]).map((r) => ({
      ...r,
      author: people.get(r.user_id)?.full_name ?? "Membre",
      author_avatar: people.get(r.user_id)?.avatar_url ?? null,
    }));
    return (
      <>
        <Banner ok={sp.ok} erreur={sp.erreur} />
        <div className="-mx-4 -mt-6 mb-6">{tabs}</div>
        <div className="space-y-5">
          <PhotoUploader meId={me.id} clubAircraft={clubAircraft} />
          <PhotoGallery photos={photos} meId={me.id} admin={me.role === "admin"} />
        </div>
      </>
    );
  }

  // Charger les vols + passagers inscrits
  const { data } = await supabase
    .from("flight_shares")
    .select(
      `id, pilot_id, dep_icao, dep_name, dep_lat, dep_lon,
       arr_icao, arr_name, arr_lat, arr_lon,
       flight_date, seats, aircraft, comment, status,
       flight_share_seats ( member_id )`,
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
      flight_share_seats: { member_id: string }[];
    };
    const passengers = (row.flight_share_seats ?? []).map((s) => ({
      member_id: s.member_id,
      member_name: people.get(s.member_id)?.full_name ?? "Membre",
    }));
    return {
      id: row.id,
      pilot_id: row.pilot_id,
      pilot_name: people.get(row.pilot_id)?.full_name ?? "Pilote",
      pilot_avatar: people.get(row.pilot_id)?.avatar_url ?? null,
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
        {tabs}
        <FlightBoard flights={flights} meId={me.id} admin={me.role === "admin"} clubAircraft={clubAircraft} />
      </div>
    </>
  );
}
