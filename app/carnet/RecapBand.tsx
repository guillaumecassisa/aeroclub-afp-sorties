import { hm, type Check, type Recap } from "@/lib/carnet";

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

export function RecapBand({ r, licenceForm }: { r: Recap; licenceForm: React.ReactNode }) {
  const p = r.passengers;
  const n = r.night;
  const lapl = r.licence.licence_type === "LAPL";
  return (
    <section className="mb-5 overflow-hidden rounded-2xl border border-line bg-white shadow-sm">
      {/* Totaux et activité récente */}
      <div className="grid grid-cols-2 gap-x-6 gap-y-2 bg-navy-2 px-5 py-3 sm:grid-cols-3 lg:grid-cols-6">
        <Stat label="Heures totales" value={hm(r.totals.total)} sub={`dont CDB ${hm(r.totals.pic)}`} />
        <Stat label="Atterrissages" value={String(r.totals.landings)} sub={r.totals.nightLandings ? `dont ${r.totals.nightLandings} de nuit` : `${r.totals.flights} vol${r.totals.flights > 1 ? "s" : ""}`} />
        <Stat label="90 derniers jours" value={hm(r.last90.total)} sub={`${r.last90.landings} att.`} />
        <Stat label="12 derniers mois" value={hm(r.last12m.total)} sub={`${r.last12m.flights} vol${r.last12m.flights > 1 ? "s" : ""}`} />
        <Stat label="Double commande" value={hm(r.totals.dual)} sub={r.totals.instructor ? `instructeur ${hm(r.totals.instructor)}` : undefined} />
        <Stat label="Dernier vol" value={r.lastFlight ? frDate(r.lastFlight) : "—"} sub={r.totals.night ? `nuit ${hm(r.totals.night)}` : undefined} />
      </div>

      {/* Ma licence */}
      <div className="border-b border-line bg-paper px-4 py-2">{licenceForm}</div>

      <div className="grid gap-3 p-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_minmax(0,2fr)]">
        {/* Emport de passagers de jour */}
        <Card ok={p.ok} bad={!p.ok}>
          <Title label="Emport de passagers · FCL.060" status={p.ok ? "✓ Autorisé de jour" : "✕ Non autorisé"} tone={p.ok ? "ok" : "bad"} />
          <p className="text-sm text-ink">
            {p.landings} décollage{p.landings > 1 ? "s" : ""} et atterrissage{p.landings > 1 ? "s" : ""} en 90 jours (3 requis)
          </p>
          <p className="text-xs text-muted">{p.ok ? `Valable jusqu'au ${frDate(p.validUntil)} sans nouveau vol.` : "3 décollages et atterrissages requis (seul ou avec instructeur) avant d'emmener un passager."}</p>
          {lapl && (
            <p className="mt-1 text-xs text-ink">
              LAPL : 10 h CDB depuis la délivrance (FCL.105.A) :{" "}
              {r.lapl.picSinceIssue == null ? (
                <span className="text-muted">indiquez la date de délivrance</span>
              ) : r.lapl.picSinceIssue >= 600 ? (
                <b className="text-ok">✓ {hm(r.lapl.picSinceIssue)}</b>
              ) : (
                <b className="text-danger">✕ {hm(r.lapl.picSinceIssue)} / 10:00</b>
              )}
            </p>
          )}
        </Card>

        {/* Vol de nuit */}
        <Card ok={n.rating && n.passengersOk} bad={false}>
          <Title
            label="Vol de nuit · FCL.810"
            status={n.rating ? "✓ Qualification de nuit" : "Pas de qualification de nuit"}
            tone={n.rating ? "ok" : "muted"}
          />
          {n.rating ? (
            <>
              <p className="text-sm text-ink">
                Passagers de nuit :{" "}
                {n.passengersOk ? (
                  <b className="text-ok">✓ jusqu&apos;au {frDate(n.validUntil)}</b>
                ) : (
                  <b className="text-danger">✕ non autorisé</b>
                )}
              </p>
              <p className="text-xs text-muted">
                1 décollage et atterrissage de nuit en 90 jours (sans IR) · {n.landings90} en 90 j. La qualification n&apos;a pas
                d&apos;échéance{lapl ? " ; ses privilèges suivent ceux du LAPL" : " ; elle s'exerce avec une SEP en état de validité"}.
              </p>
            </>
          ) : (
            <p className="text-xs text-muted">Cochez « Qualification vol de nuit » ci-dessus si vous l&apos;avez obtenue.</p>
          )}
          <p className="mt-1 text-xs text-ink">
            Expérience de nuit : <b>{hm(n.total)}</b> · {n.landingsTotal} atterrissage{n.landingsTotal > 1 ? "s" : ""}
          </p>
        </Card>

        {/* Maintien des privilèges : prorogation SEP (PPL) ou expérience récente LAPL */}
        {lapl ? (
          <Card ok={r.lapl.ok} bad={false}>
            <Title
              label="Maintien des privilèges LAPL(A) · FCL.140.A"
              status={r.lapl.ok ? "✓ Conditions remplies" : "Conditions à compléter"}
              tone={r.lapl.ok ? "ok" : "navy"}
              extra={`24 derniers mois, du ${frDate(r.lapl.window.from)} au ${frDate(r.lapl.window.to)}${r.lapl.ok && r.lapl.validUntil ? ` · valable jusqu'au ${frDate(r.lapl.validUntil)} sans nouveau vol` : ""}`}
            />
            <Checks checks={r.lapl.checks} cols="xl:grid-cols-3" />
            <p className="mt-1 text-[10.5px] text-muted">
              12 h comme CDB, en double ou en solo supervisé, dont 12 décollages et atterrissages et 1 h d&apos;entraînement avec un
              instructeur, sur avion ou TMG ; ou un contrôle de compétence LAPL(A) avec un examinateur.
            </p>
          </Card>
        ) : (
          <Card ok={r.sep.ok} bad={false}>
            <Title
              label="Prorogation SEP par l'expérience · FCL.740.A"
              status={r.sep.ok ? "✓ Conditions remplies" : "Conditions à compléter"}
              tone={r.sep.ok ? "ok" : "navy"}
              extra={r.sep.expiry ? `du ${frDate(r.sep.window.from)} au ${frDate(r.sep.window.to)} (échéance ${frDate(r.sep.expiry)})` : "sur les 12 derniers mois : indiquez l'échéance de votre SEP"}
            />
            <Checks checks={r.sep.checks} cols="2xl:grid-cols-4" />
            <p className="mt-1 text-[10.5px] text-muted">
              Dans les 12 mois avant l&apos;échéance : 12 h dont 6 h CDB, 12 décollages et atterrissages, 1 h d&apos;entraînement avec un
              instructeur (compté sur les heures en double commande) ; sinon contrôle de compétence. À vérifier avec votre FI / examinateur.
            </p>
          </Card>
        )}
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

function Card({ ok, bad, children }: { ok: boolean; bad: boolean; children: React.ReactNode }) {
  return <div className={`rounded-xl border px-4 py-2.5 ${ok ? "border-ok/30 bg-ok-soft" : bad ? "border-danger/30 bg-danger-soft" : "border-line bg-paper"}`}>{children}</div>;
}

function Title({ label, status, tone, extra }: { label: string; status: string; tone: "ok" | "bad" | "navy" | "muted"; extra?: string }) {
  const c = { ok: "text-ok", bad: "text-danger", navy: "text-navy-2", muted: "text-muted" }[tone];
  return (
    <p className="flex flex-wrap items-baseline gap-x-2 text-[11px] font-bold tracking-wide text-muted uppercase">
      {label}
      <span className={`text-sm tracking-normal normal-case ${c}`}>{status}</span>
      {extra && <span className="text-xs font-normal tracking-normal text-muted normal-case">{extra}</span>}
    </p>
  );
}

function Checks({ checks, cols }: { checks: Check[]; cols: string }) {
  return (
    <ul className={`mt-1.5 grid gap-x-4 gap-y-1.5 sm:grid-cols-2 ${cols}`}>
      {checks.map((c) => {
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
  );
}
