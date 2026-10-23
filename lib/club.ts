/**
 * Paramètres du club : tout ce qui change d'un aéroclub à l'autre se règle ici,
 * par variables d'environnement (Vercel → Settings → Environment Variables).
 * Voir docs/NOUVEAU-CLUB.md.
 */
export const CLUB_NAME = process.env.NEXT_PUBLIC_CLUB_NAME || "Aéroclub Air France Provence";
/** Terrain du club (code OACI) et son nom usuel */
export const HOME_ICAO = (process.env.NEXT_PUBLIC_HOME_ICAO || "LFMA").toUpperCase();
export const HOME_AIRFIELD = process.env.NEXT_PUBLIC_HOME_AIRFIELD || "Aix-les-Milles";
