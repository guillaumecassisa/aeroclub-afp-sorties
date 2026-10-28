"use client";

import { useEffect, useMemo, useState } from "react";
import { compute, type MbData } from "@/lib/mb";
import { downloadDossierVol, loadDossierPart, saveDossierPart, type MbSnapshot } from "@/lib/dossierVol";

const fmt = (n: number, d = 1, max = d) => n.toLocaleString("fr-FR", { minimumFractionDigits: d, maximumFractionDigits: max });

export function Calculator({ data, title, model }: { data: MbData; title: string; model: string }) {
  const [loads, setLoads] = useState<string[]>(data.stations.map(() => ""));
  const [fuel, setFuel] = useState("");
  const [trip, setTrip] = useState("");
  const num = (v: string) => Math.max(0, Number(v.replace(",", ".")) || 0);

  const r = useMemo(
    () => compute(data, loads.map(num), num(fuel), num(trip)),
    [data, loads, fuel, trip],
  );
  const hasTrip = num(trip) > 0;
  const [busy, setBusy] = useState(false);

  // Dernier calcul gardé dans le navigateur : repris dans le dossier de vol PDF (avec les performances)
  const snapshot = useMemo<MbSnapshot>(
    () => ({
      model,
      stations: data.stations.map((s, i) => {
        const load = num(loads[i]);
        return { label: s.label, arm: s.arm, load, unit: s.fuel ? "L" : "kg", kg: s.fuel ? load * data.fuel_density : load };
      }),
      fuel: {
        mainL: data.fuel_capacity_l != null && data.fuel_capacity_l > 0 ? num(fuel) : null,
        tripL: num(trip),
        density: data.fuel_density,
        arm: Number(data.fuel_arm),
      },
      to: r.to,
      ldg: r.ldg,
      zf: r.zf,
      hasTrip,
      empty: { mass: Number(data.empty_mass), moment: Number(data.empty_moment) },
      mtow: data.mtow ?? null,
      mlw: data.mlw ?? null,
      mzfw: data.mzfw ?? null,
      envelope: data.envelope,
      ok: r.ok,
      problems: r.problems,
      source: data.source ?? null,
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [data, loads, fuel, trip, r, model],
  );
  useEffect(() => {
    if (loads.some((l) => num(l) > 0) || num(fuel) > 0) saveDossierPart(title, "mb", snapshot);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [snapshot, title]);

  async function download() {
    setBusy(true);
    try {
      await downloadDossierVol({ registration: title, model, mb: snapshot, perf: loadDossierPart(title, "perf") });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]">
      <div className="space-y-4">
        <section className="card p-5">
          <Heading>Chargement</Heading>
          <ul className="divide-y divide-line">
            {data.stations.map((s, i) => {
              const over = s.max != null && num(loads[i]) > s.max;
              const unit = s.fuel ? "L" : "kg";
              return (
                <li key={i} className="flex items-center gap-3 py-2.5">
                  <label className="min-w-0 flex-1" htmlFor={`st-${i}`}>
                    <span className="block text-sm font-semibold text-ink">{s.label}</span>
                    <span className="block text-[11px] text-muted">
                      Bras : {fmt(s.arm, 2, 4)} m{s.max != null ? ` · max ${s.max} ${unit}` : ""}
                      {s.fuel ? ` · ${fmt(num(loads[i]) * data.fuel_density)} kg` : ""}
                      {s.wing ? " · dans l'aile" : ""}
                    </span>
                  </label>
                  <input
                    id={`st-${i}`}
                    inputMode="decimal"
                    value={loads[i]}
                    placeholder="0"
                    onChange={(e) => setLoads((l) => l.map((x, j) => (j === i ? e.target.value : x)))}
                    className={`field w-24 py-1.5 text-center ${over ? "border-danger text-danger" : ""}`}
                  />
                  <span className="w-6 text-xs text-muted">{unit}</span>
                </li>
              );
            })}
          </ul>
          <Heading className="mt-4">Carburant</Heading>
          <ul className="divide-y divide-line">
            {/* Réservoir principal : affiché seulement si une capacité est définie (avions avec réservoir central) */}
            {data.fuel_capacity_l != null && data.fuel_capacity_l > 0 && (
              <li className="flex items-center gap-3 py-2.5">
                <label className="min-w-0 flex-1" htmlFor="fuel">
                  <span className="block text-sm font-semibold text-ink">
                    {data.stations.some((s) => s.fuel) ? "Réservoir principal" : "Carburant embarqué"}
                  </span>
                  <span className="block text-[11px] text-muted">
                    {fmt(num(fuel) * data.fuel_density)} kg · capacité {data.fuel_capacity_l} L · bras {fmt(Number(data.fuel_arm), 2, 4)} m
                  </span>
                </label>
                <input id="fuel" inputMode="decimal" value={fuel} placeholder="0" onChange={(e) => setFuel(e.target.value)} className="field w-24 py-1.5 text-center" />
                <span className="w-6 text-xs text-muted">L</span>
              </li>
            )}
            <li className="flex items-center gap-3 py-2.5">
              <label className="min-w-0 flex-1" htmlFor="trip">
                <span className="block text-sm font-semibold text-ink">
                  Délestage prévu (trip fuel){data.fuel_capacity_l ? ", pris sur le réservoir principal" : ""}
                </span>
                <span className="block text-[11px] text-muted">{fmt(num(trip) * data.fuel_density)} kg</span>
              </label>
              <input id="trip" inputMode="decimal" value={trip} placeholder="0" onChange={(e) => setTrip(e.target.value)} className="field w-24 py-1.5 text-center" />
              <span className="w-6 text-xs text-muted">L</span>
            </li>
          </ul>
        </section>

        <section className="card p-5">
          <Heading>Résultats</Heading>
          <ResultRow label="Décollage" p={r.to} color={r.ok ? "text-ok" : "text-danger"} />
          <ResultRow label="Atterrissage" p={r.ldg} color="text-wait" />
          <ResultRow label="Sans carburant" p={r.zf} color="text-muted" />
          {data.mzfw ? (
            <p className="mt-1 text-xs text-muted">
              Masse sans carburant{data.stations.some((s) => s.wing) ? " ni charge en aile" : ""} : {fmt(r.zeroWing)} kg (max {data.mzfw}{" "}
              kg)
            </p>
          ) : null}
          {r.ok ? (
            <p className="mt-3 rounded-lg border border-ok/30 bg-ok-soft px-3 py-2 text-sm font-semibold text-ok">
              ✓ {hasTrip ? "Décollage et atterrissage" : "Décollage"} dans les limites
            </p>
          ) : (
            <ul className="mt-3 space-y-1 rounded-lg border border-danger/30 bg-danger-soft px-3 py-2 text-sm font-semibold text-danger">
              {r.problems.map((p) => (
                <li key={p}>✕ {p}</li>
              ))}
            </ul>
          )}
        </section>

        <div className="flex justify-end gap-2 print:hidden">
          <button
            type="button"
            className="btn-secondary"
            onClick={() => {
              setLoads(data.stations.map(() => ""));
              setFuel("");
              setTrip("");
            }}
          >
            Réinitialiser
          </button>
          <button type="button" className="btn-primary" onClick={download} disabled={busy}>
            {busy ? "Préparation…" : "📄 Dossier de vol (PDF)"}
          </button>
        </div>
      </div>

      <section className="card p-5">
        <Heading>Diagramme de centrage</Heading>
        <Chart data={data} to={r.to} ldg={hasTrip ? r.ldg : null} zf={r.zf} title={title} />
        <p className="mt-2 flex flex-wrap justify-center gap-4 text-xs text-muted">
          <span className="flex items-center gap-1.5">
            <span className="h-2.5 w-2.5 rounded-full bg-ok" /> Décollage
          </span>
          <span className="flex items-center gap-1.5">
            <span className="h-2.5 w-2.5 rounded-full bg-wait" /> Atterrissage
          </span>
          <span className="flex items-center gap-1.5">
            <span className="h-2.5 w-2.5 rounded-full bg-muted" /> Sans carburant
          </span>
          <span className="flex items-center gap-1.5">
            <span className="h-2.5 w-2.5 rounded-sm border border-dashed border-navy-2 bg-line" /> Domaine de centrage
          </span>
        </p>
      </section>
    </div>
  );
}

function Heading({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return (
    <h2 className={`mb-2 flex items-center gap-2 text-xs font-bold tracking-[0.2em] text-muted uppercase ${className}`}>
      <span aria-hidden className="h-0.5 w-4 bg-red" />
      {children}
    </h2>
  );
}

function ResultRow({ label, p, color }: { label: string; p: { mass: number; moment: number; cg: number }; color: string }) {
  return (
    <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1 border-b border-line py-3 last:border-b-0">
      <span className="w-28 font-semibold text-ink">{label}</span>
      <span className={`text-2xl font-bold ${color}`}>{fmt(p.mass)} kg</span>
      <span className="text-sm text-ink">CG {fmt(p.cg, 3)} m</span>
      <span className="ml-auto text-xs text-muted">{fmt(p.moment)} kg.m</span>
    </div>
  );
}

function Chart({
  data,
  to,
  ldg,
  zf,
  title,
}: {
  data: MbData;
  to: { mass: number; cg: number };
  ldg: { mass: number; cg: number } | null;
  zf: { mass: number; cg: number };
  title: string;
}) {
  const env = data.envelope;
  const showZf = Math.abs(zf.mass - to.mass) > 0.05;
  const pts = [
    ...env,
    { arm: to.cg, mass: to.mass },
    ...(ldg ? [{ arm: ldg.cg, mass: ldg.mass }] : []),
    ...(showZf ? [{ arm: zf.cg, mass: zf.mass }] : []),
  ].filter(
    (p) => Number.isFinite(p.arm) && Number.isFinite(p.mass),
  );
  const arms = pts.map((p) => p.arm);
  const masses = [...pts.map((p) => p.mass), Number(data.mtow ?? 0)];
  const span = Math.max(...arms) - Math.min(...arms) + 0.02;
  const armStep = [0.01, 0.02, 0.05, 0.1, 0.2, 0.5].find((st) => span / st <= 9) ?? 1;
  const a0 = Math.floor((Math.min(...arms) - 0.01) / armStep) * armStep;
  const a1 = Math.ceil((Math.max(...arms) + 0.01) / armStep) * armStep;
  const m0 = Math.max(0, Math.floor((Math.min(...masses) - 60) / 50) * 50);
  const m1 = Math.ceil((Math.max(...masses) + 30) / 50) * 50;

  const W = 640, H = 420, L = 56, R = 16, T = 16, B = 44;
  const x = (a: number) => L + ((a - a0) / (a1 - a0)) * (W - L - R);
  const y = (m: number) => T + (1 - (m - m0) / (m1 - m0)) * (H - T - B);
  const xTicks: number[] = [];
  for (let a = a0; a <= a1 + 1e-9; a += armStep) xTicks.push(Number(a.toFixed(3)));
  const mStep = m1 - m0 > 500 ? 100 : 50;
  const yTicks: number[] = [];
  for (let m = m0; m <= m1; m += mStep) yTicks.push(m);

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="h-auto w-full rounded-lg bg-paper" role="img" aria-label={`Diagramme de centrage ${title}`}>
      {yTicks.map((m) => (
        <g key={`y${m}`}>
          <line x1={L} x2={W - R} y1={y(m)} y2={y(m)} stroke="#dfe3ea" strokeWidth="1" />
          <text x={L - 6} y={y(m) + 3} textAnchor="end" fontSize="10" fill="#5f6b7d">
            {m} kg
          </text>
        </g>
      ))}
      {xTicks.map((a) => (
        <g key={`x${a}`}>
          <line x1={x(a)} x2={x(a)} y1={T} y2={H - B} stroke="#dfe3ea" strokeWidth="1" />
          <text x={x(a)} y={H - B + 14} textAnchor="middle" fontSize="10" fill="#5f6b7d">
            {a.toLocaleString("fr-FR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
          </text>
        </g>
      ))}
      <text x={(L + W - R) / 2} y={H - 6} textAnchor="middle" fontSize="11" fill="#5f6b7d">
        Bras de levier (m)
      </text>
      <polygon
        points={env.map((p) => `${x(p.arm)},${y(p.mass)}`).join(" ")}
        fill="#e7e9ee"
        stroke="#002157"
        strokeWidth="2"
        strokeDasharray="6 4"
      />
      {data.mtow && (
        <g>
          <line x1={L} x2={W - R} y1={y(Number(data.mtow))} y2={y(Number(data.mtow))} stroke="#e4002b" strokeDasharray="4 4" strokeWidth="1" />
          <text x={W - R - 4} y={y(Number(data.mtow)) - 5} textAnchor="end" fontSize="10" fill="#e4002b">
            MTOW {data.mtow} kg
          </text>
        </g>
      )}
      {showZf && (
        <>
          <line x1={x(to.cg)} y1={y(to.mass)} x2={x(zf.cg)} y2={y(zf.mass)} stroke="#8a94a6" strokeWidth="1" strokeDasharray="2 4" />
          <circle cx={x(zf.cg)} cy={y(zf.mass)} r="6" fill="#fff" stroke="#8a94a6" strokeWidth="3" />
          <text x={x(zf.cg) + 10} y={y(zf.mass) + 4} fontSize="11" fontWeight="700" fill="#5f6b7d">
            ZF
          </text>
        </>
      )}
      {ldg && (
        <>
          <line x1={x(to.cg)} y1={y(to.mass)} x2={x(ldg.cg)} y2={y(ldg.mass)} stroke="#9a5b0a" strokeWidth="1.5" strokeDasharray="3 3" />
          <circle cx={x(ldg.cg)} cy={y(ldg.mass)} r="7" fill="#fff" stroke="#9a5b0a" strokeWidth="3" />
          <text x={x(ldg.cg)} y={y(ldg.mass) + 20} textAnchor="middle" fontSize="11" fontWeight="700" fill="#9a5b0a">
            LDG
          </text>
        </>
      )}
      <circle cx={x(to.cg)} cy={y(to.mass)} r="7" fill="#fff" stroke="#1d6b45" strokeWidth="3" />
      <text x={x(to.cg)} y={y(to.mass) - 12} textAnchor="middle" fontSize="11" fontWeight="700" fill="#1d6b45">
        TO
      </text>
    </svg>
  );
}
