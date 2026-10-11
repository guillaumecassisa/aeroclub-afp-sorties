import type { Metadata } from "next";
import { requireMember } from "@/lib/auth";

export const metadata: Metadata = { title: "Préparer son vol" };

export default async function Page() {
  await requireMember();

  const tools = [
    {
      title: "Météo – Météo France Aviation",
      description: "Bulletins météo, TEMSI, vent en altitude pour la France.",
      href: "https://aviation.meteo.fr",
      icon: "🌤️",
    },
    {
      title: "NOTAM – SIA",
      description: "Consultation des NOTAMs France sur le site du Service de l'Information Aéronautique.",
      href: "https://www.sia.aviation-civile.gouv.fr/",
      icon: "📋",
    },
    {
      title: "Plan de vol – SIA",
      description: "Déposer ou annuler un plan de vol via le portail SIA.",
      href: "https://www.sia.aviation-civile.gouv.fr/",
      icon: "✈️",
    },
    {
      title: "Aéroport.fr – Fiches terrain",
      description: "Fiches de terrains, fréquences, procédures et cartes VAC.",
      href: "https://www.aeroport.fr/",
      icon: "🛬",
    },
    {
      title: "SkyDemon",
      description: "Planification de vol VFR, météo intégrée, NOTAMs et espace aérien.",
      href: "https://www.skydemon.aero/",
      icon: "🗺️",
    },
    {
      title: "EuroFPL",
      description: "Dépôt de plan de vol IFR/VFR en ligne.",
      href: "https://www.eurofpl.eu/",
      icon: "📡",
    },
    {
      title: "WindyTy",
      description: "Visualisation des vents et du temps en altitude.",
      href: "https://www.windy.com/",
      icon: "💨",
    },
    {
      title: "Aviation Française – Espaces aériens",
      description: "Carte interactive des espaces aériens français.",
      href: "https://www.sia.aviation-civile.gouv.fr/documents/supp/map/",
      icon: "🗾",
    },
    {
      title: "METAR / TAF – NOAA",
      description: "Rapports METAR et prévisions TAF pour tous les aérodromes.",
      href: "https://aviationweather.gov/",
      icon: "📊",
    },
    {
      title: "Réglementation – DGAC",
      description: "Réglementation aéronautique, textes officiels, FCL.",
      href: "https://www.ecologie.gouv.fr/direction-generale-laviation-civile-dgac",
      icon: "📜",
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
        <div className="lg:col-span-2">
          <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Outils en ligne</h2>
          <div className="grid gap-3 sm:grid-cols-2">
            {tools.map((tool) => (
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
    </>
  );
}
