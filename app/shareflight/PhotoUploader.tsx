"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createBrowserSupabase } from "@/lib/supabase/client";
import { registerFlightPhotos } from "./actions";

const MAX_FILES = 10;

/** Réduit une photo dans le navigateur (2000 px max, JPEG) : envoi rapide, même depuis un téléphone. */
async function shrink(file: File): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, 2000 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  return await new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("conversion"))), "image/jpeg", 0.85),
  );
}

type Picked = { id: string; blob: Blob; preview: string };

export function PhotoUploader({ meId, clubAircraft }: { meId: string; clubAircraft: { registration: string; model: string }[] }) {
  const router = useRouter();
  const input = useRef<HTMLInputElement>(null);
  const [open, setOpen] = useState(false);
  const [picked, setPicked] = useState<Picked[]>([]);
  const [caption, setCaption] = useState("");
  const [route, setRoute] = useState("");
  const [aircraft, setAircraft] = useState("");
  const [takenOn, setTakenOn] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok?: string; error?: string } | null>(null);

  async function pick(files: FileList | null) {
    if (!files) return;
    setMsg(null);
    const list = Array.from(files).filter((f) => f.type.startsWith("image/")).slice(0, MAX_FILES - picked.length);
    const out: Picked[] = [];
    for (const f of list) {
      try {
        const blob = await shrink(f);
        out.push({ id: `${Date.now()}-${Math.random()}`, blob, preview: URL.createObjectURL(blob) });
      } catch {
        setMsg({ error: `« ${f.name} » est illisible : essayez une photo en JPEG ou PNG.` });
      }
    }
    setPicked((cur) => [...cur, ...out]);
    if (input.current) input.current.value = "";
  }

  function remove(id: string) {
    setPicked((cur) => {
      const r = cur.find((p) => p.id === id);
      if (r) URL.revokeObjectURL(r.preview);
      return cur.filter((p) => p.id !== id);
    });
  }

  async function send() {
    if (!picked.length) return;
    setBusy(true);
    setMsg(null);
    const supabase = createBrowserSupabase();
    const paths: string[] = [];
    for (const [i, p] of picked.entries()) {
      const path = `photos/${meId}/${Date.now()}-${i}.jpg`;
      const { error } = await supabase.storage
        .from("documents")
        .upload(path, p.blob, { contentType: "image/jpeg", cacheControl: "31536000", upsert: false });
      if (error) {
        setMsg({ error: `Envoi impossible : ${error.message}` });
        if (paths.length) await supabase.storage.from("documents").remove(paths);
        setBusy(false);
        return;
      }
      paths.push(path);
    }
    const res = await registerFlightPhotos({ paths, caption, route, aircraft, taken_on: takenOn || null });
    setBusy(false);
    if (res.error) return setMsg({ error: res.error });
    picked.forEach((p) => URL.revokeObjectURL(p.preview));
    setPicked([]);
    setCaption("");
    setRoute("");
    setAircraft("");
    setTakenOn("");
    setOpen(false);
    setMsg({ ok: `${res.count} photo${(res.count ?? 0) > 1 ? "s" : ""} partagée${(res.count ?? 0) > 1 ? "s" : ""}. Merci !` });
    router.refresh();
  }

  if (!open) {
    return (
      <div className="flex flex-wrap items-center gap-3">
        <p className="text-sm text-muted">Une belle nav, un paysage, un coucher de soleil ? Partagez vos photos de vol avec le club.</p>
        <button type="button" className="btn-primary ml-auto" onClick={() => setOpen(true)}>
          📷 Partager des photos
        </button>
        {msg?.ok && <p className="w-full text-sm text-ok">{msg.ok}</p>}
      </div>
    );
  }

  return (
    <div className="card space-y-4 p-5">
      <div className="flex items-center justify-between gap-2">
        <h2 className="font-bold text-navy-2">Partager des photos de vol</h2>
        <button type="button" className="text-sm text-muted hover:underline" onClick={() => setOpen(false)} disabled={busy}>
          Fermer
        </button>
      </div>

      <div className="flex flex-wrap gap-2">
        {picked.map((p) => (
          <div key={p.id} className="relative h-24 w-24 overflow-hidden rounded-lg border border-line">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={p.preview} alt="" className="h-full w-full object-cover" />
            {!busy && (
              <button
                type="button"
                onClick={() => remove(p.id)}
                className="absolute top-1 right-1 grid h-6 w-6 place-items-center rounded-full bg-black/60 text-xs text-white"
                aria-label="Retirer cette photo"
              >
                ✕
              </button>
            )}
          </div>
        ))}
        {picked.length < MAX_FILES && (
          <label className="grid h-24 w-24 cursor-pointer place-items-center rounded-lg border-2 border-dashed border-line text-center text-xs text-muted hover:border-navy-2 hover:text-navy-2">
            <span>
              <span className="block text-2xl">＋</span>
              {picked.length ? "Ajouter" : "Choisir des photos"}
            </span>
            <input ref={input} type="file" accept="image/*" multiple className="sr-only" onChange={(e) => pick(e.target.files)} />
          </label>
        )}
      </div>
      <p className="text-xs text-muted">Jusqu&apos;à {MAX_FILES} photos à la fois. Elles sont réduites automatiquement avant l&apos;envoi.</p>

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="sm:col-span-2">
          <label htmlFor="ph-caption" className="label">Légende</label>
          <input id="ph-caption" className="field" maxLength={300} value={caption} onChange={(e) => setCaption(e.target.value)} placeholder="Ex. Survol des calanques au coucher du soleil" />
        </div>
        <div>
          <label htmlFor="ph-route" className="label">Trajet</label>
          <input id="ph-route" className="field" maxLength={80} value={route} onChange={(e) => setRoute(e.target.value)} placeholder="Ex. LFMA → LFKC" />
        </div>
        <div>
          <label htmlFor="ph-ac" className="label">Avion</label>
          <input id="ph-ac" className="field" list="ph-aircraft" maxLength={40} value={aircraft} onChange={(e) => setAircraft(e.target.value)} placeholder="Ex. F-HCLI" />
          <datalist id="ph-aircraft">
            {clubAircraft.map((a) => (
              <option key={a.registration} value={a.registration}>{a.model}</option>
            ))}
          </datalist>
        </div>
        <div>
          <label htmlFor="ph-date" className="label">Date du vol</label>
          <input id="ph-date" type="date" className="field" value={takenOn} onChange={(e) => setTakenOn(e.target.value)} />
        </div>
      </div>

      {msg?.error && <p className="text-sm text-danger">{msg.error}</p>}
      <button type="button" className="btn-primary" disabled={busy || !picked.length} onClick={send}>
        {busy ? "Envoi en cours…" : `Partager ${picked.length || ""} photo${picked.length > 1 ? "s" : ""}`}
      </button>
    </div>
  );
}
