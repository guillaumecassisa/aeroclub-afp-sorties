import { SKY_LABELS, type Metar } from "@/lib/metar";
import { WeatherIcon } from "@/components/WeatherIcon";

/** Carte « Météo du jour » (METAR décodé).
 *  `compact` + `dark` : rendu sur fond sombre (bg-navy-2), texte blanc.
 */
export function WeatherCard({
  metar,
  compact,
  dark,
}: {
  metar: Metar | null;
  compact?: boolean;
  dark?: boolean;
}) {
  const label = dark ? "text-white/60" : "text-muted";
  const value = dark ? "text-white font-bold" : "font-bold text-navy-2";
  const sub   = dark ? "text-white/50" : "text-muted";
  const title = dark ? "text-white font-semibold" : "font-semibold text-ink";
  const temp  = dark ? "text-white text-3xl font-bold tracking-tight" : "text-3xl font-bold tracking-tight text-navy-2";

  if (!metar)
    return (
      <p className={`mt-2 text-sm ${sub}`}>
        Météo indisponible pour le moment (service météo injoignable).
      </p>
    );

  const age = Math.round((Date.now() - new Date(metar.observedAt).getTime()) / 60000);

  return (
    <>
      <div className="mt-2 flex items-center gap-3">
        <WeatherIcon sky={metar.sky} className="h-14 w-14 shrink-0" />
        <div>
          <p className={title}>{SKY_LABELS[metar.sky]}</p>
          {metar.temp !== null && (
            <p className={temp}>{Math.round(metar.temp)}°C</p>
          )}
        </div>
      </div>
      <dl className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1.5 text-sm">
        <dt className={label}>QNH</dt>
        <dd className={value}>{metar.qnh} hPa</dd>
        {metar.windSpeed !== null && (
          <>
            <dt className={label}>Vent</dt>
            <dd className={dark ? "text-white font-semibold" : "font-semibold text-ink"}>
              {metar.windSpeed === 0
                ? "Calme"
                : `${metar.windDir === "VRB" ? "Variable" : `${String(metar.windDir).padStart(3, "0")}°`} / ${metar.windSpeed} kt${
                    metar.windGust ? ` (raf. ${metar.windGust})` : ""
                  }`}
            </dd>
          </>
        )}
        {metar.visibility && (
          <>
            <dt className={label}>Visibilité</dt>
            <dd className={dark ? "text-white font-semibold" : "font-semibold text-ink"}>
              {metar.visibility}
            </dd>
          </>
        )}
        {metar.ceiling !== null && (
          <>
            <dt className={label}>Plafond</dt>
            <dd className={dark ? "text-white font-semibold" : "font-semibold text-ink"}>
              {metar.ceiling} ft
            </dd>
          </>
        )}
      </dl>
      <p className={`mt-3 text-xs ${sub}`}>
        {metar.stationName} ({metar.station}) · observé à{" "}
        {new Date(metar.observedAt).toISOString().slice(11, 16)}Z
        {age >= 0 && ` · il y a ${age} min`}
      </p>
      {!compact && (
        <p className="mt-2 rounded-md bg-paper px-2.5 py-2 font-mono text-[11px] leading-relaxed text-ink">
          {metar.raw}
        </p>
      )}
    </>
  );
}
