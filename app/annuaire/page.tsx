import type { Metadata } from "next";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { DirectoryList, type DirectoryEntry } from "./DirectoryList";

export const metadata: Metadata = { title: "Annuaire" };

export default async function Page() {
  const me = await requireMember();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("member_directory");
  const members = (data ?? []) as DirectoryEntry[];

  return (
    <>
      <Banner erreur={error?.message} />
      <h1 className="text-2xl font-bold tracking-tight text-navy-2">Annuaire des membres</h1>
      <p className="mb-5 text-sm text-muted">
        {members.length} membre{members.length > 1 ? "s" : ""}. Touchez un numéro pour appeler. Pour modifier vos informations,
        passez par « Mon compte ».
      </p>
      <DirectoryList members={members} meId={me.id} />
    </>
  );
}
