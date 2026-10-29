"use client";

import { useActionState, useEffect, useMemo, useState, useTransition } from "react";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";
import { FUNCTIONS, blockMinutes, entryFunction, hm, type LogEntry } from "@/lib/carnet";
import { deleteEntry, saveEntry, type CarnetState } from "./actions";

type Plane = { registration: string; model: string };
type Mode = { kind: "vol" | "report"; entry: LogEntry | null } | null;

const frDate = (d: string) => new Date(d + "T12:00:00Z").toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit", year: "numeric", timeZone: "UTC" });
const t5 = (t: string | null) => (t ? t.slice(0, 5) : "");
const dur = (m: number) => (m ? hm(m) : "");
const SHORT = { cdb: "CDB", dc: "DC", inst: "INST", copi: "COPI" } as const;

export function CarnetClient({ entries, fleet, myName, today }: { entries: LogEntry[]; fleet: Plane[]; myName: string; today: string }) {
  const [mode, setMode] = useState<Mode>(entries.length ? null : { kind: "vol", entry: null });
  const [msg, setMsg] = useState<CarnetState>(undefined);
  const [year, setYear] = useState<string>("tout");
  const [pending, start] = useTransition();

  const years = useMemo(() => Array.from(new Set(entries.map((e) => e.flight_date.slice(0, 4)))).sort().reverse(), [entries]);
  const shown = year === "tout" ? entries : entries.filter((e) => e.flight_date.startsWith(year));
  const sum = shown.reduce(
    (a, e) => ({ total: a.total + e.total_min, pic: a.pic + e.pic_min, dual: a.dual + e.dual_min, ld: a.ld + e.landings_day, ln: a.ln + e.landings_night, night: a.night + e.night_min }),
    { total: 0, pic: 0, dual: 0, ld: 0, ln: 0, night: 0 },
  );

  function remove(e: LogEntry) {
    if (!window.confirm(`Supprimer la ligne du ${frDate(e.flight_date)} ?`)) return;
    start(async () => setMsg(await deleteEntry(e.id)));
  }

  return (
    <section>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <h2 className="mr-auto text-lg font-bold text-navy-2">Mes vols</h2>
        <button type="button" className="btn-primary" onClick={() => { setMsg(undefined); setMode({ kind: "vol", entry: null }); }}>
          ＋ Ajouter un vol
        </button>
        <button type="button" className="btn-secondary" onClick={() => { setMsg(undefined); setMode({ kind: "report", entry: null }); }}>
          Reporter mes heures antérieures
        </button>
      </div>

      {mode && (
        <EntryForm
          key={`${mode.kind}-${mode.entry?.id ?? "new"}`}
          kind={mode.kind}
          entry={mode.entry}
          fleet={fleet}
          myName={myName}
          today={today}
          last={entries.find((e) => e.kind === "vol") ?? null}
          onClose={(m) => { setMode(null); if (m) setMsg(m); }}
        />
      )}
      <div className="mb-3"><FormMessage state={msg} /></div>

      {entries.length === 0 ? (
        !mode && <div className="card p-8 text-center text-muted">Aucun vol pour le moment : ajoutez votre premier vol ou reportez vos heures antérieures.</div>
      ) : (
        <div className="card overflow-hidden">
          <div className="flex flex-wrap items-center gap-2 border-b border-line px-4 py-2 text-sm">
            <span className="text-muted">Année :</span>
            {["tout", ...years].map((y) => (
              <button key={y} type="button" onClick={() => setYear(y)} className={`rounded-full px-3 py-1 font-semibold ${year === y ? "bg-navy-2 text-white" : "text-navy-2 hover:bg-sky-soft"}`}>
                {y === "tout" ? "Tout" : y}
              </button>
            ))}
          </div>
          {/* Téléphone : une carte par vol */}
          <ul className="divide-y divide-line sm:hidden">
            {shown.map((e) => (
              <li key={e.id} className={`px-4 py-3 ${e.kind === "report" ? "bg-sky-soft/50" : ""}`}>
                <div className="flex items-baseline justify-between gap-2">
                  <span className="font-semibold text-ink">
                    {e.kind === "report" ? "Report des heures antérieures" : `${e.dep_place ?? "?"} → ${e.arr_place ?? "?"}`}
                  </span>
                  <span className="font-bold tabular-nums text-navy-2">{hm(e.total_min)}</span>
                </div>
                <p className="text-xs text-muted">
                  {frDate(e.flight_date)} · {e.aircraft_model ?? (e.kind === "report" ? "tous types" : "")} {e.aircraft_reg ?? ""} ·{" "}
                  {e.kind === "report" ? `CDB ${hm(e.pic_min)}` : SHORT[entryFunction(e)]} · {e.landings_day + e.landings_night} att.
                </p>
                {e.remarks && <p className="truncate text-xs text-muted">{e.remarks}</p>}
                <div className="mt-1 flex gap-3">
                  <button type="button" onClick={() => setMode({ kind: e.kind, entry: e })} className="text-xs text-sky hover:underline">Modifier</button>
                  <button type="button" onClick={() => remove(e)} disabled={pending} className="text-xs text-danger hover:underline">Supprimer</button>
                </div>
              </li>
            ))}
            <li className="flex justify-between bg-paper px-4 py-2 text-sm font-semibold">
              <span>Total · {shown.length} ligne{shown.length > 1 ? "s" : ""}</span>
              <span className="tabular-nums">{hm(sum.total)} · {sum.ld + sum.ln} att.</span>
            </li>
          </ul>
          <div className="hidden overflow-x-auto sm:block">
            <table className="w-full min-w-[900px] text-sm">
              <thead className="bg-paper text-left text-[11px] tracking-wide text-muted uppercase">
                <tr>
                  <th className="px-3 py-2">Date</th>
                  <th className="px-3 py-2">Départ</th>
                  <th className="px-3 py-2">Arrivée</th>
                  <th className="px-3 py-2">Aéronef</th>
                  <th className="px-3 py-2 text-right">Durée</th>
                  <th className="px-3 py-2">Fonction</th>
                  <th className="px-3 py-2 text-right">Att. jour / nuit</th>
                  <th className="px-3 py-2">CDB · remarques</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {shown.map((e) =>
                  e.kind === "report" ? (
                    <tr key={e.id} className="bg-sky-soft/50">
                      <td className="px-3 py-2 whitespace-nowrap">{frDate(e.flight_date)}</td>
                      <td className="px-3 py-2 font-semibold text-navy-2" colSpan={2}>Report des heures antérieures</td>
                      <td className="px-3 py-2">{e.aircraft_model ?? "tous types"}</td>
                      <td className="px-3 py-2 text-right font-semibold tabular-nums">{hm(e.total_min)}</td>
                      <td className="px-3 py-2 text-xs text-muted">CDB {hm(e.pic_min)} · DC {hm(e.dual_min)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{e.landings_day} / {e.landings_night}</td>
                      <td className="px-3 py-2 text-xs text-muted">{e.remarks}</td>
                      <Actions onEdit={() => setMode({ kind: "report", entry: e })} onDelete={() => remove(e)} pending={pending} />
                    </tr>
                  ) : (
                    <tr key={e.id}>
                      <td className="px-3 py-2 whitespace-nowrap">{frDate(e.flight_date)}</td>
                      <td className="px-3 py-2 whitespace-nowrap"><b>{e.dep_place}</b> <span className="text-muted">{t5(e.dep_time)}</span></td>
                      <td className="px-3 py-2 whitespace-nowrap"><b>{e.arr_place}</b> <span className="text-muted">{t5(e.arr_time)}</span></td>
                      <td className="px-3 py-2 whitespace-nowrap">{e.aircraft_model} <span className="text-muted">{e.aircraft_reg}</span></td>
                      <td className="px-3 py-2 text-right font-semibold tabular-nums">{hm(e.total_min)}</td>
                      <td className="px-3 py-2 text-xs whitespace-nowrap">{SHORT[entryFunction(e)]}{e.night_min ? ` · nuit ${hm(e.night_min)}` : ""}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{e.landings_day} / {e.landings_night}</td>
                      <td className="max-w-56 truncate px-3 py-2 text-xs text-muted" title={e.remarks ?? undefined}>
                        {[e.pic_name, e.remarks].filter(Boolean).join(" · ")}
                      </td>
                      <Actions onEdit={() => setMode({ kind: "vol", entry: e })} onDelete={() => remove(e)} pending={pending} />
                    </tr>
                  ),
                )}
              </tbody>
              <tfoot className="bg-paper text-sm font-semibold">
                <tr>
                  <td className="px-3 py-2" colSpan={4}>
                    Total {year === "tout" ? "" : year} · {shown.length} ligne{shown.length > 1 ? "s" : ""}
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums">{hm(sum.total)}</td>
                  <td className="px-3 py-2 text-xs font-normal text-muted">CDB {hm(sum.pic)} · DC {hm(sum.dual)}{sum.night ? ` · nuit ${hm(sum.night)}` : ""}</td>
                  <td className="px-3 py-2 text-right tabular-nums">{sum.ld} / {sum.ln}</td>
                  <td colSpan={2} />
                </tr>
              </tfoot>
            </table>
          </div>
        </div>
      )}
    </section>
  );
}

function Actions({ onEdit, onDelete, pending }: { onEdit: () => void; onDelete: () => void; pending: boolean }) {
  return (
    <td className="px-3 py-2 text-right whitespace-nowrap">
      <button type="button" onClick={onEdit} className="mr-2 text-xs text-sky hover:underline">Modifier</button>
      <button type="button" onClick={onDelete} disabled={pending} className="text-xs text-danger hover:underline">Supprimer</button>
    </td>
  );
}

function EntryForm({
  kind, entry, fleet, myName, today, last, onClose,
}: {
  kind: "vol" | "report";
  entry: LogEntry | null;
  fleet: Plane[];
  myName: string;
  today: string;
  last: LogEntry | null;
  onClose: (m?: CarnetState) => void;
}) {
  const [state, action] = useActionState<CarnetState, FormData>(saveEntry, undefined);
  const [dep, setDep] = useState(t5(entry?.dep_time ?? null));
  const [arr, setArr] = useState(t5(entry?.arr_time ?? null));
  const [total, setTotal] = useState(entry ? hm(entry.total_min) : "");
  const [totalTouched, setTotalTouched] = useState(!!entry);
  const [reg, setReg] = useState(entry?.aircraft_reg ?? "");
  const [model, setModel] = useState(entry?.aircraft_model ?? "");
  const [fn, setFn] = useState<string>(entry ? entryFunction(entry) : "cdb");
  const [pic, setPic] = useState(entry?.pic_name ?? "SELF");

  // Durée totale calculée depuis les heures bloc (modifiable)
  useEffect(() => {
    if (totalTouched) return;
    const m = blockMinutes(dep, arr);
    if (m != null) setTotal(hm(m));
  }, [dep, arr, totalTouched]);

  useEffect(() => {
    if (state?.ok) onClose(state);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]);

  const pickReg = (v: string) => {
    const r = v.toUpperCase();
    setReg(r);
    const f = fleet.find((p) => p.registration === r);
    if (f) setModel(f.model);
  };

  return (
    <form onSubmit={keepValues(action)} className="card mb-4 space-y-4 p-5">
      <input type="hidden" name="id" value={entry?.id ?? ""} />
      <input type="hidden" name="kind" value={kind} />
      <div className="flex items-center justify-between gap-2">
        <h3 className="font-bold text-navy-2">
          {kind === "report" ? (entry ? "Modifier le report" : "Reporter mes heures antérieures") : entry ? "Modifier le vol" : "Nouveau vol"}
        </h3>
        <button type="button" className="text-sm text-muted hover:underline" onClick={() => onClose()}>
          Fermer
        </button>
      </div>

      {kind === "report" ? (
        <>
          <p className="text-sm text-muted">
            Totaux de votre carnet papier (ou d&apos;un autre carnet) à la date indiquée. Vous pouvez faire un report par type d&apos;appareil.
            Ces heures comptent dans vos totaux, pas dans l&apos;expérience récente.
          </p>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <L label="Arrêté au"><input type="date" name="flight_date" required defaultValue={entry?.flight_date ?? today} className="field" /></L>
            <L label="Type d'appareil (facultatif)"><input name="aircraft_model" defaultValue={entry?.aircraft_model ?? ""} placeholder="tous types" className="field" maxLength={40} /></L>
            <L label="Heures totales (HH:MM)"><input name="total" required defaultValue={entry ? hm(entry.total_min) : ""} placeholder="125:30" className="field" /></L>
            <L label="dont CDB (HH:MM)"><input name="pic" defaultValue={entry ? hm(entry.pic_min) : ""} placeholder="80:00" className="field" /></L>
            <L label="dont double commande"><input name="dual" defaultValue={entry ? hm(entry.dual_min) : ""} placeholder="45:30" className="field" /></L>
            <L label="dont instructeur"><input name="instructor" defaultValue={entry ? hm(entry.instructor_min) : ""} className="field" /></L>
            <L label="dont copilote"><input name="copilot" defaultValue={entry ? hm(entry.copilot_min) : ""} className="field" /></L>
            <L label="dont nuit"><input name="night" defaultValue={entry ? hm(entry.night_min) : ""} className="field" /></L>
            <L label="Atterrissages de jour"><input name="landings_day" inputMode="numeric" defaultValue={entry?.landings_day ?? ""} className="field" /></L>
            <L label="Atterrissages de nuit"><input name="landings_night" inputMode="numeric" defaultValue={entry?.landings_night ?? ""} className="field" /></L>
            <L label="dont IFR"><input name="ifr" defaultValue={entry ? hm(entry.ifr_min) : ""} className="field" /></L>
            <L label="Remarque"><input name="remarks" defaultValue={entry?.remarks ?? ""} placeholder="Carnet papier n°1" className="field" maxLength={500} /></L>
          </div>
        </>
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <L label="Date"><input type="date" name="flight_date" required max={today} defaultValue={entry?.flight_date ?? today} className="field" /></L>
            <L label="Immatriculation">
              <input name="aircraft_reg" list="carnet-fleet" value={reg} onChange={(e) => pickReg(e.target.value)} placeholder="F-HCLI" className="field uppercase" maxLength={20} />
              <datalist id="carnet-fleet">
                {fleet.map((p) => <option key={p.registration} value={p.registration}>{p.model}</option>)}
              </datalist>
            </L>
            <L label="Modèle"><input name="aircraft_model" value={model} onChange={(e) => setModel(e.target.value)} placeholder="DR400" className="field" maxLength={40} /></L>
            <L label="Fonction à bord">
              <select name="function" value={fn} onChange={(e) => { setFn(e.target.value); if (e.target.value === "cdb" || e.target.value === "inst") setPic("SELF"); else if (pic === "SELF") setPic(""); }} className="field">
                {FUNCTIONS.map((f) => <option key={f.value} value={f.value}>{f.label}</option>)}
              </select>
            </L>
            <L label="Départ (lieu)"><input name="dep_place" defaultValue={entry?.dep_place ?? last?.arr_place ?? ""} placeholder="LFMA" className="field uppercase" maxLength={40} /></L>
            <L label="Heure de départ (bloc)"><input type="time" name="dep_time" value={dep} onChange={(e) => setDep(e.target.value)} className="field" /></L>
            <L label="Arrivée (lieu)"><input name="arr_place" defaultValue={entry?.arr_place ?? ""} placeholder="LFMA" className="field uppercase" maxLength={40} /></L>
            <L label="Heure d'arrivée (bloc)"><input type="time" name="arr_time" value={arr} onChange={(e) => setArr(e.target.value)} className="field" /></L>
            <L label="Durée totale (HH:MM)">
              <input name="total" required value={total} onChange={(e) => { setTotal(e.target.value); setTotalTouched(true); }} placeholder="1:35" className="field font-semibold" />
            </L>
            <L label="Atterrissages de jour"><input name="landings_day" type="number" min={0} defaultValue={entry?.landings_day ?? 1} className="field" /></L>
            <L label="Atterrissages de nuit"><input name="landings_night" type="number" min={0} defaultValue={entry?.landings_night ?? 0} className="field" /></L>
            <L label="Nom du commandant de bord"><input name="pic_name" value={pic} onChange={(e) => setPic(e.target.value)} placeholder={fn === "dc" ? "Nom de l'instructeur" : "SELF"} className="field" maxLength={80} /></L>
          </div>
          <details className="rounded-lg bg-paper p-3">
            <summary className="cursor-pointer text-sm font-semibold text-navy-2">Nuit, IFR, multimoteur</summary>
            <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <L label="Temps de nuit (HH:MM)"><input name="night" defaultValue={entry ? dur(entry.night_min) : ""} className="field" /></L>
              <L label="Temps IFR (HH:MM)"><input name="ifr" defaultValue={entry ? dur(entry.ifr_min) : ""} className="field" /></L>
              <L label="Approches IFR"><input name="ifr_approaches" type="number" min={0} defaultValue={entry?.ifr_approaches ?? 0} className="field" /></L>
              <label className="flex items-center gap-2 pt-6 text-sm">
                <input type="checkbox" name="multi" defaultChecked={!!entry && entry.me_min > 0} /> Avion multimoteur (ME)
              </label>
            </div>
          </details>
          <L label="Remarques et appositions">
            <input name="remarks" defaultValue={entry?.remarks ?? ""} placeholder="Ex. navigation, tour de piste, vol découverte…" className="field" maxLength={500} />
          </L>
          {fn === "dc" && myName && <p className="text-xs text-muted">En double commande, indiquez le nom de l&apos;instructeur comme commandant de bord.</p>}
        </>
      )}

      <FormMessage state={state?.error ? state : undefined} />
      <div className="flex gap-2">
        <SubmitButton pending="Enregistrement…">{entry ? "Enregistrer" : kind === "report" ? "Ajouter le report" : "Ajouter au carnet"}</SubmitButton>
        <button type="button" className="btn-secondary" onClick={() => onClose()}>Annuler</button>
      </div>
    </form>
  );
}

function L({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="label">{label}</span>
      {children}
    </label>
  );
}
