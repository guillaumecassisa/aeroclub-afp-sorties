"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";

/** Sélecteur d'avion + onglets « Fiche avion » / « Masse & centrage ». */
export function AircraftSwitcher({
  current,
  fleet,
  tab,
  info,
}: {
  current: string;
  fleet: { id: string; registration: string; model: string }[];
  tab: "fiche" | "centrage";
  info?: string;
}) {
  const router = useRouter();
  const base = (id: string) => (tab === "centrage" ? `/flotte/${id}/centrage` : `/flotte/${id}`);
  return (
    <div className="mb-4 print:hidden">
      <div className="flex flex-wrap items-center gap-3">
        <label htmlFor="aircraft-switch" className="text-xs font-bold tracking-[0.2em] text-muted uppercase">
          Aéronef
        </label>
        <select
          id="aircraft-switch"
          value={current}
          onChange={(e) => router.push(base(e.target.value))}
          className="field w-auto min-w-64 font-semibold"
        >
          {fleet.map((a) => (
            <option key={a.id} value={a.id}>
              {a.registration} — {a.model}
            </option>
          ))}
        </select>
        {info && <span className="ml-auto text-xs text-muted">{info}</span>}
      </div>
      <nav className="mt-3 grid grid-cols-2 gap-1 rounded-lg bg-line/60 p-1 text-sm font-semibold">
        <Link
          href={`/flotte/${current}`}
          className={`rounded-md px-3 py-2 text-center ${tab === "fiche" ? "bg-white text-navy-2 shadow-sm" : "text-muted hover:text-navy-2"}`}
        >
          Fiche avion
        </Link>
        <Link
          href={`/flotte/${current}/centrage`}
          className={`rounded-md px-3 py-2 text-center ${tab === "centrage" ? "bg-white text-navy-2 shadow-sm" : "text-muted hover:text-navy-2"}`}
        >
          Masse &amp; centrage
        </Link>
      </nav>
    </div>
  );
}
