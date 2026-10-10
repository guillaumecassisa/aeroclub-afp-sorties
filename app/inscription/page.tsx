"use client";

import Link from "next/link";
import { PasswordInput } from "@/components/PasswordInput";
import { useActionState } from "react";
import { signup } from "@/app/auth/actions";
import { AuthCardClient } from "@/components/AuthCardClient";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";

export default function Page() {
  const [state, action, busy] = useActionState(signup, undefined);
  return (
    <AuthCardClient title="Créer mon compte">
      {state?.ok ? (
        <FormMessage state={state} />
      ) : (
        <form onSubmit={keepValues(action)} className="space-y-4">
          <div>
            <label className="label" htmlFor="full_name">Prénom et nom</label>
            <input className="field" id="full_name" name="full_name" autoComplete="name" required />
          </div>
          <div>
            <label className="label" htmlFor="phone">Téléphone <span className="font-normal text-muted">(visible dans l&apos;annuaire du club)</span></label>
            <input className="field" id="phone" name="phone" type="tel" autoComplete="tel" />
          </div>
          <div>
            <label className="label" htmlFor="email">Email</label>
            <input className="field" id="email" name="email" type="email" autoComplete="email" required />
          </div>
          <div>
            <label className="label" htmlFor="password">Mot de passe <span className="font-normal text-muted">(8 caractères min.)</span></label>
            <PasswordInput id="password" name="password" autoComplete="new-password" minLength={8} required />
          </div>
          <label className="flex items-start gap-2.5 text-sm text-ink">
            <input type="checkbox" name="consent" required className="mt-0.5 h-4 w-4 shrink-0 accent-sky" />
            <span>
              J&apos;ai lu la{" "}
              <Link href="/confidentialite" target="_blank" className="font-semibold text-sky hover:underline">
                politique de confidentialité
              </Link>{" "}
              et j&apos;accepte que mes données soient utilisées pour la vie du club (annuaire, événements, bar).
            </span>
          </label>
          <FormMessage state={state} />
          <SubmitButton busy={busy} pending="Création…" className="btn-primary w-full">Créer mon compte</SubmitButton>
          <p className="text-xs text-muted">
            Votre compte devra être validé par un administrateur du club avant de pouvoir vous inscrire aux sorties.
          </p>
        </form>
      )}
      <p className="mt-6 text-sm text-muted">
        Déjà inscrit ?{" "}
        <Link href="/connexion" className="font-semibold text-sky hover:underline">Se connecter</Link>
      </p>
    </AuthCardClient>
  );
}
