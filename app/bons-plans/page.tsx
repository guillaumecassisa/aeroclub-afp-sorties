import type { Metadata } from "next";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import type { Tip } from "@/lib/aerodromes";
import { TipsExplorer } from "./TipsExplorer";

export const metadata: Metadata = { title: "Bons plans aérodromes" };

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const me = await requireMember();
  const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase
    .from("airfield_tips")
    .select("id, icao, airfield_name, lat, lon, category, title, description, on_field, contact, created_by, created_at")
    .is("archived_at", null)
    .order("created_at", { ascending: false });
  const tips = ((data ?? []) as Tip[]).map((t) => ({ ...t, lat: Number(t.lat), lon: Number(t.lon) }));

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />
      <h1 className="text-2xl font-bold tracking-tight text-navy-2">Bons plans aérodromes</h1>
      <p className="mb-4 text-sm text-muted">
        Restaurants, avitaillement, hébergement, visites… partagés par les membres du club. Cliquez sur un terrain pour voir ses
        bons plans.
      </p>
      <TipsExplorer tips={tips} meId={me.id} admin={me.role === "admin"} initialIcao={sp.ad ?? null} />
    </>
  );
}
