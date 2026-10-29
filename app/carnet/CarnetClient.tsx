"use client";

import { useActionState, useEffect, useMemo, useState, useTransition } from "react";
import { FormMessage, keepValues } from "@/components/ui";
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

// Largeurs des 26 colonnes (proportions) : le carnet tient dans la largeur de la page, sans défilement
const COLS = [74, 40, 40, 40, 40, 46, 58, 37, 33, 33, 38, 52, 27, 27, 28, 34, 33, 37, 33, 34, 33, 62, 38, 33, 64, 38];
const SUM = COLS.reduce((a, b) => a + b, 0);

const TH = "border border-white/25 px-0.5 py-1 text-center align-middle font-semibold leading-tight";
const TD = "border border-line px-[3px] py-1 align-middle overflow-hidden text-ellipsis whitespace-nowrap";

export function CarnetClient({ entries, fleet, today }: { entries: LogEntry[]; fleet: Plane[]; myName: string; today: string }) {
  const [msg, setMsg] = useState<CarnetState>(undefined);
  const [editing, setEditing] = useState<string | null>(null);
  const [mobileForm, setMobileForm] = useState<LogEntry | "new" | null>(null);
  const [pending, start] = useTransition();

  // Lignes du carnet dans l'ordre chronologique (toutes les heures depuis le début)
  const flights = useMemo(
    () => entries.filter((e) => e.kind === "vol").sort((a, b) => (a.flight_date + t5(a.dep_time)).localeCompare(b.flight_date + t5(b.dep_time))),
    [entries],
  );
  // Avions déjà notés par le pilote hors flotte du club (proposés en plus des avions du club)
  const mine = useMemo(() => {
    const m = new Map<string, string>();
    for (const e of flights) if (e.aircraft_reg && !fleet.some((p) => p.registration === e.aircraft_reg)) m.set(e.aircraft_reg, e.aircraft_model ?? "");
    return [...m].map(([registration, model]) => ({ registration, model })).sort((a, b) => a.registration.localeCompare(b.registration));
  }, [flights, fleet]);
  const pages = Math.max(1, Math.ceil((flights.length + 1) / PER_PAGE)); // + la ligne de saisie
  const [page, setPage] = useState(pages - 1);
  useEffect(() => setPage(pages - 1), [pages]);

  const rows = flights.slice(page * PER_PAGE, (page + 1) * PER_PAGE);
  const before = flights.slice(0, page * PER_PAGE).reduce(add, zero());
  const pageTot = rows.reduce(add, zero());
  const lastPage = page === pages - 1;
  const prevArr = flights.at(-1)?.arr_place ?? null;

  function remove(e: LogEntry) {
    if (!window.confirm(`Supprimer la ligne du ${frDate(e.flight_date)} ?`)) return;
    start(async () => setMsg(await deleteEntry(e.id)));
  }
  const done = (m?: CarnetState) => {
    setEditing(null);
    setMobileForm(null);
    if (m) setMsg(m);
  };

  const pager = (
    <div className="flex flex-wrap items-center gap-1 text-sm">
      <span className="mr-1 font-semibold text-navy-2">Page {page + 1} / {pages}</span>
      {[
        ["«", 0, page === 0, "Première page"],
        ["‹", page - 1, page === 0, "Page précédente"],
        ["›", page + 1, lastPage, "Page suivante"],
        ["»", pages - 1, lastPage, "Dernière page"],
      ].map(([l, p, dis, t]) => (
        <button key={t as string} type="button" title={t as string} aria-label={t as string} disabled={dis as boolean} onClick={() => setPage(p as number)} className="rounded-full px-2.5 py-0.5 text-base text-navy-2 hover:bg-sky-soft disabled:opacity-30">
          {l}
        </button>
      ))}
    </div>
  );

  return (
    <section>
      <div className="mb-3"><FormMessage state={msg} /></div>

      {/* ── Ordinateur et tablette : le carnet, colonne pour colonne ── */}
      <div className="card hidden overflow-hidden md:block">
        <div className="flex flex-wrap items-center gap-2 border-b border-line px-3 py-1.5">
          {pager}
          <span className="ml-auto text-xs text-muted">Saisie dans la ligne vide en bas de la dernière page, comme sur votre carnet.</span>
        </div>
        <table className="w-full table-fixed border-collapse text-[11px]">
          <colgroup>
            {COLS.map((w, i) => <col key={i} style={{ width: `${(w / SUM) * 100}%` }} />)}
          </colgroup>
          <thead className="bg-navy-2 text-[9.5px] text-white">
            <tr>
              <th className={TH} rowSpan={2}>Date</th>
              <th className={TH} colSpan={2}>Départ</th>
              <th className={TH} colSpan={2}>Arrivée</th>
              <th className={TH} colSpan={2}>Aéronef</th>
              <th className={TH} colSpan={2}>Temps comme pilote d&apos;aéronef mono-pilote</th>
              <th className={TH} rowSpan={2}>Temps pilote multi-pilote</th>
              <th className={TH} rowSpan={2}>Durée totale du vol</th>
              <th className={TH} rowSpan={2}>Nom du CDB</th>
              <th className={TH} colSpan={2}>Atterris&shy;sages</th>
              <th className={TH} rowSpan={2}>IFR APCH</th>
              <th className={TH} colSpan={2}>Conditions opération.</th>
              <th className={TH} colSpan={4}>Temps comme pilote en fonction</th>
              <th className={TH} colSpan={3}>Séances de simulateur</th>
              <th className={TH} rowSpan={2}>Remarques et appositions</th>
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
                <EntryRow key={e.id} entry={e} fleet={fleet} mine={mine} today={today} prevArr={null} onDone={done} />
              ) : (
                <tr key={e.id} className="hover:bg-sky-soft/40">
                  <td className={`${TD} tabular-nums`}>{frDate(e.flight_date)}</td>
                  <td className={`${TD} font-semibold`}>{e.dep_place}</td>
                  <td className={`${TD} text-center tabular-nums`}>{t5(e.dep_time)}</td>
                  <td className={`${TD} font-semibold`}>{e.arr_place}</td>
                  <td className={`${TD} text-center tabular-nums`}>{t5(e.arr_time)}</td>
                  <td className={TD} title={e.aircraft_model ?? undefined}>{e.aircraft_model}</td>
                  <td className={TD}>{e.aircraft_reg}</td>
                  <Num v={dur(e.se_min)} /><Num v={dur(e.me_min)} /><Num v={dur(e.multi_pilot_min)} />
                  <Num v={dur(e.total_min)} bold />
                  <td className={TD} title={e.pic_name ?? undefined}>{e.pic_name}</td>
                  <Num v={n0(e.landings_day)} /><Num v={n0(e.landings_night)} /><Num v={n0(e.ifr_approaches)} />
                  <Num v={dur(e.night_min)} /><Num v={dur(e.ifr_min)} />
                  <Num v={dur(e.pic_min)} /><Num v={dur(e.copilot_min)} /><Num v={dur(e.dual_min)} /><Num v={dur(e.instructor_min)} />
                  <td className={`${TD} tabular-nums`}>{frDate(e.sim_date)}</td>
                  <td className={TD}>{e.sim_type}</td>
                  <Num v={dur(e.sim_min)} />
                  <td className={TD} title={e.remarks ?? undefined}>{e.remarks}</td>
                  <td className={`${TD} text-center whitespace-nowrap`}>
                    <button type="button" title="Modifier" aria-label="Modifier" onClick={() => { setMsg(undefined); setEditing(e.id); }} className="px-0.5 text-sky hover:opacity-70">✎</button>
                    <button type="button" title="Supprimer" aria-label="Supprimer" onClick={() => remove(e)} disabled={pending} className="px-0.5 text-danger hover:opacity-70">✕</button>
                  </td>
                </tr>
              ),
            )}
            {lastPage && !editing && (
              <EntryRow key={`new-${flights.length}`} entry={null} fleet={fleet} mine={mine} today={today} prevArr={prevArr} onDone={done} />
            )}
            {/* lignes vides pour garder l'aspect de la page */}
            {Array.from({ length: Math.max(0, PER_PAGE - rows.length - (lastPage && !editing ? 1 : 0)) }).map((_, i) => (
              <tr key={`vide-${i}`} className="h-6">{COLS.map((__, j) => <td key={j} className={TD} />)}</tr>
            ))}
          </tbody>
          <tfoot className="text-[10.5px] font-semibold">
            <TotRow label="TOTAL DE LA PAGE" t={pageTot} />
            <TotRow label="TOTAL DES PAGES PRÉCÉDENTES" t={before} muted />
            <TotRow label="TOTAL" t={plus(before, pageTot)} strong />
          </tfoot>
        </table>
        <p className="border-t border-line px-3 py-1.5 text-[11px] text-muted">
          Je certifie que les informations de ce carnet sont exactes. · Dates JJ/MM/AAAA, heures et durées HH:MM. La durée totale se
          calcule depuis les heures bloc et se reporte en SE et en CDB : déplacez-la en DC pour un vol en double commande.
        </p>
      </div>

      {/* ── Téléphone : une fiche par vol, et la saisie par rubriques du carnet ── */}
      <div className="md:hidden">
        {mobileForm ? (
          <EntryCard
            key={mobileForm === "new" ? "new" : mobileForm.id}
            entry={mobileForm === "new" ? null : mobileForm}
            fleet={fleet}
            mine={mine}
            today={today}
            prevArr={prevArr}
            onDone={done}
          />
        ) : (
          <button type="button" className="btn-primary mb-3 w-full" onClick={() => { setMsg(undefined); setMobileForm("new"); }}>
            ＋ Ajouter un vol
          </button>
        )}
        <div className="card overflow-hidden">
          <div className="border-b border-line px-3 py-1.5">{pager}</div>
          {rows.length === 0 ? (
            <p className="p-4 text-center text-sm text-muted">Aucun vol sur cette page.</p>
          ) : (
            <ul className="divide-y divide-line">
              {[...rows].reverse().map((e) => (
                <li key={e.id} className="px-3 py-2.5">
                  <div className="flex items-baseline justify-between gap-2">
                    <span className="font-semibold text-ink">
                      {e.dep_place ?? "?"} <span className="text-muted">{t5(e.dep_time)}</span> → {e.arr_place ?? "?"} <span className="text-muted">{t5(e.arr_time)}</span>
                    </span>
                    <span className="font-bold tabular-nums text-navy-2">{hm(e.total_min)}</span>
                  </div>
                  <p className="text-xs text-muted">
                    {frDate(e.flight_date)} · {[e.aircraft_model, e.aircraft_reg].filter(Boolean).join(" ")} · {[
                      e.pic_min && `CDB ${hm(e.pic_min)}`,
                      e.dual_min && `DC ${hm(e.dual_min)}`,
                      e.instructor_min && `INST ${hm(e.instructor_min)}`,
                      e.copilot_min && `COPI ${hm(e.copilot_min)}`,
                    ].filter(Boolean).join(" · ")} · {e.landings_day + e.landings_night} att.{e.night_min ? ` · nuit ${hm(e.night_min)}` : ""}
                  </p>
                  {(e.pic_name || e.remarks) && <p className="truncate text-xs text-muted">{[e.pic_name, e.remarks].filter(Boolean).join(" · ")}</p>}
                  <div className="mt-1 flex gap-4">
                    <button type="button" onClick={() => { setMsg(undefined); setMobileForm(e); window.scrollTo({ top: 0, behavior: "smooth" }); }} className="text-xs text-sky hover:underline">Modifier</button>
                    <button type="button" onClick={() => remove(e)} disabled={pending} className="text-xs text-danger hover:underline">Supprimer</button>
                  </div>
                </li>
              ))}
            </ul>
          )}
          <dl className="grid grid-cols-3 gap-2 border-t border-line bg-paper px-3 py-2 text-center text-xs">
            <MobTot label="Page" t={pageTot} />
            <MobTot label="Pages précédentes" t={before} />
            <MobTot label="Total" t={plus(before, pageTot)} strong />
          </dl>
        </div>
      </div>
    </section>
  );
}

