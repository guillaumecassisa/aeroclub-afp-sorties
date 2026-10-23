import Link from "next/link";
import type { Metadata } from "next";
import { requireMember, canOrganize, isStaff } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner, StatusPill } from "@/components/Banner";
import { formatWhen, dayBadge } from "@/lib/dates";
import type { OutingSummary } from "@/lib/types";

export const metadata: Metadata = { title: "Événements" };
export const dynamic = "force-dynamic";

const KIND_ICON: Record<string, string> = { vol: "✈️", activite: "🏍️", evenement: "🥂", formation: "🎓" };

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const me = await requireMember();
  const sp = await searchParams;
  const supabase = await createClient();

  // list_outings applique la visibilité : publiés pour tous, propositions pour leur auteur et les organisateurs
  const [{ data: up, error }, { data: pastRaw }] = await Promise.all([
    supabase.rpc("list_outings", { p_past: false }),
    supabase.rpc("list_outings", { p_past: true }),
  ]);
  const all = (up ?? []) as OutingSummary[];
  const toReview = all.filter((o) => o.approval && o.approval !== "approved" && o.status === "open");
  const published = all.filter((o) => (!o.approval || o.approval === "approved") && o.status === "open");
  const upcoming = published.filter((o) => o.departure_at);
  const projects = published.filter((o) => !o.departure_at);
  const cancelled = all.filter((o) => o.status === "cancelled");
  const past = [...cancelled, ...((pastRaw ?? []) as OutingSummary[])].slice(0, 30);

  const organizer = canOrganize(me);

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur ?? error?.message} />
      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">Événements</h1>
          <p className="text-sm text-muted">Sorties, activités et événements du club. Places attribuées dans l&apos;ordre d&apos;inscription.</p>
        </div>
        <Link href="/sorties/nouvelle" className="btn-primary">
          {organizer ? "+ Créer" : "+ Proposer un événement"}
        </Link>
      </div>

      {toReview.length > 0 && (
        <section className="mb-8">
          <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">
            {isStaff(me) ? "Propositions à valider" : "Mes propositions"}
          </h2>
          <div className="space-y-3">
            {toReview.map((o) => (
              <OutingCard key={o.id} outing={o} />
            ))}
          </div>
        </section>
      )}

      {upcoming.length === 0 && projects.length === 0 && past.length === 0 && toReview.length === 0 && (
        <div className="card p-8 text-center text-muted">Aucun événement pour le moment.</div>
      )}

      {upcoming.length > 0 && (
        <section className="mb-8">
          <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">À venir</h2>
          <div className="space-y-3">
            {upcoming.map((o) => (
              <OutingCard key={o.id} outing={o} />
            ))}
          </div>
        </section>
      )}

      {projects.length > 0 && (
        <section className="mb-8">
          <h2 className="mb-1 text-sm font-semibold tracking-wide text-muted uppercase">📌 Projets · date à définir</h2>
          <p className="mb-3 text-xs text-muted">Inscrivez-vous pour montrer votre intérêt : vous serez prévenu(e) quand la date sera fixée.</p>
          <div className="space-y-3">
            {projects.map((o) => (
              <OutingCard key={o.id} outing={o} />
            ))}
          </div>
        </section>
      )}

      {past.length > 0 && (
        <section>
          <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">Passés / annulés</h2>
          <div className="space-y-3">
            {past.map((o) => (
              <OutingCard key={o.id} outing={o} muted />
            ))}
          </div>
        </section>
      )}
    </>
  );
}

function places(o: OutingSummary) {
  if (o.total_capacity == null) return `${o.confirmed_count} inscrit(s)`;
  const left = Math.max(o.total_capacity - o.confirmed_count, 0);
  if (left === 0) return o.waitlist_count ? `Complet · ${o.waitlist_count} en attente` : "Complet";
  return `${left} place${left > 1 ? "s" : ""} libre${left > 1 ? "s" : ""} sur ${o.total_capacity}`;
}

function OutingCard({ outing: o, muted }: { outing: OutingSummary; muted?: boolean }) {
  const badge = dayBadge(o.departure_at);
  const icon = KIND_ICON[o.kind ?? "vol"] ?? "✈️";
  const cancelled = o.status === "cancelled";
  return (
    <Link
      href={`/sorties/${o.id}`}
      className={`card flex gap-4 p-4 transition hover:shadow-md ${muted ? "opacity-60" : ""}`}
    >
      <div
        className={`flex w-12 shrink-0 flex-col items-center justify-center rounded-xl py-2 ${
          o.departure_at ? "bg-sky-soft text-navy-2" : "bg-wait-soft text-wait"
        }`}
      >
        <span className="text-[10px] font-semibold uppercase tracking-wide">{badge.weekday}</span>
        <span className="text-2xl font-bold leading-none">{badge.day}</span>
        <span className="text-[11px] font-medium uppercase">{badge.month}</span>
      </div>

      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-start justify-between gap-1">
          <p className="font-semibold text-ink">
            <span aria-hidden>{icon}</span> {o.title}
          </p>
          <div className="flex flex-wrap gap-1">
            {cancelled && <span className="pill bg-danger-soft text-danger">Annulé</span>}
            {o.approval === "pending" && !cancelled && <span className="pill bg-wait-soft text-wait">À valider</span>}
            {o.approval === "rejected" && !cancelled && <span className="pill bg-danger-soft text-danger">Refusée</span>}
            {!cancelled && <StatusPill status={o.my_status} />}
          </div>
        </div>
        {o.destination && <p className="text-sm text-muted">{o.destination}</p>}
        <p className="mt-1 text-xs text-muted">
          {formatWhen(o.departure_at)} · par {o.instructor_name}
          {!cancelled && !muted && <> · {places(o)}</>}
        </p>
        {o.aircraft_summary && <p className="mt-0.5 text-xs text-muted">{o.aircraft_summary}</p>}
      </div>
    </Link>
  );
}
