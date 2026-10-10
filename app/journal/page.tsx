import Link from "next/link";
import type { Metadata } from "next";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { formatShort } from "@/lib/dates";

export const metadata: Metadata = { title: "Journal des modifications" };

type Entry = {
  id: number;
  at: string;
  actor: string | null;
  action: "insert" | "update" | "delete";
  table_name: string;
  row_id: string | null;
  details: Record<string, unknown> | null;
};

const TABLES: Record<string, string> = {
  aircraft: "Avion",
  aircraft_documents: "Document avion",
  announcements: "Annonce",
  bar_products: "Produit du bar",
  bar_consumptions: "Consommation bar",
  bar_settlements: "Règlement bar",
  outings: "Événement",
  profiles: "Droits d'un membre",
};
const ROLES: Record<string, string> = {
  member: "membre",
  instructor: "instructeur",
  admin: "administrateur",
  pending: "sans accès",
};
const ACTIONS = { insert: "Ajout", update: "Modification", delete: "Suppression" } as const;
const FIELDS: Record<string, string> = {
  role: "niveau de droits",
  is_instructor: "instructeur",
  is_treasurer: "trésorier",
  is_secretary: "secrétaire",
  is_maintenance: "resp. maintenance",
  anonymized_at: "données effacées (RGPD)",
  archived_at: "retiré / archivé",
  available: "disponible",
  unavailable_reason: "motif d'indisponibilité",
  price_cents: "prix (centimes)",
  active: "actif",
  status: "statut",
  approval: "validation",
  title: "titre",
  name: "nom",
  category: "catégorie",
};

function label(e: Entry): string {
  const d = e.details ?? {};
  const name = (d.title ?? d.name ?? d.registration ?? d.product_name) as string | undefined;
  if (e.action === "update") {
    const parts = Object.entries(d)
      .filter(([k]) => !["updated_at", "archived_by"].includes(k))
      .map(([k, v]) => {
        const { avant, apres } = (v ?? {}) as { avant: unknown; apres: unknown };
        const f = (x: unknown) => {
          if (x === null || x === undefined) return "—";
          if (x === true) return "oui";
          if (x === false) return "non";
          const v = String(x);
          if (ROLES[v]) return ROLES[v];
          if (/^\d{4}-\d{2}-\d{2}T/.test(v)) return formatShort(v);
          return v;
        };
        return `${FIELDS[k] ?? k} : ${f(avant)} → ${f(apres)}`;
      });
    return parts.join(" · ") || "modification";
  }
  if (e.table_name === "bar_consumptions" && e.action === "delete")
    return `annulation de ${d.quantity ?? "?"} × ${d.product_name ?? "?"}`;
  return name ? `« ${name} »` : "";
}

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  await requireAdmin();
  const sp = await searchParams;
  const filter = sp.t && TABLES[sp.t] ? sp.t : null;
  const supabase = await createClient();
  let q = supabase.from("audit_log").select("*").order("at", { ascending: false }).limit(300);
  if (filter) q = q.eq("table_name", filter);
  const { data, error } = await q;
  const entries = (data ?? []) as Entry[];
  const ids = [...new Set(entries.flatMap((e) => [e.actor, e.table_name === "profiles" ? e.row_id : null]).filter(Boolean))] as string[];
  const { data: people } = ids.length
    ? await supabase.from("profiles").select("id, full_name, email").in("id", ids)
    : { data: [] };
  const names = new Map((people ?? []).map((p) => [p.id as string, (p.full_name || p.email) as string]));

  return (
    <>
      <Link href="/droits" className="mb-3 inline-block text-sm text-sky hover:underline">
        ← Gestion des droits
      </Link>
      <h1 className="text-2xl font-bold tracking-tight text-navy-2">Journal des modifications</h1>
      <p className="mb-4 text-sm text-muted">
        Chaque ajout, modification ou suppression sensible est enregistré ici automatiquement : qui, quoi, quand. Ce journal
        ne peut être ni modifié ni effacé, même par un administrateur. 300 dernières entrées.
      </p>
      {error && (
        <p className="mb-4 rounded-lg bg-danger-soft px-3 py-2 text-sm text-danger">
          Journal indisponible : exécutez le fichier « mise-a-jour-complete.sql » dans Supabase.
        </p>
      )}
      <nav className="mb-4 flex flex-wrap gap-1.5" aria-label="Filtrer">
        {[null, ...Object.keys(TABLES)].map((k) => (
          <Link
            key={k ?? "tout"}
            href={k ? `/journal?t=${k}` : "/journal"}
            className={`rounded-full border px-3 py-1.5 text-xs font-semibold ${
              filter === k ? "border-navy-2 bg-navy-2 text-white" : "border-line bg-white text-navy-2 hover:border-navy-2"
            }`}
          >
            {k ? TABLES[k] : "Tout"}
          </Link>
        ))}
      </nav>
      {entries.length === 0 ? (
        <div className="card p-8 text-center text-sm text-muted">Aucune entrée pour le moment.</div>
      ) : (
        <ul className="card divide-y divide-line">
          {entries.map((e) => (
            <li key={e.id} className="flex flex-wrap items-baseline gap-x-3 gap-y-1 px-4 py-2.5 text-sm">
              <span className="w-32 shrink-0 text-xs text-muted">{formatShort(e.at)}</span>
              <span
                className={`pill ${
                  e.action === "delete" ? "bg-danger-soft text-danger" : e.action === "insert" ? "bg-ok-soft text-ok" : "bg-sky-soft text-navy-2"
                }`}
              >
                {ACTIONS[e.action]}
              </span>
              <span className="font-semibold text-ink">
                {TABLES[e.table_name] ?? e.table_name}
                {e.table_name === "profiles" && e.row_id ? ` de ${names.get(e.row_id) ?? "?"}` : ""}
              </span>
              <span className="min-w-0 flex-1 text-ink">{label(e)}</span>
              <span className="text-xs text-muted">par {e.actor ? names.get(e.actor) ?? "?" : "système"}</span>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
