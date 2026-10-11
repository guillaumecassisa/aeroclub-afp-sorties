import Link from "next/link";
import type { Metadata } from "next";
import { requireMember, canOrganize } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { formatDate, formatTime, dayBadge } from "@/lib/dates";

export const metadata: Metadata = { title: "Événements" };
export const dynamic = "force-dynamic";

const KIND_ICON: Record<string, string> = {
  vol: "✈️",
  activite: "🏍️",
  evenement: "🥂",
};

type Outing = {
  id: string;
  title: string;
  destination: string | null;
  departure_at: string;
  return_at: string | null;
  status: string;
  kind: string | null;
  max_participants: number | null;
  instructor: { full_name: string } | null;
};

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const me = await requireMember();
  const sp = await searchParams;
  const supabase = await createClient();

  const { data } = await supabase
    .from("outings")
    .select("id, title, destination, departure_at, return_at, status, kind, max_participants, instructor:instructor_id(full_name)")
    .order("departure_at", { ascending: true });

  // Get user registrations
  const { data: myRegs } = await supabase
    .from("registrations")
    .select("outing_id, status")
    .eq("user_id", me.id)
    .neq("status", "cancelled");

  const myRegMap = new Map((myRegs ?? []).map((r) => [r.outing_id, r.status]));

  const outings = (data ?? []) as unknown as Outing[];
  const now = new Date();
  const upcoming = outings.filter((o) => o.status === "open" && new Date(o.departure_at) >= now);
  const past = outings.filter((o) => o.status !== "open" || new Date(o.departure_at) < now);

  const organizer = canOrganize(me);

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />
      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">Événements</h1>
          <p className="text-sm text-muted">Sorties, activités et événements du club.</p>
        </div>
        {organizer && (
          <Link href="/sorties/nouvelle" className="btn-primary">
            + Créer
          </Link>
        )}
      </div>

      {upcoming.length === 0 && past.length === 0 && (
        <div className="card p-8 text-center text-muted">Aucun événement pour le moment.</div>
      )}

      {upcoming.length > 0 && (
        <section className="mb-8">
          <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">À venir</h2>
          <div className="space-y-3">
            {upcoming.map((o) => (
              <OutingCard key={o.id} outing={o} myStatus={myRegMap.get(o.id)} />
            ))}
          </div>
        </section>
      )}

      {past.length > 0 && (
        <section>
          <h2 className="mb-3 text-sm font-semibold tracking-wide text-muted uppercase">Passés / annulés</h2>
          <div className="space-y-3">
            {past.map((o) => (
              <OutingCard key={o.id} outing={o} myStatus={myRegMap.get(o.id)} muted />
            ))}
          </div>
        </section>
      )}
    </>
  );
}

function OutingCard({ outing: o, myStatus, muted }: { outing: Outing; myStatus?: string; muted?: boolean }) {
  const badge = dayBadge(o.departure_at);
  const icon = KIND_ICON[o.kind ?? "vol"] ?? "✈️";
  return (
    <Link
      href={`/sorties/${o.id}`}
      className={`card flex gap-4 p-4 transition hover:shadow-md ${muted ? "opacity-60" : ""}`}
    >
      <div className="flex w-12 shrink-0 flex-col items-center justify-center rounded-xl bg-sky-soft py-2 text-navy-2">
        <span className="text-[10px] font-semibold uppercase tracking-wide">{badge.weekday}</span>
        <span className="text-2xl font-bold leading-none">{badge.day}</span>
        <span className="text-[11px] font-medium uppercase">{badge.month}</span>
      </div>

      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-start justify-between gap-1">
          <p className="font-semibold text-ink">
            <span aria-hidden>{icon}</span> {o.title}
          </p>
          {o.status === "cancelled" && <span className="pill bg-danger-soft text-danger">Annulé</span>}
          {myStatus === "confirmed" && o.status !== "cancelled" && <span className="pill bg-ok-soft text-ok">Inscrit ✓</span>}
          {myStatus === "waitlist" && <span className="pill bg-wait-soft text-wait">Liste d&apos;attente</span>}
        </div>
        {o.destination && <p className="text-sm text-muted">{o.destination}</p>}
        <p className="mt-1 text-xs text-muted">
          {formatDate(o.departure_at)} · {formatTime(o.departure_at)}
        </p>
      </div>
    </Link>
  );
}
