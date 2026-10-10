"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

export function MemberSearch({ initial }: { initial: string }) {
  const router = useRouter();
  const [q, setQ] = useState(initial);
  return (
    <input
      type="search"
      value={q}
      onChange={(e) => {
        setQ(e.target.value);
        router.replace(`/droits${e.target.value ? `?q=${encodeURIComponent(e.target.value)}` : ""}`, { scroll: false });
      }}
      placeholder="Rechercher un membre…"
      aria-label="Rechercher un membre"
      className="field sm:max-w-xs"
    />
  );
}
