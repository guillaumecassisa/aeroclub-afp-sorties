import { NextResponse } from "next/server";
import { getCurrentProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

/** Sauvegarde complète des données du club (JSON), réservée aux administrateurs. */
export async function GET() {
  const me = await getCurrentProfile();
  if (!me || me.role !== "admin") return new NextResponse("Réservé aux administrateurs.", { status: 403 });
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("admin_export");
  if (error) return new NextResponse(`Sauvegarde impossible : ${error.message}`, { status: 500 });
  const stamp = new Date().toISOString().slice(0, 16).replace(/[:T]/g, "-");
  return new NextResponse(JSON.stringify(data, null, 1), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "content-disposition": `attachment; filename="sauvegarde-club-${stamp}.json"`,
      "cache-control": "no-store",
    },
  });
}
