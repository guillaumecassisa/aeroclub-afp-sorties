// Prévisions TAF via aviationweather.gov (NOAA), mises en cache 30 minutes.
// LFMA n'émet pas de TAF : on affiche ceux des terrains voisins qui en publient.
export type Taf = { station: string; raw: string; issued: string | null };

const STATIONS = (process.env.TAF_STATIONS || "LFMA,LFML,LFMY").split(",").map((s) => s.trim().toUpperCase());

export async function getTafs(): Promise<Taf[] | null> {
  try {
    const res = await fetch(`https://aviationweather.gov/api/data/taf?ids=${STATIONS.join(",")}&format=json`, {
      next: { revalidate: 1800 },
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return null;
    const list = (await res.json()) as { icaoId: string; rawTAF?: string; issueTime?: string }[];
    return STATIONS.map((id) => list.find((t) => t.icaoId === id))
      .filter((t): t is { icaoId: string; rawTAF?: string; issueTime?: string } => !!t?.rawTAF)
      .map((t) => ({ station: t.icaoId, raw: t.rawTAF!, issued: t.issueTime ?? null }));
  } catch {
    return null;
  }
}
