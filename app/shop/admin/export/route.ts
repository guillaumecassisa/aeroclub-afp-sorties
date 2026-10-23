import { NextResponse, type NextRequest } from "next/server";
import { getCurrentProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { fetchAll, loadShopData, type StockMove } from "@/lib/shop";
import { buildShopWorkbook, period } from "@/lib/shopExport";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Export Excel du shop, réservé aux administrateurs
export async function GET(request: NextRequest) {
  const me = await getCurrentProfile();
  if (!me || me.role !== "admin") return new NextResponse("Accès réservé aux administrateurs.", { status: 403 });

  const supabase = await createClient();
  const p = period(request.nextUrl.searchParams);
  const data = await loadShopData(supabase);
  if (data.error) return new NextResponse(data.error, { status: 500 });
  const moves = await fetchAll<StockMove>((a, b) =>
    supabase.from("shop_stock_moves").select("*, author:created_by(full_name)").order("created_at").range(a, b),
  );
  const buf = await buildShopWorkbook(data, moves, p);
  return new NextResponse(new Uint8Array(buf), {
    headers: {
      "content-type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "content-disposition": `attachment; filename="shop-ventes-${p.slug}.xlsx"`,
      "cache-control": "no-store",
    },
  });
}
