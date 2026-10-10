import Link from "next/link";
import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { canManageDocs, requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { formatShort } from "@/lib/dates";
import { SubmitButton } from "@/components/ui";
import { DOC_BUCKET, DOC_CATEGORIES, formatSize, type AircraftDocument } from "@/lib/docs";
import type { Aircraft } from "@/lib/types";
import { deleteDocument, restoreDocument, updateDocument } from "../actions";
import { DocUploader } from "./DocUploader";
import { AircraftSwitcher } from "./AircraftSwitcher";

export const metadata: Metadata = { title: "Documentation avion" };

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const me = await requireMember();
  const { id } = await params;
  const supabase = await createClient();
  const [{ data: a }, { data: fleet }] = await Promise.all([
    supabase.from("aircraft").select("*").eq("id", id).maybeSingle(),
    supabase.from("aircraft").select("id, registration, model").eq("active", true).order("type").order("registration"),
  ]);
  if (!a) notFound();
  const fleetList = (fleet ?? []) as { id: string; registration: string; model: string }[];
  if (!fleetList.some((f) => f.id === id)) fleetList.unshift({ id, registration: a.registration, model: a.model });
  const aircraft = a as Aircraft;
  const manager = canManageDocs(me);

  const { data: rows } = await supabase
    .from("aircraft_documents")
    .select("*")
    .eq("aircraft_id", id)
    .order("title");
  const all = (rows ?? []) as (AircraftDocument & { archived_at?: string | null })[];
  const docs = all.filter((d) => !d.archived_at);
  const archived = manager ? all.filter((d) => d.archived_at) : [];

  // Liens de téléchargement temporaires (1 h) : les fichiers restent privés au club
  const urls = new Map<string, string>();
  if (docs.length) {
    const { data: signed } = await supabase.storage
      .from(DOC_BUCKET)
      .createSignedUrls(
        docs.map((d) => d.file_path),
        3600,
      );
    for (const s of signed ?? []) if (s.path && s.signedUrl) urls.set(s.path, s.signedUrl);
  }

  const groups = DOC_CATEGORIES.map((c) => ({ ...c, docs: docs.filter((d) => d.category === c.key) })).filter(
    (g) => g.docs.length > 0,
  );
  const down = aircraft.available === false;

  return (
    <>
      <Link href="/flotte" className="mb-3 inline-block text-sm text-sky hover:underline">
        ← Toute la flotte
      </Link>
      <AircraftSwitcher current={id} fleet={fleetList} tab="fiche" />

      <section className="card overflow-hidden">
        <div className="relative overflow-hidden bg-navy-2 px-5 py-6 text-white sm:px-6">
          <span aria-hidden className="pointer-events-none absolute -top-6 right-10 h-40 w-5 skew-x-[-28deg] bg-red sm:right-16" />
          <span aria-hidden className="pointer-events-none absolute -top-6 right-18 h-40 w-2 skew-x-[-28deg] bg-white/15 sm:right-24" />
          <h1 className="font-mono text-3xl font-bold tracking-wider">{aircraft.registration}</h1>
          <p className="mt-1 text-white/85">
            {aircraft.model} · {aircraft.seats} places
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2 px-5 py-3 sm:px-6">
          <span className="pill bg-sky-soft text-navy-2">Type {aircraft.type}</span>
          <span className={`pill ${down ? "bg-danger-soft text-danger" : "bg-ok-soft text-ok"}`}>
            {down ? `Indisponible${aircraft.unavailable_reason ? ` · ${aircraft.unavailable_reason}` : ""}` : "Disponible"}
          </span>
          <span className="ml-auto text-sm text-muted">
            {docs.length} document{docs.length > 1 ? "s" : ""}
          </span>
        </div>
      </section>

      {/* Sommaire */}
      {groups.length > 1 && (
        <nav className="mt-4 flex flex-wrap gap-1.5" aria-label="Catégories">
          {groups.map((g) => (
            <a
              key={g.key}
              href={`#${g.key}`}
              className="rounded-full border border-line bg-white px-3 py-1.5 text-xs font-semibold text-navy-2 hover:border-navy-2"
            >
              {g.label} ({g.docs.length})
            </a>
          ))}
        </nav>
      )}

      {docs.length === 0 && (
        <div className="card mt-4 p-8 text-center text-muted">
          Aucun document pour cet avion pour le moment.
          {manager && " Ajoutez-en avec le formulaire ci-dessous."}
        </div>
      )}

      {groups.map((g) => (
        <section key={g.key} id={g.key} className="mt-6 scroll-mt-28">
          <h2 className="mb-2 text-lg font-bold tracking-tight text-navy-2">{g.label}</h2>
          <ul className="card divide-y divide-line">
            {g.docs.map((d) => {
              const url = urls.get(d.file_path);
              return (
                <li key={d.id} className="px-4 py-3">
                  <div className="flex items-center gap-3">
                    <FileIcon name={d.file_name} />
                    <div className="min-w-0 flex-1">
                      {url ? (
                        <a href={url} target="_blank" rel="noopener noreferrer" className="font-semibold text-navy-2 hover:underline">
                          {d.title}
                        </a>
                      ) : (
                        <span className="font-semibold text-ink">{d.title}</span>
                      )}
                      <p className="truncate text-xs text-muted">
                        {d.file_name}
                        {d.size_bytes ? ` · ${formatSize(d.size_bytes)}` : ""} · ajouté le {formatShort(d.created_at)}
                      </p>
                    </div>
                    {url && (
                      <a href={url} target="_blank" rel="noopener noreferrer" className="btn-secondary shrink-0 py-1.5">
                        Ouvrir
                      </a>
                    )}
                  </div>
                  {manager && (
                    <details className="mt-2 pl-11">
                      <summary className="cursor-pointer text-xs font-semibold text-sky">Modifier</summary>
                      <div className="mt-2 flex flex-wrap items-end gap-2">
                        <form action={updateDocument.bind(null, d.id, id)} className="flex flex-wrap items-end gap-2">
                          <input name="title" defaultValue={d.title} className="field w-64 py-1.5 text-sm" aria-label="Titre" required />
                          <select name="category" defaultValue={d.category} className="field w-auto py-1.5 text-sm" aria-label="Catégorie">
                            {DOC_CATEGORIES.map((c) => (
                              <option key={c.key} value={c.key}>
                                {c.label}
                              </option>
                            ))}
                          </select>
                          <SubmitButton className="btn-secondary py-1.5" pending="…">
                            Enregistrer
                          </SubmitButton>
                        </form>
                        <form action={deleteDocument.bind(null, d.id, id)}>
                          <SubmitButton
                            className="btn-danger py-1.5"
                            pending="…"
                            confirm={`Retirer « ${d.title} » ? Il sera archivé et pourra être restauré.`}
                          >
                            Retirer
                          </SubmitButton>
                        </form>
                      </div>
                    </details>
                  )}
                </li>
              );
            })}
          </ul>
        </section>
      ))}

      {manager && <DocUploader aircraftId={id} />}

      {archived.length > 0 && (
        <details className="card mt-6 p-4">
          <summary className="cursor-pointer text-sm font-semibold text-muted">
            Documents retirés ({archived.length}) — archivés, jamais effacés
          </summary>
          <ul className="mt-3 divide-y divide-line">
            {archived.map((d) => (
              <li key={d.id} className="flex items-center gap-3 py-2 text-sm">
                <FileIcon name={d.file_name} />
                <span className="min-w-0 flex-1 truncate text-muted">
                  {d.title} · retiré le {formatShort(d.archived_at!)}
                </span>
                <form action={restoreDocument.bind(null, d.id, id)}>
                  <SubmitButton className="btn-secondary py-1.5" pending="…">
                    Restaurer
                  </SubmitButton>
                </form>
              </li>
            ))}
          </ul>
        </details>
      )}
    </>
  );
}

function FileIcon({ name }: { name: string }) {
  const ext = (name.split(".").pop() ?? "").toUpperCase().slice(0, 4);
  const color = ext === "PDF" ? "bg-red" : ["JPG", "JPEG", "PNG", "WEBP"].includes(ext) ? "bg-ok" : "bg-navy-2";
  return (
    <span className={`flex h-9 w-8 shrink-0 items-end justify-center rounded-sm pb-1 text-[9px] font-bold text-white ${color}`}>
      {ext || "DOC"}
    </span>
  );
}
