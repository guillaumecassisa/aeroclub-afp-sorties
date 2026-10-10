"use client";

import { useEffect, useState } from "react";

function fmt(d: Date, tz: string) {
  return new Intl.DateTimeFormat("fr-FR", { timeZone: tz, hour: "2-digit", minute: "2-digit", second: "2-digit" }).format(d);
}

/** Heures UTC et locale qui défilent en direct. */
export function Clocks({ initial }: { initial: string }) {
  const [now, setNow] = useState(() => new Date(initial));
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(t);
  }, []);
  return (
    <div className="grid grid-cols-2 gap-3">
      <div>
        <p className="text-[11px] font-semibold tracking-[0.18em] text-white/70 uppercase">Heure UTC</p>
        <p className="font-mono text-3xl font-bold tabular-nums sm:text-4xl" suppressHydrationWarning>
          {fmt(now, "UTC")}
          <span className="ml-1 text-lg text-white/70">Z</span>
        </p>
      </div>
      <div>
        <p className="text-[11px] font-semibold tracking-[0.18em] text-white/70 uppercase">Heure locale</p>
        <p className="font-mono text-3xl font-bold tabular-nums text-white/90 sm:text-4xl" suppressHydrationWarning>
          {fmt(now, "Europe/Paris")}
        </p>
      </div>
    </div>
  );
}
