import { HOME_ICAO } from "@/lib/club";

/** Catégories des questions du quiz (la clé « lfma » désigne le terrain du club). */
export const QUIZ_CATEGORIES: Record<string, string> = {
  general: "✈️ Général",
  meteo: "☁️ Météo",
  reglementation: "📋 Réglementation",
  navigation: "🗺️ Navigation",
  mecanique: "✈️ Mécanique du vol",
  moteur: "🔧 Moteur",
  lfma: `🛬 ${HOME_ICAO}`,
  instruments: "🎛️ Instruments",
  radio: "📻 Radio",
  documents: "📄 Documents",
  aerodynamique: "🌊 Aérodynamique",
  performances: "📊 Performances",
  culture: "🌍 Culture",
  flotte: "🛩️ Flotte",
  securite: "🛡️ Sécurité",
  sol: "⛽ Au sol",
};
