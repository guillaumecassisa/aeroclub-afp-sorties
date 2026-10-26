"use client";

import "leaflet/dist/leaflet.css";
import { useEffect, useRef, useState } from "react";
import type { Map as LMap, LayerGroup } from "leaflet";
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
const RED = "#e4002b";
const SKY_LINE = "#0ea5e9";

function fmtDate(iso: string) {
  return new Date(iso + "T12:00:00").toLocaleDateString("fr-FR", {
    weekday: "long",
    day: "numeric",
    month: "long",
  });
}

// ─── Formulaire bandeau "Proposer un vol" ───────────────────────────────────
function PublishBanner({ onPublished, clubAircraft }: { onPublished?: () => void; clubAircraft: { registration: string; model: string }[] }) {
  const [open, setOpen] = useState(false);
  const [dep, setDep] = useState("");
  const [arr, setArr] = useState("");
  const today = new Date().toISOString().slice(0, 10);
  const depAd = AERODROMES.find((a) => a.icao === dep.trim().toUpperCase().slice(0, 4));
  const arrAd = AERODROMES.find((a) => a.icao === arr.trim().toUpperCase().slice(0, 4));

  return (
    <div className="border-b border-line bg-white">
      {/* Barre de déclenchement */}
      {!open && (
        <div className="mx-auto flex max-w-6xl items-center gap-4 px-4 py-3">
          <span className="text-sm text-muted">Vous partez en navigation et souhaitez emmener des passagers ?</span>
          <button type="button" onClick={() => setOpen(true)} className="btn-primary ml-auto shrink-0">
            ✈️ Proposer un vol
          </button>
        </div>
      )}

      {/* Formulaire déployé */}
      {open && (
        <form
          onSubmit={keepValues(async (fd) => {
            await publishFlight(fd);
            setOpen(false);
            setDep("");
            setArr("");
          })}
          className="mx-auto max-w-6xl px-4 py-4"
        >
          <div className="flex flex-wrap items-end gap-3">
            {/* Départ */}
            <label className="block flex-1 min-w-32">
              <span className="label">Départ</span>
              <input
                name="dep_icao"
                list="sf-dep"
                required
                value={dep}
                onChange={(e) => setDep(e.target.value)}
                placeholder="ex. LFMA"
                className="field uppercase"
                autoComplete="off"
              />
              <datalist id="sf-dep">
                {AERODROMES.map((a) => <option key={a.icao} value={a.icao}>{a.name}</option>)}
              </datalist>
              {dep.length >= 4 && (
                <span className="mt-0.5 block text-xs text-muted">{depAd ? `✓ ${depAd.name}` : "⚠ Inconnu"}</span>
              )}
            </label>

            <span className="mb-2.5 text-xl text-muted">→</span>

            {/* Arrivée */}
            <label className="block flex-1 min-w-32">
              <span className="label">Arrivée</span>
              <input
                name="arr_icao"
                list="sf-arr"
                required
                value={arr}
                onChange={(e) => setArr(e.target.value)}
                placeholder="ex. LFNA"
                className="field uppercase"
                autoComplete="off"
              />
              <datalist id="sf-arr">
                {AERODROMES.map((a) => <option key={a.icao} value={a.icao}>{a.name}</option>)}
              </datalist>
              {arr.length >= 4 && (
                <span className="mt-0.5 block text-xs text-muted">{arrAd ? `✓ ${arrAd.name}` : "⚠ Inconnu"}</span>
              )}
            </label>

            {/* Date */}
            <label className="block min-w-36">
              <span className="label">Date</span>
              <input name="flight_date" type="date" required min={today} className="field" />
            </label>

            {/* Places */}
            <label className="block w-28">
              <span className="label">Places</span>
              <select name="seats" className="field" defaultValue="1">
                {[1, 2, 3, 4, 5].map((n) => (
                  <option key={n} value={n}>{n} place{n > 1 ? "s" : ""}</option>
                ))}
              </select>
            </label>

            {/* Avion */}
            <label className="block w-40">
              <span className="label">Avion</span>
              <select name="aircraft" className="field" defaultValue="">
                <option value="">— Non précisé —</option>
                {clubAircraft.map((a) => (
                  <option key={a.registration} value={a.registration}>
                    {a.registration} · {a.model}
                  </option>
                ))}
              </select>
            </label>

            {/* Commentaire */}
            <label className="block w-full">
              <span className="label">Commentaire (facultatif)</span>
              <input
                name="comment"
                maxLength={600}
                className="field"
                placeholder="Heure de départ, conditions, informations utiles…"
              />
            </label>

            {/* Boutons */}
            <div className="flex gap-2 w-full">
              <SubmitButton pending="Publication…">Publier</SubmitButton>
              <button
                type="button"
                onClick={() => { setOpen(false); setDep(""); setArr(""); }}
                className="btn-secondary"
              >
                Annuler
              </button>
            </div>
          </div>
        </form>
      )}
    </div>
  );
}

