import type { NextConfig } from "next";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

// Empreinte des outils HTML : leur adresse change dès que leur contenu change (jamais d'ancienne copie en cache)
const toolsVersion = (() => {
  try {
    const h = createHash("sha1");
    for (const f of ["public/outils/performances.html", "public/outils/pistes.json"]) h.update(readFileSync(f));
    return h.digest("hex").slice(0, 10);
  } catch {
    return String(Date.now());
  }
})();

// Adresse de la base (Supabase) autorisée pour les images, envois de fichiers et connexions
const supaOrigin = (() => {
  try {
    return new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").origin;
  } catch {
    return "https://*.supabase.co";
  }
})();
const supa = `${supaOrigin} ${supaOrigin.replace(/^http/, "ws")}`;

// En-têtes de sécurité appliqués à toutes les pages
const securityHeaders = [
  { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains; preload" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "SAMEORIGIN" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=(), usb=()" },
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
  {
    key: "Content-Security-Policy",
    value: [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline'",
      "style-src 'self' 'unsafe-inline'",
      `img-src 'self' data: blob: ${supa.split(" ")[0]} https://tile.openstreetmap.org`,
      "font-src 'self' data:",
      `connect-src 'self' ${supa}`,
      "frame-src 'self'",
      "frame-ancestors 'self'",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'",
    ].join("; "),
  },
];

const nextConfig: NextConfig = {
  poweredByHeader: false,
  env: { TOOLS_VERSION: toolsVersion },
  // Envois de photos (affiches d'événements, réduites dans le navigateur) : 5 Mo maximum
  experimental: { serverActions: { bodySizeLimit: "5mb" } },
  async headers() {
    return [
      { source: "/:path*", headers: securityHeaders },
      // Outils HTML et leurs données : toujours la dernière version (pas de copie périmée dans le navigateur)
      { source: "/outils/:file*", headers: [{ key: "Cache-Control", value: "no-store, max-age=0" }] },
    ];
  },
};

export default nextConfig;
