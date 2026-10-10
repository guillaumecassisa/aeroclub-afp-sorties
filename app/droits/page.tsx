import type { Metadata } from "next";
import { requireAdmin } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { Avatar } from "@/components/Avatar";
import type { Profile } from "@/lib/types";
import Link from "next/link";
import { anonymizeMember, assignFunction, removeFunction, setRole } from "./actions";
import { MemberSearch } from "./MemberSearch";

export const metadata: Metadata = { title: "Gestion des droits" };

type Fn = {
  key: string;
  label: string;
  text: string;
  has: (m: Profile) => boolean;
};

const FUNCTIONS: Fn[] = [
  {
    key: "admin",
    label: "Administrateur",
    text: "Tous les droits : gestion des droits, flotte, annonces, événements.",
    has: (m) => m.role === "admin",
  },
  {
    key: "instructeur",
    label: "Instructeur",
    text: "Crée et publie des événements, valide les propositions, gère les documents des avions.",
    has: (m) => m.is_instructor ?? m.role === "instructor",
  },
  {
    key: "secretaire",
    label: "Secrétaire",
    text: "Droits administrateur complets, avec le titre de secrétaire.",
    has: (m) => !!m.is_secretary,
  },
  {
    key: "tresorier",
    label: "Trésorier",
    text: "Seul à voir les consommations du bar de tous les membres ; gère les documents des avions.",
    has: (m) => !!m.is_treasurer,
  },
  {
    key: "maintenance",
    label: "Resp. maintenance",
    text: "Accès à « Flotte (maintenance) » (disponibilité des avions) et gestion des documents.",
    has: (m) => !!m.is_maintenance,
  },
];