// ─── Mini-formulaire rejoindre ───────────────────────────────────────────────
function JoinForm({ share, onClose }: { share: FlightShare; onClose: () => void }) {
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);

  async function handle(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    await joinFlight(share.id, msg);
  }

  return (
    <form onSubmit={handle} className="mt-2 grid gap-2 border-t border-line pt-2">
      <input
        value={msg}
        onChange={(e) => setMsg(e.target.value)}
        maxLength={300}
        className="field text-xs"
        placeholder="Message au pilote (facultatif)"
      />
      <div className="flex gap-2">
        <SubmitButton busy={busy} pending="…" className="btn-primary text-xs px-3 py-1.5">
          Confirmer
        </SubmitButton>
        <button type="button" onClick={onClose} className="btn-secondary text-xs px-3 py-1.5">
          Annuler
        </button>
      </div>
    </form>
  );
}

// ─── Carte d'un vol dans la liste ───────────────────────────────────────────
function FlightCard({
  share,
  meId,
  admin,
  selected,
  onSelect,
}: {
  share: FlightShare;
  meId: string;
  admin: boolean;
  selected: boolean;
  onSelect: () => void;
}) {
  const [joining, setJoining] = useState(false);
  const isPilot = share.pilot_id === meId;
  const isPassenger = share.passengers.some((p) => p.member_id === meId);
  const available = share.seats - share.seats_taken;
  const canJoin = !isPilot && !isPassenger && share.status === "open" && available > 0;

  return (
    <article
      onClick={() => onSelect()}
      className={`cursor-pointer rounded-lg border p-3 transition-colors ${
        selected
          ? "border-navy-2 bg-sky-soft ring-1 ring-navy-2/20"
          : "border-line bg-white hover:border-navy-2/40 hover:bg-sky-soft/50"
      }`}
    >
      {/* Route + badge */}
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0 flex-1">
          <p className="text-xs font-bold text-navy-2">
            <span className="font-mono">{share.dep_icao}</span>
            <span className="mx-1 font-normal text-muted">→</span>
            <span className="font-mono">{share.arr_icao}</span>
          </p>
          <p className="mt-0.5 truncate text-[11px] text-muted">
            {share.dep_name} → {share.arr_name}
          </p>
        </div>
        <span
          className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold ${
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
                : `${available}pl.`}
        </span>
      </div>

      {/* Date + pilote */}
      <p className="mt-1 text-[11px] font-semibold text-ink">
        {fmtDate(share.flight_date)}
      </p>
      <p className="mt-0.5 text-[11px] text-muted">
        {share.pilot_name}
        {share.aircraft && <span className="font-mono"> · {share.aircraft}</span>}
      </p>

      {/* Commentaire */}
      {share.comment && (
        <p className="mt-1 line-clamp-2 text-[11px] text-muted">{share.comment}</p>
      )}

      {/* Passagers inscrits */}
      {share.passengers.length > 0 && (
        <p className="mt-1 text-[11px] text-muted">
          👤 {share.passengers.map((p) => p.member_name).join(", ")}
        </p>
      )}

      {/* Actions (visibles seulement si sélectionné) */}
      {selected && (
        <div className="mt-2 flex flex-wrap gap-1.5 border-t border-line pt-2" onClick={(e) => e.stopPropagation()}>
          {canJoin && !joining && (
            <button
              type="button"
              onClick={() => setJoining(true)}
              className="btn-primary py-1 px-3 text-xs"
            >
              ✈️ Rejoindre
            </button>
          )}
          {isPassenger && share.status === "open" && (
            <form action={leaveFlight.bind(null, share.id)}>
              <SubmitButton pending="…" className="btn-secondary py-1 px-3 text-xs" confirm="Se désinscrire ?">
                Me désinscrire
              </SubmitButton>
            </form>
          )}
          {(isPilot || admin) && share.status === "open" && (
            <>
              <form action={closeFlight.bind(null, share.id, "closed")}>
                <SubmitButton pending="…" className="btn-secondary py-1 px-3 text-xs" confirm="Clôturer ce vol ?">
                  Clôturer
                </SubmitButton>
              </form>
              <form action={closeFlight.bind(null, share.id, "cancelled")}>
                <SubmitButton
                  pending="…"
                  className="rounded-full border border-danger px-3 py-1 text-xs font-semibold text-danger hover:bg-danger-soft"
                  confirm="Annuler ce vol ?"
                >
                  Annuler
                </SubmitButton>
              </form>
            </>
          )}
        </div>
      )}

      {joining && selected && (
        <div onClick={(e) => e.stopPropagation()}>
          <JoinForm share={share} onClose={() => setJoining(false)} />
        </div>
      )}
    </article>
  );
}

