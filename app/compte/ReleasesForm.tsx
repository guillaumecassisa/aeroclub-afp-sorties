"use client";

import { useActionState } from "react";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";
import { saveReleases } from "./actions";

export function ReleasesForm({
  types,
  released,
}: {
  types: { type: string; registrations: string[] }[];
  released: string[];
}) {
  const [state, action, busy] = useActionState(saveReleases, undefined);

  if (types.length === 0) {
    return <p className="text-sm text-muted">Aucun avion n&apos;est encore enregistré dans la flotte du club.</p>;
  }

  return (
    <form onSubmit={keepValues(action)} className="space-y-4">
      <div className="grid gap-2 sm:grid-cols-3">
        {types.map(({ type, registrations }) => (
          <label
            key={type}
            className="flex cursor-pointer items-center gap-3 rounded-lg border border-line bg-white px-3 py-2.5 hover:bg-paper has-[:checked]:border-navy-2 has-[:checked]:bg-sky-soft"
          >
            <input type="checkbox" name="type" value={type} defaultChecked={released.includes(type)} className="h-4 w-4 accent-sky" />
            <span className="font-bold tracking-wide text-navy-2">{type}</span>
            <span className="truncate text-xs text-muted">
              {registrations.join(", ")}
            </span>
          </label>
        ))}
      </div>
      <FormMessage state={state} />
      <SubmitButton busy={busy} pending="Enregistrement…">Enregistrer mes lâchers</SubmitButton>
    </form>
  );
}
