"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { hm } from "@/lib/carnet";
import {
  IMPORT_FIELDS,
  buildRows,
  decodeFile,
  dupKey,
  guessMapping,
  parseCsv,
  type Fn,
  type ImportField,
} from "@/lib/carnetImport";
import { importEntries } from "../actions";

const frDate = (d: string) => new Date(d + "T12:00:00Z").toLocaleDateString("fr-FR", { timeZone: "UTC" });

export function ImportClient({ existing }: { existing: string[] }) {
  const router = useRouter();
  const [fileName, setFileName] = useState("");
  const [rows, setRows] = useState<string[][]>([]);
  const [headerRow, setHeaderRow] = useState(0);
  const [mapping, setMapping] = useState<(ImportField | "")[]>([]);
  const [defaultFn, setDefaultFn] = useState<Fn>("cdb");
  const [msg, setMsg] = useState<{ ok?: string; error?: string }>();
  const [progress, setProgress] = useState<string>();
  const [pending, start] = useTransition();

  async function onFile(f: File | undefined) {
    setMsg(undefined);
    if (!f) return;
    if (f.size > 5_000_000) return setMsg({ error: "Fichier trop lourd (5 Mo maximum)." });
    if (/\.xlsx?$/i.test(f.name))
      return setMsg({ error: "C'est un fichier Excel : ouvrez-le puis « Enregistrer sous » → CSV (séparateur point-virgule), et importez ce CSV." });
    const text = decodeFile(await f.arrayBuffer());
    const parsed = parseCsv(text);
    if (parsed.length < 2) return setMsg({ error: "Fichier vide ou illisible." });
    const g = guessMapping(parsed);
    setFileName(f.name);
    setRows(parsed);
    setHeaderRow(g.headerRow);
    setMapping(g.mapping);
  }

  const width = useMemo(() => Math.max(0, ...rows.map((r) => r.length)), [rows]);
  const header = rows[headerRow] ?? [];
  const result = useMemo(() => (rows.length ? buildRows(rows, headerRow, mapping, defaultFn) : { rows: [], errors: [] }), [rows, headerRow, mapping, defaultFn]);
  const seen = useMemo(() => new Set(existing), [existing]);
  const fresh = useMemo(() => {
    const s = new Set(seen);
    return result.rows.filter((r) => {
      const k = dupKey(r);
      if (s.has(k)) return false;
      s.add(k);
      return true;
    });
  }, [result.rows, seen]);
  const dups = result.rows.length - fresh.length;
  const totalMin = fresh.reduce((a, r) => a + r.total_min, 0);
  const hasDate = mapping.includes("date");
  const hasDuration = mapping.includes("total") || (mapping.includes("dep_time") && mapping.includes("arr_time"));
  const hasFunction = mapping.some((m) => m === "function" || m === "pic" || m === "dual" || m === "instructor");

  function setCol(i: number, f: ImportField | "") {
    setMapping((m) => {
      const next = [...m];
      while (next.length < width) next.push("");
      if (f) next.forEach((v, j) => v === f && (next[j] = ""));
      next[i] = f;
      return next;
    });
  }

  function doImport() {
    setMsg(undefined);
    start(async () => {
      let inserted = 0, skipped = 0;
      for (let i = 0; i < fresh.length; i += 800) {
        setProgress(`Import… ${Math.min(i + 800, fresh.length)} / ${fresh.length}`);
        const res = await importEntries(JSON.stringify(fresh.slice(i, i + 800)));
        if (res?.error) {
          setProgress(undefined);
          return setMsg({ error: res.error + (inserted ? ` (${inserted} vols déjà importés)` : "") });
        }
        inserted += res?.inserted ?? 0;
        skipped += res?.skipped ?? 0;
      }
      setProgress(undefined);
      setMsg({ ok: `${inserted} vol${inserted > 1 ? "s" : ""} ajouté${inserted > 1 ? "s" : ""} à votre carnet${skipped ? ` (${skipped} ignoré${skipped > 1 ? "s" : ""})` : ""}.` });
      setRows([]);
      setFileName("");
      router.refresh();
    });
  }

  return (
    <div className="space-y-4">
      {/* 1. Exporter depuis Aerogest */}
      <section className="rounded-2xl border border-line bg-white p-4 shadow-sm">
        <h2 className="text-sm font-bold text-navy-2">1. Exportez vos vols depuis Aerogest</h2>
        <ol className="mt-1 list-decimal space-y-0.5 pl-5 text-sm text-ink">
          <li>Connectez-vous à Aerogest et ouvrez la liste de vos vols (carnet de vol / mes vols).</li>
          <li>Choisissez la période la plus large possible (depuis votre premier vol).</li>
          <li>Exportez au format <b>CSV</b>. Si vous n&apos;avez qu&apos;un export Excel, ouvrez-le puis « Enregistrer sous » → CSV.</li>
        </ol>
      </section>

      {/* 2. Choisir le fichier */}
      <section className="rounded-2xl border border-line bg-white p-4 shadow-sm">
        <h2 className="text-sm font-bold text-navy-2">2. Choisissez le fichier CSV</h2>
        <label className="mt-2 flex cursor-pointer flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-line bg-paper px-4 py-6 text-center hover:border-navy-2">
          <span className="text-2xl">📄</span>
          <span className="text-sm font-semibold text-navy-2">{fileName || "Cliquez pour choisir votre fichier .csv"}</span>
          <span className="text-xs text-muted">{fileName ? `${rows.length - headerRow - 1} lignes lues` : "Séparateur ; , ou tabulation · 5 Mo maximum"}</span>
          <input type="file" accept=".csv,.txt,text/csv,.xls,.xlsx" className="sr-only" onChange={(e) => onFile(e.target.files?.[0])} />
        </label>
        {msg?.error && <p className="mt-2 rounded-lg bg-danger-soft px-3 py-2 text-sm text-danger">{msg.error}</p>}
        {msg?.ok && (
          <p className="mt-2 rounded-lg bg-ok-soft px-3 py-2 text-sm text-ok">
            ✓ {msg.ok}{" "}
            <a href="/carnet" className="font-semibold underline">
              Voir mon carnet
            </a>
          </p>
        )}
      </section>

      {rows.length > 0 && (
        <>
          {/* 3. Colonnes */}
          <section className="rounded-2xl border border-line bg-white p-4 shadow-sm">
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <h2 className="text-sm font-bold text-navy-2">3. Vérifiez la correspondance des colonnes</h2>
              <label className="text-xs text-muted">
                Ligne d&apos;en-tête{" "}
                <select className="field ml-1 inline-block w-auto py-0.5 text-xs" value={headerRow} onChange={(e) => {
                  const h = Number(e.target.value);
                  setHeaderRow(h);
                }}>
                  {rows.slice(0, 10).map((_, i) => (
                    <option key={i} value={i}>
                      {i + 1}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            <div className="mt-2 grid gap-x-4 gap-y-1.5 sm:grid-cols-2 lg:grid-cols-3">
              {Array.from({ length: width }, (_, i) => (
                <label key={i} className="flex min-w-0 items-center gap-2 text-sm">
                  <span className="w-28 shrink-0 truncate font-semibold text-ink" title={header[i]}>
                    {header[i] || `Colonne ${i + 1}`}
                  </span>
                  <select className="field min-w-0 flex-1 py-1 text-xs" value={mapping[i] ?? ""} onChange={(e) => setCol(i, e.target.value as ImportField | "")}>
                    <option value="">— ignorer —</option>
                    {IMPORT_FIELDS.map((f) => (
                      <option key={f.value} value={f.value}>
                        {f.label}
                      </option>
                    ))}
                  </select>
                </label>
              ))}
            </div>
            {!hasFunction && (
              <p className="mt-3 text-sm text-ink">
                Aucune colonne « fonction » : ces vols sont comptés comme{" "}
                <select className="field inline-block w-auto py-0.5 text-sm" value={defaultFn} onChange={(e) => setDefaultFn(e.target.value as Fn)}>
                  <option value="cdb">Commandant de bord (CDB)</option>
                  <option value="dc">Double commande (élève)</option>
                  <option value="inst">Instructeur</option>
                </select>
              </p>
            )}
            {(!hasDate || !hasDuration) && (
              <p className="mt-2 rounded-lg bg-danger-soft px-3 py-2 text-sm text-danger">
                Indiquez au moins la colonne <b>Date du vol</b> et la colonne <b>Durée du vol</b> (ou les heures de départ et d&apos;arrivée).
              </p>
            )}
          </section>

          {/* 4. Aperçu */}
          <section className="rounded-2xl border border-line bg-white p-4 shadow-sm">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <h2 className="text-sm font-bold text-navy-2">
                4. Aperçu : {fresh.length} vol{fresh.length > 1 ? "s" : ""} à importer · {hm(totalMin)} de vol
              </h2>
              <button type="button" className="btn-primary" disabled={pending || !fresh.length || !hasDate || !hasDuration} onClick={doImport}>
                {progress ?? `Importer ${fresh.length} vol${fresh.length > 1 ? "s" : ""}`}
              </button>
            </div>
            {(dups > 0 || result.errors.length > 0) && (
              <p className="mt-1 text-xs text-muted">
                {dups > 0 && `${dups} vol${dups > 1 ? "s" : ""} déjà dans votre carnet (ignoré${dups > 1 ? "s" : ""}). `}
                {result.errors.length > 0 && `${result.errors.length} ligne${result.errors.length > 1 ? "s" : ""} non reconnue${result.errors.length > 1 ? "s" : ""} : `}
                {result.errors.slice(0, 5).map((e) => `ligne ${e.line} (${e.message})`).join(", ")}
                {result.errors.length > 5 && "…"}
              </p>
            )}
            <div className="mt-2 overflow-x-auto">
              <table className="w-full min-w-[720px] text-xs">
                <thead>
                  <tr className="border-b border-line text-left text-muted">
                    {["Date", "Départ", "Arrivée", "Appareil", "Durée", "Att.", "Nuit", "CDB", "DC", "INST", "Remarques"].map((h) => (
                      <th key={h} className="px-1.5 py-1 font-semibold">
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody className="divide-y divide-line">
                  {fresh.slice(0, 15).map((r) => (
                    <tr key={r.line}>
                      <td className="px-1.5 py-1 whitespace-nowrap">{frDate(r.flight_date)}</td>
                      <td className="px-1.5 py-1 whitespace-nowrap">
                        {r.dep_place ?? "—"} {r.dep_time && <span className="text-muted">{r.dep_time}</span>}
                      </td>
                      <td className="px-1.5 py-1 whitespace-nowrap">
                        {r.arr_place ?? "—"} {r.arr_time && <span className="text-muted">{r.arr_time}</span>}
                      </td>
                      <td className="px-1.5 py-1 whitespace-nowrap">
                        {r.aircraft_reg ?? "—"} {r.aircraft_model && <span className="text-muted">{r.aircraft_model}</span>}
                      </td>
                      <td className="px-1.5 py-1 font-semibold tabular-nums">{hm(r.total_min)}</td>
                      <td className="px-1.5 py-1 tabular-nums">{r.landings_day + r.landings_night}</td>
                      <td className="px-1.5 py-1 tabular-nums">{r.night_min ? hm(r.night_min) : ""}</td>
                      <td className="px-1.5 py-1 tabular-nums">{r.pic_min ? hm(r.pic_min) : ""}</td>
                      <td className="px-1.5 py-1 tabular-nums">{r.dual_min ? hm(r.dual_min) : ""}</td>
                      <td className="px-1.5 py-1 tabular-nums">{r.instructor_min ? hm(r.instructor_min) : ""}</td>
                      <td className="max-w-[200px] truncate px-1.5 py-1 text-muted">{r.remarks}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {fresh.length > 15 && <p className="mt-1 text-xs text-muted">… et {fresh.length - 15} autres vols.</p>}
            </div>
            <p className="mt-2 text-[11px] text-muted">
              Sans colonne « atterrissages », 1 atterrissage de jour est compté par vol. Vous pourrez corriger chaque ligne ensuite dans votre carnet.
            </p>
          </section>
        </>
      )}
    </div>
  );
}
