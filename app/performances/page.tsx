import Link from "next/link";
import type { Metadata } from "next";
import { requireMember } from "@/lib/auth";
import { PerfFrame } from "./PerfFrame";

export const metadata: Metadata = { title: "Performances décollage / atterrissage" };

// Le numéro de version force le navigateur à recharger le calculateur après chaque mise à jour du site
const VERSION = (process.env.VERCEL_GIT_COMMIT_SHA ?? "local").slice(0, 7);
const CALCULATEUR_URL = `/outils/performances.html?v=${VERSION}`;
const EMBED_URL = `${CALCULATEUR_URL}&embed=1`;

export default async function Page() {
  await requireMember();
  return (
    <>
      <Link href="/preparer-son-vol" className="mb-3 inline-block text-sm text-sky hover:underline">
        ← Préparer son vol
      </Link>
      <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">Performances décollage / atterrissage</h1>
          <p className="text-sm text-muted">
            Distances de décollage et d&apos;atterrissage des avions du club, d&apos;après les manuels de vol.
          </p>
        </div>
        <a href={CALCULATEUR_URL} target="_blank" rel="noopener noreferrer" className="btn-secondary">
          Ouvrir en plein écran ↗
        </a>
      </div>

      <PerfFrame src={EMBED_URL} />

      <p className="mt-3 text-xs text-muted">
        Outil d&apos;aide à la préparation du vol : les résultats ne remplacent pas le manuel de vol de l&apos;avion ni le
        jugement du commandant de bord.
      </p>
    </>
  );
}
