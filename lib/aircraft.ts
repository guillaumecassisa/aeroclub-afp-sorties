import type { Aircraft } from "@/lib/types";

/** Date du jour (AAAA-MM-JJ) à l'heure de Paris. */
export function todayParis() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris" }).format(new Date());
}

/** « 07/09 » à partir de « 2026-09-07 » */
export function shortDay(d: string) {
  return `${d.slice(8, 10)}/${d.slice(5, 7)}`;
}

export type AvailabilityStatus =
  | { down: false; upcoming?: string }
  | { down: true; label: string };

/**
 * Indisponible aujourd'hui ? Une indisponibilité datée ne compte que pendant sa période :
 * avant le début l'avion reste disponible (avec une mention), après la fin il redevient disponible.
 */
export function availability(a: Aircraft, today = todayParis()): AvailabilityStatus {
  if (a.available !== false) return { down: false };
  const from = a.unavailable_from ?? null;
  const until = a.unavailable_until ?? null;
  const period = from && until ? `${shortDay(from)} → ${shortDay(until)}` : until ? `jusqu'au ${shortDay(until)}` : from ? `depuis le ${shortDay(from)}` : "";
  if (until && until < today) return { down: false };
  if (from && from > today) return { down: false, upcoming: `Indispo ${period}${a.unavailable_reason ? ` · ${a.unavailable_reason}` : ""}` };
  const label = [a.unavailable_reason || "Indisponible", period].filter(Boolean).join(" — ");
  return { down: true, label };
}
