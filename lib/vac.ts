/**
 * Cartes VAC officielles (AIP France, SIA) : le PDF de chaque aérodrome est publié à chaque cycle
 * AIRAC (tous les 28 jours) sous une adresse qui contient la date d'entrée en vigueur du cycle.
 * Le lien est recalculé automatiquement : il pointe toujours vers la carte en vigueur.
 */
const MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
// Un cycle AIRAC connu (11 juin 2026) : les suivants tombent tous les 28 jours
const REF = Date.UTC(2026, 5, 11);
const DAY = 86_400_000;

/** Date d'entrée en vigueur du cycle AIRAC en cours (heure de Paris). */
export function currentAiracDate(now = new Date()): Date {
  const p = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Paris", year: "numeric", month: "2-digit", day: "2-digit" })
    .format(now)
    .split("-")
    .map(Number);
  const today = Date.UTC(p[0], p[1] - 1, p[2]);
  const cycles = Math.floor((today - REF) / (28 * DAY));
  return new Date(REF + cycles * 28 * DAY);
}

/** « 01_OCT_2026 » : nom du dossier du cycle sur le site du SIA. */
export function airacFolder(d = currentAiracDate()) {
  return `${String(d.getUTCDate()).padStart(2, "0")}_${MONTHS[d.getUTCMonth()]}_${d.getUTCFullYear()}`;
}

/** Adresse du PDF officiel (texte + cartes) de la VAC d'un aérodrome pour le cycle en cours. */
export function vacUrl(icao: string, d = currentAiracDate()) {
  return `https://www.sia.aviation-civile.gouv.fr/media/dvd/eAIP_${airacFolder(d)}/Atlas-VAC/PDF_AIPparSSection/VAC/AD/AD-2.${icao.toUpperCase()}.pdf`;
}

/** Prochain cycle (pour informer de la date de mise à jour des cartes). */
export function nextAiracDate(now = new Date()) {
  return new Date(currentAiracDate(now).getTime() + 28 * DAY);
}
