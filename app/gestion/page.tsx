import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { canManageDocs, canManageFleet, canTeach, isTreasurer, requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = { title: "Gestion du club" };
export const dynamic = "force-dynamic";

type Tile = { href: string; icon: string; title: string; text: string; badge?: number };

/** Point d'entrée unique des outils de gestion, selon les fonctions de chacun. */
export default async function Page() {
  const me = await requireMember();
  const admin = me.role === "admin";
  const tiles: { section: string; items: Tile[] }[] = [];

  let pending = 0;
  let deletions = 0;
  if (admin) {
    const supabase = await createClient();
    const { data } = await supabase.from("profiles").select("role, deletion_requested_at, anonymized_at");
    for (const p of data ?? []) {
      if (p.anonymized_at) continue;
      if (p.role === "pending") pending++;
      if (p.deletion_requested_at) deletions++;
    }
    tiles.push({
      section: "Membres et club",
      items: [
        { href: "/droits", icon: "👥", title: "Membres et droits", text: "Valider les comptes, attribuer les fonctions, demandes RGPD.", badge: pending + deletions },
        { href: "/infos-club", icon: "🏛️", title: "Informations du club", text: "Nom, adresse, directeur de publication : mentions légales." },
        { href: "/liens", icon: "🔗", title: "Liens utiles", text: "Liens affichés dans « Préparer son vol »." },
        { href: "/journal", icon: "📜", title: "Journal des modifications", text: "Qui a changé quoi, et quand." },
        { href: "/sauvegarde", icon: "💾", title: "Sauvegarde", text: "Télécharger une copie complète des données." },
      ],
    });
  }
  const money: Tile[] = [];
  if (isTreasurer(me)) money.push({ href: "/bar/tresorerie", icon: "🧾", title: "Trésorerie du bar", text: "Ardoises du mois, encaissements, carte du bar." });
  if (admin) money.push({ href: "/shop/admin", icon: "🛍️", title: "Shop (gestion)", text: "Articles, commandes, livraisons." });
  if (admin || isTreasurer(me)) money.push({ href: "/stats", icon: "📊", title: "Statistiques", text: "Chiffre d'affaires du bar et du shop." });
  if (money.length) tiles.push({ section: "Bar et shop", items: money });

  const fleet: Tile[] = [];
  if (canManageFleet(me)) fleet.push({ href: "/maintenance", icon: "🛠️", title: "Flotte (maintenance)", text: "Avions, disponibilités, immobilisations." });
  if (canManageDocs(me)) fleet.push({ href: "/flotte/import", icon: "📂", title: "Importer des documents", text: "Manuels, check-lists, fiches de pesée des avions." });
  if (fleet.length) tiles.push({ section: "Flotte", items: fleet });

  if (canTeach(me))
    tiles.push({
      section: "Pédagogie",
      items: [
        { href: "/pedagogie?onglet=rex", icon: "🛡️", title: "Retours d'expérience", text: "Analyser et publier les REX." },
        { href: "/pedagogie?onglet=annonces", icon: "📣", title: "Annonces et documents", text: "Publier dans l'Espace pédagogique." },
      ],
    });

  if (!tiles.length) redirect("/");

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">Gestion du club</h1>
        <p className="text-sm text-muted">Les outils correspondant à vos fonctions.</p>
      </div>
      {tiles.map((g) => (
        <section key={g.section}>
          <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">{g.section}</h2>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {g.items.map((t) => (
              <Link key={t.href} href={t.href} className="card flex items-start gap-3 p-4 transition hover:shadow-md">
                <span className="text-2xl" aria-hidden>{t.icon}</span>
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-2 font-semibold text-navy-2">
                    {t.title}
                    {!!t.badge && <span className="pill bg-danger-soft text-danger">{t.badge}</span>}
                  </span>
                  <span className="mt-0.5 block text-xs text-muted">{t.text}</span>
                </span>
              </Link>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
