import { NextResponse, type NextRequest } from "next/server";
import { getCurrentProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { currentMonthKey, isMonthKey } from "@/lib/money";
import type { BarMonthSummary } from "@/lib/types";
import { loadBarData } from "@/lib/bar";
import { buildBarWorkbook } from "@/lib/barExport";
import { period } from "@/lib/shopExport";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// ?format=xlsx : classeur Excel complet sur une période ; sinon CSV d'un mois (séparateur « ; », BOM pour Excel)
export async function GET(request: NextRequest) {
  if (request.nextUrl.searchParams.get("format") === "xlsx") {
    const me = await getCurrentProfile();
    if (!me || me.role === "pending" || !me.is_treasurer) return new NextResponse("Réservé au trésorier.", { status: 403 });
    const supabase = await createClient();
    const data = await loadBarData(supabase);
    if (data.error) return new NextResponse(data.error, { status: 500 });
    const p = period(request.nextUrl.searchParams, "Depuis l'ouverture du bar");
    const buf = await buildBarWorkbook(data, p, currentMonthKey());
    return new NextResponse(new Uint8Array(buf), {
      headers: {
        "content-type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "content-disposition": `attachment; filename="bar-${p.slug}.xlsx"`,
        "cache-control": "no-store",
      },
    });
  }

  const param = request.nextUrl.searchParams.get("mois") ?? undefined;
  const month = isMonthKey(param) ? param : currentMonthKey();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("bar_month_summary", { p_month: `${month}-01` });
  if (error || !data) return new NextResponse(error?.message ?? "Erreur", { status: 403 });

  const s = data as BarMonthSummary;
  const productNames = s.products.map((p) => p.name);
  // Une cellule qui commence par = + - @ serait exécutée comme une formule par Excel : on la neutralise
  const esc = (raw: string) => {
    const v = /^[=+\-@\t\r]/.test(raw) && !/^-?\d/.test(raw) ? `'${raw}` : raw;
    return /[;"\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
  };
  const money = (c: number) => (c / 100).toFixed(2).replace(".", ",");

  const lines = [
    ["Membre", "Email", ...productNames, "Total (€)", "Réglé"].map(esc).join(";"),
    ...s.members.map((m) =>
      [
        m.full_name || "",
        m.email,
        ...productNames.map((n) => String(m.items[n] ?? 0)),
        money(m.total_cents),
        m.paid ? "oui" : "non",
      ]
        .map(esc)
        .join(";"),
    ),
    ["TOTAL", "", ...s.products.map((p) => String(p.quantity)), money(s.total_cents), ""].map(esc).join(";"),
  ];

  return new NextResponse("﻿" + lines.join("\r\n"), {
    headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": `attachment; filename="bar-${month}.csv"`,
    },
  });
}
