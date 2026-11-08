"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { convertWingTanks } from "./actions";

export function WingTanksButton({ planes }: { planes: string[] }) {
  const [msg, setMsg] = useState<{ ok?: string; error?: string } | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();
  return (
    <div className="card mb-5 border-wait/40 bg-wait-soft p-4">
      <p className="font-semibold text-ink">Masse et centrage : réservoirs d&apos;aile gauche et droite</p>
      <p className="text-sm text-muted">
        Le carburant se saisira réservoir par réservoir (aile gauche, aile droite) et le doublon carburant des PS28 / B23 disparaît.
        Avions concernés : {planes.join(", ")}.
      </p>
      <div className="mt-2 flex flex-wrap items-center gap-3">
        <button
          type="button"
          className="btn-primary"
          disabled={pending}
          onClick={() => start(async () => {
            const r = await convertWingTanks();
            setMsg(r);
            if (r.ok) router.refresh();
          })}
        >
          {pending ? "Mise à jour…" : "Mettre à jour les réservoirs d'aile"}
        </button>
        {msg?.ok && <span className="text-sm text-ok">✓ {msg.ok}</span>}
        {msg?.error && <span className="text-sm text-danger">{msg.error}</span>}
      </div>
    </div>
  );
}
