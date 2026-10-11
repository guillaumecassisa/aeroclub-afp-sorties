import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { requireMember, canOrganize, isStaff } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { isoToParisLocal } from "@/lib/dates";
import { OutingForm } from "@/components/OutingForm";
import type { Aircraft } from "@/lib/types";

export const metadata: Metadata = { title: "Modifier la sortie" };

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const me = await requireMember();
  const supabase = await createClient();

  const { data: outing } = await supabase
    .from("outings")
    .select("*, instructor:instructor_id(id)")
    .eq("id", id)
    .single();

  if (!outing) notFound();
  const canEdit = isStaff(me) || outing.instructor?.id === me.id;
  if (!canEdit || !canOrganize(me)) redirect(`/sorties/${id}`);

  const { data: aircraftRaw } = await supabase
    .from("outing_aircraft")
    .select("aircraft_id, position")
    .eq("outing_id", id)
    .order("position");

  const { data: fleet } = await supabase.from("aircraft").select("*").eq("active", true).order("registration");

  return (
    <>
      <h1 className="mb-6 text-2xl font-bold tracking-tight text-navy-2">Modifier l&apos;événement</h1>
      <OutingForm
        fleet={(fleet ?? []) as Aircraft[]}
        initial={{
          id,
          kind: outing.kind ?? "vol",
          title: outing.title,
          destination: outing.destination ?? "",
          meeting_point: outing.meeting_point ?? "",
          description: outing.description ?? "",
          departure_at: isoToParisLocal(outing.departure_at),
          return_at: isoToParisLocal(outing.return_at),
          registration_deadline: isoToParisLocal(outing.registration_deadline),
          aircraft: (aircraftRaw ?? []).map((r) => r.aircraft_id),
          instructor_aircraft: outing.instructor_aircraft_id,
          max_participants: outing.max_participants,
        }}
        submitLabel="Enregistrer"
      />
    </>
  );
}