function MobTot({ label, t, strong }: { label: string; t: Tot; strong?: boolean }) {
  return (
    <div>
      <dt className="text-[10px] font-semibold text-muted uppercase">{label}</dt>
      <dd className={`font-bold tabular-nums ${strong ? "text-navy-2" : "text-ink"}`}>{hm(t.total)}</dd>
      <dd className="text-[10px] text-muted">CDB {hm(t.pic)} · {t.ld + t.ln} att.</dd>
    </div>
  );
}

function Num({ v, bold }: { v: string; bold?: boolean }) {
  return <td className={`${TD} text-right tabular-nums ${bold ? "font-bold" : ""}`}>{v}</td>;
}

function TotRow({ label, t, muted, strong }: { label: string; t: Tot; muted?: boolean; strong?: boolean }) {
  const c = `${TD} text-right tabular-nums ${strong ? "bg-sky-soft text-navy-2" : muted ? "bg-paper text-muted" : "bg-paper"}`;
  return (
    <tr>
      <td className={`${TD} text-right ${strong ? "bg-sky-soft text-navy-2" : "bg-paper"}`} colSpan={7}>{label}</td>
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

// ── Saisie d'une ligne : état partagé par la ligne du tableau et la fiche du téléphone ──────

type Values = {
  flight_date: string; dep_place: string; dep_time: string; arr_place: string; arr_time: string; aircraft_model: string; aircraft_reg: string;
  se: string; me: string; multi_pilot: string; total: string; pic_name: string; landings_day: string; landings_night: string; ifr_approaches: string;
  night: string; ifr: string; pic: string; copilot: string; dual: string; instructor: string; sim_date: string; sim_type: string; sim: string; remarks: string;
};
type EntryProps = { entry: LogEntry | null; fleet: Plane[]; mine: Plane[]; today: string; prevArr: string | null; onDone: (m?: CarnetState) => void };

/** « 1410 » -> « 14:10 » pendant la frappe */
const maskTime = (s: string) => {
  const d = s.replace(/\D/g, "").slice(0, 4);
  return d.length > 2 ? `${d.slice(0, 2)}:${d.slice(2)}` : d;
};

function useEntry({ entry, fleet, mine, today, prevArr, onDone }: EntryProps) {
  const [state, action] = useActionState<CarnetState, FormData>(saveEntry, undefined);
  const [v, setV] = useState<Values>(() => ({
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

  const set = (k: keyof Values, val: string) => {
    if (k === "dep_time" || k === "arr_time") val = maskTime(val);
    if (k === "dep_place" || k === "arr_place") val = val.toUpperCase();
    if (k === "total") setTotalTouched(true);
    setV((o) => {
      const n = { ...o, [k]: val };
      if (k === "total") for (const f of Object.keys(follow)) if (follow[f]) (n as Record<string, string>)[f] = val;
      return n;
    });
    if (k in follow) setFollow((f) => ({ ...f, [k]: false }));
  };

  // Durée totale depuis les heures bloc
  useEffect(() => {
    if (totalTouched) return;
    const m = blockMinutes(v.dep_time, v.arr_time);
    if (m != null && v.dep_time.length === 5 && v.arr_time.length === 5 && hm(m) !== v.total)
      setV((o) => {
        const n = { ...o, total: hm(m) };
        for (const f of Object.keys(follow)) if (follow[f]) (n as Record<string, string>)[f] = hm(m);
        return n;
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [v.dep_time, v.arr_time, totalTouched]);

  useEffect(() => {
    if (state?.ok) onDone(state);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]);

  const known = [...fleet, ...mine];
  const [other, setOther] = useState(() => !!entry?.aircraft_reg && !known.some((p) => p.registration === entry.aircraft_reg));
  const pickReg = (val: string) => {
    if (val === "__autre") {
      setOther(true);
      setV((o) => ({ ...o, aircraft_reg: "" }));
      return;
    }
    const r = val.toUpperCase();
    const f = known.find((p) => p.registration === r);
    setV((o) => ({ ...o, aircraft_reg: r, aircraft_model: f ? f.model || o.aircraft_model : o.aircraft_model }));
  };
  const bad = (s: string) => parseDuration(s) == null;
  return { state, action, v, set, other, setOther, pickReg, bad };
}

const IN = "w-full min-w-0 rounded border border-line bg-white px-0.5 py-0.5 text-[11px] focus:border-navy-2 focus:outline-none";
const DUR = new Set<keyof Values>(["se", "me", "multi_pilot", "total", "night", "ifr", "pic", "copilot", "dual", "instructor", "sim"]);

/** Date JJ/MM/AAAA tapée au clavier (compacte), envoyée au format AAAA-MM-JJ */
function DateText({ value, onChange, form, name, required }: { value: string; onChange: (iso: string) => void; form?: string; name: string; required?: boolean }) {
  const [txt, setTxt] = useState(value ? frDate(value) : "");
  const ok = !txt || /^\d{2}\/\d{2}\/\d{4}$/.test(txt);
  return (
    <>
      <input type="hidden" form={form} name={name} value={value} />
      <input
        inputMode="numeric"
        placeholder="JJ/MM/AAAA"
        required={required}
        value={txt}
        onChange={(e) => {
          const d = e.target.value.replace(/\D/g, "").slice(0, 8);
          const t = [d.slice(0, 2), d.slice(2, 4), d.slice(4)].filter(Boolean).join("/");
          setTxt(t);
          const m = t.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
          onChange(m ? `${m[3]}-${m[2]}-${m[1]}` : "");
        }}
        className={`${IN} tabular-nums ${ok ? "" : "border-danger text-danger"}`}
      />
    </>
  );
}

function RegField({ h, fleet, mine, form, className }: { h: ReturnType<typeof useEntry>; fleet: Plane[]; mine: Plane[]; form?: string; className: string }) {
  if (h.other)
    return (
      <span className="flex items-center gap-0.5">
        <input form={form} name="aircraft_reg" autoFocus value={h.v.aircraft_reg} onChange={(e) => h.pickReg(e.target.value)} placeholder="F-GXXX" maxLength={20} className={`${className} uppercase`} />
        <button type="button" title="Choisir dans la liste" onClick={() => h.setOther(false)} className="text-[10px] text-sky hover:underline">liste</button>
      </span>
    );
  return (
    <>
      <input type="hidden" form={form} name="aircraft_reg" value={h.v.aircraft_reg} />
      <select value={h.v.aircraft_reg} onChange={(e) => h.pickReg(e.target.value)} className={className}>
        <option value="">—</option>
        <optgroup label="Avions du club">
          {fleet.map((p) => <option key={p.registration} value={p.registration}>{p.registration} · {p.model}</option>)}
        </optgroup>
        {mine.length > 0 && (
          <optgroup label="Mes autres avions">
            {mine.map((p) => <option key={p.registration} value={p.registration}>{p.registration}{p.model ? ` · ${p.model}` : ""}</option>)}
          </optgroup>
        )}
        <option value="__autre">＋ Autre immatriculation…</option>
      </select>
    </>
  );
}

/** Une ligne du carnet en saisie : mêmes colonnes que le carnet */
function EntryRow(props: EntryProps) {
  const h = useEntry(props);
  const { entry, fleet, mine, onDone } = props;
  const formId = `ligne-${entry?.id ?? "nouvelle"}`;
  const cell = `${TD} bg-wait-soft/60 p-0.5`;
  const inp = (k: keyof Values, ph?: string) => (
    <td className={cell}>
      <input
        form={formId}
        name={k}
        value={h.v[k]}
        inputMode={DUR.has(k) || k.includes("time") || k.startsWith("landings") || k === "ifr_approaches" ? "numeric" : undefined}
        placeholder={ph}
        onChange={(e) => h.set(k, e.target.value)}
        className={`${IN} ${DUR.has(k) ? "text-right tabular-nums" : ""} ${k === "total" ? "font-bold" : ""} ${DUR.has(k) && h.bad(h.v[k]) ? "border-danger text-danger" : ""}`}
      />
    </td>
  );
  return (
    <>
      <tr>
        <td className={cell}>
          <form id={formId} onSubmit={keepValues(h.action)} className="contents">
            <input type="hidden" name="id" value={entry?.id ?? ""} />
            <input type="hidden" name="kind" value="vol" />
          </form>
          <DateText form={formId} name="flight_date" required value={h.v.flight_date} onChange={(iso) => h.set("flight_date", iso)} />
        </td>
        {inp("dep_place", "LFMA")}
        {inp("dep_time", "HH:MM")}
        {inp("arr_place", "LFMA")}
        {inp("arr_time", "HH:MM")}
        {inp("aircraft_model", "DR400")}
        <td className={cell}><RegField h={h} fleet={fleet} mine={mine} form={formId} className={IN} /></td>
        {inp("se")}
        {inp("me")}
        {inp("multi_pilot")}
        {inp("total", "1:35")}
        {inp("pic_name")}
        {inp("landings_day")}
        {inp("landings_night")}
        {inp("ifr_approaches")}
        {inp("night")}
        {inp("ifr")}
        {inp("pic")}
        {inp("copilot")}
        {inp("dual")}
        {inp("instructor")}
        <td className={cell}><DateText form={formId} name="sim_date" value={h.v.sim_date} onChange={(iso) => h.set("sim_date", iso)} /></td>
        {inp("sim_type")}
        {inp("sim")}
        {inp("remarks", "Nav, TDP…")}
        <td className={`${cell} text-center`}>
          <button type="submit" form={formId} title={entry ? "Enregistrer" : "Ajouter au carnet"} className="w-full rounded bg-navy-2 px-0.5 py-0.5 text-[10.5px] font-semibold text-white hover:opacity-90">
            {entry ? "OK" : "＋"}
          </button>
          {entry && <button type="button" title="Annuler" onClick={() => onDone()} className="text-[10px] text-muted hover:underline">annuler</button>}
        </td>
      </tr>
      {h.state?.error && (
        <tr>
          <td colSpan={26} className="border border-line bg-danger-soft px-3 py-1.5 text-sm text-danger">{h.state.error}</td>
        </tr>
      )}
    </>
  );
}

/** Téléphone : la même ligne du carnet, rubrique par rubrique */
function EntryCard(props: EntryProps) {
  const h = useEntry(props);
  const { entry, fleet, mine, onDone, today } = props;
  const F = "field px-2 py-1.5 text-sm";
  const f = (k: keyof Values, label: string, ph?: string) => (
    <label className="block min-w-0">
      <span className="text-[11px] font-semibold text-muted">{label}</span>
      <input
        name={k}
        value={h.v[k]}
        inputMode={DUR.has(k) || k.includes("time") || k.startsWith("landings") || k === "ifr_approaches" ? "numeric" : undefined}
        placeholder={ph}
        onChange={(e) => h.set(k, e.target.value)}
        className={`${F} ${k === "total" ? "font-bold" : ""} ${DUR.has(k) && h.bad(h.v[k]) ? "border-danger text-danger" : ""}`}
      />
    </label>
  );
  // Rubrique du carnet (fonction, pas composant : les champs ne perdent pas le focus)
  const G = (title: string, cols: string, children: React.ReactNode) => (
    <fieldset className="rounded-lg border border-line p-2.5">
      <legend className="px-1 text-xs font-bold text-navy-2">{title}</legend>
      <div className={`grid gap-2 ${cols}`}>{children}</div>
    </fieldset>
  );
  return (
    <form onSubmit={keepValues(h.action)} className="card mb-3 space-y-2.5 p-3">
      <input type="hidden" name="id" value={entry?.id ?? ""} />
      <input type="hidden" name="kind" value="vol" />
      <div className="flex items-center justify-between">
        <h3 className="font-bold text-navy-2">{entry ? "Modifier le vol" : "Nouveau vol"}</h3>
        <button type="button" onClick={() => onDone()} className="text-sm text-muted hover:underline">Fermer</button>
      </div>
      <label className="block">
        <span className="text-[11px] font-semibold text-muted">Date</span>
        <input type="date" name="flight_date" required max={today} value={h.v.flight_date} onChange={(e) => h.set("flight_date", e.target.value)} className={F} />
      </label>
      {G("Départ", "grid-cols-2", <>{f("dep_place", "Lieu", "LFMA")}{f("dep_time", "Heure", "HH:MM")}</>)}
      {G("Arrivée", "grid-cols-2", <>{f("arr_place", "Lieu", "LFMA")}{f("arr_time", "Heure", "HH:MM")}</>)}
      {G("Aéronef", "grid-cols-2", <>
        <label className="block min-w-0">
          <span className="text-[11px] font-semibold text-muted">Immat</span>
          <RegField h={h} fleet={fleet} mine={mine} className={`${F} w-full`} />
        </label>
        {f("aircraft_model", "Modèle", "DR400")}
      </>)}
      {G("Temps de vol", "grid-cols-4", <>
        {f("se", "SE")}{f("me", "ME")}{f("multi_pilot", "Multi-pil.")}{f("total", "Total", "1:35")}
      </>)}
      {f("pic_name", "Nom du commandant de bord")}
      {G("Atterrissages", "grid-cols-3", <>{f("landings_day", "Jour")}{f("landings_night", "Nuit")}{f("ifr_approaches", "IFR APCH")}</>)}
      {G("Conditions opérationnelles", "grid-cols-2", <>{f("night", "Nuit")}{f("ifr", "IFR")}</>)}
      {G("Temps comme pilote en fonction", "grid-cols-4", <>{f("pic", "CDB")}{f("copilot", "COPI")}{f("dual", "DC")}{f("instructor", "INST")}</>)}
      <details className="rounded-lg border border-line p-2.5">
        <summary className="cursor-pointer text-xs font-bold text-navy-2">Séance de simulateur</summary>
        <div className="mt-2 grid grid-cols-3 gap-2">
          <label className="block min-w-0">
            <span className="text-[11px] font-semibold text-muted">Date</span>
            <input type="date" name="sim_date" value={h.v.sim_date} onChange={(e) => h.set("sim_date", e.target.value)} className={F} />
          </label>
          {f("sim_type", "Type")}{f("sim", "Durée")}
        </div>
      </details>
      {f("remarks", "Remarques et appositions", "Nav, tours de piste…")}
      {h.state?.error && <p className="rounded-lg bg-danger-soft px-3 py-2 text-sm text-danger">{h.state.error}</p>}
      <button type="submit" className="btn-primary w-full">{entry ? "Enregistrer" : "Ajouter au carnet"}</button>
    </form>
  );
}
