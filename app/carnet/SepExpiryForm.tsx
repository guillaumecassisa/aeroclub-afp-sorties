"use client";

import { useActionState } from "react";
import { SubmitButton, keepValues } from "@/components/ui";
import { saveSepExpiry, type CarnetState } from "./actions";

export function SepExpiryForm({ value }: { value: string }) {
  const [state, action] = useActionState<CarnetState, FormData>(saveSepExpiry, undefined);
  return (
    <form onSubmit={keepValues(action)} className="flex items-center gap-2">
      <label className="flex items-center gap-2 text-xs font-semibold text-ink">
        Échéance de ma SEP
        <input type="date" name="sep_expiry" defaultValue={value} className="field w-auto px-2 py-1 text-sm" />
      </label>
      <SubmitButton className="btn-secondary px-3 py-1 text-sm" pending="…">
        OK
      </SubmitButton>
      {state?.error && <span className="text-xs text-danger">{state.error}</span>}
    </form>
  );
}
