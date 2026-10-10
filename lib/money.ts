const fmt = new Intl.NumberFormat("fr-FR", { style: "currency", currency: "EUR" });

/** 250 -> "2,50 €" */
export function euros(cents: number) {
  return fmt.format((cents ?? 0) / 100);
}

/** "2,5" / "2.50" / "2" -> 250 ; null si invalide */
export function parseEuros(v: string): number | null {
  const n = Number(v.replace(",", ".").replace(/[€\s]/g, ""));
  if (!Number.isFinite(n) || n < 0 || n > 1000) return null;
  return Math.round(n * 100);
}

/** Mois courant (heure de Paris) au format "2026-09" */
export function currentMonthKey(d = new Date()) {
  const p = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris", year: "numeric", month: "2-digit" }).formatToParts(d);
  return `${p.find((x) => x.type === "year")!.value}-${p.find((x) => x.type === "month")!.value}`;
}

export function monthLabel(key: string) {
  const [y, m] = key.split("-").map(Number);
  const s = new Intl.DateTimeFormat("fr-FR", { month: "long", year: "numeric", timeZone: "UTC" }).format(
    new Date(Date.UTC(y, m - 1, 1)),
  );
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export function shiftMonth(key: string, delta: number) {
  const [y, m] = key.split("-").map(Number);
  const d = new Date(Date.UTC(y, m - 1 + delta, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

export function isMonthKey(v: string | undefined): v is string {
  return !!v && /^\d{4}-(0[1-9]|1[0-2])$/.test(v);
}
