import { SKY_LABELS, type Metar } from "@/lib/metar";
import { WeatherIcon } from "@/components/WeatherIcon";

/** Carte « Météo du jour » (METAR décodé). */
export function WeatherCard({ metar, compact }: { metar: Metar | null; compact?: boolean }) {
  if (!metar) return <p className="mt-2 text-sm text-muted">Météo indisponible pour le moment (service météo injoignable).</p>;
  const age = Math.round((Date.now() - new Date(metar.observedAt).getTime()) / 60000);
  return (
    <>
      <div className="mt-2 flex items-center gap-3">
        <WeatherIcon sky={metar.sky} className="h-14 w-14 shrink-0" />
        <div>
          <p className="font-semibold text-ink">{SKY_LABELS[metar.sky]}</p>
          {metar.temp !== null && <p className="text-3xl font-bold tracking-tight text-navy-2">{Math.round(metar.temp)}°C</p>}
        </div>
      </div>
      <dl className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1.5 text-sm">
        <dt className="text-muted">QNH</dt>
        <dd className="font-bold text-navy-2">{metar.qnh} hPa</dd>
        {metar.windSpeed !== null && (
          <>
            <dt className="text-muted">Vent</dt>
            <dd className="font-semibold text-ink">
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
            <dt className="text-muted">Visibilité</dt>
            <dd className="font-semibold text-ink">{metar.visibility}</dd>
          </>
        )}
        {metar.ceiling !== null && (
          <>
            <dt className="text-muted">Plafond</dt>
            <dd className="font-semibold text-ink">{metar.ceiling} ft</dd>
          </>
        )}
      </dl>
      <p className="mt-3 text-xs text-muted">
        {metar.stationName} ({metar.station}) · observé à {new Date(metar.observedAt).toISOString().slice(11, 16)}Z
        {age >= 0 && ` · il y a ${age} min`}
      </p>
      {!compact && (
        <p className="mt-2 rounded-md bg-paper px-2.5 py-2 font-mono text-[11px] leading-relaxed text-ink">{metar.raw}</p>
      )}
    </>
  );
}
