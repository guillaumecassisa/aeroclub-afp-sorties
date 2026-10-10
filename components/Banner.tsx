/** Affiche les messages passés dans l'URL (?ok=... / ?erreur=...) après une action. */
export function Banner({ ok, erreur }: { ok?: string; erreur?: string }) {
  if (!ok && !erreur) return null;
  return (
    <div
      role={erreur ? "alert" : "status"}
      className={`mb-4 rounded-lg px-4 py-3 text-sm font-medium ${
        erreur ? "bg-danger-soft text-danger" : "bg-ok-soft text-ok"
      }`}
    >
      {erreur ?? ok}
    </div>
  );
}

export function StatusPill({ status }: { status: "confirmed" | "waitlist" | null }) {
  if (status === "confirmed") return <span className="pill bg-ok-soft text-ok">✓ Inscrit</span>;
  if (status === "waitlist") return <span className="pill bg-wait-soft text-wait">Liste d&apos;attente</span>;
  return null;
}
