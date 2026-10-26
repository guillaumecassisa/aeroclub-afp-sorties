"use client";

import { useCallback, useEffect, useState } from "react";
import { SubmitButton } from "@/components/ui";
import { deleteFlightPhoto } from "./actions";

export type FlightPhoto = {
  id: string;
  user_id: string;
  url: string;
  caption: string | null;
  route: string | null;
  aircraft: string | null;
  taken_on: string | null;
  created_at: string;
  author: string;
  author_avatar: string | null;
};

const dateFr = (iso: string) =>
  new Intl.DateTimeFormat("fr-FR", { day: "numeric", month: "long", year: "numeric", timeZone: "Europe/Paris" }).format(
    new Date(iso.length === 10 ? `${iso}T12:00:00Z` : iso),
  );

export function PhotoGallery({ photos, meId, admin }: { photos: FlightPhoto[]; meId: string; admin: boolean }) {
  const [open, setOpen] = useState<number | null>(null);
  const close = useCallback(() => setOpen(null), []);
  const move = useCallback((d: number) => setOpen((i) => (i === null ? i : (i + d + photos.length) % photos.length)), [photos.length]);

  useEffect(() => {
    if (open === null) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
      if (e.key === "ArrowRight") move(1);
      if (e.key === "ArrowLeft") move(-1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, close, move]);

  if (photos.length === 0) {
    return <div className="card p-8 text-center text-muted">Aucune photo pour le moment : soyez le premier à partager la vôtre !</div>;
  }

  const p = open === null ? null : photos[open];
  return (
    <>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4">
        {photos.map((ph, i) => (
          <button
            key={ph.id}
            type="button"
            onClick={() => setOpen(i)}
            className="group relative aspect-square overflow-hidden rounded-xl bg-paper"
            title={ph.caption ?? undefined}
          >
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={ph.url} alt={ph.caption ?? `Photo de ${ph.author}`} loading="lazy" className="h-full w-full object-cover transition group-hover:scale-105" />
            <span className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/70 to-transparent p-2 text-left text-xs text-white opacity-0 transition group-hover:opacity-100">
              {ph.caption && <span className="line-clamp-2 font-semibold">{ph.caption}</span>}
              <span className="block opacity-80">{ph.author}</span>
            </span>
          </button>
        ))}
      </div>

      {p && (
        <div
          className="fixed inset-0 z-[100] flex flex-col bg-[#0b0f17]"
          role="dialog"
          aria-modal="true"
          aria-label={p.caption ?? "Photo de vol"}
          onClick={close}
        >
          <div className="flex items-center justify-between p-3 text-white">
            <span className="text-sm opacity-80">
              {open! + 1} / {photos.length}
            </span>
            <button type="button" onClick={close} className="rounded-full px-3 py-1 text-2xl hover:bg-white/10" aria-label="Fermer">
              ✕
            </button>
          </div>
          <div className="relative flex min-h-0 flex-1 items-center justify-center px-2" onClick={(e) => e.stopPropagation()}>
            {photos.length > 1 && (
              <button type="button" onClick={() => move(-1)} className="absolute left-2 z-10 rounded-full bg-white/10 px-3 py-2 text-2xl text-white hover:bg-white/20" aria-label="Photo précédente">
                ‹
              </button>
            )}
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={p.url} alt={p.caption ?? ""} className="max-h-full max-w-full object-contain" />
            {photos.length > 1 && (
              <button type="button" onClick={() => move(1)} className="absolute right-2 z-10 rounded-full bg-white/10 px-3 py-2 text-2xl text-white hover:bg-white/20" aria-label="Photo suivante">
                ›
              </button>
            )}
          </div>
          <div className="flex flex-wrap items-end justify-between gap-3 p-4 text-white" onClick={(e) => e.stopPropagation()}>
            <div className="min-w-0">
              {p.caption && <p className="font-semibold">{p.caption}</p>}
              <p className="text-sm opacity-80">
                {[p.author, p.route, p.aircraft, p.taken_on ? dateFr(p.taken_on) : null].filter(Boolean).join(" · ")}
              </p>
            </div>
            <div className="flex items-center gap-3">
              <a href={p.url} target="_blank" rel="noopener noreferrer" className="text-sm underline opacity-80 hover:opacity-100">
                Taille réelle
              </a>
              {(p.user_id === meId || admin) && (
                <form action={deleteFlightPhoto.bind(null, p.id)}>
                  <SubmitButton className="text-sm text-red-300 hover:underline" pending="…" confirm="Supprimer cette photo ?">
                    Supprimer
                  </SubmitButton>
                </form>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
