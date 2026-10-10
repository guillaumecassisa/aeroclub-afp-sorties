// Toutes les dates sont affichées et saisies à l'heure de Paris,
// quel que soit le fuseau du serveur (Vercel tourne en UTC).
export const TZ = "Europe/Paris";

function parts(date: Date) {
  const f = new Intl.DateTimeFormat("en-GB", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const o: Record<string, string> = {};
  for (const p of f.formatToParts(date)) o[p.type] = p.value;
  return o;
}

/** "2026-10-04T09:00" (heure de Paris) -> ISO UTC. Retourne null si vide/invalide. */
export function parisLocalToISO(local: string | null | undefined): string | null {
  if (!local) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(local.trim());
  if (!m) return null;
  const [, y, mo, d, h, mi] = m.map(Number);
  const target = Date.UTC(y, mo - 1, d, h, mi);
  let guess = target;
  for (let i = 0; i < 3; i++) {
    const p = parts(new Date(guess));
    const shown = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute);
    const diff = target - shown;
    if (diff === 0) break;
    guess += diff;
  }
  return new Date(guess).toISOString();
}

/** ISO -> "2026-10-04T09:00" (heure de Paris) pour un <input type="datetime-local"> */
export function isoToParisLocal(iso: string | null | undefined): string {
  if (!iso) return "";
  const p = parts(new Date(iso));
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
}

export function formatDate(iso: string) {
  return new Intl.DateTimeFormat("fr-FR", {
    timeZone: TZ,
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  }).format(new Date(iso));
}

export function formatTime(iso: string) {
  return new Intl.DateTimeFormat("fr-FR", { timeZone: TZ, hour: "2-digit", minute: "2-digit" }).format(
    new Date(iso),
  );
}

export function formatDateTime(iso: string) {
  return `${formatDate(iso)} à ${formatTime(iso)}`;
}

export function formatShort(iso: string) {
  return new Intl.DateTimeFormat("fr-FR", {
    timeZone: TZ,
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(iso));
}

/** Jour et mois pour la pastille calendrier */
export function dayBadge(iso: string) {
  const d = new Date(iso);
  return {
    day: new Intl.DateTimeFormat("fr-FR", { timeZone: TZ, day: "numeric" }).format(d),
    month: new Intl.DateTimeFormat("fr-FR", { timeZone: TZ, month: "short" }).format(d).replace(".", ""),
    weekday: new Intl.DateTimeFormat("fr-FR", { timeZone: TZ, weekday: "short" }).format(d).replace(".", ""),
  };
}
