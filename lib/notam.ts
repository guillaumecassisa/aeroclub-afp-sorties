// NOTAM en vigueur, via la recherche publique de la FAA (couvre les terrains internationaux).
// Mis en cache 30 minutes. En cas d'échec, la page affiche des liens vers SOFIA.
export type Notam = { id: string; location: string; text: string; from: string | null; to: string | null };

const LOCATIONS = (process.env.NOTAM_LOCATIONS || "LFMA,LFML").split(",").map((s) => s.trim().toUpperCase());

export async function getNotams(): Promise<Record<string, Notam[]> | null> {
  try {
    const body = new URLSearchParams({
      searchType: "0",
      designatorsForLocation: LOCATIONS.join(","),
      notamsOnly: "false",
      offset: "0",
    });
    const res = await fetch("https://notams.aim.faa.gov/notamSearch/search", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
      next: { revalidate: 1800 },
      signal: AbortSignal.timeout(7000),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as {
      notamList?: {
        notamNumber?: string;
        facilityDesignator?: string;
        icaoId?: string;
        icaoMessage?: string;
        traditionalMessageFrom4thWord?: string;
        traditionalMessage?: string;
        startDate?: string;
        endDate?: string;
      }[];
    };
    if (!Array.isArray(data.notamList)) return null;
    const out: Record<string, Notam[]> = Object.fromEntries(LOCATIONS.map((l) => [l, []]));
    for (const n of data.notamList) {
      const loc = (n.icaoId || n.facilityDesignator || "").toUpperCase();
      if (!out[loc]) continue;
      const text = (n.icaoMessage || n.traditionalMessageFrom4thWord || n.traditionalMessage || "").trim();
      if (!text) continue;
      out[loc].push({
        id: n.notamNumber || text.slice(0, 12),
        location: loc,
        text,
        from: n.startDate ?? null,
        to: n.endDate ?? null,
      });
    }
    return out;
  } catch {
    return null;
  }
}

export const NOTAM_LOCATIONS = LOCATIONS;
