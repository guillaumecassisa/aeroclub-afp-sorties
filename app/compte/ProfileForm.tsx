"use client";

import { useActionState } from "react";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";
import type { Profile } from "@/lib/types";
import { updateProfile } from "./actions";

export function ProfileForm({ me }: { me: Profile }) {
  const [state, action, busy] = useActionState(updateProfile, undefined);
  return (
    <form onSubmit={keepValues(action)} className="space-y-4">
      <div className="grid gap-4 sm:grid-cols-2">
        <div>
          <label className="label" htmlFor="full_name">Prénom et nom</label>
          <input className="field" id="full_name" name="full_name" defaultValue={me.full_name} autoComplete="name" required />
        </div>
        <div>
          <label className="label" htmlFor="phone">Téléphone <span className="font-normal text-muted">(visible dans l&apos;annuaire)</span></label>
          <input className="field" id="phone" name="phone" type="tel" defaultValue={me.phone ?? ""} autoComplete="tel" />
        </div>
      </div>
      <div>
        <label className="label" htmlFor="email">Email de connexion</label>
        <input className="field bg-paper text-muted" id="email" value={me.email} readOnly />
        <p className="mt-1 text-xs text-muted">Pour changer d&apos;email, contactez un administrateur du club.</p>
      </div>
      <div>
        <label className="label" htmlFor="address">Adresse postale</label>
        <textarea className="field min-h-20" id="address" name="address" defaultValue={me.address ?? ""} autoComplete="street-address" />
      </div>
      <fieldset className="rounded-lg border border-line p-4">
        <legend className="px-1 text-sm font-semibold text-ink">Personne à prévenir en cas d&apos;urgence</legend>
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label className="label" htmlFor="emergency_name">Nom</label>
            <input className="field" id="emergency_name" name="emergency_name" defaultValue={me.emergency_name ?? ""} />
          </div>
          <div>
            <label className="label" htmlFor="emergency_phone">Téléphone</label>
            <input className="field" id="emergency_phone" name="emergency_phone" type="tel" defaultValue={me.emergency_phone ?? ""} />
          </div>
        </div>
      </fieldset>
      <p className="text-xs text-muted">
        L&apos;annuaire du club affiche votre nom, votre téléphone et vos lâchers. L&apos;adresse et la personne à prévenir
        ne sont visibles que par les instructeurs et les administrateurs.
      </p>
      <FormMessage state={state} />
      <SubmitButton busy={busy} pending="Enregistrement…">Enregistrer mes coordonnées</SubmitButton>
    </form>
  );
}
