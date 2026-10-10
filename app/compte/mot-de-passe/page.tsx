"use client";

import Link from "next/link";
import { PasswordInput } from "@/components/PasswordInput";
import { useActionState } from "react";
import { updatePassword } from "@/app/auth/actions";
import { AuthCardClient } from "@/components/AuthCardClient";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";

export default function Page() {
  const [state, action, busy] = useActionState(updatePassword, undefined);
  return (
    <AuthCardClient title="Nouveau mot de passe">
      <form onSubmit={keepValues(action)} className="space-y-4">
        <div>
          <label className="label" htmlFor="password">Nouveau mot de passe <span className="font-normal text-muted">(8 caractères min.)</span></label>
          <PasswordInput id="password" name="password" autoComplete="new-password" minLength={8} required />
        </div>
        <div>
          <label className="label" htmlFor="confirm">Confirmation</label>
          <PasswordInput id="confirm" name="confirm" autoComplete="new-password" minLength={8} required />
        </div>
        <FormMessage state={state} />
        <SubmitButton busy={busy} pending="Enregistrement…" className="btn-primary w-full">Enregistrer</SubmitButton>
      </form>
      <p className="mt-6 text-sm">
        <Link href="/" className="text-sky hover:underline">← Retour à l&apos;accueil</Link>
      </p>
    </AuthCardClient>
  );
}
