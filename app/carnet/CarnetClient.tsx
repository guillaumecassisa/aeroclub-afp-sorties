"use client";

import { useActionState, useEffect, useMemo, useRef, useState, useTransition } from "react";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";
import { blockMinutes, hm, parseDuration, type LogEntry } from "@/lib/carnet";
import { deleteEntry, saveEntry, type CarnetState } from "./actions";

type Plane = { registration: string; model: string };

/** 12 lignes par page, comme le carnet de vol papier (et le modèle Excel Dataero) */
const PER_PAGE = 12;

const frDate = (d: string | null) => (d ? new Date(d + "T12:00:00Z").toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit", year: "numeric", timeZone: "UTC" }) : "");
const t5 = (t: string | null) => (t ? t.slice(0, 5) : "");
const dur = (m: number) => (m ? hm(m) : "");
const n0 = (n: number) => (n ? String(n) : "");

// Colonnes totalisées en bas de page (même ordre que le carnet)
type Tot = { se: number; me: number; mp: number; total: number; ld: number; ln: number; apch: number; night: number; ifr: number; pic: number; copi: number; dc: number; inst: number; sim: number };
const zero = (): Tot => ({ se: 0, me: 0, mp: 0, total: 0, ld: 0, ln: 0, apch: 0, night: 0, ifr: 0, pic: 0, copi: 0, dc: 0, inst: 0, sim: 0 });
const add = (t: Tot, e: LogEntry): Tot => ({
  se: t.se + e.se_min, me: t.me + e.me_min, mp: t.mp + e.multi_pilot_min, total: t.total + e.total_min,
  ld: t.ld + e.landings_day, ln: t.ln + e.landings_night, apch: t.apch + e.ifr_approaches,
  night: t.night + e.night_min, ifr: t.ifr + e.ifr_min, pic: t.pic + e.pic_min, copi: t.copi + e.copilot_min,
  dc: t.dc + e.dual_min, inst: t.inst + e.instructor_min, sim: t.sim + e.sim_min,
});
const plus = (a: Tot, b: Tot): Tot => Object.fromEntries(Object.keys(a).map((k) => [k, a[k as keyof Tot] + b[k as keyof Tot]])) as Tot;

const TH = "border border-white/25 px-1.5 py-1 text-center align-middle font-semibold";
const TD = "border border-line px-1.5 py-1 align-middle";

export function CarnetClient({ entries, fleet, today }: { entries: LogEntry[]; fleet: Plane[]; myName: string; today: string }) {
  const [msg, setMsg] = useState<CarnetState>(undefined);
  const [editing, setEditing] = useState<string | null>(null);
  const [report, setReport] = useState<LogEntry | "new" | null>(null);
  const [pending, start] = useTransition();

  // Lignes du carnet dans l'ordre chronologique ; les reports forment le « total des pages précédentes » de la page 1
  const flights = useMemo(
    () => entries.filter((e) => e.kind === "vol").sort((a, b) => (a.flight_date + t5(a.dep_time)).localeCompare(b.flight_date + t5(b.dep_time))),
    [entries],
  );
  const reports = entries.filter((e) => e.kind === "report");
  const carried = reports.reduce(add, zero());
  const pages = Math.max(1, Math.ceil((flights.length + 1) / PER_PAGE)); // + la ligne de saisie
  const [page, setPage] = useState(pages - 1);
  useEffect(() => setPage(pages - 1), [pages]);

  const rows = flights.slice(page * PER_PAGE, (page + 1) * PER_PAGE);
  const before = flights.slice(0, page * PER_PAGE).reduce(add, carried);
  const pageTot = rows.reduce(add, zero());
  const lastPage = page === pages - 1;

  function remove(e: LogEntry) {
    if (!window.confirm(`Supprimer la ligne du ${frDate(e.flight_date)} ?`)) return;
    start(async () => setMsg(await deleteEntry(e.id)));
  }
  const done = (m?: CarnetState) => {
    setEditing(null);
    setReport(null);
    if (m) setMsg(m);
  };

  return (
    <section>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <h2 className="mr-auto text-lg font-bold text-navy-2">Mes vols</h2>
        <button type="button" className="btn-secondary" onClick={() => { setMsg(undefined); setReport("new"); }}>
          Reporter mes heures antérieures
        </button>
      </div>
      {report && <ReportForm entry={report === "new" ? null : report} today={today} onClose={done} />}
      <div className="mb-3"><FormMessage state={msg} /></div>

      {/* Le carnet prend toute la largeur de l'écran : ses 25 colonnes restent lisibles */}
      <div className="card relative left-1/2 w-[calc(100vw-2rem)] max-w-[1900px] -translate-x-1/2 overflow-hidden">
        <div className="flex flex-wrap items-center gap-2 border-b border-line px-4 py-2 text-sm">
          <span className="font-semibold text-navy-2">Page {page + 1} / {pages}</span>
          <button type="button" className="rounded-full px-3 py-1 text-navy-2 hover:bg-sky-soft disabled:opacity-40" disabled={page === 0} onClick={() => setPage(0)}>« Première</button>
          <button type="button" className="rounded-full px-3 py-1 text-navy-2 hover:bg-sky-soft disabled:opacity-40" disabled={page === 0} onClick={() => setPage((p) => p - 1)}>‹ Précédente</button>
          <button type="button" className="rounded-full px-3 py-1 text-navy-2 hover:bg-sky-soft disabled:opacity-40" disabled={lastPage} onClick={() => setPage((p) => p + 1)}>Suivante ›</button>
          <button type="button" className="rounded-full px-3 py-1 text-navy-2 hover:bg-sky-soft disabled:opacity-40" disabled={lastPage} onClick={() => setPage(pages - 1)}>Dernière »</button>
          <span className="ml-auto text-xs text-muted">Saisie : remplissez la ligne vide en bas de la dernière page, comme sur votre carnet.</span>
        </div>

        <div className="overflow-x-auto">
          <table className="w-max min-w-full border-collapse text-[12.5px]">
            <thead className="bg-navy-2 text-[11px] text-white">
              <tr>
                <th className={TH} rowSpan={2}>Date<br /><span className="font-normal opacity-70">JJ/MM/AAAA</span></th>
                <th className={TH} colSpan={2}>Départ</th>
                <th className={TH} colSpan={2}>Arrivée</th>
                <th className={TH} colSpan={2}>Aéronef</th>
                <th className={TH} colSpan={2}><W>Temps comme pilote d&apos;aéronef mono-pilote</W></th>
                <th className={TH} rowSpan={2}><W>Temps comme pilote d&apos;aéronef multi-pilote</W></th>
                <th className={TH} rowSpan={2}><W>Durée totale du vol</W></th>
                <th className={TH} rowSpan={2}><W>Nom du commandant de bord</W></th>
                <th className={TH} colSpan={2}><W>Nombre d&apos;atterrissages</W></th>
                <th className={TH} rowSpan={2}>IFR APCH</th>
                <th className={TH} colSpan={2}><W>Temps en conditions opérationnelles</W></th>
                <th className={TH} colSpan={4}><W>Temps comme pilote en fonction</W></th>
                <th className={TH} colSpan={3}><W>Séances de simulateur</W></th>
                <th className={TH} rowSpan={2}><W>Remarques et appositions</W></th>
                <th className={TH} rowSpan={2} />
              </tr>
              <tr>
                {["Lieu", "Heure", "Lieu", "Heure", "Modèle", "Immat", "SE", "ME", "Jour", "Nuit", "Nuit", "IFR", "CDB", "COPI", "DC", "INST", "Date", "Type", "Durée"].map((h, i) => (
                  <th key={i} className={TH}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((e) =>
                editing === e.id ? (
                  <EntryRow key={e.id} entry={e} fleet={fleet} today={today} prevArr={null} onDone={done} />
                ) : (
                  <tr key={e.id} className="hover:bg-sky-soft/40">
                    <td className={`${TD} whitespace-nowrap`}>{frDate(e.flight_date)}</td>
                    <td className={`${TD} font-semibold`}>{e.dep_place}</td>
                    <td className={`${TD} text-center tabular-nums`}>{t5(e.dep_time)}</td>
                    <td className={`${TD} font-semibold`}>{e.arr_place}</td>
                    <td className={`${TD} text-center tabular-nums`}>{t5(e.arr_time)}</td>
                    <td className={TD}>{e.aircraft_model}</td>
                    <td className={`${TD} whitespace-nowrap`}>{e.aircraft_reg}</td>
                    <Num v={dur(e.se_min)} /><Num v={dur(e.me_min)} /><Num v={dur(e.multi_pilot_min)} />
                    <Num v={dur(e.total_min)} bold />
                    <td className={`${TD} whitespace-nowrap`}>{e.pic_name}</td>
                    <Num v={n0(e.landings_day)} /><Num v={n0(e.landings_night)} /><Num v={n0(e.ifr_approaches)} />
                    <Num v={dur(e.night_min)} /><Num v={dur(e.ifr_min)} />
                    <Num v={dur(e.pic_min)} /><Num v={dur(e.copilot_min)} /><Num v={dur(e.dual_min)} /><Num v={dur(e.instructor_min)} />
                    <td className={`${TD} whitespace-nowrap`}>{frDate(e.sim_date)}</td>
                    <td className={TD}>{e.sim_type}</td>
                    <Num v={dur(e.sim_min)} />
                    <td className={`${TD} max-w-64 min-w-40`}>{e.remarks}</td>
                    <td className={`${TD} whitespace-nowrap`}>
                      <button type="button" onClick={() => { setMsg(undefined); setEditing(e.id); }} className="mr-2 text-xs text-sky hover:underline">Modifier</button>
                      <button type="button" onClick={() => remove(e)} disabled={pending} className="text-xs text-danger hover:underline">Suppr.</button>
                    </td>
                  </tr>
                ),
              )}
              {lastPage && !editing && (
                <EntryRow key={`new-${flights.length}`} entry={null} fleet={fleet} today={today} prevArr={flights.at(-1)?.arr_place ?? null} onDone={done} />
              )}
              {/* lignes vides pour garder l'aspect de la page */}
              {Array.from({ length: Math.max(0, PER_PAGE - rows.length - (lastPage && !editing ? 1 : 0)) }).map((_, i) => (
                <tr key={`vide-${i}`} className="h-7">{Array.from({ length: 26 }).map((__, j) => <td key={j} className={TD} />)}</tr>
              ))}
            </tbody>
            <tfoot className="text-[12px] font-semibold">
              <TotRow label="TOTAL DE LA PAGE" t={pageTot} />
              <TotRow label="TOTAL DES PAGES PRÉCÉDENTES" t={before} muted note={page === 0 && reports.length ? "dont report des heures antérieures" : undefined} />
              <TotRow label="TOTAL" t={plus(before, pageTot)} strong />
            </tfoot>
          </table>
        </div>
        <p className="border-t border-line px-4 py-2 text-xs text-muted">
          Je certifie que les informations de ce carnet sont exactes. · Durées au format HH:MM (1:35). La durée totale se calcule depuis les
          heures bloc et se reporte en SE et en CDB : déplacez-la en DC pour un vol en double commande.
        </p>
      </div>

      {reports.length > 0 && (
        <div className="mt-3 text-sm text-muted">
          Reports d&apos;heures antérieures :{" "}
          {reports.map((r) => (
            <button key={r.id} type="button" className="mr-3 text-sky hover:underline" onClick={() => setReport(r)}>
              {frDate(r.flight_date)}{r.aircraft_model ? ` (${r.aircraft_model})` : ""} — {hm(r.total_min)}
            </button>
          ))}
        </div>
      )}
    </section>
  );
}

/** En-tête sur plusieurs lignes (comme sur le carnet papier) */
function W({ children }: { children: React.ReactNode }) {
  return <div className="mx-auto w-[84px] leading-tight whitespace-normal">{children}</div>;
}

function Num({ v, bold }: { v: string; bold?: boolean }) {
  return <td className={`${TD} text-right tabular-nums ${bold ? "font-bold" : ""}`}>{v}</td>;
}

function TotRow({ label, t, muted, strong, note }: { label: string; t: Tot; muted?: boolean; strong?: boolean; note?: string }) {
  const c = `${TD} text-right tabular-nums ${strong ? "bg-sky-soft text-navy-2" : muted ? "bg-paper text-muted" : "bg-paper"}`;
  return (
    <tr>
      <td className={`${TD} text-right ${strong ? "bg-sky-soft text-navy-2" : "bg-paper"}`} colSpan={7}>
        {label}
        {note && <span className="block text-[10px] font-normal">{note}</span>}
      </td>
      <td className={c}>{hm(t.se)}</td><td className={c}>{hm(t.me)}</td><td className={c}>{hm(t.mp)}</td><td className={c}>{hm(t.total)}</td>
      <td className={c} />
      <td className={c}>{t.ld}</td><td className={c}>{t.ln}</td><td className={c}>{t.apch}</td>
      <td className={c}>{hm(t.night)}</td><td className={c}>{hm(t.ifr)}</td>
      <td className={c}>{hm(t.pic)}</td><td className={c}>{hm(t.copi)}</td><td className={c}>{hm(t.dc)}</td><td className={c}>{hm(t.inst)}</td>
      <td className={c} /><td className={c} /><td className={c}>{hm(t.sim)}</td>
      <td className={c} colSpan={2} />
    </tr>
  );
}

const IN = "min-w-0 rounded border border-line bg-white px-1 py-0.5 text-[12.5px] focus:border-navy-2 focus:outline-none";

/** Une ligne du carnet en saisie : mêmes colonnes que le carnet */
function EntryRow({ entry, fleet, today, prevArr, onDone }: { entry: LogEntry | null; fleet: Plane[]; today: string; prevArr: string | null; onDone: (m?: CarnetState) => void }) {
  const [state, action] = useActionState<CarnetState, FormData>(saveEntry, undefined);
  const formId = `ligne-${entry?.id ?? "nouvelle"}`;
  const form = useRef<HTMLFormElement>(null);
  const [v, setV] = useState(() => ({
    flight_date: entry?.flight_date ?? today,
    dep_place: entry?.dep_place ?? prevArr ?? "",
    dep_time: t5(entry?.dep_time ?? null),
    arr_place: entry?.arr_place ?? "",
    arr_time: t5(entry?.arr_time ?? null),
    aircraft_model: entry?.aircraft_model ?? "",
    aircraft_reg: entry?.aircraft_reg ?? "",
    se: entry ? dur(entry.se_min) : "",
    me: entry ? dur(entry.me_min) : "",
    multi_pilot: entry ? dur(entry.multi_pilot_min) : "",
    total: entry ? dur(entry.total_min) : "",
    pic_name: entry?.pic_name ?? "SELF",
    landings_day: entry ? n0(entry.landings_day) : "1",
    landings_night: entry ? n0(entry.landings_night) : "",
    ifr_approaches: entry ? n0(entry.ifr_approaches) : "",
    night: entry ? dur(entry.night_min) : "",
    ifr: entry ? dur(entry.ifr_min) : "",
    pic: entry ? dur(entry.pic_min) : "",
    copilot: entry ? dur(entry.copilot_min) : "",
    dual: entry ? dur(entry.dual_min) : "",
    instructor: entry ? dur(entry.instructor_min) : "",
    sim_date: entry?.sim_date ?? "",
    sim_type: entry?.sim_type ?? "",
    sim: entry ? dur(entry.sim_min) : "",
    remarks: entry?.remarks ?? "",
  }));
  // Colonnes qui suivent la durée totale tant qu'on ne les a pas modifiées (SE et CDB par défaut)
  const [follow, setFollow] = useState<Record<string, boolean>>(() => (entry ? {} : { se: true, pic: true }) as Record<string, boolean>);
  const [totalTouched, setTotalTouched] = useState(!!entry);

  const set = (k: keyof typeof v, val: string) => {
    setV((o) => {
      const n = { ...o, [k]: val };
      if (k === "total") for (const f of Object.keys(follow)) if (follow[f]) (n as Record<string, string>)[f] = val;
      return n;
    });
    if (k in follow && k !== "total") setFollow((f) => ({ ...f, [k]: false }));
  };

  // Durée totale depuis les heures bloc
  useEffect(() => {
    if (totalTouched) return;
    const m = blockMinutes(v.dep_time, v.arr_time);
    if (m != null && hm(m) !== v.total) set("total", hm(m));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [v.dep_time, v.arr_time, totalTouched]);

  useEffect(() => {
    if (state?.ok) onDone(state);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]);

  const pickReg = (val: string) => {
    const r = val.toUpperCase();
    const f = fleet.find((p) => p.registration === r);
    setV((o) => ({ ...o, aircraft_reg: r, aircraft_model: f ? f.model : o.aircraft_model }));
  };
  const bad = (s: string) => parseDuration(s) == null;
  const inp = (k: keyof typeof v, o: { w: string; ph?: string; up?: boolean; time?: boolean; num?: boolean; d?: boolean }) => (
    <td className={`${TD} bg-wait-soft/60 p-0.5`}>
      <input
        form={formId}
        name={k}
        value={v[k]}
        type={o.time ? "time" : o.num ? "number" : "text"}
        min={o.num ? 0 : undefined}
        placeholder={o.ph}
        onChange={(e) => (k === "aircraft_reg" ? pickReg(e.target.value) : (k === "total" && setTotalTouched(true), set(k, o.up ? e.target.value.toUpperCase() : e.target.value)))}
        className={`${IN} ${o.w} ${o.d ? "text-right tabular-nums" : ""} ${o.d && bad(v[k]) ? "border-danger text-danger" : ""}`}
        list={k === "aircraft_reg" ? "carnet-fleet" : undefined}
      />
    </td>
  );

  return (
    <>
      <tr>
        <td className={`${TD} bg-wait-soft/60 p-0.5`}>
          <form id={formId} ref={form} onSubmit={keepValues(action)} className="contents">
            <input type="hidden" name="id" value={entry?.id ?? ""} />
            <input type="hidden" name="kind" value="vol" />
          </form>
          <datalist id="carnet-fleet">
            {fleet.map((p) => <option key={p.registration} value={p.registration}>{p.model}</option>)}
          </datalist>
          <input form={formId} type="date" name="flight_date" required max={today} value={v.flight_date} onChange={(e) => set("flight_date", e.target.value)} className={`${IN} w-32`} />
        </td>
        {inp("dep_place", { w: "w-16", ph: "LFMA", up: true })}
        {inp("dep_time", { w: "w-[86px]", time: true })}
        {inp("arr_place", { w: "w-16", ph: "LFMA", up: true })}
        {inp("arr_time", { w: "w-[86px]", time: true })}
        {inp("aircraft_model", { w: "w-20", ph: "DR400" })}
        {inp("aircraft_reg", { w: "w-20", ph: "F-HCLI", up: true })}
        {inp("se", { w: "w-14", d: true })}
        {inp("me", { w: "w-14", d: true })}
        {inp("multi_pilot", { w: "w-14", d: true })}
        {inp("total", { w: "w-14 font-bold", d: true, ph: "1:35" })}
        {inp("pic_name", { w: "w-28" })}
        {inp("landings_day", { w: "w-12", num: true })}
        {inp("landings_night", { w: "w-12", num: true })}
        {inp("ifr_approaches", { w: "w-12", num: true })}
        {inp("night", { w: "w-14", d: true })}
        {inp("ifr", { w: "w-14", d: true })}
        {inp("pic", { w: "w-14", d: true })}
        {inp("copilot", { w: "w-14", d: true })}
        {inp("dual", { w: "w-14", d: true })}
        {inp("instructor", { w: "w-14", d: true })}
        <td className={`${TD} bg-wait-soft/60 p-0.5`}>
          <input form={formId} type="date" name="sim_date" value={v.sim_date} onChange={(e) => set("sim_date", e.target.value)} className={`${IN} w-32`} />
        </td>
        {inp("sim_type", { w: "w-20" })}
        {inp("sim", { w: "w-14", d: true })}
        {inp("remarks", { w: "w-56", ph: "Nav, tours de piste…" })}
        <td className={`${TD} bg-wait-soft/60 whitespace-nowrap`}>
          <SaveButton formId={formId} label={entry ? "OK" : "Ajouter"} />
          {entry && (
            <button type="button" onClick={() => onDone()} className="ml-2 text-xs text-muted hover:underline">Annuler</button>
          )}
        </td>
      </tr>
      {state?.error && (
        <tr>
          <td colSpan={26} className="border border-line bg-danger-soft px-3 py-1.5 text-sm text-danger">{state.error}</td>
        </tr>
      )}
    </>
  );
}

function SaveButton({ formId, label }: { formId: string; label: string }) {
  return (
    <button type="submit" form={formId} className="rounded-full bg-navy-2 px-3 py-1 text-xs font-semibold text-white hover:opacity-90">
      {label}
    </button>
  );
}

function ReportForm({ entry, today, onClose }: { entry: LogEntry | null; today: string; onClose: (m?: CarnetState) => void }) {
  const [state, action] = useActionState<CarnetState, FormData>(saveEntry, undefined);
  useEffect(() => {
    if (state?.ok) onClose(state);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]);
  const [delPending, start] = useTransition();
  const d = (m: number | undefined) => (entry && m ? hm(m) : "");
  return (
    <form onSubmit={keepValues(action)} className="card mb-4 space-y-3 p-5">
      <input type="hidden" name="id" value={entry?.id ?? ""} />
      <input type="hidden" name="kind" value="report" />
      <div className="flex items-center justify-between gap-2">
        <h3 className="font-bold text-navy-2">{entry ? "Modifier le report" : "Reporter mes heures antérieures"}</h3>
        <button type="button" className="text-sm text-muted hover:underline" onClick={() => onClose()}>Fermer</button>
      </div>
      <p className="text-sm text-muted">
        Totaux de votre carnet papier à la date indiquée : ils s&apos;ajoutent au « total des pages précédentes » de la première page. Un
        report par type d&apos;appareil est possible. Ils comptent dans vos totaux, pas dans l&apos;expérience récente.
      </p>
      <div className="grid gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <L label="Arrêté au"><input type="date" name="flight_date" required defaultValue={entry?.flight_date ?? today} className="field" /></L>
        <L label="Type (facultatif)"><input name="aircraft_model" defaultValue={entry?.aircraft_model ?? ""} placeholder="tous types" className="field" maxLength={40} /></L>
        <L label="Durée totale"><input name="total" required defaultValue={d(entry?.total_min)} placeholder="125:30" className="field" /></L>
        <L label="CDB"><input name="pic" defaultValue={d(entry?.pic_min)} className="field" /></L>
        <L label="DC"><input name="dual" defaultValue={d(entry?.dual_min)} className="field" /></L>
        <L label="INST"><input name="instructor" defaultValue={d(entry?.instructor_min)} className="field" /></L>
        <L label="COPI"><input name="copilot" defaultValue={d(entry?.copilot_min)} className="field" /></L>
        <L label="Nuit"><input name="night" defaultValue={d(entry?.night_min)} className="field" /></L>
        <L label="IFR"><input name="ifr" defaultValue={d(entry?.ifr_min)} className="field" /></L>
        <L label="Atterrissages jour"><input name="landings_day" inputMode="numeric" defaultValue={entry?.landings_day || ""} className="field" /></L>
        <L label="Atterrissages nuit"><input name="landings_night" inputMode="numeric" defaultValue={entry?.landings_night || ""} className="field" /></L>
        <L label="Remarque"><input name="remarks" defaultValue={entry?.remarks ?? ""} placeholder="Carnet papier n°1" className="field" maxLength={500} /></L>
      </div>
      <FormMessage state={state?.error ? state : undefined} />
      <div className="flex flex-wrap gap-2">
        <SubmitButton pending="Enregistrement…">{entry ? "Enregistrer" : "Ajouter le report"}</SubmitButton>
        <button type="button" className="btn-secondary" onClick={() => onClose()}>Annuler</button>
        {entry && (
          <button
            type="button"
            disabled={delPending}
            className="ml-auto text-sm text-danger hover:underline"
            onClick={() => window.confirm("Supprimer ce report ?") && start(async () => onClose(await deleteEntry(entry.id)))}
          >
            Supprimer ce report
          </button>
        )}
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
