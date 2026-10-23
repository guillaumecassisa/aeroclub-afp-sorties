"use client";

import { useState, useTransition } from "react";
import { Avatar } from "@/components/Avatar";
import type { Person } from "@/lib/types";
import { cancelRegistration, moveCrew, placeWaitlisted } from "../actions";

type Ac = {
  id: string;
  registration: string;
  model: string;
  type?: string;
  seats: number;
  capacity: number;
  instructor_onboard: boolean;
  occupants: Person[];
};

type Drag =
  | { kind: "waitlist"; reg: string; name: string }
  | { kind: "crew"; reg: string; from: string; name: string }
  | { kind: "organizer"; from: string; name: string };

/**
 * Répartition des équipages par glisser-déposer (organisateurs, ordinateur) :
 * liste d'attente → avion, avion → avion, ou sur une personne pour échanger les places.
 * Toutes les règles (places, lâchers, instructeur à bord) restent vérifiées par la base.
 */
export function CrewBoard({
  outingId,
  aircraft,
  waitlist,
  organizer,
  canRemove,
}: {
  outingId: string;
  aircraft: Ac[];
  waitlist: (Person & { position: number })[];
  organizer: { name: string; avatar_url?: string | null };
  canRemove: boolean;
}) {
  const [drag, setDrag] = useState<Drag | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const used = (a: Ac) => a.occupants.length + (a.instructor_onboard ? 1 : 0);
  const hasFreeSeat = (a: Ac, d: Drag) =>
    d.kind === "organizer" ? a.occupants.length < a.capacity - 1 : a.occupants.length < a.capacity;

  function run(fn: () => Promise<unknown>) {
    setDrag(null);
    setOver(null);
    start(async () => {
      await fn();
    });
  }

  /** Dépôt sur un avion (siège libre) */
  function dropOnAircraft(a: Ac) {
    const d = drag;
    if (!d) return;
    if (d.kind !== "waitlist" && d.from === a.id) return setDrag(null);
    const fd = new FormData();
    if (d.kind === "waitlist") {
      fd.set("aircraft", a.id);
      return run(() => placeWaitlisted(outingId, d.reg, fd));
    }
    fd.set("who", d.kind === "organizer" ? "organizer" : d.reg);
    fd.set("target", a.id);
    run(() => moveCrew(outingId, fd));
  }

  /** Dépôt sur une personne d'un autre avion : échange des places */
  function dropOnPerson(a: Ac, withWho: string) {
    const d = drag;
    if (!d) return;
    if (d.kind === "waitlist") return dropOnAircraft(a);
    if (d.from === a.id) return setDrag(null);
    const fd = new FormData();
    fd.set("who", d.kind === "organizer" ? "organizer" : d.reg);
    fd.set("target", `${a.id}|${withWho}`);
    run(() => moveCrew(outingId, fd));
  }

  function remove(p: Person) {
    if (!window.confirm(`Retirer ${p.full_name} de la sortie ?`)) return;
    run(() => cancelRegistration(outingId, p.registration_id, false));
  }

  const chip = (p: Person, extra?: React.ReactNode) => (
    <>
      <Avatar url={p.avatar_url} name={p.full_name} size="xs" />
      <span className="min-w-0 truncate text-ink">{p.full_name}</span>
      {p.is_guest && <span className="pill bg-paper text-muted">accompagnant</span>}
      {extra}
      {p.weight_kg != null && <span className="text-xs text-muted">{p.weight_kg} kg</span>}
      {canRemove && (
        <button
          type="button"
          onClick={() => remove(p)}
          className="ml-auto text-xs text-danger opacity-0 transition-opacity group-hover:opacity-100 hover:underline"
        >
          Retirer
        </button>
      )}
    </>
  );

  return (
    <div className={`space-y-3 ${pending ? "pointer-events-none opacity-60" : ""}`} aria-busy={pending}>
      <p className="text-xs text-muted">
        Glissez une personne de la liste d&apos;attente vers un avion, d&apos;un avion à l&apos;autre, ou sur quelqu&apos;un pour
        échanger vos places. {pending && <strong className="text-navy-2">Enregistrement…</strong>}
      </p>
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="grid gap-4 sm:grid-cols-2 lg:col-span-2">
          {aircraft.map((a) => {
            const accepts = !!drag && (drag.kind === "waitlist" || drag.from !== a.id) && hasFreeSeat(a, drag);
            const isOver = over === a.id;
            return (
              <div
                key={a.id}
                onDragOver={(e) => {
                  if (!drag) return;
                  e.preventDefault();
                  setOver(a.id);
                }}
                onDragLeave={() => setOver((o) => (o === a.id ? null : o))}
                onDrop={(e) => {
                  e.preventDefault();
                  if (accepts) dropOnAircraft(a);
                  else setOver(null);
                }}
                className={`card overflow-hidden transition-shadow ${
                  isOver && accepts ? "ring-2 ring-navy-2" : isOver && drag ? "ring-2 ring-danger/50" : ""
                }`}
              >
                <div className="flex items-center justify-between border-b border-line px-4 py-3">
                  <h2 className="font-semibold text-navy-2">
                    {a.registration} <span className="text-sm font-normal text-muted">· {a.model}</span>
                  </h2>
                  <span className="text-xs text-muted">
                    {used(a)} / {a.seats} sièges
                  </span>
                </div>
                <ul className="divide-y divide-line">
                  {a.instructor_onboard && (
                    <li
                      draggable
                      onDragStart={() => setDrag({ kind: "organizer", from: a.id, name: organizer.name })}
                      onDragEnd={() => setDrag(null)}
                      onDragOver={(e) => {
                        if (drag && drag.kind === "crew" && drag.from !== a.id) {
                          e.preventDefault();
                          e.stopPropagation();
                          setOver(`organizer`);
                        }
                      }}
                      onDrop={(e) => {
                        if (drag && drag.kind === "crew") {
                          e.preventDefault();
                          e.stopPropagation();
                          dropOnPerson(a, "organizer");
                        }
                      }}
                      className={`group flex cursor-grab items-center gap-2 px-4 py-2 text-sm active:cursor-grabbing ${
                        over === "organizer" ? "bg-sky-soft" : ""
                      }`}
                    >
                      <span aria-hidden className="text-muted">⠿</span>
                      <Avatar url={organizer.avatar_url} name={organizer.name} size="xs" />
                      <span className="text-ink">{organizer.name}</span>
                      <span className="pill bg-sky-soft text-navy-2">Organisateur</span>
                    </li>
                  )}
                  {a.occupants.map((p) => (
                    <li
                      key={p.registration_id}
                      draggable
                      onDragStart={() => setDrag({ kind: "crew", reg: p.registration_id, from: a.id, name: p.full_name })}
                      onDragEnd={() => setDrag(null)}
                      onDragOver={(e) => {
                        if (drag && drag.kind !== "waitlist" && drag.from !== a.id) {
                          e.preventDefault();
                          e.stopPropagation();
                          setOver(p.registration_id);
                        }
                      }}
                      onDrop={(e) => {
                        if (drag && drag.kind !== "waitlist") {
                          e.preventDefault();
                          e.stopPropagation();
                          dropOnPerson(a, p.registration_id);
                        }
                      }}
                      className={`group flex cursor-grab items-center gap-2 px-4 py-2 text-sm active:cursor-grabbing ${
                        over === p.registration_id ? "bg-sky-soft" : ""
                      }`}
                      title={drag && drag.kind !== "waitlist" && drag.from !== a.id ? `Échanger avec ${p.full_name}` : undefined}
                    >
                      <span aria-hidden className="text-muted">⠿</span>
                      {chip(
                        p,
                        !p.released && a.type ? <span className="pill bg-wait-soft text-wait">non lâché {a.type}</span> : null,
                      )}
                    </li>
                  ))}
                  {Array.from({ length: Math.max(a.capacity - a.occupants.length, 0) }).map((_, i) => (
                    <li
                      key={`free-${i}`}
                      className={`px-4 py-2 text-sm ${isOver && accepts ? "bg-sky-soft text-navy-2" : "text-muted"}`}
                    >
                      {isOver && accepts && i === 0 ? `Déposer ${drag?.name} ici` : "Place libre"}
                    </li>
                  ))}
                </ul>
              </div>
            );
          })}
        </div>

        <div className="card h-fit overflow-hidden">
          <div className="border-b border-line px-4 py-3">
            <h2 className="font-semibold text-navy-2">Liste d&apos;attente ({waitlist.length})</h2>
          </div>
          {waitlist.length === 0 ? (
            <p className="px-4 py-4 text-sm text-muted">Personne en attente.</p>
          ) : (
            <ul className="divide-y divide-line">
              {waitlist.map((p) => (
                <li
                  key={p.registration_id}
                  draggable
                  onDragStart={() => setDrag({ kind: "waitlist", reg: p.registration_id, name: p.full_name })}
                  onDragEnd={() => setDrag(null)}
                  className="group flex cursor-grab items-center gap-2 px-4 py-2 text-sm active:cursor-grabbing"
                >
                  <span aria-hidden className="text-muted">⠿</span>
                  <span className="text-xs text-muted">n° {p.position}</span>
                  {chip(p)}
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}
