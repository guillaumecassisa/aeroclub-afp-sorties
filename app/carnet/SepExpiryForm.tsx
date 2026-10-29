"use client";

import { useActionState } from "react";
import { SubmitButton, keepValues } from "@/components/ui";
import { saveSepExpiry, type CarnetState } from "./actions";

export function SepExpiryForm({ value }: { value: string }) {
  const [state, action] = useActionState<CarnetState, FormData>(saveSepExpiry, undefined);
  return (
    <form onSubmit={keepValues(action)} className="flex items-end gap-2">
      <label className="block">
        <span className="label">Échéance de ma SEP</span>
        <input type="date" name="sep_expiry" defaultValue={value} className="field w-auto py-1.5" />
      </label>
      <SubmitButton className="btn-secondary py-1.5" pending="…">
        OK
      </SubmitButton>
      {state?.error && <span className="text-xs text-danger">{state.error}</span>}
    </form>
  );
}
