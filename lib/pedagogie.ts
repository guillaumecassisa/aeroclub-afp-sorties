export const PEDA_BUCKET = "pedagogy";

export const PEDA_CATEGORIES = [
  { key: "cours", label: "Cours et supports", icon: "📘" },
  { key: "procedures", label: "Procédures et consignes", icon: "📋" },
  { key: "securite", label: "Sécurité des vols", icon: "🛡️" },
  { key: "reglementation", label: "Réglementation", icon: "⚖️" },
  { key: "examens", label: "Examens et tests", icon: "📝" },
  { key: "autre", label: "Autres", icon: "📎" },
] as const;

export const REX_PHASES = [
  { key: "sol", label: "Au sol / préparation" },
  { key: "roulage", label: "Roulage" },
  { key: "decollage", label: "Décollage" },
  { key: "montee", label: "Montée" },
  { key: "croisiere", label: "Croisière" },
  { key: "navigation", label: "Navigation" },
  { key: "approche", label: "Approche / circuit" },
  { key: "atterrissage", label: "Atterrissage" },
  { key: "radio", label: "Radio / ATC" },
  { key: "meteo", label: "Météo" },
  { key: "autre", label: "Autre" },
] as const;

export const REX_STATUS: Record<string, { label: string; cls: string }> = {
  nouveau: { label: "Nouveau", cls: "bg-wait-soft text-wait" },
  en_analyse: { label: "En analyse", cls: "bg-sky-soft text-navy-2" },
  publie: { label: "Publié", cls: "bg-ok-soft text-ok" },
  clos: { label: "Clos sans publication", cls: "bg-paper text-muted" },
};

export const phaseLabel = (k: string) => REX_PHASES.find((p) => p.key === k)?.label ?? k;
