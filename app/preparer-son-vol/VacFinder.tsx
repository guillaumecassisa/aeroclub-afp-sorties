"use client";

import { useEffect, useMemo, useState } from "react";
import { AERODROMES } from "@/lib/aerodromes";
import { airacFolder, currentAiracDate, nextAiracDate, vacUrl } from "@/lib/vac";

const norm = (s: string) =>
  s
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase();
// Seuls les codes OACI « LFxx » ont une VAC dans l'AIP France (les terrains privés LF50… n'en ont pas)
const LIST = AERODROMES.filter((a) => /^LF[A-Z]{2}$/.test(a.icao));
const KEY = "vac-recents";
const fmt = (d: Date) => new Intl.DateTimeFormat("fr-FR", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }).format(d);

export function VacFinder({ favorites }: { favorites: string[] }) {
  const [q, setQ] = useState("");
  const [recents, setRecents] = useState<string[]>([]);
  useEffect(() => {
    try {
      setRecents(JSON.parse(localStorage.getItem(KEY) ?? "[]").filter((x: unknown) => typeof x === "string").slice(0, 8));
    } catch {
      /* stockage indisponible : pas d'historique */
    }
  }, []);

  const results = useMemo(() => {
    const t = norm(q.trim());
    if (t.length < 2) return [];
    return LIST.filter((a) => norm(a.icao).startsWith(t) || norm(a.name).includes(t))
      .sort((a, b) => Number(!norm(a.icao).startsWith(t)) - Number(!norm(b.icao).startsWith(t)) || a.name.localeCompare(b.name))
      .slice(0, 12);
  }, [q]);

  const remember = (icao: string) => {
    const next = [icao, ...recents.filter((r) => r !== icao)].slice(0, 8);
    setRecents(next);
    try {
      localStorage.setItem(KEY, JSON.stringify(next));
    } catch {
      /* rien */
    }
  };
  const nameOf = (icao: string) => LIST.find((a) => a.icao === icao)?.name ?? "";
  const quick = [...new Set([...favorites, ...recents])].filter((i) => LIST.some((a) => a.icao === i));
  const cycle = currentAiracDate();

  const Chip = ({ icao }: { icao: string }) => (
    <a
      href={vacUrl(icao)}
      target="_blank"
      rel="noopener noreferrer"
      onClick={() => remember(icao)}
      className="pill bg-sky-soft text-sm text-navy-2 transition hover:bg-navy-2 hover:text-white"
      title={`VAC ${icao} ${nameOf(icao)}`}
    >
      <strong>{icao}</strong> <span className="font-normal opacity-80">{nameOf(icao)}</span>
    </a>
  );

  return (
    <section className="card p-5">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-lg font-bold tracking-tight text-navy-2">🗺️ Cartes VAC</h2>
        <p className="text-xs text-muted">
          AIP France officielle (SIA) · cycle du {fmt(cycle)} · prochain le {fmt(nextAiracDate())}
        </p>
      </div>
      <p className="mt-1 text-sm text-muted">
        Cherchez un terrain par code OACI ou par nom : la carte en vigueur s&apos;ouvre en PDF (texte et cartes de
        l&apos;atterrissage à vue), toujours à jour du dernier cycle.
      </p>

      <input
        type="search"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Ex. LFKC, Calvi, Avignon…"
        aria-label="Rechercher un aérodrome"
        className="field mt-3"
        autoComplete="off"
      />

      {results.length > 0 && (
        <ul className="mt-2 divide-y divide-line overflow-hidden rounded-xl border border-line">
          {results.map((a) => (
            <li key={a.icao}>
              <a
                href={vacUrl(a.icao)}
                target="_blank"
                rel="noopener noreferrer"
                onClick={() => remember(a.icao)}
                className="flex items-center gap-3 px-3 py-2.5 transition hover:bg-sky-soft"
              >
                <span className="w-14 font-mono font-bold text-navy-2">{a.icao}</span>
                <span className="min-w-0 flex-1 truncate text-sm text-ink">{a.name}</span>
                <span className="text-xs font-semibold text-sky">VAC (PDF) ↗</span>
              </a>
            </li>
          ))}
        </ul>
      )}
      {q.trim().length >= 2 && results.length === 0 && (
        <p className="mt-2 text-sm text-muted">Aucun aérodrome trouvé.</p>
      )}

      {quick.length > 0 && (
        <div className="mt-4">
          <p className="mb-2 text-xs font-semibold tracking-wide text-muted uppercase">Accès rapide</p>
          <div className="flex flex-wrap gap-2">
            {quick.map((i) => (
              <Chip key={i} icao={i} />
            ))}
          </div>
        </div>
      )}

      <p className="mt-4 text-xs text-muted">
        Source : <a href={`https://www.sia.aviation-civile.gouv.fr/media/dvd/eAIP_${airacFolder(cycle)}/Atlas-VAC/FR/VACProduitPartie.htm`} target="_blank" rel="noopener noreferrer" className="underline">atlas VAC du SIA</a>.
        Les terrains privés ou ULM sans carte dans l&apos;AIP ne s&apos;ouvrent pas. Vérifiez toujours les NOTAM et SUP AIP
        avant le vol.
      </p>
    </section>
  );
}
