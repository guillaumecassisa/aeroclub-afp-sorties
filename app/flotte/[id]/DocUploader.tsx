"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createBrowserSupabase } from "@/lib/supabase/client";
import { DOC_BUCKET, DOC_CATEGORIES, safeFileName, titleFromFileName } from "@/lib/docs";
import { registerDocument } from "../actions";

type Row = { id: string; file: File; title: string; category: string; status: "pending" | "uploading" | "done" | "error"; error?: string };

const MAX = 50 * 1024 * 1024;
const ALLOWED_MIME = new Set([
  "application/pdf",
  "image/jpeg", "image/png", "image/webp", "image/gif", "image/svg+xml",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "text/plain", "text/csv",
]);

export function DocUploader({ aircraftId }: { aircraftId: string }) {
  const router = useRouter();
  const input = useRef<HTMLInputElement>(null);
  const [rows, setRows] = useState<Row[]>([]);
  const [category, setCategory] = useState<string>("manuel");
  const [busy, setBusy] = useState(false);

  function pick(files: FileList | null) {
    if (!files) return;
    setRows((cur) => [
      ...cur.filter((r) => r.status !== "done"),
      ...Array.from(files).map((f) => {
        const mimeOk = !f.type || ALLOWED_MIME.has(f.type);
        return {
          id: `${Date.now()}-${Math.random()}`,
          file: f,
          title: titleFromFileName(f.name),
          category,
          status: "pending" as const,
          error: f.size > MAX ? "Fichier trop lourd (50 Mo maximum)." : !mimeOk ? `Type de fichier non autorisé (${f.type}).` : undefined,
        };
      }),
    ]);
    if (input.current) input.current.value = "";
  }

  const update = (i: number, patch: Partial<Row>) => setRows((cur) => cur.map((r, j) => (j === i ? { ...r, ...patch } : r)));

  async function send() {
    setBusy(true);
    const supabase = createBrowserSupabase();
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      if (r.status === "done" || r.file.size > MAX || (r.file.type && !ALLOWED_MIME.has(r.file.type))) continue;
      update(i, { status: "uploading", error: undefined });
      const path = `${aircraftId}/${Date.now()}-${safeFileName(r.file.name)}`;
      const { error } = await supabase.storage
        .from(DOC_BUCKET)
        .upload(path, r.file, { contentType: r.file.type || "application/octet-stream", upsert: false });
      if (error) {
        update(i, { status: "error", error: `Envoi impossible : ${error.message}` });
        continue;
      }
      const res = await registerDocument({
        aircraftId,
        category: r.category,
        title: r.title,
        path,
        fileName: r.file.name,
        mime: r.file.type || null,
        size: r.file.size,
      });
      update(i, res.error ? { status: "error", error: res.error } : { status: "done" });
    }
    setBusy(false);
    router.refresh();
  }

  const pending = rows.filter((r) => r.status !== "done" && r.file.size <= MAX && (!r.file.type || ALLOWED_MIME.has(r.file.type))).length;

  return (
    <section className="card mt-8 border-t-[3px] border-t-navy-2 p-5">
      <h2 className="font-bold text-navy-2">Ajouter des documents</h2>
      <p className="mt-0.5 text-sm text-muted">
        PDF, images, documents… jusqu&apos;à 50 Mo par fichier. Vous pouvez en sélectionner plusieurs à la fois, puis ajuster le
        titre et la catégorie de chacun avant l&apos;envoi.
      </p>

      <div className="mt-4 flex flex-wrap items-end gap-3">
        <div>
          <label className="label" htmlFor="defcat">Catégorie par défaut</label>
          <select id="defcat" className="field w-auto" value={category} onChange={(e) => setCategory(e.target.value)}>
            {DOC_CATEGORIES.map((c) => (
              <option key={c.key} value={c.key}>
                {c.label}
              </option>
            ))}
          </select>
        </div>
        <label className="btn-secondary cursor-pointer">
          Choisir des fichiers…
          <input ref={input} type="file" multiple className="sr-only" onChange={(e) => pick(e.target.files)} />
        </label>
      </div>
      <p className="mt-1 text-xs text-muted">{DOC_CATEGORIES.find((c) => c.key === category)?.hint}</p>

      {rows.length > 0 && (
        <ul className="mt-4 space-y-2">
          {rows.map((r, i) => (
            <li key={r.id} className="rounded-lg border border-line bg-paper p-3">
              <div className="flex flex-wrap items-center gap-2">
                <input
                  className="field min-w-48 flex-1 py-1.5 text-sm"
                  value={r.title}
                  onChange={(e) => update(i, { title: e.target.value })}
                  disabled={r.status === "done" || busy}
                  aria-label="Titre du document"
                />
                <select
                  className="field w-auto py-1.5 text-sm"
                  value={r.category}
                  onChange={(e) => update(i, { category: e.target.value })}
                  disabled={r.status === "done" || busy}
                  aria-label="Catégorie"
                >
                  {DOC_CATEGORIES.map((c) => (
                    <option key={c.key} value={c.key}>
                      {c.label}
                    </option>
                  ))}
                </select>
                <span className="text-xs">
                  {r.status === "uploading" && <span className="text-wait">Envoi…</span>}
                  {r.status === "done" && <span className="font-semibold text-ok">✓ Ajouté</span>}
                </span>
                {r.status !== "done" && !busy && (
                  <button
                    type="button"
                    onClick={() => setRows((cur) => cur.filter((_, j) => j !== i))}
                    className="rounded px-1.5 text-muted hover:bg-danger-soft hover:text-danger"
                    aria-label="Retirer"
                  >
                    ✕
                  </button>
                )}
              </div>
              <p className="mt-1 truncate text-xs text-muted">{r.file.name}</p>
              {r.error && <p className="mt-1 text-xs font-semibold text-danger">{r.error}</p>}
            </li>
          ))}
        </ul>
      )}

      {pending > 0 && (
        <button type="button" onClick={send} disabled={busy} className="btn-primary mt-4">
          {busy ? "Envoi en cours…" : `Envoyer ${pending} document${pending > 1 ? "s" : ""}`}
        </button>
      )}
    </section>
  );
}