// ─── Carte Leaflet principale ────────────────────────────────────────────────
function MainMap({
  flights,
  selected,
  onSelect,
}: {
  flights: FlightShare[];
  selected: string | null;
  onSelect: (id: string) => void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const mapRef = useRef<LMap | null>(null);
  const layerRef = useRef<LayerGroup | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const L = (await import("leaflet")).default;
      if (cancelled || !el.current || mapRef.current) return;
      const m = L.map(el.current, { zoomSnap: 0.5, scrollWheelZoom: true }).setView([44.5, 4.5], 6);
      L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 14,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      }).addTo(m);
      layerRef.current = L.layerGroup().addTo(m);
      mapRef.current = m;
    })();
    return () => {
      cancelled = true;
      mapRef.current?.remove();
      mapRef.current = null;
    };
  }, []);

  // Redessiner les routes sur la carte à chaque changement
  useEffect(() => {
    if (!mapRef.current || !layerRef.current) return;
    (async () => {
      const L = (await import("leaflet")).default;
      layerRef.current!.clearLayers();

      for (const f of flights) {
        const isSel = f.id === selected;
        const color = isSel ? RED : NAVY;
        const weight = isSel ? 3 : 1.5;

        // Ligne de route
        L.polyline(
          [[f.dep_lat, f.dep_lon], [f.arr_lat, f.arr_lon]],
          { color, weight, dashArray: isSel ? undefined : "5 4", opacity: isSel ? 1 : 0.5 },
        )
          .on("click", () => onSelect(f.id))
          .addTo(layerRef.current!);

        // Marqueurs dep/arr
        const dot = (lat: number, lon: number, label: string, isArr: boolean) => {
          L.circleMarker([lat, lon], {
            radius: isSel ? 7 : 5,
            color: isSel ? RED : "#ffffff",
            weight: isSel ? 3 : 1.5,
            fillColor: isSel ? RED : NAVY,
            fillOpacity: 1,
          })
            .bindTooltip(`${label} (${f.dep_icao}${isArr ? "→" + f.arr_icao : ""})`, { permanent: false })
            .on("click", () => onSelect(f.id))
            .addTo(layerRef.current!);
        };

        dot(f.dep_lat, f.dep_lon, f.dep_name, false);
        dot(f.arr_lat, f.arr_lon, f.arr_name, true);
      }
    })();
  }, [flights, selected, onSelect]);

  return <div ref={el} className="z-0 h-full w-full" />;
}

// ─── Composant principal ─────────────────────────────────────────────────────
export function FlightBoard({
  flights,
  meId,
  admin,
  clubAircraft,
}: {
  flights: FlightShare[];
  meId: string;
  admin: boolean;
  clubAircraft: { registration: string; model: string }[];
}) {
  const [selected, setSelected] = useState<string | null>(
    flights.find((f) => f.status === "open")?.id ?? null,
  );
  const [filter, setFilter] = useState<"open" | "all">("open");

  const shown = (filter === "open" ? flights.filter((f) => f.status === "open") : flights).sort(
    (a, b) => a.flight_date.localeCompare(b.flight_date),
  );

  return (
    <div className="flex flex-col" style={{ height: "calc(100dvh - 166px)" }}>
      {/* ── Bandeau proposer un vol ── */}
      <PublishBanner clubAircraft={clubAircraft} />

      {/* ── Corps : carte + liste ── */}
      <div className="flex min-h-0 flex-1">
        {/* Carte (prend tout l'espace disponible) */}
        <div className="relative flex-1 overflow-hidden">
          <MainMap flights={shown} selected={selected} onSelect={setSelected} />
          {/* Légende overlay */}
          <div className="pointer-events-none absolute bottom-2 left-2 rounded-md bg-white/80 px-2 py-1 text-[10px] text-muted shadow backdrop-blur-sm">
            <span className="mr-2 inline-block h-0.5 w-4 bg-navy-2 align-middle" /> vol disponible &nbsp;
            <span className="mr-2 inline-block h-0.5 w-4 bg-red align-middle" /> sélectionné
          </div>
        </div>

        {/* ── Colonne de droite ── */}
        <div className="flex w-72 flex-col border-l border-line bg-paper xl:w-80">
          {/* Filtres */}
          <div className="flex gap-1 border-b border-line bg-white p-2">
            <button
              type="button"
              onClick={() => setFilter("open")}
              className={`flex-1 rounded-md py-1.5 text-xs font-semibold transition-colors ${
                filter === "open" ? "bg-navy-2 text-white" : "text-muted hover:text-navy-2"
              }`}
            >
              Ouverts ({flights.filter((f) => f.status === "open").length})
            </button>
            <button
              type="button"
              onClick={() => setFilter("all")}
              className={`flex-1 rounded-md py-1.5 text-xs font-semibold transition-colors ${
                filter === "all" ? "bg-navy-2 text-white" : "text-muted hover:text-navy-2"
              }`}
            >
              Tous ({flights.length})
            </button>
          </div>

          {/* Liste des vols */}
          <div className="flex-1 overflow-y-auto">
            {shown.length === 0 ? (
              <div className="p-6 text-center text-xs text-muted">
                Aucun vol partagé pour le moment.<br />
                <span className="font-medium">Proposez le premier !</span>
              </div>
            ) : (
              <div className="space-y-2 p-2">
                {shown.map((f) => (
                  <FlightCard
                    key={f.id}
                    share={f}
                    meId={meId}
                    admin={admin}
                    selected={selected === f.id}
                    onSelect={() => setSelected(f.id === selected ? null : f.id)}
                  />
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
