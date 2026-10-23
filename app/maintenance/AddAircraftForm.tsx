"use client";

import { useActionState } from "react";
import type { addAircraft } from "./actions";
import type { FormState } from "@/lib/types";

export function AddAircraftForm({
  action,
}: {
  action: typeof addAircraft;
}) {
  const [state, formAction, pending] = useActionState<FormState, FormData>(action, undefined);

  return (
    <div className="card p-5">
      {state?.error && (
        <div className="mb-4 rounded-lg bg-danger-soft px-4 py-3 text-sm font-medium text-danger">
          {state.error}
        </div>
      )}
      {state?.ok && (
        <div className="mb-4 rounded-lg bg-ok-soft px-4 py-3 text-sm font-medium text-ok">
          {state.ok}
        </div>
      )}
      <form action={formAction} className="space-y-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">Immatriculation *</label>
            <input
              name="registration"
              className="field uppercase"
              placeholder="F-GABC"
              required
              maxLength={10}
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">Modèle *</label>
            <input
              name="model"
              className="field"
              placeholder="DR400-180"
              required
            />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">Nombre de places *</label>
            <select name="seats" className="field" defaultValue="4">
              {[1, 2, 3, 4, 5, 6].map((n) => (
                <option key={n} value={n}>
                  {n} place{n > 1 ? "s" : ""}
                </option>
              ))}
            </select>
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-muted">Type (optionnel)</label>
            <input
              name="type"
              className="field uppercase"
              placeholder="DR400"
            />
          </div>
        </div>
        <button type="submit" disabled={pending} className="btn-primary">
          {pending ? "Ajout…" : "Ajouter à la flotte"}
        </button>
      </form>
    </div>
  );
}
