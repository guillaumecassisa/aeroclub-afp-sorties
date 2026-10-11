import type { Metadata } from "next";
import { requireMember, canOrganize } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import { OutingForm } from "@/components/OutingForm";
import type { Aircraft } from "@/lib/types";

export const metadata: Metadata = { title: "Nouvelle sortie" };

export default async function Page() {
  const me = await requireMember();
  if (!canOrganize(me)) redirect("/?erreur=" + encodeURIComponent("Réservé aux instructeurs et fonctions du club."));

  const supabase = await createClient();
  const { data } = await supabase.from("aircraft").select("*").eq("active", true).order("registration");
  const fleet = (data ?? []) as Aircraft[];

  return (
    <>
      <h1 className="mb-6 text-2xl font-bold tracking-tight text-navy-2">Créer un événement</h1>
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
        submitLabel="Créer"
      />
    </>
  );
}
