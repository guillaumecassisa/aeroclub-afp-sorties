import Link from "next/link";
import type { Metadata } from "next";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { addLink, deleteLink, updateLink } from "./actions";

export const metadata: Metadata = { title: "Liens de l'accueil" };

type L = { id: string; section: string; title: string; subtitle: string | null; url: string; icon: string | null; position: number };

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  await requireAdmin();
  const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from("club_links").select("*").order("section").order("position").order("title");
  const links = (data ?? []) as L[];

  return (
    <>
      <Link href="/" className="mb-3 inline-block text-sm text-sky hover:underline">
        ← Accueil
      </Link>
      <Banner ok={sp.ok} erreur={sp.erreur} />
      <h1 className="text-2xl font-bold tracking-tight text-navy-2">Liens de l&apos;accueil</h1>
      <p className="mb-5 text-sm text-muted">
        « Outils de vol » et « Liens » affichés en bas de l&apos;accueil. Réservé aux administrateurs. L&apos;ordre suit le
        numéro de position.
      </p>

      {(["outils", "liens"] as const).map((section) => (
        <section key={section} className="mb-6">
          <h2 className="mb-2 font-bold text-navy-2">{section === "outils" ? "Outils de vol" : "Liens"}</h2>
          <ul className="space-y-2">
            {links
              .filter((l) => l.section === section)
              .map((l) => (
                <li key={l.id} className="card p-3">
                  <form action={updateLink.bind(null, l.id)} className="grid gap-2 sm:grid-cols-[4rem_1fr_1fr_2fr_4rem_auto] sm:items-center">
                    <input type="hidden" name="section" value={section} />
                    <input name="icon" defaultValue={l.icon ?? ""} aria-label="Icône" className="field py-1.5 text-center" />
                    <input name="title" defaultValue={l.title} aria-label="Titre" className="field py-1.5" required />
                    <input name="subtitle" defaultValue={l.subtitle ?? ""} aria-label="Sous-titre" className="field py-1.5" />
                    <input name="url" defaultValue={l.url} aria-label="Adresse" className="field py-1.5" required />
                    <input name="position" type="number" defaultValue={l.position} aria-label="Position" className="field py-1.5" />
                    <SubmitButton className="btn-secondary py-1.5" pending="…">
                      Enregistrer
                    </SubmitButton>
                  </form>
                  <form action={deleteLink.bind(null, l.id)} className="mt-1 text-right">
                    <SubmitButton
                      className="text-xs font-semibold text-danger hover:underline"
                      pending="…"
                      confirm={`Retirer « ${l.title} » de l'accueil ?`}
                    >
                      Retirer
                    </SubmitButton>
                  </form>
                </li>
              ))}
          </ul>
        </section>
      ))}

      <section className="card p-5">
        <h2 className="mb-3 font-bold text-navy-2">Ajouter un lien</h2>
        <form action={addLink} className="grid gap-3 sm:grid-cols-2">
          <label className="block">
            <span className="label">Rubrique</span>
            <select name="section" className="field" defaultValue="outils">
              <option value="outils">Outils de vol</option>
              <option value="liens">Liens</option>
            </select>
          </label>
          <label className="block">
            <span className="label">Titre</span>
            <input name="title" className="field" placeholder="Ex. Aérogest Online" required maxLength={60} />
          </label>
          <label className="block">
            <span className="label">Sous-titre (facultatif)</span>
            <input name="subtitle" className="field" placeholder="Ex. Réservation & planning" maxLength={80} />
          </label>
          <label className="block">
            <span className="label">Adresse</span>
            <input name="url" className="field" placeholder="https://…" required />
          </label>
          <label className="block">
            <span className="label">Icône (un emoji, facultatif)</span>
            <input name="icon" className="field" placeholder="✈️" maxLength={8} />
          </label>
          <label className="block">
            <span className="label">Position</span>
            <input name="position" type="number" className="field" defaultValue={10} />
          </label>
          <div className="sm:col-span-2">
            <SubmitButton pending="Ajout…">Ajouter</SubmitButton>
          </div>
        </form>
      </section>
    </>
  );
}
