"use client";

import "leaflet/dist/leaflet.css";
import { useEffect, useMemo, useRef, useState } from "react";
import type { LayerGroup, Map as LMap } from "leaflet";
import { AERODROMES, TIP_CATEGORIES, type Tip } from "@/lib/aerodromes";
import { SubmitButton } from "@/components/ui";
import { addTip, archiveTip } from "./actions";

const catOf = (k: string) => TIP_CATEGORIES.find((c) => c.key === k) ?? TIP_CATEGORIES[TIP_CATEGORIES.length - 1];
const NAVY = "#002157";
const RED = "#e4002b";

export function TipsExplorer({
  tips,
  meId,
  admin,
  initialIcao,
}: {
  tips: Tip[];
  meId: string;
  admin: boolean;
  initialIcao: string | null;
}) {
  const [view, setView] = useState<"carte" | "liste">("carte");
  const [cat, setCat] = useState<string>("tous");
  const [selected, setSelected] = useState<string | null>(initialIcao);
  const [adding, setAdding] = useState(false);
  const [pick, setPick] = useState<string>(initialIcao ?? "");
  const mapEl = useRef<HTMLDivElement>(null);
  const map = useRef<LMap | null>(null);
  const tipLayer = useRef<LayerGroup | null>(null);
  const adLayer = useRef<LayerGroup | null>(null);
  const [ready, setReady] = useState(false);

  const shown = useMemo(() => (cat === "tous" ? tips : tips.filter((t) => t.category === cat)), [tips, cat]);
  const byField = useMemo(() => {
    const m = new Map<string, { icao: string; name: string; lat: number; lon: number; tips: Tip[] }>();
    for (const t of shown) {
      const cur = m.get(t.icao) ?? { icao: t.icao, name: t.airfield_name, lat: t.lat, lon: t.lon, tips: [] };
      cur.tips.push(t);
      m.set(t.icao, cur);
    }
    return m;
  }, [shown]);
  const fields = [...byField.values()].sort((a, b) => a.icao.localeCompare(b.icao));
  const current = selected ? byField.get(selected) : null;
  const counts = (k: string) => (k === "tous" ? tips.length : tips.filter((t) => t.category === k).length);

  // Carte (Leaflet, fond OpenStreetMap), chargée seulement dans le navigateur
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const L = (await import("leaflet")).default;
      if (cancelled || !mapEl.current || map.current) return;
      const m = L.map(mapEl.current, { zoomSnap: 0.5, scrollWheelZoom: true }).setView([46.6, 2.4], 5.5);
      L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 14,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      }).addTo(m);
      adLayer.current = L.layerGroup().addTo(m);
      tipLayer.current = L.layerGroup().addTo(m);
      map.current = m;
      setReady(true);
    })();
    return () => {
      cancelled = true;
      map.current?.remove();
      map.current = null;
    };
  }, []);

  // Pastilles des terrains qui ont des bons plans
  useEffect(() => {
    if (!ready || !tipLayer.current) return;
    (async () => {
      const L = (await import("leaflet")).default;
      tipLayer.current!.clearLayers();
      for (const f of fields) {
        const on = f.icao === selected;
        L.circleMarker([f.lat, f.lon], {
          radius: on ? 10 : 8,
          color: on ? RED : "#ffffff",
          weight: on ? 4 : 2,
          fillColor: NAVY,
          fillOpacity: 1,
        })
          .bindTooltip(`${f.icao} · ${f.name} (${f.tips.length})`)
          .on("click", () => {
            setSelected(f.icao);
            setPick(f.icao);
          })
          .addTo(tipLayer.current!);
      }
    })();
  }, [ready, fields, selected]);

  // En mode ajout : tous les aérodromes, cliquables pour choisir le terrain
  useEffect(() => {
    if (!ready || !adLayer.current) return;
    (async () => {
      const L = (await import("leaflet")).default;
      adLayer.current!.clearLayers();
      if (!adding) return;
      for (const a of AERODROMES) {
        L.circleMarker([a.lat, a.lon], { radius: 4, color: "#5f6b7d", weight: 1, fillColor: "#ffffff", fillOpacity: 1 })
          .bindTooltip(`${a.icao} · ${a.name}`)
          .on("click", () => {
            setPick(a.icao);
            setSelected(a.icao);
          })
          .addTo(adLayer.current!);
      }
    })();
  }, [ready, adding]);

  // La carte était masquée (vue liste) : recalcule sa taille
  useEffect(() => {
    if (view === "carte") setTimeout(() => map.current?.invalidateSize(), 0);
  }, [view]);

  // Centre la carte sur le terrain choisi
  useEffect(() => {
    if (!ready || !selected) return;
    const f = byField.get(selected) ?? AERODROMES.find((a) => a.icao === selected);
    if (f && map.current) map.current.panTo([f.lat, f.lon]);
  }, [ready, selected, byField]);

  const pickedAd = AERODROMES.find((a) => a.icao === pick.trim().toUpperCase().slice(0, 4));

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <div className="inline-flex rounded-lg border border-line bg-white p-0.5 text-sm font-semibold">
          {(["carte", "liste"] as const).map((v) => (
            <button
              key={v}
              type="button"
              onClick={() => setView(v)}
              className={`rounded-md px-3 py-1.5 ${view === v ? "bg-navy-2 text-white" : "text-muted hover:text-navy-2"}`}
            >
              {v === "carte" ? "🗺️ Carte" : "☰ Liste"}
            </button>
          ))}
        </div>
        <button type="button" onClick={() => setAdding((a) => !a)} className="btn-primary ml-auto">
          {adding ? "Fermer" : "+ Ajouter un bon plan"}
        </button>
      </div>

      <div className="mb-4 flex flex-wrap gap-1.5">
        {[{ key: "tous", label: "Tous", icon: "" }, ...TIP_CATEGORIES].map((c) =>
          c.key === "tous" || counts(c.key) > 0 ? (
            <button
              key={c.key}
              type="button"
              onClick={() => setCat(c.key)}
              className={`rounded-full border px-3 py-1 text-sm ${
                cat === c.key ? "border-navy-2 bg-sky-soft font-semibold text-navy-2" : "border-line bg-white text-muted hover:border-navy-2/40"
              }`}
            >
              {c.icon ? `${c.icon} ` : ""}
              {c.label} ({counts(c.key)})
            </button>
          ) : null,
        )}
      </div>

      {adding && (
        <form action={addTip} className="card mb-4 grid gap-3 border-l-4 border-l-navy-2 p-5 sm:grid-cols-2">
          <p className="text-sm text-muted sm:col-span-2">
            Choisissez le terrain dans la liste ou cliquez sur un petit point de la carte.
          </p>
          <label className="block">
            <span className="label">Aérodrome</span>
            <input
              name="icao"
              list="aerodromes"
              required
              value={pick}
              onChange={(e) => {
                setPick(e.target.value);
                const code = e.target.value.trim().toUpperCase().slice(0, 4);
                if (AERODROMES.some((a) => a.icao === code)) setSelected(code);
              }}
              placeholder="Code OACI ou nom (ex. LFMA)"
              className="field uppercase"
              autoComplete="off"
            />
            <datalist id="aerodromes">
              {AERODROMES.map((a) => (
                <option key={a.icao} value={a.icao}>
                  {a.name}
                </option>
              ))}
            </datalist>
            <span className="mt-1 block text-xs text-muted">{pickedAd ? `${pickedAd.icao} · ${pickedAd.name}` : "Terrain non reconnu"}</span>
          </label>
          <label className="block">
            <span className="label">Catégorie</span>
            <select name="category" className="field" defaultValue="resto">
              {TIP_CATEGORIES.map((c) => (
                <option key={c.key} value={c.key}>
                  {c.icon} {c.label}
                </option>
              ))}
            </select>
          </label>
          <label className="block">
            <span className="label">Nom</span>
            <input name="title" required maxLength={80} className="field" placeholder="Ex. Le Saint Tex" />
          </label>
          <label className="block">
            <span className="label">Site web ou téléphone (facultatif)</span>
            <input name="contact" maxLength={200} className="field" placeholder="https://… ou 04 94 00 00 00" />
          </label>
          <label className="block sm:col-span-2">
            <span className="label">Description</span>
            <textarea
              name="description"
              maxLength={1000}
              className="field min-h-20"
              placeholder="Ce qui vaut le détour, horaires, conseils (réserver, accès à pied depuis le parking avions…)"
            />
          </label>
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" name="on_field" defaultChecked className="h-4 w-4" /> Sur l&apos;aérodrome (accessible à pied)
          </label>
          <div className="sm:text-right">
            <SubmitButton pending="Ajout…">Ajouter</SubmitButton>
          </div>
        </form>
      )}

      <div className={`grid gap-4 ${view === "carte" ? "lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)]" : ""}`}>
        <div className={view === "carte" ? "" : "hidden"}>
          <div ref={mapEl} className="z-0 h-[480px] w-full overflow-hidden rounded-lg border border-line bg-paper lg:h-[600px]" />
          <p className="mt-2 text-center text-xs text-muted">
            <span className="mr-1 inline-block h-2.5 w-2.5 rounded-full bg-navy-2 align-middle" /> un point = un terrain · cliquez pour
            voir ses bons plans
          </p>
        </div>

        {view === "carte" ? (
          <div>
            {current ? (
              <FieldTips field={current} meId={meId} admin={admin} />
            ) : (
              <div className="card p-6 text-sm text-muted">
                {fields.length === 0
                  ? "Aucun bon plan pour le moment : ajoutez le premier !"
                  : "Choisissez un terrain sur la carte pour voir ses bons plans."}
              </div>
            )}
          </div>
        ) : (
          <div className="space-y-6">
            {fields.length === 0 && <p className="card p-6 text-sm text-muted">Aucun bon plan dans cette catégorie.</p>}
            {fields.map((f) => (
              <FieldTips key={f.icao} field={f} meId={meId} admin={admin} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function FieldTips({
  field,
  meId,
  admin,
}: {
  field: { icao: string; name: string; tips: Tip[] };
  meId: string;
  admin: boolean;
}) {
  return (
    <section>
      <div className="mb-2 flex items-start gap-2">
        <span aria-hidden className="text-xl">
          📍
        </span>
        <div>
          <h2 className="text-lg font-bold text-navy-2">{field.name}</h2>
          <p className="text-xs text-muted">
            <span className="font-mono">{field.icao}</span> · {field.tips.length} bon plan{field.tips.length > 1 ? "s" : ""}
          </p>
        </div>
      </div>
      <ul className="space-y-2">
        {field.tips.map((t) => {
          const c = catOf(t.category);
          const isUrl = !!t.contact && /^https?:\/\//i.test(t.contact);
          return (
            <li key={t.id} className="card flex gap-3 p-4">
              <span aria-hidden className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-paper text-xl">
                {c.icon}
              </span>
              <div className="min-w-0 flex-1">
                <p className="font-bold text-ink">{t.title}</p>
                {t.description && <p className="mt-0.5 text-sm whitespace-pre-line text-ink">{t.description}</p>}
                <p className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted">
                  <span>{c.label}</span>
                  <span>{t.on_field ? "✈️ sur l'aérodrome" : "🚶 à proximité"}</span>
                  {t.contact &&
                    (isUrl ? (
                      <a href={t.contact} target="_blank" rel="noopener noreferrer nofollow" className="truncate text-sky hover:underline">
                        🔗 {t.contact.replace(/^https?:\/\/(www\.)?/, "").replace(/\/$/, "").slice(0, 40)}
                      </a>
                    ) : (
                      <a href={`tel:${t.contact.replace(/[^0-9+]/g, "")}`} className="text-sky hover:underline">
                        📞 {t.contact}
                      </a>
                    ))}
                </p>
              </div>
              {admin && (
                <form action={archiveTip.bind(null, t.id, t.icao)} className="shrink-0">
                  <SubmitButton
                    pending="…"
                    confirm={`Retirer « ${t.title} » ?`}
                    className="rounded px-1.5 text-muted hover:bg-danger-soft hover:text-danger"
                  >
                    <span aria-label="Retirer">✕</span>
                  </SubmitButton>
                </form>
              )}
            </li>
          );
        })}
      </ul>
    </section>
  );
}
