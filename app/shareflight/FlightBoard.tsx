"use client";

import "leaflet/dist/leaflet.css";
import { useEffect, useRef, useState } from "react";
import type { Map as LMap, Polyline, Marker } from "leaflet";
import { AERODROMES } from "@/lib/aerodromes";
import { SubmitButton, keepValues } from "@/components/ui";
import { publishFlight, joinFlight, leaveFlight, closeFlight } from "./actions";

export type FlightShare = {
  id: string;
  pilot_id: string;
  pilot_name: string;
  pilot_avatar: string | null;
  dep_icao: string;
  dep_name: string;
  dep_lat: number;
  dep_lon: number;
  arr_icao: string;
  arr_name: string;
  arr_lat: number;
  arr_lon: number;
  flight_date: string;
  seats: number;
  aircraft: string | null;
  comment: string | null;
  status: "open" | "closed" | "cancelled";
  seats_taken: number;
  passengers: { member_id: string; member_name: string }[];
};

const NAVY = "#002157";
const SKY = "#0e7490";

function fmtDate(iso: string) {
  return new Date(iso + "T12:00:00").toLocaleDateString("fr-FR", {
    weekday: "long",
    day: "numeric",
    month: "long",
  });
}

function fmtDateShort(iso: string) {
  return new Date(iso + "T12:00:00").toLocaleDateString("fr-FR", {
    day: "numeric",
    month: "short",
  });
}

// Carte pour un vol individuel (dep → arr)
function FlightMap({ dep, arr }: { dep: { lat: number; lon: number; icao: string }; arr: { lat: number; lon: number; icao: string } }) {
  const el = useRef<HTMLDivElement>(null);
  const mapRef = useRef<LMap | null>(null);
  const lineRef = useRef<Polyline | null>(null);
  const markersRef = useRef<Marker[]>([]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const L = (await import("leaflet")).default;
      if (cancelled || !el.current || mapRef.current) return;
      const midLat = (dep.lat + arr.lat) / 2;
      const midLon = (dep.lon + arr.lon) / 2;
      const m = L.map(el.current, { zoomSnap: 0.5, scrollWheelZoom: false, dragging: false, attributionControl: false }).setView(
        [midLat, midLon],
        7,
      );
      L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom: 14 }).addTo(m);
      lineRef.current = L.polyline(
        [
          [dep.lat, dep.lon],
          [arr.lat, arr.lon],
        ],
        { color: NAVY, weight: 2.5, dashArray: "6 4" },
      ).addTo(m);
      const icon = (label: string) =>
        L.divIcon({
          className: "",
          html: `<div style="background:${NAVY};color:#fff;font-size:10px;font-weight:700;padding:2px 5px;border-radius:4px;white-space:nowrap">${label}</div>`,
          iconAnchor: [18, 8],
        });
      markersRef.current = [
        L.marker([dep.lat, dep.lon], { icon: icon(dep.icao) }).addTo(m),
        L.marker([arr.lat, arr.lon], { icon: icon(arr.icao) }).addTo(m),
      ];
      m.fitBounds(lineRef.current.getBounds(), { padding: [24, 24] });
      mapRef.current = m;
    })();
    return () => {
      cancelled = true;
      mapRef.current?.remove();
      mapRef.current = null;
    };
  }, [dep.lat, dep.lon, dep.icao, arr.lat, arr.lon, arr.icao]);

  return <div ref={el} className="z-0 h-32 w-full rounded-lg border border-line bg-paper" />;
}

// Formulaire de rejoindre un vol
function JoinForm({ share, onClose }: { share: FlightShare; onClose: () => void }) {
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);

  async function handle(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    await joinFlight(share.id, msg);
  }

  return (
    <form onSubmit={handle} className="mt-3 grid gap-2 border-t border-line pt-3">
      <label className="block">
        <span className="label">Message au pilote (facultatif)</span>
        <input
          value={msg}
          onChange={(e) => setMsg(e.target.value)}
          maxLength={300}
          className="field"
          placeholder="Ex. Je serai à l'aérodrome à partir de 9h"
        />
      </label>
      <div className="flex gap-2">
        <SubmitButton busy={busy} pending="Inscription…">
          Rejoindre ce vol
        </SubmitButton>
        <button type="button" onClick={onClose} className="btn-ghost">
          Annuler
        </button>
      </div>
    </form>
  );
}

