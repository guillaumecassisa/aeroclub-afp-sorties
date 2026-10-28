"use client";

import { useEffect, useRef, useState } from "react";
import { downloadDossierVol, loadDossierPart, saveDossierPart, type PerfSnapshot } from "@/lib/dossierVol";

type Plane = { registration: string; model: string; type: string };
type PerfWindow = Window & { perfDossier?: () => PerfSnapshot };

// Type d'avion du site -> avion du calculateur (données du manuel de vol)
const perfId = (type: string) => type.toLowerCase().replace(/[^a-z0-9]/g, "");

/**
 * Calculateur intégré sans cadre (la hauteur suit le contenu, une seule barre de défilement),
 * avec le choix de l'immatriculation et le téléchargement du dossier de vol en PDF.
 */
export function PerfFrame({ src, fleet }: { src: string; fleet: Plane[] }) {
  const ref = useRef<HTMLIFrameElement>(null);
  const [h, setH] = useState(1400);
  const [reg, setReg] = useState(fleet[0]?.registration ?? "");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const regRef = useRef(reg);
  const saveTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  regRef.current = reg;

  const plane = fleet.find((p) => p.registration === reg) ?? null;
  const calc = () => ref.current?.contentWindow as PerfWindow | null | undefined;

  // L'avion choisi pilote le calculateur
  useEffect(() => {
    if (plane) calc()?.postMessage({ type: "perf-set-aircraft", id: perfId(plane.type) }, window.location.origin);
  }, [plane]);

  useEffect(() => {
    const onMsg = (e: MessageEvent) => {
      if (e.origin !== window.location.origin || e.source !== ref.current?.contentWindow) return;
      const d = e.data as { type?: string; h?: number; id?: string };
      if (d?.type === "perf-height" && typeof d.h === "number" && d.h > 200) {
        const need = Math.ceil(d.h) + 16;
        setH((cur) => (Math.abs(cur - need) > 2 ? need : cur));
      }
      // Chaque calcul est gardé (par immatriculation) pour le dossier de vol de la page Masse et centrage
      if (d?.type === "perf-changed") {
        clearTimeout(saveTimer.current);
        saveTimer.current = setTimeout(() => {
          const cur = fleet.find((p) => p.registration === regRef.current);
          const snap = calc()?.perfDossier?.();
          if (cur && snap && snap.aircraftId === perfId(cur.type)) saveDossierPart(cur.registration, "perf", snap);
        }, 600);
      }
      // Le calculateur annonce son avion (au chargement) : on l'aligne sur l'immatriculation choisie
      if (d?.type === "perf-aircraft" && d.id) {
        const cur = fleet.find((p) => p.registration === regRef.current);
        if (cur && perfId(cur.type) !== d.id) calc()?.postMessage({ type: "perf-set-aircraft", id: perfId(cur.type) }, window.location.origin);
      }
    };
    window.addEventListener("message", onMsg);
    // Le cadre a pu se charger avant cet écouteur : on mesure aussi directement (même site)
    const measure = () => {
      const doc = ref.current?.contentDocument;
      const wrap = doc?.querySelector(".wrap");
      if (doc?.readyState === "complete" && wrap) {
        const need = Math.ceil(wrap.getBoundingClientRect().bottom + doc.defaultView!.scrollY) + 16;
        if (need > 200) setH((cur) => (Math.abs(cur - need) > 2 ? need : cur));
      }
    };
    measure();
    const t = setInterval(measure, 1000);
    return () => {
      window.removeEventListener("message", onMsg);
      clearInterval(t);
    };
  }, [fleet]);

  async function download() {
    setErr(null);
    const snap = calc()?.perfDossier?.();
    if (!snap || !plane) {
      setErr("Le calculateur n'est pas encore chargé : patientez une seconde et réessayez.");
      return;
    }
    setBusy(true);
    try {
      saveDossierPart(plane.registration, "perf", snap);
      await downloadDossierVol({ registration: plane.registration, model: plane.model, perf: snap, mb: loadDossierPart(plane.registration, "mb") });
    } catch {
      setErr("Le PDF n'a pas pu être créé. Réessayez.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="mb-4 flex flex-wrap items-end gap-3">
        <label className="block">
          <span className="label">Avion</span>
          <select className="field w-auto min-w-56 font-semibold" value={reg} onChange={(e) => setReg(e.target.value)}>
            {fleet.map((p) => (
              <option key={p.registration} value={p.registration}>
                {p.registration} — {p.model}
              </option>
            ))}
          </select>
        </label>
        <button type="button" className="btn-primary ml-auto" onClick={download} disabled={busy || !plane}>
          {busy ? "Préparation…" : "📄 Dossier de vol (PDF)"}
        </button>
        <p className="w-full text-xs text-muted">
          Dossier de vol A4 à emporter : conditions, décollage et atterrissage, plus la masse et centrage de {reg || "cet avion"} si
          vous l&apos;avez calculée aujourd&apos;hui sur cet appareil.
        </p>
        {err && <p className="w-full text-sm text-danger">{err}</p>}
      </div>
      <iframe
        ref={ref}
        src={src}
        title="Calculateur de performances décollage / atterrissage"
        scrolling="no"
        style={{ height: h }}
        className="block w-full border-0 bg-transparent"
        onLoad={() => plane && calc()?.postMessage({ type: "perf-set-aircraft", id: perfId(plane.type) }, window.location.origin)}
      />
    </>
  );
}
