import type { Metadata } from "next";
import { notFound } from "next/navigation";
import Link from "next/link";
import { requireMember, canOrganize, isStaff } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { formatDateTime } from "@/lib/dates";
import { registerForOuting, cancelRegistration, cancelOuting } from "../actions";

export const dynamic = "force-dynamic";

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }): Promise<Metadata> {
  const { id } = await params;
  const supabase = await createClient();
  const { data } = await supabase.from("outings").select("title").eq("id", id).single();
  return { title: data?.title ?? "Événement" };
}

export default async function Page({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const { id } = await params;
  const sp = await searchParams;
  const me = await requireMember();
  const supabase = await createClient();

  const { data: outing } = await supabase
    .from("outings")
    .select("*, instructor:instructor_id(id, full_name, phone, avatar_url)")
    .eq("id", id)
    .single();

  if (!outing) notFound();

  const { data: regsRaw } = await supabase
    .from("registrations")
    .select("id, user_id, status, aircraft_id, created_at, member:user_id(full_name, phone, avatar_url)")
    .eq("outing_id", id)
    .neq("status", "cancelled")
    .order("created_at");

  const regs = regsRaw ?? [];
  const myReg = regs.find((r) => r.user_id === me.id);
  const confirmed = regs.filter((r) => r.status === "confirmed");
  const waitlist = regs.filter((r) => r.status === "waitlist");

  const { data: aircraftRaw } = await supabase
    .from("outing_aircraft")
    .select("aircraft:aircraft_id(id, registration, model, seats)")
    .eq("outing_id", id)
    .order("position");

  const aircraft = (aircraftRaw ?? []).map((r) => r.aircraft).filter(Boolean);

  const isOpen = outing.status === "open";
  const canManage = isStaff(me) || outing.instructor?.id === me.id;
  const hasDeadline = outing.registration_deadline && new Date(outing.registration_deadline) < new Date();

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />

      <div className="mb-6 flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link href="/sorties" className="mb-1 inline-flex items-center gap-1 text-sm text-muted hover:text-navy-2">
            ← Événements
          </Link>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">{outing.title}</h1>
          {outing.status === "cancelled" && (
            <span className="pill mt-1 bg-danger-soft text-danger">Annulé</span>
          )}
        </div>
        {canManage && isOpen && (
          <div className="flex gap-2">
            <Link href={`/sorties/${id}/modifier`} className="btn-secondary">
              Modifier
            </Link>
            <form action={cancelOuting.bind(null, id)}>
              <SubmitButton
                className="btn-secondary text-danger"
                pending="…"
                confirm="Annuler cette sortie ?"
              >
                Annuler la sortie
              </SubmitButton>
            </form>
          </div>
        )}
      </div>

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="lg:col-span-2 space-y-4">
          {/* Info */}
          <div className="card p-5 space-y-2 text-sm">
            <p>
              <span className="font-medium text-muted">Départ :</span>{" "}
              <span className="text-ink">{formatDateTime(outing.departure_at)}</span>
            </p>
            {outing.return_at && (
              <p>
                <span className="font-medium text-muted">Retour :</span>{" "}
                <span className="text-ink">{formatDateTime(outing.return_at)}</span>
              </p>
            )}
            {outing.destination && (
              <p>
                <span className="font-medium text-muted">Destination :</span>{" "}
                <span className="text-ink">{outing.destination}</span>
              </p>
            )}
            {outing.meeting_point && (
              <p>
                <span className="font-medium text-muted">Point de RDV :</span>{" "}
                <span className="text-ink">{outing.meeting_point}</span>
              </p>
            )}
            {outing.registration_deadline && (
              <p>
                <span className="font-medium text-muted">Inscription avant :</span>{" "}
                <span className="text-ink">{formatDateTime(outing.registration_deadline)}</span>
              </p>
            )}
            {outing.description && (
              <p className="mt-3 whitespace-pre-wrap text-ink">{outing.description}</p>
            )}
          </div>

          {/* Inscription */}
          {isOpen && !hasDeadline && (
            <div className="card p-5">
              {myReg ? (
                <div className="flex items-center justify-between gap-3">
                  <p className="text-sm font-medium text-ink">
                    {myReg.status === "confirmed" ? "✅ Vous êtes inscrit." : "⏳ Vous êtes sur liste d'attente."}
                  </p>
                  <form action={cancelRegistration.bind(null, myReg.id, id)}>
                    <SubmitButton
                      className="btn-secondary text-danger text-sm"
                      pending="…"
                      confirm="Annuler votre inscription ?"
                    >
                      Se désinscrire
                    </SubmitButton>
                  </form>
                </div>
              ) : (
                <form action={registerForOuting.bind(null, id)}>
                  {aircraft.length > 0 && (
                    <div className="mb-3">
                      <label className="mb-1 block text-sm font-medium text-ink">Avion préféré</label>
                      <select name="aircraft_id" className="field">
                        <option value="">Sans préférence</option>
                        {aircraft.map((a: { id: string; registration: string; model: string }) => (
                          <option key={a.id} value={a.id}>
                            {a.registration} · {a.model}
                          </option>
                        ))}
                      </select>
                    </div>
                  )}
                  <SubmitButton className="btn-primary" pending="Inscription…">
                    S&apos;inscrire
                  </SubmitButton>
                </form>
              )}
            </div>
          )}
          {isOpen && hasDeadline && !myReg && (
            <p className="text-sm text-muted">Les inscriptions sont closes.</p>
          )}
        </div>

        {/* Participants */}
        <div className="space-y-4">
          <div className="card overflow-hidden">
            <div className="border-b border-line px-4 py-3">
              <h2 className="font-semibold text-navy-2">Inscrits ({confirmed.length})</h2>
            </div>
            {confirmed.length === 0 ? (
              <p className="px-4 py-4 text-sm text-muted">Aucun inscrit pour l&apos;instant.</p>
            ) : (
              <ul className="divide-y divide-line">
                {confirmed.map((r) => {
                  const m = r.member as { full_name: string } | null;
                  return (
                    <li key={r.id} className="px-4 py-2 text-sm text-ink">
                      {m?.full_name ?? "—"}
                    </li>
                  );
                })}
              </ul>
            )}
          </div>

          {waitlist.length > 0 && (
            <div className="card overflow-hidden">
              <div className="border-b border-line px-4 py-3">
                <h2 className="font-semibold text-navy-2">Liste d&apos;attente ({waitlist.length})</h2>
              </div>
              <ul className="divide-y divide-line">
                {waitlist.map((r, i) => {
                  const m = r.member as { full_name: string } | null;
                  return (
                    <li key={r.id} className="flex items-center gap-2 px-4 py-2 text-sm text-ink">
                      <span className="text-xs text-muted">{i + 1}.</span>
                      {m?.full_name ?? "—"}
                    </li>
                  );
                })}
              </ul>
            </div>
          )}
        </div>
      </div>
    </>
  );
}
