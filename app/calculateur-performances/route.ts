import { readFileSync } from "node:fs";
import { join } from "node:path";

// Calculateur de performances servi par le site lui-même (et non comme simple fichier statique) :
// chaque mise en ligne sert forcément la version qui vient d'être construite, jamais une ancienne copie.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const VERSION = process.env.TOOLS_VERSION ?? "dev";
let html: string | null = null;

export function GET() {
  if (!html) {
    html = readFileSync(join(process.cwd(), "public", "outils", "performances.html"), "utf8").replace(
      '<footer id="footerText">',
      `<div style="margin-top:4px;font-size:11px;color:#8a94a6">Calculateur version ${VERSION}</div>\n  <footer id="footerText">`,
    );
  }
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store, max-age=0",
    },
  });
}
