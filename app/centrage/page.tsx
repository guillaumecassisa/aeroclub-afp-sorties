import { redirect } from "next/navigation";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

/** Raccourci : ouvre la masse et centrage du premier avion renseigné. */
export default async function Page() {
  await requireMember();
  const supabase = await createClient();
  const [{ data: fleet }, { data: mb }] = await Promise.all([
    supabase.from("aircraft").select("id").eq("active", true).order("type").order("registration"),
    supabase.from("aircraft_mb").select("aircraft_id, envelope"),
  ]);
  const ready = new Set((mb ?? []).filter((m) => Array.isArray(m.envelope) && m.envelope.length >= 3).map((m) => m.aircraft_id));
  const first = (fleet ?? []).find((a) => ready.has(a.id)) ?? (fleet ?? [])[0];
  redirect(first ? `/flotte/${first.id}/centrage` : "/flotte");
}