// Carte d'un vol
function FlightCard({ share, meId, admin }: { share: FlightShare; meId: string; admin: boolean }) {
  const [joining, setJoining] = useState(false);
  const [expanded, setExpanded] = useState(false);
  const isPilot = share.pilot_id === meId;
  const isPassenger = share.passengers.some((p) => p.member_id === meId);
  const available = share.seats - share.seats_taken;
  const canJoin = !isPilot && !isPassenger && share.status === "open" && available > 0;

  return (
    <article className="card overflow-hidden">
      {/* En-tête */}
      <div className="flex items-start gap-3 p-4">
        <div className="min-w-0 flex-1">
          {/* Route */}
          <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5">
            <span className="font-mono text-xs font-bold text-sky">{share.dep_icao}</span>
            <span className="text-muted">→</span>
            <span className="font-mono text-xs font-bold text-sky">{share.arr_icao}</span>
            <span className="text-xs text-muted">·</span>
            <span className="truncate text-sm text-ink">
              {share.dep_name} → {share.arr_name}
            </span>
          </div>
          {/* Date */}
          <p className="mt-0.5 text-[13px] font-semibold text-navy-2">{fmtDate(share.flight_date)}</p>
          {/* Pilote + avion */}
          <p className="mt-1 text-xs text-muted">
            Pilote : <span className="font-medium text-ink">{share.pilot_name}</span>
            {share.aircraft && (
              <>
                {" "}
                · <span className="font-mono">{share.aircraft}</span>
              </>
            )}
          </p>
        </div>

        {/* Badge places */}
        <div className="shrink-0 text-right">
          <span
            className={`inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-bold ${
              share.status !== "open"
                ? "bg-paper text-muted"
                : available === 0
                  ? "bg-danger-soft text-danger"
                  : "bg-ok-soft text-ok"
            }`}
          >
            {share.status === "cancelled"
              ? "Annulé"
              : share.status === "closed"
                ? "Clôturé"
                : available === 0
                  ? "Complet"
                  : `${available} place${available > 1 ? "s" : ""}`}
          </span>
        </div>
      </div>

      {/* Carte mini */}
      <div className="px-4 pb-1">
        <button
          type="button"
          className="w-full text-left"
          onClick={() => setExpanded((v) => !v)}
          aria-expanded={expanded}
        >
          {expanded ? (
            <FlightMap
              dep={{ lat: share.dep_lat, lon: share.dep_lon, icao: share.dep_icao }}
              arr={{ lat: share.arr_lat, lon: share.arr_lon, icao: share.arr_icao }}
            />
          ) : (
            <div className="flex h-8 items-center justify-center rounded-lg bg-paper text-xs text-muted hover:bg-sky-soft">
              🗺️ Voir la carte
            </div>
          )}
        </button>
      </div>

      {/* Corps */}
      <div className="px-4 pb-4">
        {share.comment && <p className="mt-2 text-sm whitespace-pre-line text-ink">{share.comment}</p>}

        {/* Passagers */}
        {share.passengers.length > 0 && (
          <div className="mt-2">
            <p className="text-xs text-muted">
              Inscrits :{" "}
              {share.passengers.map((p) => (
                <span key={p.member_id} className="font-medium text-ink">
                  {p.member_name}{" "}
                </span>
              ))}
            </p>
          </div>
        )}

        {/* Actions */}
        <div className="mt-3 flex flex-wrap gap-2">
          {canJoin && !joining && (
            <button type="button" onClick={() => setJoining(true)} className="btn-primary">
              ✈️ Je rejoins ce vol
            </button>
          )}
          {isPassenger && share.status === "open" && (
            <form action={leaveFlight.bind(null, share.id)}>
              <SubmitButton
                pending="…"
                className="btn-ghost"
                confirm="Se désinscrire de ce vol ?"
              >
                Me désinscrire
              </SubmitButton>
            </form>
          )}
          {(isPilot || admin) && share.status === "open" && (
            <>
              <form action={closeFlight.bind(null, share.id, "closed")}>
                <SubmitButton pending="…" className="btn-ghost" confirm="Clôturer ce vol (plus de nouvelles inscriptions) ?">
                  Clôturer
                </SubmitButton>
              </form>
              <form action={closeFlight.bind(null, share.id, "cancelled")}>
                <SubmitButton
                  pending="…"
                  className="rounded-lg border border-danger px-3 py-1.5 text-sm font-medium text-danger hover:bg-danger-soft"
                  confirm="Annuler ce vol ?"
                >
                  Annuler le vol
                </SubmitButton>
              </form>
            </>
          )}
        </div>

        {joining && <JoinForm share={share} onClose={() => setJoining(false)} />}
      </div>
    </article>
  );
}

