export const DOC_BUCKET = "aircraft-docs";

export const DOC_CATEGORIES = [
  { key: "manuel", label: "Manuel de vol", hint: "Manuel de vol (MDV / AFM / POH), suppléments" },
  { key: "checklist", label: "Check-lists", hint: "Check-lists normales et d'urgence" },
  { key: "masse_centrage", label: "Masse et centrage", hint: "Fiche de pesée, feuille de centrage" },
  { key: "performances", label: "Performances", hint: "Abaques et tableaux de performances" },
  { key: "procedures", label: "Procédures et consignes club", hint: "Consignes d'utilisation, avitaillement, parking…" },
  { key: "administratif", label: "Documents de bord", hint: "CDN, CEN / ARC, assurance, licence radio, certificat acoustique" },
  { key: "maintenance", label: "Maintenance", hint: "Programme d'entretien, visites, consignes de navigabilité" },
  { key: "equipements", label: "Équipements & avionique", hint: "Manuels des équipements installés (GPS, EFIS, radio…)" },
  { key: "autre", label: "Autres", hint: "Tout le reste" },
] as const;

export type DocCategory = (typeof DOC_CATEGORIES)[number]["key"];

export const CATEGORY_LABEL: Record<string, string> = Object.fromEntries(DOC_CATEGORIES.map((c) => [c.key, c.label]));

export type AircraftDocument = {
  id: string;
  aircraft_id: string;
  category: DocCategory;
  title: string;
  file_path: string;
  file_name: string;
  mime_type: string | null;
  size_bytes: number | null;
  created_at: string;
};

export function formatSize(bytes: number | null) {
  if (!bytes) return "";
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} Ko`;
  return `${(bytes / 1024 / 1024).toFixed(1).replace(".", ",")} Mo`;
}

/** "Manuel_de_vol-F-HUIT (2).pdf" -> "Manuel de vol F-HUIT (2)" */
export function titleFromFileName(name: string) {
  return name
    .replace(/\.[a-z0-9]{2,5}$/i, "")
    .replace(/[_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Immatriculation trouvée dans un nom de fichier (« F-HSAA — Fiche de pesée.pdf » -> « F-HSAA »). */
export function registrationIn(name: string) {
  const m = name.toUpperCase().match(/\bF-?([A-Z]{4})\b/);
  return m ? `F-${m[1]}` : null;
}

/** Catégorie devinée d'après le chemin du fichier dans l'archive. */
export function guessCategory(path: string): string {
  const s = path.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
  if (/annexe|equipement|avionique|garmin|dynon|uavionix|g3x|av30|skyview/.test(s)) return "equipements";
  if (/manuel de vol|\bpoh\b|\bafm\b|\bmdv\b|flight manual/.test(s)) return "manuel";
  if (/check-?list/.test(s)) return "checklist";
  if (/pesee|centrage|weight|balance/.test(s)) return "masse_centrage";
  if (/performance/.test(s)) return "performances";
  if (/licence|calipso|immatriculation|navigabilite|assurance|acoustique|\bcdn\b|\bcen\b|\barc\b/.test(s)) return "administratif";
  if (/entretien|maintenance|visite|consigne/.test(s)) return "maintenance";
  if (/procedure|consigne club|avitaillement/.test(s)) return "procedures";
  return "autre";
}

/** « Annexes équipements/F-HUFA — F-HUFA - GUIDE RAPIDE.pdf » -> « GUIDE RAPIDE » */
export function cleanTitle(path: string, registration: string | null) {
  let t = titleFromFileName(path.split("/").pop() ?? path);
  if (registration) {
    const reg = registration.replace("-", "-?");
    for (let i = 0; i < 2; i++) t = t.replace(new RegExp(`^\\s*${reg}\\s*[—–-]\\s*`, "i"), "");
  }
  return t.replace(/\s*—\s*/g, " — ").trim() || titleFromFileName(path);
}

export function safeFileName(name: string) {
  const dot = name.lastIndexOf(".");
  const base = (dot > 0 ? name.slice(0, dot) : name)
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-zA-Z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "document";
  const ext = dot > 0 ? name.slice(dot + 1).toLowerCase().replace(/[^a-z0-9]/g, "") : "";
  return ext ? `${base}.${ext}` : base;
}
