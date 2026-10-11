"use client";

import { useState } from "react";
import { SubmitButton } from "@/components/ui";
import { setAvailability, toggleAircraft } from "./actions";

type Aircraft = {
  id: string;
  registration: string;
  model: string;
  seats: number;
  type: string | null;
  active: boolean;
  available: boolean;
  unavailable_reason: string | null;
};

export function AircraftCard({ aircraft: a }: { aircraft: Aircraft }) {
  const [showForm, setShowForm] = useState(false);
  const isAvailable = a.available !== false;
  const isActive = a.active !== false;

  return (
    <li className="px-4 py-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        {/* Info avion */}
        <div className="flex-1 min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold text-navy-2 text-lg">{a.registration}</span>
            <span className="text-sm text-muted">{a.model}</span>
            {a.type && (
              <span className="rounded bg-paper border border-line px-1.5 py-0.5 text-xs text-muted">
                {a.type}
              </span>
            )}
            <span className="text-xs text-muted">{a.seats} places</span>
          </div>
          {!isAvailable && a.unavailable_reason && (
            <p className="mt-1 text-sm text-danger">⚠️ {a.unavailable_reason}</p>
          )}
        </div>

        {/* Statut + actions */}
        <div className="flex flex-wrap items-center gap-2">
          {isActive && (
            <span className={`pill ${isAvailable ? "bg-ok-soft text-ok" : "bg-danger-soft text-danger"}`}>
              {isAvailable ? "✅ Disponible" : "🔧 Indisponible"}
            </span>
          )}

          {isActive && isAvailable && !showForm && (
            <button
              className="btn-secondary text-sm"
              onClick={() => setShowForm(true)}
            >
              Marquer indisponible
            </button>
          )}

          {isActive && !isAvailable && (
            <form action={setAvailability.bind(null, a.id, true, undefined)}>
              <SubmitButton className="btn-primary text-sm" pending="…">
                Remettre en service
              </SubmitButton>
            </form>
          )}

          {isActive ? (
            <form action={toggleAircraft.bind(null, a.id, false)}>
              <SubmitButton
                className="text-xs text-muted hover:text-danger px-2 py-1"
                pending="…"
                confirm={`Retirer ${a.registration} de la flotte active ?`}
              >
                Retirer de la flotte
              </SubmitButton>
            </form>
          ) : (
            <form action={toggleAircraft.bind(null, a.id, true)}>
              <SubmitButton className="btn-secondary text-sm" pending="…">
                Réintégrer
              </SubmitButton>
            </form>
          )}
        </div>
      </div>

      {/* Inline form — mark unavailable */}
      {showForm && (
        <div className="mt-3 rounded-xl border border-line bg-paper p-4">
          <form
            action={setAvailability.bind(null, a.id, false, undefined)}
            className="space-y-3"
          >
            <div>
              <label className="mb-1 block text-xs font-medium text-muted">
                Motif (visible par les membres)
              </label>
              <input
                name="reason"
                className="field"
                placeholder="ex: Visite 50h, réparation phare, révision radio…"
                maxLength={120}
                autoFocus
              />
            </div>
            <div className="flex gap-2">
              <SubmitButton className="btn-primary text-sm" pending="Enregistrement…">
                Confirmer l'indisponibilité
              </SubmitButton>
              <button
                type="button"
                className="btn-secondary text-sm"
                onClick={() => setShowForm(false)}
              >
                Annuler
              </button>
            </div>
          </form>
        </div>
      )}
    </li>
  );
}
