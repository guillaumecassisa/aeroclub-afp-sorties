// Météo via les METAR publics d'aviationweather.gov (NOAA), mis en cache 10 minutes.
// LFMA (Aix-les-Milles) ne publie pas de METAR : on prend la première station disponible.
const STATIONS = (process.env.QNH_STATIONS || "LFMA,LFML").split(",").map((s) => s.trim().toUpperCase());

const NAMES: Record<string, string> = {
  LFMA: "Aix-les-Milles",
  LFML: "Marseille-Provence",
  LFMV: "Avignon",
  LFMY: "Salon",
  LFMQ: "Le Castellet",
};

export type Sky = "clear" | "few" | "cloudy" | "overcast" | "rain" | "storm" | "fog" | "snow";

export const SKY_LABELS: Record<Sky, string> = {
  clear: "Ciel dégagé",
  few: "Peu nuageux",
  cloudy: "Nuageux",
  overcast: "Couvert",
  rain: "Pluie",
  storm: "Orages",
  fog: "Brouillard / brume",
  snow: "Neige",
};

export type Metar = {
  station: string;
  stationName: string;
  qnh: number;
  observedAt: string;
  raw: string;
  sky: Sky;
  temp: number | null;
  dewp: number | null;
  windDir: number | "VRB" | null;
  windSpeed: number | null;
  windGust: number | null;
  visibility: string | null;
  ceiling: number | null;
};

type Raw = {
  icaoId: string;
  altim?: number;
  reportTime: string;
  rawOb: string;
  temp?: number;
  dewp?: number;
  wdir?: number | string;
  wspd?: number;
  wgst?: number;
  visib?: number | string;
  wxString?: string;
  clouds?: { cover: string; base?: number }[];
};

function skyOf(m: Raw): Sky {
  const wx = (m.wxString || "").toUpperCase();
  const raw = m.rawOb.toUpperCase();
  if (/TS/.test(wx)) return "storm";
  if (/SN|SG|PL|GS/.test(wx)) return "snow";
  if (/RA|DZ|SH/.test(wx)) return "rain";
  if (/FG|BR|HZ/.test(wx)) return "fog";
  const covers = (m.clouds ?? []).map((c) => c.cover);
  if (covers.includes("OVC") || covers.includes("OVX")) return "overcast";
  if (covers.includes("BKN")) return "cloudy";
  if (covers.includes("SCT") || covers.includes("FEW")) return "few";
  if (/\bCAVOK\b|\bNSC\b|\bSKC\b|\bCLR\b/.test(raw)) return "clear";
  return "clear";
}

export async function getMetar(): Promise<Metar | null> {
  try {
    const res = await fetch(`https://aviationweather.gov/api/data/metar?ids=${STATIONS.join(",")}&format=json`, {
      next: { revalidate: 600 },
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) return null;
    const list = (await res.json()) as Raw[];
    for (const id of STATIONS) {
      const m = list.find((x) => x.icaoId === id && typeof x.altim === "number");
      if (!m) continue;
      const ceiling =
        (m.clouds ?? [])
          .filter((c) => ["BKN", "OVC", "OVX"].includes(c.cover) && typeof c.base === "number")
          .map((c) => c.base!)
          .sort((a, b) => a - b)[0] ?? null;
      const visib = m.visib;
      return {
        station: id,
        stationName: NAMES[id] ?? id,
        qnh: Math.round(m.altim!),
        observedAt: m.reportTime,
        raw: m.rawOb,
        sky: skyOf(m),
        temp: typeof m.temp === "number" ? m.temp : null,
        dewp: typeof m.dewp === "number" ? m.dewp : null,
        windDir: m.wdir === "VRB" ? "VRB" : typeof m.wdir === "number" ? m.wdir : null,
        windSpeed: typeof m.wspd === "number" ? m.wspd : null,
        windGust: typeof m.wgst === "number" ? m.wgst : null,
        // aviationweather renvoie la visibilité en milles terrestres (« 6+ » = 10 km ou plus)
        visibility:
          visib == null
            ? null
            : String(visib).includes("+") || Number(visib) >= 6
              ? "≥ 10 km"
              : `${Math.round(Number(visib) * 1.609 * 10) / 10} km`,
        ceiling,
      };
    }
    return null;
  } catch {
    return null;
  }
}

/** Compatibilité */
export const getQnh = getMetar;
