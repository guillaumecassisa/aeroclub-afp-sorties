"use client";

import { useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { unzipSync } from "fflate";
import { createBrowserSupabase } from "@/lib/supabase/client";
import { DOC_BUCKET, DOC_CATEGORIES, cleanTitle, formatSize, guessCategory, registrationIn, safeFileName } from "@/lib/docs";
import { registerDocument } from "../actions";

type Status = "ready" | "uploading" | "done" | "error" | "skipped";
type Row = {
  key: string;
  source: File;
  entry: string | null; // chemin dans l'archive, ou null pour un fichier déposé directement
  name: string;
  size: number;
  aircraftId: string;
  title: string;
  category: string;
  include: boolean;
  status: Status;
  note?: string;
};

const MAX = 50 * 1024 * 1024;
const MIME: Record<string, string> = {
  pdf: "application/pdf",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
  doc: "application/msword",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel",
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  txt: "text/plain",
};
const mimeOf = (name: string) => MIME[(name.split(".").pop() ?? "").toLowerCase()] ?? "application/octet-stream";

export function BulkImport({ fleet, existing }: { fleet: { id: string; registration: string }[]; existing: string[] }) {
  const router = useRouter();
  const input = useRef<HTMLInputElement>(null);
  const [rows, setRows] = useState<Row[]>([]);
  const [busy, setBusy] = useState(false);
  const [reading, setReading] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const known = useMemo(() => new Set(existing), [existing]);
  const byReg = useMemo(() => new Map(fleet.map((a) => [a.registration.toUpperCase(), a.id])), [fleet]);

  function makeRow(source: File, entry: string | null, name: string, size: number): Row {
    const reg = registrationIn(name) ?? registrationIn(source.name);
    const aircraftId = (reg && byReg.get(reg)) || "";
    const title = cleanTitle(name, reg);
    const dup = aircraftId && known.has(`${aircraftId}|${title.toLowerCase()}`);
    const tooBig = size > MAX;
    return {
      key: `${source.name}|${entry ?? ""}|${Math.random()}`,
      source,
      entry,
      name,
      size,
      aircraftId,
      title,
      category: guessCategory(name),
      include: !dup && !tooBig && !!aircraftId,
      status: dup ? "skipped" : "ready",
      note: dup
        ? "Déjà présent sur cet avion"
        : tooBig
          ? "Fichier trop lourd (50 Mo maximum)"
          : !aircraftId
            ? reg
              ? `${reg} n'est pas dans la flotte`
              : "Avion non reconnu : choisissez-le"
            : undefined,
    };
  }

  async function pick(files: FileList | null) {
    if (!files?.length) return;
    setReading(true);
    setProblem(null);
    const added: Row[] = [];
    for (const f of Array.from(files)) {
      if (/\.zip$/i.test(f.name)) {
        try {
          const buf = new Uint8Array(await f.arrayBuffer());
          // Lecture de la liste seulement (rien n'est décompressé ici)
          unzipSync(buf, {
            filter: (e) => {
              const base = e.name.split("/").pop() ?? "";
              if (!e.name.endsWith("/") && base && !base.startsWith(".") && !e.name.startsWith("__MACOSX"))
                added.push(makeRow(f, e.name, e.name, e.originalSize));
              return false;
            },
          });
        } catch {
          setProblem(`Archive illisible : ${f.name}`);
        }
      } else {
        added.push(makeRow(f, null, f.name, f.size));
      }
    }
    setRows((cur) => [...cur.filter((r) => r.status !== "done"), ...added]);
    setReading(false);
    if (input.current) input.current.value = "";
  }

  const update = (key: string, patch: Partial<Row>) => setRows((cur) => cur.map((r) => (r.key === key ? { ...r, ...patch } : r)));

  async function send() {
    setBusy(true);
    const supabase = createBrowserSupabase();
    const todo = rows.filter((r) => r.include && r.aircraftId && r.status !== "done" && r.size <= MAX);
    // Regroupe par archive pour ne la décompresser qu'une fois
    const groups = new Map<File, Row[]>();
    for (const r of todo) groups.set(r.source, [...(groups.get(r.source) ?? []), r]);

    for (const [source, list] of groups) {
      let files: Record<string, Uint8Array> = {};
      if (list.some((r) => r.entry)) {
        try {
          const wanted = new Set(list.map((r) => r.entry));
          files = unzipSync(new Uint8Array(await source.arrayBuffer()), { filter: (e) => wanted.has(e.name) });
        } catch {
          list.forEach((r) => update(r.key, { status: "error", note: "Archive illisible." }));
          continue;
        }
      }
      for (const r of list) {
        update(r.key, { status: "uploading", note: undefined });
        const base = r.name.split("/").pop() ?? r.name;
        const data = r.entry ? files[r.entry] : r.source;
        if (!data) {
          update(r.key, { status: "error", note: "Fichier introuvable dans l'archive." });
          continue;
        }
        const body = data instanceof Uint8Array ? new Blob([data as BlobPart], { type: mimeOf(base) }) : data;
        const path = `${r.aircraftId}/${Date.now()}-${safeFileName(base)}`;
        const { error } = await supabase.storage
          .from(DOC_BUCKET)
          .upload(path, body, { contentType: mimeOf(base), upsert: false });
        if (error) {
          update(r.key, { status: "error", note: `Envoi impossible : ${error.message}` });
          continue;
        }
        const res = await registerDocument({
          aircraftId: r.aircraftId,
          category: r.category,
          title: r.title,
          path,
          fileName: base,
          mime: mimeOf(base),
          size: r.size,
        });
        update(r.key, res.error ? { status: "error", note: res.error } : { status: "done", include: false });
      }
      files = {};
    }
    setBusy(false);
    router.refresh();
  }

  const selected = rows.filter((r) => r.include && r.aircraftId && r.status !== "done");
  const done = rows.filter((r) => r.status === "done").length;
  const errors = rows.filter((r) => r.status === "error").length;
  const totalSize = selected.reduce((s, r) => s + r.size, 0);
  const regOf = (id: string) => fleet.find((a) => a.id === id)?.registration ?? "";
  const sorted = [...rows].sort(
    (a, b) => regOf(a.aircraftId).localeCompare(regOf(b.aircraftId)) || a.category.localeCompare(b.category) || a.title.localeCompare(b.title),
  );

  return (
    <section className="card p-5">
      <label
        className="flex cursor-pointer flex-col items-center justify-center rounded-lg border-2 border-dashed border-line bg-paper px-4 py-8 text-center hover:border-navy-2/40"
        onDragOver={(e) => e.preventDefault()}
        onDrop={(e) => {
          e.preventDefault();
          if (!busy) pick(e.dataTransfer.files);
        }}
      >
        <span className="text-3xl" aria-hidden>
          📦
        </span>
        <span className="mt-2 font-semibold text-navy-2">Glissez ici vos archives .zip ou vos fichiers</span>
        <span className="text-sm text-muted">ou cliquez pour les choisir (plusieurs à la fois)</span>
        <input
          ref={input}
          type="file"
          multiple
          accept=".zip,.pdf,.jpg,.jpeg,.png,.webp,.doc,.docx,.xls,.xlsx,.txt"
          className="sr-only"
          disabled={busy}
          onChange={(e) => pick(e.target.files)}
        />
      </label>
      {reading && <p className="mt-3 text-sm text-wait">Lecture des archives…</p>}
      {problem && <p className="mt-3 text-sm font-semibold text-danger">{problem}</p>}

      {rows.length > 0 && (
        <>
          <div className="mt-5 flex flex-wrap items-center gap-3">
            <p className="text-sm text-ink">
              <strong>{selected.length}</strong> document{selected.length > 1 ? "s" : ""} à envoyer ({formatSize(totalSize) || "0 Ko"})
              {done > 0 && <span className="text-ok"> · {done} ajouté{done > 1 ? "s" : ""}</span>}
              {errors > 0 && <span className="text-danger"> · {errors} en erreur</span>}
            </p>
            <button
              type="button"
              onClick={send}
              disabled={busy || selected.length === 0}
              className="btn-primary ml-auto disabled:opacity-50"
            >
              {busy ? "Envoi en cours…" : `Envoyer ${selected.length} document${selected.length > 1 ? "s" : ""}`}
            </button>
          </div>
          {busy && <p className="mt-1 text-xs text-muted">Gardez cette page ouverte jusqu&apos;à la fin de l&apos;envoi.</p>}

          <div className="mt-3 overflow-x-auto">
            <table className="w-full min-w-[720px] text-sm">
              <thead>
                <tr className="border-b border-line text-left text-xs text-muted">
                  <th className="py-2 pr-2">Envoyer</th>
                  <th className="py-2 pr-2">Avion</th>
                  <th className="py-2 pr-2">Titre</th>
                  <th className="py-2 pr-2">Catégorie</th>
                  <th className="py-2 pr-2 text-right">Taille</th>
                  <th className="py-2">État</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-line">
                {sorted.map((r) => {
                  const locked = busy || r.status === "done" || r.status === "uploading";
                  return (
                    <tr key={r.key} className={r.include || r.status === "done" ? "" : "opacity-60"}>
                      <td className="py-1.5 pr-2">
                        <input
                          type="checkbox"
                          className="h-4 w-4"
                          checked={r.include}
                          disabled={locked || !r.aircraftId || r.size > MAX}
                          onChange={(e) => update(r.key, { include: e.target.checked })}
                          aria-label={`Envoyer ${r.title}`}
                        />
                      </td>
                      <td className="py-1.5 pr-2">
                        <select
                          className="field w-auto py-1 font-mono text-xs"
                          value={r.aircraftId}
                          disabled={locked}
                          onChange={(e) =>
                            update(r.key, {
                              aircraftId: e.target.value,
                              include: !!e.target.value && r.size <= MAX,
                              status: "ready",
                              note: undefined,
                            })
                          }
                          aria-label="Avion"
                        >
                          <option value="">—</option>
                          {fleet.map((a) => (
                            <option key={a.id} value={a.id}>
                              {a.registration}
                            </option>
                          ))}
                        </select>
                      </td>
                      <td className="py-1.5 pr-2">
                        <input
                          className="field py-1 text-xs"
                          value={r.title}
                          disabled={locked}
                          onChange={(e) => update(r.key, { title: e.target.value })}
                          aria-label="Titre"
                        />
                      </td>
                      <td className="py-1.5 pr-2">
                        <select
                          className="field w-auto py-1 text-xs"
                          value={r.category}
                          disabled={locked}
                          onChange={(e) => update(r.key, { category: e.target.value })}
                          aria-label="Catégorie"
                        >
                          {DOC_CATEGORIES.map((c) => (
                            <option key={c.key} value={c.key}>
                              {c.label}
                            </option>
                          ))}
                        </select>
                      </td>
                      <td className="py-1.5 pr-2 text-right text-xs whitespace-nowrap text-muted">{formatSize(r.size)}</td>
                      <td className="py-1.5 text-xs">
                        {r.status === "uploading" && <span className="text-wait">Envoi…</span>}
                        {r.status === "done" && <span className="font-semibold text-ok">✓ Ajouté</span>}
                        {r.status === "error" && <span className="font-semibold text-danger">{r.note}</span>}
                        {(r.status === "ready" || r.status === "skipped") && r.note && <span className="text-muted">{r.note}</span>}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </section>
  );
}
