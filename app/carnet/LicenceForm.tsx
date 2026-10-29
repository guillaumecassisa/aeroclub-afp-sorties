"use client";

import { useActionState, useState } from "react";
import { SubmitButton, keepValues } from "@/components/ui";
import type { LicenceSettings } from "@/lib/carnet";
import { saveLicence, type CarnetState } from "./actions";

/** Ma licence : le récapitulatif applique les conditions propres au PPL(A) ou au LAPL(A) */
export function LicenceForm({ licence }: { licence: LicenceSettings }) {
  const [state, action] = useActionState<CarnetState, FormData>(saveLicence, undefined);
  const [type, setType] = useState(licence.licence_type);
  const lbl = "flex items-center gap-1.5 text-xs font-semibold text-ink";
  const fld = "field w-auto px-2 py-1 text-sm";
  return (
    <form onSubmit={keepValues(action)} className="flex flex-wrap items-center gap-x-4 gap-y-2">
      <label className={lbl}>
        Licence
        <select name="licence_type" value={type} onChange={(e) => setType(e.target.value as "PPL" | "LAPL")} className={`${fld} font-semibold`}>
          <option value="PPL">PPL(A)</option>
          <option value="LAPL">LAPL(A)</option>
        </select>
      </label>
      <label className={lbl}>
        N°
        <input name="licence_number" defaultValue={licence.licence_number ?? ""} placeholder="FRA.FCL.PA.A.123456" maxLength={40} className={`${fld} w-52 uppercase`} />
      </label>
      <label className={lbl}>
        Délivrée le
        <input type="date" name="licence_issued" defaultValue={licence.licence_issued ?? ""} className={fld} />
      </label>
      {type === "PPL" && (
        <label className={lbl}>
          Échéance SEP
          <input type="date" name="sep_expiry" defaultValue={licence.sep_expiry ?? ""} className={fld} />
        </label>
      )}
      <label className={lbl}>
        <input type="checkbox" name="night_rating" defaultChecked={licence.night_rating} /> Qualification vol de nuit
      </label>
      <SubmitButton className="btn-secondary px-3 py-1 text-sm" pending="…">
        Enregistrer
      </SubmitButton>
      {state?.error && <span className="text-xs text-danger">{state.error}</span>}
      {state?.ok && <span className="text-xs text-ok">✓ {state.ok}</span>}
    </form>
  );
}
