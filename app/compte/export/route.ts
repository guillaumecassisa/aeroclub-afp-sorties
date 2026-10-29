import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Droit d'accès et de portabilité (RGPD art. 15 et 20) : toutes mes données, au format JSON
export async function GET() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.redirect(new URL("/connexion", process.env.NEXT_PUBLIC_SITE_URL || "http://localhost:3000"));

  const [profile, weight, releases, registrations, consumptions, settlements, proposals, logbook, logbookSettings] = await Promise.all([
    supabase
      .from("profiles")
      .select(
        "full_name, email, phone, address, emergency_name, emergency_phone, avatar_url, role, is_instructor, is_treasurer, is_secretary, is_maintenance, notify_events, show_phone, deletion_requested_at, created_at",
      )
      .eq("id", user.id)
      .maybeSingle(),
    supabase.from("pilot_weights").select("weight_kg, updated_at").eq("user_id", user.id).maybeSingle(),
    supabase.from("pilot_types").select("aircraft_type").eq("user_id", user.id),
    supabase
      .from("registrations")
      .select("status, created_at, outings(title, departure_at, destination)")
      .eq("user_id", user.id)
      .order("created_at"),
    supabase
      .from("bar_consumptions")
      .select("product_name, unit_price_cents, quantity, created_at")
      .eq("user_id", user.id)
      .order("created_at"),
    supabase.from("bar_settlements").select("month, paid_at").eq("user_id", user.id),
    supabase.from("outings").select("title, departure_at, approval, status, created_at").eq("instructor_id", user.id),
    supabase.from("logbook_entries").select("*").eq("user_id", user.id).order("flight_date"),
    supabase.from("logbook_settings").select("licence_type, licence_number, licence_issued, night_rating, sep_expiry, updated_at").eq("user_id", user.id).maybeSingle(),
  ]);

  const body = {
    export: {
      date: new Date().toISOString(),
      site: process.env.NEXT_PUBLIC_SITE_URL || "",
      note: "Données personnelles vous concernant enregistrées sur le site du club (RGPD, art. 15 et 20).",
    },
    compte: {
      email_de_connexion: user.email,
      cree_le: user.created_at,
      derniere_connexion: user.last_sign_in_at,
      consentement_confidentialite: user.user_metadata?.privacy_accepted_at ?? null,
    },
    profil: profile.data,
    poids: weight.data,
    lachers: (releases.data ?? []).map((r) => r.aircraft_type),
    inscriptions: registrations.data ?? [],
    evenements_organises_ou_proposes: proposals.data ?? [],
    bar: { consommations: consumptions.data ?? [], mois_regles: settlements.data ?? [] },
    carnet_de_vol: { lignes: logbook.data ?? [], reglages: logbookSettings.data, note: "Durées en minutes." },
  };

  return new NextResponse(JSON.stringify(body, null, 2), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "content-disposition": `attachment; filename="mes-donnees-aeroclub-${new Date().toISOString().slice(0, 10)}.json"`,
      "cache-control": "no-store",
    },
  });
}
