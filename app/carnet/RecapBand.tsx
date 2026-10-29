import { hm, type Recap } from "@/lib/carnet";

const frDate = (d: string | null) =>
  d ? new Date(d + "T12:00:00Z").toLocaleDateString("fr-FR", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }) : "—";

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="min-w-0">
      <p className="text-[10px] font-semibold tracking-wide text-white/70 uppercase">{label}</p>
      <p className="leading-tight text-white">
        <span className="text-xl font-bold">{value}</span>
        {sub && <span className="ml-2 text-xs text-white/70">{sub}</span>}
      </p>
    </div>
  );
}

export function RecapBand({ r, sepForm }: { r: Recap; sepForm: React.ReactNode }) {
  const p = r.passengers;
  return (
    <section className="relative left-1/2 mb-5 w-[calc(100vw-2rem)] max-w-[1900px] -translate-x-1/2 overflow-hidden rounded-2xl border border-line bg-white shadow-sm">
      {/* Totaux et activité récente */}
      <div className="grid grid-cols-2 gap-x-6 gap-y-2 bg-navy-2 px-5 py-3 sm:grid-cols-3 lg:grid-cols-6">
        <Stat label="Heures totales" value={hm(r.totals.total)} sub={`dont CDB ${hm(r.totals.pic)}`} />
        <Stat label="Atterrissages" value={String(r.totals.landings)} sub={r.totals.nightLandings ? `dont ${r.totals.nightLandings} de nuit` : `${r.totals.flights} vol${r.totals.flights > 1 ? "s" : ""}`} />
        <Stat label="90 derniers jours" value={hm(r.last90.total)} sub={`${r.last90.landings} att.`} />
        <Stat label="12 derniers mois" value={hm(r.last12m.total)} sub={`${r.last12m.flights} vol${r.last12m.flights > 1 ? "s" : ""}`} />
        <Stat label="Double commande" value={hm(r.totals.dual)} sub={r.totals.instructor ? `instructeur ${hm(r.totals.instructor)}` : undefined} />
        <Stat label="Dernier vol" value={r.lastFlight ? frDate(r.lastFlight) : "—"} sub={r.totals.night ? `nuit ${hm(r.totals.night)}` : undefined} />
      </div>

      <div className="grid gap-3 p-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,2.4fr)]">
        {/* Emport de passagers */}
        <div className={`rounded-xl border px-4 py-2.5 ${p.ok ? "border-ok/30 bg-ok-soft" : "border-danger/30 bg-danger-soft"}`}>
          <p className="flex flex-wrap items-baseline gap-x-2 text-[11px] font-bold tracking-wide text-muted uppercase">
            Emport de passagers · FCL.060
            <span className={`text-sm tracking-normal normal-case ${p.ok ? "text-ok" : "text-danger"}`}>{p.ok ? "✓ Autorisé de jour" : "✕ Non autorisé"}</span>
          </p>
          <p className="text-sm text-ink">
            {p.landings} décollage{p.landings > 1 ? "s" : ""} et atterrissage{p.landings > 1 ? "s" : ""} en 90 jours (3 requis)
            {p.ok ? ` · valable jusqu'au ${frDate(p.validUntil)}` : ""}
          </p>
          <p className="text-xs text-muted">
            Nuit : {p.nightOk ? `✓ jusqu'au ${frDate(p.nightValidUntil)}` : "✕ 1 décollage et atterrissage de nuit en 90 jours requis (sans IR)"}
          </p>
        </div>

        {/* Prorogation SEP */}
        <div className={`rounded-xl border px-4 py-2.5 ${r.sep.ok ? "border-ok/30 bg-ok-soft" : "border-line bg-paper"}`}>
          <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
            <p className="flex flex-wrap items-baseline gap-x-2 text-[11px] font-bold tracking-wide text-muted uppercase">
              Prorogation SEP par l&apos;expérience · FCL.740.A
              <span className={`text-sm tracking-normal normal-case ${r.sep.ok ? "text-ok" : "text-navy-2"}`}>
                {r.sep.ok ? "✓ Conditions remplies" : "Conditions à compléter"}
              </span>
              <span className="text-xs font-normal tracking-normal text-muted normal-case">
                {r.sep.expiry ? `du ${frDate(r.sep.window.from)} au ${frDate(r.sep.window.to)}` : "sur les 12 derniers mois"}
              </span>
            </p>
            {sepForm}
          </div>
          <ul className="mt-1.5 grid gap-x-4 gap-y-1.5 sm:grid-cols-2 xl:grid-cols-4">
            {r.sep.checks.map((c) => {
              const pct = Math.min(100, (c.done / c.need) * 100);
              const ok = c.done >= c.need;
              return (
                <li key={c.label}>
                  <div className="flex justify-between gap-2 text-xs">
                    <span className="truncate text-ink">{c.label}</span>
                    <span className={`font-semibold whitespace-nowrap ${ok ? "text-ok" : "text-ink"}`}>
                      {c.unit === "h" ? `${hm(c.done)} / ${hm(c.need)}` : `${c.done} / ${c.need}`}{ok ? " ✓" : ""}
                    </span>
                  </div>
                  <div className="mt-0.5 h-1.5 overflow-hidden rounded-full bg-line">
                    <div className={`h-full rounded-full ${ok ? "bg-ok" : "bg-navy-2"}`} style={{ width: `${pct}%` }} />
                  </div>
                </li>
              );
            })}
          </ul>
          <p className="mt-1 text-[10.5px] text-muted">
            Entraînement d&apos;1 h avec instructeur compté sur les heures en double commande ; le contrôle de compétence reste
            l&apos;alternative. À vérifier avec votre FI / examinateur.
          </p>
        </div>
      </div>

      {/* Par type d'appareil */}
      {r.byType.length > 0 && (
        <div className="border-t border-line px-5 py-2.5">
          <p className="mb-1 text-[11px] font-bold tracking-wide text-muted uppercase">Expérience par type d&apos;appareil</p>
          <div className="overflow-x-auto">
            <table className="w-full min-w-[520px] text-sm">
              <thead>
                <tr className="text-left text-xs text-muted">
                  <th className="py-1 font-semibold">Type</th>
                  <th className="py-1 text-right font-semibold">Heures</th>
                  <th className="py-1 text-right font-semibold">dont CDB</th>
                  <th className="py-1 text-right font-semibold">Atterrissages</th>
                  <th className="py-1 text-right font-semibold">90 jours</th>
                  <th className="py-1 text-right font-semibold">Dernier vol</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {r.byType.map((t) => (
                  <tr key={t.model}>
                    <td className="py-1 font-semibold text-ink">{t.model}</td>
                    <td className="py-1 text-right tabular-nums">{hm(t.total)}</td>
                    <td className="py-1 text-right tabular-nums">{hm(t.pic)}</td>
                    <td className="py-1 text-right tabular-nums">{t.landings}</td>
                    <td className="py-1 text-right tabular-nums">{t.last90 ? hm(t.last90) : "—"}</td>
                    <td className="py-1 text-right">{frDate(t.last)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </section>
  );
}
