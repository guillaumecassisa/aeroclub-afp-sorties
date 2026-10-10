"use client";

import { startTransition } from "react";
import { useFormStatus } from "react-dom";

/**
 * Soumission sans réinitialisation du formulaire (React vide sinon les champs
 * après chaque action, ce qui ferait perdre la saisie en cas d'erreur).
 */
export function keepValues(dispatch: (fd: FormData) => void) {
  return (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const fd = new FormData(e.currentTarget);
    startTransition(() => dispatch(fd));
  };
}

export function SubmitButton({
  children,
  pending: pendingLabel,
  className = "btn-primary",
  confirm,
  busy,
  "aria-label": ariaLabel,
}: {
  "aria-label"?: string;
  children: React.ReactNode;
  pending?: string;
  className?: string;
  confirm?: string;
  busy?: boolean;
}) {
  const status = useFormStatus();
  const pending = busy ?? status.pending;
  return (
    <button
      type="submit"
      aria-label={ariaLabel}
      className={className}
      disabled={pending}
      onClick={(e) => {
        if (confirm && !window.confirm(confirm)) e.preventDefault();
      }}
    >
      {pending ? (pendingLabel ?? "…") : children}
    </button>
  );
}

export function FormMessage({ state }: { state: { error?: string; ok?: string } | undefined }) {
  if (!state) return null;
  if (state.error)
    return (
      <p role="alert" className="rounded-lg bg-danger-soft px-3 py-2 text-sm text-danger">
        {state.error}
      </p>
    );
  if (state.ok) return <p role="status" className="rounded-lg bg-ok-soft px-3 py-2 text-sm text-ok">{state.ok}</p>;
  return null;
}
