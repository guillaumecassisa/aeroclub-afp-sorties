"use client";

import { useEffect, useRef, useState } from "react";

/** Calculateur intégré sans cadre : la hauteur suit le contenu, une seule barre de défilement (celle de la page). */
export function PerfFrame({ src }: { src: string }) {
  const ref = useRef<HTMLIFrameElement>(null);
  const [h, setH] = useState(1400);
  useEffect(() => {
    const onMsg = (e: MessageEvent) => {
      if (e.origin !== window.location.origin || e.source !== ref.current?.contentWindow) return;
      const d = e.data as { type?: string; h?: number };
      if (d?.type === "perf-height" && typeof d.h === "number" && d.h > 200) {
        const need = Math.ceil(d.h) + 16;
        setH((cur) => (Math.abs(cur - need) > 2 ? need : cur));
      }
    };
    window.addEventListener("message", onMsg);
    // Le cadre a pu se charger avant cet écouteur : on mesure aussi directement (même site)
    const measure = () => {
      const doc = ref.current?.contentDocument;
      const wrap = doc?.querySelector(".wrap");
      if (doc?.readyState === "complete" && wrap) {
        const need = Math.ceil(wrap.getBoundingClientRect().bottom + doc.defaultView!.scrollY) + 16;
        if (need > 200) setH((cur) => (Math.abs(cur - need) > 2 ? need : cur));
      }
    };
    measure();
    const t = setInterval(measure, 1000);
    return () => {
      window.removeEventListener("message", onMsg);
      clearInterval(t);
    };
  }, []);
  return (
    <iframe
      ref={ref}
      src={src}
      title="Calculateur de performances décollage / atterrissage"
      scrolling="no"
      style={{ height: h }}
      className="block w-full border-0 bg-transparent"
    />
  );
}
