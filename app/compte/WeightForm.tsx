"use client";

import { useActionState } from "react";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";
import { updateWeight } from "./actions";

export function WeightForm({ weight }: { weight: number | null }) {
  const [state, action, busy] = useActionState(updateWeight, undefined);
  return (
    <form onSubmit={keepValues(action)} className="space-y-3">
      <div className="max-w-40">
        <label className="label" htmlFor="weight_kg">
          Poids <span className="font-normal text-muted">(facultatif)</span>
        </label>
        <div className="relative">
          <input
            className="field pr-10"
            id="weight_kg"
            name="weight_kg"
            inputMode="decimal"
            defaultValue={weight ?? ""}
            placeholder="ex. 78"
          />
          <span className="pointer-events-none absolute top-1/2 right-3 -translate-y-1/2 text-sm text-muted">kg</span>
        </div>
      </div>
      <FormMessage state={state} />
      <SubmitButton busy={busy} pending="Enregistrement…">Enregistrer mon poids</SubmitButton>
    </form>
  );
}