const nameOf = (m: Profile) => m.full_name || m.email;

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const me = await requireAdmin();
  const sp = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.from("profiles").select("*").order("full_name");
  const all = ((data ?? []) as Profile[]).filter((m) => !m.anonymized_at);
  const deletionRequests = all.filter((m) => m.deletion_requested_at);
  const pending = all.filter((m) => m.role === "pending");
  const members = all.filter((m) => m.role !== "pending");
  const q = (sp.q ?? "").trim().toLowerCase();
  const shown = q ? members.filter((m) => `${m.full_name} ${m.email}`.toLowerCase().includes(q)) : members;

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">Gestion des droits</h1>
        <Link href="/journal" className="text-sm font-semibold text-sky hover:underline">
          Journal des modifications →
        </Link>
      </div>
      <p className="mb-5 text-sm text-muted">
        Tout le monde est <strong className="text-ink">membre</strong>. Les droits supplémentaires sont des{" "}
        <strong className="text-ink">fonctions</strong> que les administrateurs attribuent ou retirent ici.
      </p>

      {/* Comptes à valider */}
      {pending.length > 0 && (
        <section className="mb-6 rounded-lg border border-wait/30 bg-wait-soft p-4">
          <h2 className="mb-3 font-bold text-wait">
            {pending.length} compte{pending.length > 1 ? "s" : ""} en attente de validation
          </h2>
          <ul className="space-y-2">
            {pending.map((m) => (
              <li key={m.id} className="flex flex-wrap items-center gap-3 rounded-lg bg-white px-3 py-2.5">
                <Avatar url={m.avatar_url} name={nameOf(m)} size="sm" />
                <div className="min-w-0 flex-1">
                  <p className="truncate font-semibold text-ink">{m.full_name || "(sans nom)"}</p>
                  <p className="truncate text-xs text-muted">{m.email}</p>
                </div>
                <form action={setRole.bind(null, m.id)}>
                  <input type="hidden" name="role" value="member" />
                  <SubmitButton pending="…" className="btn-primary py-1.5">
                    Valider le compte
                  </SubmitButton>
                </form>
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* Demandes de suppression (RGPD) */}
      {deletionRequests.length > 0 && (
        <section className="mb-6 rounded-lg border border-danger/30 bg-danger-soft p-4">
          <h2 className="mb-1 font-bold text-danger">
            {deletionRequests.length} demande{deletionRequests.length > 1 ? "s" : ""} de suppression de compte
          </h2>
          <p className="mb-3 text-xs text-ink">
            RGPD : à traiter sous un mois. L&apos;anonymisation efface nom, email, téléphone, adresse, contact d&apos;urgence,
            photo, poids et lâchers ; l&apos;historique comptable du bar reste sous « Ancien membre ».
          </p>
          <ul className="space-y-2">
            {deletionRequests.map((m) => (
              <li key={m.id} className="flex flex-wrap items-center gap-3 rounded-lg bg-white px-3 py-2.5">
                <Avatar url={m.avatar_url} name={nameOf(m)} size="sm" />
                <div className="min-w-0 flex-1">
                  <p className="truncate font-semibold text-ink">{nameOf(m)}</p>
                  <p className="truncate text-xs text-muted">
                    Demandé le {new Date(m.deletion_requested_at!).toLocaleDateString("fr-FR")}
                  </p>
                </div>
                {m.id === me.id ? (
                  <span className="text-xs text-muted">Un autre administrateur doit traiter votre demande.</span>
                ) : (
                  <form action={anonymizeMember.bind(null, m.id)}>
                    <SubmitButton
                      pending="…"
                      className="btn-danger py-1.5"
                      confirm={`Effacer définitivement les données personnelles de ${nameOf(m)} ? Cette action est irréversible.`}
                    >
                      Effacer ses données
                    </SubmitButton>
                  </form>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}

      {/* Attribuer une fonction */}
      <section className="card mb-6 border-l-4 border-l-navy-2 p-5">
        <h2 className="mb-3 font-bold text-navy-2">Attribuer une fonction</h2>
        <form action={assignFunction} className="grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
          <label className="block">
            <span className="mb-1 block text-sm font-semibold text-ink">Membre</span>
            <select name="user" required defaultValue="" className="field">
              <option value="" disabled>
                Choisir un membre…
              </option>
              {members.map((m) => (
                <option key={m.id} value={m.id}>
                  {nameOf(m)}
                </option>
              ))}
            </select>
          </label>
          <label className="block">
            <span className="mb-1 block text-sm font-semibold text-ink">Fonction</span>
            <select name="fn" required defaultValue="" className="field">
              <option value="" disabled>
                Choisir une fonction…
              </option>
              {FUNCTIONS.map((f) => (
                <option key={f.key} value={f.key}>
                  {f.label}
                </option>
              ))}
            </select>
          </label>
          <SubmitButton pending="Attribution…" className="btn-primary">
            Attribuer
          </SubmitButton>
        </form>
      </section>

      {/* Fonctions et titulaires */}
      <h2 className="mb-3 text-lg font-bold tracking-tight text-navy-2">Fonctions</h2>
      <div className="mb-8 grid gap-3 sm:grid-cols-2">
        {FUNCTIONS.map((f) => {
          const holders = members.filter(f.has);
          return (
            <section key={f.key} className="card p-4">
              <div className="flex items-baseline justify-between gap-2">
                <h3 className="font-bold text-ink">{f.label}</h3>
                <span className="text-xs text-muted">{holders.length}</span>
              </div>
              <p className="mb-3 text-xs text-muted">{f.text}</p>
              {holders.length === 0 ? (
                <p className="text-sm text-muted">Personne pour l&apos;instant.</p>
              ) : (
                <ul className="flex flex-wrap gap-2">
                  {holders.map((m) => {
                    const locked = m.id === me.id && (f.key === "admin" || f.key === "secretaire");
                    return (
                      <li
                        key={m.id}
                        className="inline-flex items-center gap-1.5 rounded-full border border-line bg-paper py-1 pr-1 pl-3 text-sm text-ink"
                      >
                        {nameOf(m)}
                        {m.id === me.id && <span className="text-xs text-muted">(vous)</span>}
                        {locked ? (
                          <span className="px-1.5" />
                        ) : (
                          <form action={removeFunction.bind(null, m.id, f.key)}>
                            <SubmitButton
                              pending="…"
                              confirm={`Retirer la fonction « ${f.label} » à ${nameOf(m)} ?`}
                              className="grid size-6 place-items-center rounded-full text-muted hover:bg-danger/10 hover:text-danger"
                              aria-label={`Retirer ${f.label} à ${nameOf(m)}`}
                            >
                              ✕
                            </SubmitButton>
                          </form>
                        )}
                      </li>
                    );
                  })}
                </ul>
              )}
            </section>
          );
        })}
      </div>

      {/* Membres */}
      <div className="mb-3 flex flex-wrap items-end justify-between gap-3">
        <h2 className="text-lg font-bold tracking-tight text-navy-2">
          Membres <span className="text-sm font-normal text-muted">({members.length})</span>
        </h2>
        <MemberSearch initial={sp.q ?? ""} />
      </div>
      <ul className="card divide-y divide-line">
        {shown.map((m) => {
          const fns = FUNCTIONS.filter((f) => f.has(m));
          return (
            <li key={m.id} className="flex flex-wrap items-center gap-3 px-4 py-3">
              <Avatar url={m.avatar_url} name={nameOf(m)} size="sm" />
              <div className="min-w-0 flex-1">
                <p className="truncate font-semibold text-ink">
                  {m.full_name || "(sans nom)"}{" "}
                  {m.id === me.id && <span className="text-xs font-normal text-muted">(vous)</span>}
                </p>
                <p className="truncate text-xs text-muted">{m.email}</p>
              </div>
              <div className="flex flex-wrap gap-1.5">
                <span className="pill bg-paper text-muted">Membre</span>
                {fns.map((f) => (
                  <span key={f.key} className="pill bg-navy-2 text-white">
                    {f.label}
                  </span>
                ))}
              </div>
            </li>
          );
        })}
        {shown.length === 0 && <li className="p-6 text-center text-sm text-muted">Aucun membre ne correspond.</li>}
      </ul>
    </>
  );
}
