"use client";

import Link from "next/link";
import { useActionState } from "react";
import { forgotPassword } from "@/app/auth/actions";
import { AuthCardClient } from "@/components/AuthCardClient";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";

export default function Page() {
  const [state, action, busy] = useActionState(forgotPassword, undefined);
  return (
    <AuthCardClient title="Mot de passe oublié">
      <p className="mb-4 text-sm text-muted">
        Indiquez l&apos;email de votre compte : vous recevrez un lien pour choisir un nouveau mot de passe.
      </p>
      <form onSubmit={keepValues(action)} className="space-y-4">
        <div>
          <label className="label" htmlFor="email">Email</label>
          <input id="email" name="email" type="email" autoComplete="email" className="field" required />
        </div>
        <FormMessage state={state} />
        <SubmitButton busy={busy} pending="Envoi…" className="btn-primary w-full">
          Recevoir le lien
        </SubmitButton>
      </form>
      <p className="mt-6 text-sm">
        <Link href="/connexion" className="text-sky hover:underline">← Retour à la connexion</Link>
      </p>
    </AuthCardClient>
  );
}
