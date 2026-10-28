import { NextResponse, type NextRequest } from "next/server";
import { getDocumentProxy } from "unpdf";
import { getCurrentProfile } from "@/lib/auth";
import { airacFolder, currentAiracDate, vacUrl } from "@/lib/vac";
import { parseDeclaredDistances, parseElevation, toLines } from "@/lib/vacPistes";

export const runtime = "nodejs";

// Distances déclarées et altitude d'un aérodrome, lues dans sa VAC en vigueur (mise en cache pour la durée du cycle)
export async function GET(request: NextRequest) {
  const me = await getCurrentProfile();
  if (!me || me.role === "pending") return NextResponse.json({ error: "Connexion requise." }, { status: 401 });
  const icao = (request.nextUrl.searchParams.get("icao") ?? "").toUpperCase();
  if (!/^LF[A-Z]{2}$/.test(icao)) return NextResponse.json({ error: "Code OACI invalide." }, { status: 400 });

  const cycle = currentAiracDate();
  const url = vacUrl(icao, cycle);
  try {
    const res = await fetch(url, { next: { revalidate: 6 * 3600 }, signal: AbortSignal.timeout(15000) });
    if (!res.ok) return NextResponse.json({ icao, cycle: airacFolder(cycle), url, found: false, runways: {} });
    const pdf = await getDocumentProxy(new Uint8Array(await res.arrayBuffer()));
    const lines: string[] = [];
    for (let p = 1; p <= pdf.numPages; p++) {
      const page = await pdf.getPage(p);
      const tc = await page.getTextContent();
      lines.push(
        ...toLines(
          (tc.items as { str?: string; transform?: number[] }[])
            .filter((i) => typeof i.str === "string" && i.transform)
            .map((i) => ({ str: i.str as string, x: i.transform![4], y: i.transform![5] })),
        ),
      );
    }
    const runways = parseDeclaredDistances(lines);
    const elevation = parseElevation(lines);
    return NextResponse.json(
      { icao, cycle: airacFolder(cycle), url, found: true, runways, elevation },
      { headers: { "cache-control": "private, max-age=3600" } },
    );
  } catch {
    return NextResponse.json({ icao, cycle: airacFolder(cycle), url, found: false, error: "VAC illisible", runways: {} });
  }
}
