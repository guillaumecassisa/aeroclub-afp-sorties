import { getMetar } from "@/lib/metar";
import { getTafs } from "@/lib/taf";
import { getNotams, NOTAM_LOCATIONS } from "@/lib/notam";
import { WeatherCard } from "@/components/WeatherCard";

const CHARTS = [
  { title: "Aeroweb (Météo-France)", text: "TEMSI, WINTEM, cartes et images satellite", url: "https://aviation.meteo.fr/" },
  { title: "SOFIA-Briefing", text: "Dossier de vol officiel : NOTAM, météo, SUP AIP", url: "https://sofia-briefing.aviation-civile.gouv.fr/sofia/pages/homepage.html" },
  { title: "SIA", text: "Cartes VAC, AIP, complément aux cartes", url: "https://www.sia.aviation-civile.gouv.fr/" },
];

/** Météo complète (METAR, TAF, cartes, NOTAM) : en tête de « Préparer son vol ». */
export async function MeteoSection() {
  const [metar, tafs, notams] = await Promise.all([getMetar(), getTafs(), getNotams()]);

  return (
    <section id="meteo" className="scroll-mt-28">
      <h2 className="text-xl font-bold tracking-tight text-navy-2">Météo LFMA</h2>
      <p className="mb-4 text-sm text-muted">
        Observation, prévisions et NOTAM autour d&apos;Aix-les-Milles. Information indicative : consultez toujours le briefing
        officiel avant le vol.
      </p>

      <div className="grid gap-4 md:grid-cols-3">
        <section className="card p-5">
          <p className="text-xs font-semibold tracking-wide text-muted uppercase">Observation (METAR)</p>
          <WeatherCard metar={metar} />
        </section>

        <section className="card p-5 md:col-span-2">
          <p className="text-xs font-semibold tracking-wide text-muted uppercase">Prévisions (TAF)</p>
          {tafs && tafs.length ? (
            <ul className="mt-3 space-y-3">
              {tafs.map((t) => (
                <li key={t.station}>
                  <p className="text-sm font-semibold text-navy-2">{t.station}</p>
                  <pre className="mt-1 rounded-md bg-paper px-3 py-2 font-mono text-[11px] leading-relaxed whitespace-pre-wrap text-ink">
                    {t.raw}
                  </pre>
                </li>
              ))}
            </ul>
          ) : (
            <p className="mt-2 text-sm text-muted">TAF indisponibles pour le moment. Voir Aeroweb ou SOFIA ci-dessous.</p>
          )}
          <p className="mt-3 text-xs text-muted">LFMA n&apos;émet pas de TAF : prévisions des terrains voisins (Marseille, Salon).</p>
        </section>
      </div>

      <section className="card mt-4 p-5">
        <p className="text-xs font-semibold tracking-wide text-muted uppercase">Cartes aéro et briefing officiel</p>
        <ul className="mt-3 grid gap-2 sm:grid-cols-3">
          {CHARTS.map((c) => (
            <li key={c.url}>
              <a
                href={c.url}
                target="_blank"
                rel="noopener noreferrer"
                className="block h-full rounded-lg border border-line px-4 py-3 hover:border-navy-2/40 hover:bg-paper"
              >
                <span className="font-semibold text-navy-2">{c.title} ↗</span>
                <span className="mt-0.5 block text-xs text-muted">{c.text}</span>
              </a>
            </li>
          ))}
        </ul>
      </section>

      <section id="notam" className="card mt-4 p-5">
        <p className="text-xs font-semibold tracking-wide text-muted uppercase">NOTAM en vigueur</p>
        {notams ? (
          <div className="mt-3 grid gap-4 md:grid-cols-2">
            {NOTAM_LOCATIONS.map((loc) => {
              const list = notams[loc] ?? [];
              return (
                <div key={loc}>
                  <p className="mb-2 font-semibold text-navy-2">
                    {loc} <span className="text-sm font-normal text-muted">({list.length})</span>
                  </p>
                  {list.length === 0 ? (
                    <p className="text-sm text-muted">Aucun NOTAM.</p>
                  ) : (
                    <ul className="max-h-96 space-y-2 overflow-y-auto pr-1">
                      {list.map((n) => (
                        <li key={n.id} className="rounded-md bg-paper px-3 py-2">
                          <details>
                            <summary className="cursor-pointer text-sm text-ink">
                              <span className="font-mono text-xs font-bold text-navy-2">{n.id}</span>{" "}
                              {n.text.replace(/\s+/g, " ").slice(0, 110)}
                              {n.text.length > 110 ? "…" : ""}
                            </summary>
                            <pre className="mt-2 font-mono text-[11px] leading-relaxed whitespace-pre-wrap text-ink">{n.text}</pre>
                          </details>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              );
            })}
          </div>
        ) : (
          <p className="mt-2 text-sm text-muted">
            NOTAM indisponibles pour le moment. Consultez le briefing officiel SOFIA pour LFMA et LFML.
          </p>
        )}
      </section>
    </section>
  );
}
