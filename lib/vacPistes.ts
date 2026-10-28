/**
 * Distances déclarées (TORA / TODA / ASDA / LDA) lues dans la VAC officielle du SIA.
 * Les VAC des terrains ouverts au VFR de nuit publient un tableau « Distances déclarées » ;
 * d'autres signalent des distances réduites (« TORA, TODA et LDA RWY 33L réduites à 1050 m »).
 * Les cartes elles-mêmes sont des images : sans ces mentions, aucune distance n'est lisible.
 */
export type DeclaredDistances = { tora?: number; toda?: number; asda?: number; lda?: number };

const RWY = String.raw`(\d{2}[LRC]?)`;

/** Analyse les lignes de texte d'une VAC (une ligne = une ligne de la page, mots dans l'ordre). */
export function parseDeclaredDistances(lines: string[]): Record<string, DeclaredDistances> {
  const out: Record<string, DeclaredDistances> = {};
  // 1. Tableau « Piste / RWY TORA TODA ASDA LDA » (l'ordre des colonnes est relu dans l'en-tête)
  lines.forEach((line, i) => {
    if (!/TORA/.test(line) || !/LDA/.test(line)) return;
    const cols = (line.match(/TORA|TODA|ASDA|LDA/g) ?? []).map((c) => c.toLowerCase() as keyof DeclaredDistances);
    for (const row of lines.slice(i + 1, i + 9)) {
      const m = row.trim().match(new RegExp(`^${RWY}((?:\\s+\\d{3,4}){${cols.length}})\\b`));
      if (!m) break;
      const nums = m[2].trim().split(/\s+/).map(Number);
      const d: DeclaredDistances = (out[m[1]] ??= {});
      cols.forEach((c, k) => (d[c] = nums[k]));
    }
  });
  // 2. Mentions de distances réduites : « TORA, TODA et LDA RWY 33L réduites à 1050 m »
  const text = lines.join(" ").replace(/\s+/g, " ");
  const re = new RegExp(String.raw`((?:TORA|TODA|ASDA|LDA)(?:\s*(?:,|et)\s*(?:TORA|TODA|ASDA|LDA))*)\s+(?:de la\s+)?RWY\s+${RWY}\s+(?:sont\s+)?réduites?\s+à\s+(\d{3,4})\s*m`, "g");
  for (const m of text.matchAll(re)) {
    const d: DeclaredDistances = (out[m[2]] ??= {});
    for (const k of m[1].match(/TORA|TODA|ASDA|LDA/g) ?? []) {
      const key = k.toLowerCase() as keyof DeclaredDistances;
      if (d[key] === undefined) d[key] = Number(m[3]);
    }
  }
  return out;
}

/** Regroupe les éléments de texte d'une page PDF en lignes (même hauteur), de gauche à droite. */
export function toLines(items: { str: string; x: number; y: number }[]): string[] {
  const lines: { y: number; items: { str: string; x: number }[] }[] = [];
  for (const it of [...items].filter((i) => i.str.trim()).sort((a, b) => b.y - a.y || a.x - b.x)) {
    const l = lines.find((l) => Math.abs(l.y - it.y) < 2.5);
    if (l) l.items.push(it);
    else lines.push({ y: it.y, items: [it] });
  }
  return lines.map((l) => l.items.sort((a, b) => a.x - b.x).map((i) => i.str.trim()).join(" "));
}