// Formulaire de publication d'un vol
function PublishForm({ onClose }: { onClose: () => void }) {
  const [dep, setDep] = useState("");
  const [arr, setArr] = useState("");
  const depAd = AERODROMES.find((a) => a.icao === dep.trim().toUpperCase().slice(0, 4));
  const arrAd = AERODROMES.find((a) => a.icao === arr.trim().toUpperCase().slice(0, 4));
  const today = new Date().toISOString().slice(0, 10);

  return (
    <form
      onSubmit={keepValues(publishFlight)}
      className="card mb-6 grid gap-3 border-l-4 border-l-navy-2 p-5 sm:grid-cols-2"
    >
      <h2 className="text-base font-bold text-navy-2 sm:col-span-2">Proposer un vol partagé</h2>

      <label className="block">
        <span className="label">Départ (code OACI)</span>
        <input
          name="dep_icao"
          list="aerodromes-dep"
          required
          value={dep}
          onChange={(e) => setDep(e.target.value)}
          placeholder="ex. LFMA"
          className="field uppercase"
          autoComplete="off"
        />
        <datalist id="aerodromes-dep">
          {AERODROMES.map((a) => (
            <option key={a.icao} value={a.icao}>
              {a.name}
            </option>
          ))}
        </datalist>
        {dep.length >= 4 && (
          <span className="mt-1 block text-xs text-muted">
            {depAd ? `✓ ${depAd.name}` : "⚠ Terrain non reconnu"}
          </span>
        )}
      </label>

      <label className="block">
        <span className="label">Arrivée (code OACI)</span>
        <input
          name="arr_icao"
          list="aerodromes-arr"
          required
          value={arr}
          onChange={(e) => setArr(e.target.value)}
          placeholder="ex. LFNA"
          className="field uppercase"
          autoComplete="off"
        />
        <datalist id="aerodromes-arr">
          {AERODROMES.map((a) => (
            <option key={a.icao} value={a.icao}>
              {a.name}
            </option>
          ))}
        </datalist>
        {arr.length >= 4 && (
          <span className="mt-1 block text-xs text-muted">
            {arrAd ? `✓ ${arrAd.name}` : "⚠ Terrain non reconnu"}
          </span>
        )}
      </label>

      <label className="block">
        <span className="label">Date du vol</span>
        <input name="flight_date" type="date" required min={today} className="field" />
      </label>

      <label className="block">
        <span className="label">Nombre de places proposées</span>
        <select name="seats" className="field" defaultValue="1">
          {[1, 2, 3, 4, 5].map((n) => (
            <option key={n} value={n}>
              {n} place{n > 1 ? "s" : ""}
            </option>
          ))}
        </select>
      </label>

      <label className="block">
        <span className="label">Immatriculation de l&apos;avion (facultatif)</span>
        <input name="aircraft" maxLength={40} className="field uppercase" placeholder="ex. F-HXAF" />
      </label>

      <label className="block sm:col-span-2">
        <span className="label">Commentaire (facultatif)</span>
        <textarea
          name="comment"
          maxLength={600}
          className="field min-h-20"
          placeholder="Heure de départ prévue, conditions, infos utiles pour les passagers…"
        />
      </label>

      <div className="flex gap-2 sm:col-span-2">
        <SubmitButton pending="Publication…">Publier ce vol</SubmitButton>
        <button type="button" onClick={onClose} className="btn-ghost">
          Annuler
        </button>
      </div>
    </form>
  );
}

// Composant principal
export function FlightBoard({
  flights,
  meId,
  admin,
}: {
  flights: FlightShare[];
  meId: string;
  admin: boolean;
}) {
  const [publishing, setPublishing] = useState(false);
  const [filter, setFilter] = useState<"open" | "all">("open");

  const shown = filter === "open" ? flights.filter((f) => f.status === "open") : flights;

  // Trier : d'abord par date, puis plus récent en premier si même date
  const sorted = [...shown].sort((a, b) => a.flight_date.localeCompare(b.flight_date));

  return (
    <div>
      {/* Barre d'actions */}
      <div className="mb-4 flex flex-wrap items-center gap-3">
        <div className="inline-flex rounded-lg border border-line bg-white p-0.5 text-sm font-semibold">
          <button
            type="button"
            onClick={() => setFilter("open")}
            className={`rounded-md px-3 py-1.5 ${filter === "open" ? "bg-navy-2 text-white" : "text-muted hover:text-navy-2"}`}
          >
            Vols ouverts ({flights.filter((f) => f.status === "open").length})
          </button>
          <button
            type="button"
            onClick={() => setFilter("all")}
            className={`rounded-md px-3 py-1.5 ${filter === "all" ? "bg-navy-2 text-white" : "text-muted hover:text-navy-2"}`}
          >
            Tous ({flights.length})
          </button>
        </div>
        {!publishing && (
          <button type="button" onClick={() => setPublishing(true)} className="btn-primary ml-auto">
            + Proposer un vol
          </button>
        )}
      </div>

      {publishing && <PublishForm onClose={() => setPublishing(false)} />}

      {sorted.length === 0 ? (
        <div className="card p-8 text-center text-sm text-muted">
          {filter === "open"
            ? "Aucun vol partagé ouvert pour le moment. Soyez le premier à proposer un vol !"
            : "Aucun vol partagé pour le moment."}
        </div>
      ) : (
        <div className="space-y-4">
          {/* Regroupement par date */}
          {(() => {
            const groups = new Map<string, FlightShare[]>();
            for (const f of sorted) {
              const g = groups.get(f.flight_date) ?? [];
              g.push(f);
              groups.set(f.flight_date, g);
            }
            return [...groups.entries()].map(([date, group]) => (
              <div key={date}>
                <h2 className="mb-2 flex items-center gap-2 text-sm font-semibold text-muted">
                  <span className="h-px flex-1 bg-line" />
                  <span>
                    📅 {fmtDate(date)}{" "}
                    <span className="font-normal">
                      · {group.length} vol{group.length > 1 ? "s" : ""}
                    </span>
                  </span>
                  <span className="h-px flex-1 bg-line" />
                </h2>
                <div className="space-y-3">
                  {group.map((share) => (
                    <FlightCard key={share.id} share={share} meId={meId} admin={admin} />
                  ))}
                </div>
              </div>
            ));
          })()}
        </div>
      )}
    </div>
  );
}
