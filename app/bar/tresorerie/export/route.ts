import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { currentMonthKey, isMonthKey } from "@/lib/money";
import type { BarMonthSummary } from "@/lib/types";

// Export CSV (séparateur « ; » et BOM pour une ouverture directe dans Excel)
export async function GET(request: NextRequest) {
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
