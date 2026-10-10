"use client";

import { useMemo, useState } from "react";
import { Avatar } from "@/components/Avatar";

export type DirectoryEntry = {
  id: string;
  full_name: string;
  phone: string | null;
  avatar_url: string | null;
  role: "member" | "instructor" | "admin";
  is_instructor?: boolean;
  types: string[];
};

const norm = (s: string) =>
  s
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "");

export function DirectoryList({ members, meId }: { members: DirectoryEntry[]; meId: string }) {
  const [q, setQ] = useState("");

  const shown = useMemo(() => {
    const nq = norm(q.trim());
    return members.filter(
      (m) =>
        (!nq || norm(m.full_name).includes(nq) || (m.phone ?? "").replace(/\s/g, "").includes(nq.replace(/\s/g, ""))),
    );
  }, [members, q]);

  return (
    <>
      <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center">
        <input
          type="search"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Rechercher un nom ou un numéro…"
          aria-label="Rechercher"
          className="field sm:max-w-xs"
        />
      </div>

      {shown.length === 0 ? (
        <div className="card p-8 text-center text-sm text-muted">Aucun membre ne correspond.</div>
      ) : (
        <ul className="grid gap-2 sm:grid-cols-2">
          {shown.map((m) => (
            <li key={m.id} className={`card flex items-center gap-3 p-3 ${m.id === meId ? "border-navy-2/40" : ""}`}>
              <Avatar url={m.avatar_url} name={m.full_name} size="md" />
              <div className="min-w-0 flex-1">
                <p className="flex items-center gap-2 truncate font-semibold text-ink">
                  <span className="truncate">{m.full_name || "(sans nom)"}</span>
                  {(m.is_instructor ?? m.role === "instructor") && <span className="pill bg-sky-soft text-sky">Instructeur</span>}
                </p>
                {m.phone ? (
                  <a href={`tel:${m.phone.replace(/\s/g, "")}`} className="text-sm text-sky hover:underline">
                    {m.phone}
                  </a>
                ) : (
                  <p className="text-sm text-muted">Pas de téléphone renseigné</p>
                )}
                <div className="mt-1 flex flex-wrap gap-1">
                  {m.types.length ? (
                    m.types.map((t) => (
                      <span key={t} className="pill bg-navy-2 text-white">
                        {t}
                      </span>
                    ))
                  ) : (
                    <span className="text-xs text-muted">Aucun lâcher renseigné</span>
                  )}
                </div>
              </div>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
