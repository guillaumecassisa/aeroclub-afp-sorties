"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createBrowserSupabase } from "@/lib/supabase/client";
import { safeFileName, titleFromFileName } from "@/lib/docs";
import { PEDA_BUCKET, PEDA_CATEGORIES } from "@/lib/pedagogie";
import { registerPedaDocument } from "./actions";

type Row = { id: string; file: File; title: string; category: string; status: "pending" | "uploading" | "done" | "error"; error?: string };

const MAX = 50 * 1024 * 1024;
const ALLOWED_MIME = new Set([
  "application/pdf",
  "image/jpeg", "image/png", "image/webp",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-powerpoint",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "text/plain",
  "video/mp4",
]);

export function PedaUploader() {
  const router = useRouter();
  const input = useRef<HTMLInputElement>(null);
  const [rows, setRows] = useState<Row[]>([]);
  const [category, setCategory] = useState<string>("cours");
  const [busy, setBusy] = useState(false);

  const invalid = (f: File) =>
    f.size > MAX ? "Fichier trop lourd (50 Mo maximum)." : f.type && !ALLOWED_MIME.has(f.type) ? `Type de fichier non autorisé (${f.type}).` : undefined;

  function pick(files: FileList | null) {
    if (!files) return;
    setRows((cur) => [
      ...cur.filter((r) => r.status !== "done"),
      ...Array.from(files).map((f) => ({
        id: `${Date.now()}-${Math.random()}`,
        file: f,
        title: titleFromFileName(f.name),
        category,
        status: "pending" as const,
        error: invalid(f),
      })),
    ]);
    if (input.current) input.current.value = "";
  }

  const update = (i: number, patch: Partial<Row>) => setRows((cur) => cur.map((r, j) => (j === i ? { ...r, ...patch } : r)));

  async function send() {
    setBusy(true);
    const supabase = createBrowserSupabase();
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i];
      if (r.status === "done" || invalid(r.file)) continue;
      update(i, { status: "uploading", error: undefined });
      const path = `${r.category}/${Date.now()}-${safeFileName(r.file.name)}`;
      const { error } = await supabase.storage
        .from(PEDA_BUCKET)
        .upload(path, r.file, { contentType: r.file.type || "application/octet-stream", upsert: false });
      if (error) {
        update(i, { status: "error", error: `Envoi impossible : ${error.message}` });
        continue;
      }
      const res = await registerPedaDocument({
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

  const ready = rows.filter((r) => r.status !== "done" && !invalid(r.file)).length;

  return (
    <div className="card space-y-3 p-4">
      <h3 className="font-semibold text-navy-2">Ajouter des documents</h3>
      <div className="flex flex-wrap items-end gap-2">
        <div>
          <label htmlFor="peda-cat" className="label">Rubrique</label>
          <select id="peda-cat" className="field" value={category} onChange={(e) => setCategory(e.target.value)}>
            {PEDA_CATEGORIES.map((c) => (
              <option key={c.key} value={c.key}>{c.label}</option>
            ))}
          </select>
        </div>
        <label className="btn-secondary cursor-pointer">
          Choisir des fichiers
          <input ref={input} type="file" multiple className="sr-only" onChange={(e) => pick(e.target.files)} />
        </label>
      </div>
      <p className="text-xs text-muted">PDF, Word, PowerPoint, Excel, images ou vidéos MP4 — 50 Mo maximum par fichier. Réservé aux membres du club.</p>

      {rows.length > 0 && (
        <ul className="divide-y divide-line rounded-lg border border-line">
          {rows.map((r, i) => (
            <li key={r.id} className="flex flex-wrap items-center gap-2 px-3 py-2 text-sm">
              <input
                className="field min-w-0 flex-1 py-1"
                value={r.title}
                onChange={(e) => update(i, { title: e.target.value })}
                disabled={r.status === "done" || r.status === "uploading"}
                aria-label="Titre"
              />
              <select
                className="field w-48 py-1"
                value={r.category}
                onChange={(e) => update(i, { category: e.target.value })}
                disabled={r.status === "done" || r.status === "uploading"}
                aria-label="Rubrique"
              >
                {PEDA_CATEGORIES.map((c) => (
                  <option key={c.key} value={c.key}>{c.label}</option>
                ))}
              </select>
              <span className="w-28 text-right text-xs">
                {r.status === "done" ? (
                  <span className="text-ok">✓ Ajouté</span>
                ) : r.status === "uploading" ? (
                  <span className="text-muted">Envoi…</span>
                ) : r.error ? (
                  <span className="text-danger">Erreur</span>
                ) : (
                  <span className="text-muted">Prêt</span>
                )}
              </span>
              {r.error && <p className="w-full text-xs text-danger">{r.error}</p>}
            </li>
          ))}
        </ul>
      )}
      {ready > 0 && (
        <button type="button" className="btn-primary" onClick={send} disabled={busy}>
          {busy ? "Envoi en cours…" : `Envoyer ${ready} document${ready > 1 ? "s" : ""}`}
        </button>
      )}
    </div>
  );
}
