// Aérodromes de France métropolitaine et Corse (code OACI, nom, latitude, longitude).
// Source : OurAirports (domaine public), extrait de septembre 2026.
import data from "./aerodromes.json";

export type Aerodrome = { icao: string; name: string; lat: number; lon: number };

export const AERODROMES: Aerodrome[] = (data as [string, string, number, number][]).map(([icao, name, lat, lon]) => ({
  icao,
  name,
  lat,
  lon,
}));

export const TIP_CATEGORIES = [
  { key: "resto", label: "Resto", icon: "🍽️" },
  { key: "avitaillement", label: "Avitaillement", icon: "⛽" },
  { key: "hebergement", label: "Hébergement", icon: "🛏️" },
  { key: "visite", label: "À voir", icon: "📸" },
  { key: "taxes", label: "Taxes", icon: "💰" },
  { key: "autre", label: "Autre", icon: "📌" },
] as const;

export type Tip = {
  id: string;
  icao: string;
  airfield_name: string;
  lat: number;
  lon: number;
  category: string;
  title: string;
  description: string | null;
  on_field: boolean;
  contact: string | null;
  created_by: string | null;
  created_at: string;
  author?: string | null;
};
