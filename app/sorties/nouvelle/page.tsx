import type { Metadata } from "next";
import Link from "next/link";
import { requireMember, canOrganize } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { OutingForm } from "@/components/OutingForm";
import type { Aircraft } from "@/lib/types";

export const metadata: Metadata = { title: "Nouvel événement" };

export default async function Page() {
  const me = await requireMember();
  const organizer = canOrganize(me);

  const supabase = await createClient();
  const { data } = await supabase.from("aircraft").select("*").eq("active", true).order("type").order("registration");
  const fleet = (data ?? []) as Aircraft[];

  return (
    <>
      <Link href="/sorties" className="mb-1 inline-flex items-center gap-1 text-sm text-muted hover:text-navy-2">
        ← Événements
      </Link>
      <h1 className="mb-2 text-2xl font-bold tracking-tight text-navy-2">
        {organizer ? "Créer un événement" : "Proposer un événement"}
      </h1>
      {!organizer && (
        <p className="mb-6 text-sm text-muted">
          Votre proposition sera publiée après validation par un instructeur ou un administrateur.
        </p>
      )}
      <OutingForm
        fleet={fleet}
        initial={{
          title: "",
          destination: "",
          meeting_point: "",
          description: "",
          departure_at: "",
          return_at: "",
          registration_deadline: "",
          aircraft: [],
          instructor_aircraft: null,
        }}
        submitLabel={organizer ? "Créer" : "Envoyer la proposition"}
      />
    </>
  );
}
