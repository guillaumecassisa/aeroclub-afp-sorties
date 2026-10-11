import type { Metadata } from "next";
import Link from "next/link";
import { requireMember } from "@/lib/auth";

export const metadata: Metadata = { title: "Préparer son vol" };

export default async function Page() {
  await requireMember();

  const externalTools = [
    {
      title: "Météo France Aviation",
      description: "Bulletins météo, TEMSI, vent en altitude pour la France.",
      href: "https://aviation.meteo.fr",
      icon: "🌤️",
    },
    {
      title: "Sofia Briefing",
      description: "Briefing météo aéronautique complet : METAR, TAF, SIGMET, vent en altitude.",
      href: "https://sofia.aero",
      icon: "🛫",
    },
  ];

  const internalTools = [
    {
      title: "Masse & centrage",
      description: "Calculer la masse et le centrage avant le vol.",
      href: "/centrage",
      icon: "⚖️",
    },
    {
      title: "Performances",
      description: "Distances de décollage et d'atterrissage selon les conditions.",
      href: "/centrage",
      icon: "📐",
    },
  ];

  const checklist = [
    { step: "Documentation personnelle", detail: "Licence, certificat médical, carnet de vol à jour." },
    { step: "Documents avion", detail: "Navigabilité, assurance, carnet de route, manuel de vol." },
    { step: "Météo", detail: "Consulter METAR, TAF, TEMSI et vent en altitude pour la route." },
    { step: "NOTAMs", detail: "Vérifier les NOTAMs sur la zone de vol et les terrains." },
    { step: "Plan de vol", detail: "Déposer si nécessaire (espace contrôlé, VFR nuit, vol en montagne…)." },
    { step: "Carburant", detail: "Calculer la quantité avec réserve réglementaire." },
    { step: "Masse et centrage", detail: "Vérifier les limites avec l'outil centrage de l'avion." },
    { step: "Fréquences", detail: "Préparer les fréquences radio (ATIS, tour, approche, FIS…)." },
    { step: "Briefing passagers", detail: "Boucles de sécurité, sortie de secours, mal des transports." },
  ];

  return (
    <>
      <div className="mb-6">
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">✈️ Préparer son vol</h1>
        <p className="text-sm text-muted">Ressources et checklist pour bien préparer chaque sortie.</p>
      </div>

      <div className="grid gap-6 lg:grid-cols-3">
        {/* Checklist */}
        <div className="lg:col-span-1">
          <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Checklist pré-vol</h2>
          <div className="card overflow-hidden">
            <ul className="divide-y divide-line">
              {checklist.map((item, i) => (
                <li key={i} className="flex items-start gap-3 px-4 py-3">
                  <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-sky-soft text-xs font-bold text-navy-2">
                    {i + 1}
                  </span>
                  <div>
                    <p className="text-sm font-medium text-ink">{item.step}</p>
                    <p className="text-xs text-muted">{item.detail}</p>
                  </div>
                </li>
              ))}
            </ul>
          </div>
        </div>

        {/* Outils */}
        <div className="lg:col-span-2 space-y-5">
          <div>
            <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Outils du club</h2>
            <div className="grid gap-3 sm:grid-cols-2">
              {internalTools.map((tool) => (
                <Link
                  key={tool.title}
                  href={tool.href}
                  className="card flex items-start gap-3 p-4 transition hover:shadow-md"
                >
                  <span className="text-2xl">{tool.icon}</span>
                  <div>
                    <p className="font-semibold text-navy-2">{tool.title}</p>
                    <p className="mt-0.5 text-xs text-muted">{tool.description}</p>
                  </div>
                </Link>
              ))}
            </div>
          </div>
          <div>
            <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Météo</h2>
            <div className="grid gap-3 sm:grid-cols-2">
              {externalTools.map((tool) => (
                <a
                  key={tool.href}
                  href={tool.href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="card flex items-start gap-3 p-4 transition hover:shadow-md"
                >
                  <span className="text-2xl">{tool.icon}</span>
                  <div>
                    <p className="font-semibold text-navy-2">{tool.title}</p>
                    <p className="mt-0.5 text-xs text-muted">{tool.description}</p>
                  </div>
                </a>
              ))}
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
