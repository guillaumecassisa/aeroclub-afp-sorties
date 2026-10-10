"use client";

import { useActionState } from "react";
import { PasswordInput } from "@/components/PasswordInput";
import { login } from "@/app/auth/actions";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";

export function LoginForm({ next }: { next: string }) {
  const [state, action, busy] = useActionState(login, undefined);
  return (
    <form onSubmit={keepValues(action)} className="space-y-4">
      <input type="hidden" name="next" value={next} />
      <div>
        <label className="label" htmlFor="email">Email</label>
        <input className="field" id="email" name="email" type="email" autoComplete="email" required />
      </div>
      <div>
        <label className="label" htmlFor="password">Mot de passe</label>
        <PasswordInput id="password" name="password" autoComplete="current-password" required />
      </div>
      <FormMessage state={state} />
      <SubmitButton busy={busy} pending="Connexion…" className="btn-primary w-full">Se connecter</SubmitButton>
    </form>
  );
}
