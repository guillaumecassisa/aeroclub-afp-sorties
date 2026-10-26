import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { isoToParisLocal } from "@/lib/dates";
import { OutingForm } from "@/components/OutingForm";
import type { Aircraft, OutingDetail } from "@/lib/types";

export const metadata: Metadata = { title: "Modifier l'événement" };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  await requireMember();
  if (!UUID.test(id)) notFound();
  const supabase = await createClient();

  const { data } = await supabase.rpc("get_outing", { p_id: id });
  if (!data) notFound();
  const o = data as OutingDetail;
  if (!o.can_edit || o.status === "cancelled") redirect(`/sorties/${id}`);

  const { data: fleet } = await supabase.from("aircraft").select("*").eq("active", true).order("type").order("registration");
  const registered = (o.kind ?? "vol") === "vol" ? o.aircraft.reduce((s, a) => s + a.occupants.length, 0) : (o.participants ?? []).length;

  return (
    <>
      <h1 className="mb-6 text-2xl font-bold tracking-tight text-navy-2">Modifier l&apos;événement</h1>
      <OutingForm
        fleet={(fleet ?? []) as Aircraft[]}
        initial={{
          id,
          kind: o.kind ?? "vol",
          title: o.title,
          destination: o.destination ?? "",
          meeting_point: o.meeting_point ?? "",
          description: o.description ?? "",
          departure_at: isoToParisLocal(o.departure_at),
          return_at: isoToParisLocal(o.return_at),
          registration_deadline: isoToParisLocal(o.registration_deadline),
          aircraft: o.aircraft.map((a) => a.id),
          instructor_aircraft: o.instructor_aircraft_id,
          max_participants: o.max_participants,
          guests_allowed: !!o.guests_allowed,
          registered_count: registered,
          poster_url: o.poster_url ?? null,
        }}
        submitLabel="Enregistrer"
      />
    </>
  );
}
