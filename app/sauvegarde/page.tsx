import type { Metadata } from "next";
import Link from "next/link";
import { requireAdmin } from "@/lib/auth";

export const metadata: Metadata = { title: "Sauvegarde" };

export default async function Page() {
  await requireAdmin();
  return (
    <div className="max-w-2xl space-y-5">
      <div>
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">Sauvegarde des données</h1>
        <p className="text-sm text-muted">
          Téléchargez une copie complète des données du club : membres, événements, bar, shop, flotte, documents (liste),
          pédagogie, REX, journal…
        </p>
      </div>

      <div className="card space-y-3 p-5">
        <a href="/sauvegarde/export" className="btn-primary inline-block">
          Télécharger la sauvegarde (.json)
        </a>
        <p className="text-xs text-muted">
          Le fichier contient des données personnelles : conservez-le dans un endroit sûr (pas en pièce jointe d&apos;email,
          pas sur un ordinateur partagé). Conseil : une sauvegarde par mois, et avant chaque grosse modification.
        </p>
      </div>

      <div className="card space-y-2 p-5 text-sm text-ink">
        <h2 className="font-semibold text-navy-2">Sauvegarde automatique</h2>
        <p>
          Le dépôt contient une sauvegarde automatique chaque nuit (base de données et fichiers, chiffrés). Elle s&apos;active une
          fois les secrets ajoutés dans GitHub : voir le guide <code>docs/SAUVEGARDES.md</code>.
        </p>
      </div>

      <Link href="/droits" className="text-sm text-sky hover:underline">
        ← Gestion des droits
      </Link>
    </div>
  );
}
