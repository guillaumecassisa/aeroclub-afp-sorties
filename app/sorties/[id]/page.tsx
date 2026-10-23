import type { Metadata } from "next";
import { notFound } from "next/navigation";
import Link from "next/link";
import { requireMember, canOrganize, isStaff } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner, StatusPill } from "@/components/Banner";
import { Avatar } from "@/components/Avatar";
import { SubmitButton } from "@/components/ui";
import { formatDateTime } from "@/lib/dates";
import { KIND_LABELS, type OutingDetail, type OutingKind, type Person } from "@/lib/types";
import {
  addGuest,
  addMember,
  cancelOuting,
  cancelRegistration,
  moveCrew,
  registerSelf,
  reviewOuting,
  setGuestCount,
  withdrawProposal,
} from "../actions";

export const dynamic = "force-dynamic";
export const metadata: Metadata = { title: "Événement" };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
  if (!UUID.test(id)) notFound();

  const supabase = await createClient();
  const { data } = await supabase.rpc("get_outing", { p_id: id });
  if (!data) notFound();
  const o = data as OutingDetail;

  const kind = (o.kind ?? "vol") as OutingKind;
  const isFlight = kind === "vol";
  const now = new Date();
  const cancelled = o.status === "cancelled";
  const started = new Date(o.departure_at) <= now;
  const deadlinePassed = !!o.registration_deadline && new Date(o.registration_deadline) < now;
  const approved = !o.approval || o.approval === "approved";
  const organizer = canOrganize(me) || !!o.is_organizer; // peut gérer les inscrits et les équipages
  const staff = isStaff(me); // peut retirer un inscrit, valider une proposition
  const mine = o.my_registration && (o.my_registration.status as string) !== "cancelled" ? o.my_registration : null;

  const occupants = isFlight ? o.aircraft.flatMap((a) => a.occupants) : (o.participants ?? []);
  const capacity = isFlight ? o.aircraft.reduce((s, a) => s + a.capacity, 0) : (o.max_participants ?? null);
  const free = capacity == null ? null : Math.max(capacity - occupants.length, 0);
  const canRegister = approved && !cancelled && !started && !deadlinePassed && !mine;
  const isMeOrganizerOnboard = !!o.is_organizer && !!o.instructor_aircraft_id;

  // Membres pouvant être ajoutés par un organisateur
  let addable: { id: string; full_name: string }[] = [];
  if (organizer && approved && !cancelled && !started) {
    const { data: dir } = await supabase.rpc("member_directory");
    const taken = new Set([...occupants, ...o.waitlist].map((p) => p.user_id));
    addable = ((dir ?? []) as { id: string; full_name: string }[]).filter(
      (m) => !taken.has(m.id) && !(m.id === o.instructor.id && o.instructor_aircraft_id),
    );
  }

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />

      <div className="mb-6 flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link href="/sorties" className="mb-1 inline-flex items-center gap-1 text-sm text-muted hover:text-navy-2">
            ← Événements
          </Link>
          <h1 className="text-2xl font-bold tracking-tight text-navy-2">{o.title}</h1>
          <div className="mt-1 flex flex-wrap gap-1">
            <span className="pill bg-sky-soft text-navy-2">{KIND_LABELS[kind]}</span>
            {cancelled && <span className="pill bg-danger-soft text-danger">Annulé</span>}
            {o.approval === "pending" && !cancelled && <span className="pill bg-wait-soft text-wait">En attente de validation</span>}
            {o.approval === "rejected" && !cancelled && <span className="pill bg-danger-soft text-danger">Proposition refusée</span>}
            {!cancelled && <StatusPill status={mine?.status ?? null} />}
          </div>
        </div>
        {!cancelled && (
          <div className="flex flex-wrap gap-2">
            {o.can_edit && !started && (
              <Link href={`/sorties/${id}/modifier`} className="btn-secondary">
                Modifier
              </Link>
            )}
            {approved && canOrganize(me) && (
              <form action={cancelOuting.bind(null, id)}>
                <SubmitButton className="btn-danger" pending="…" confirm="Annuler cet événement ? Les inscrits seront prévenus.">
                  Annuler l&apos;événement
                </SubmitButton>
              </form>
            )}
            {!approved && o.is_organizer && (
              <form action={withdrawProposal.bind(null, id)}>
                <SubmitButton className="btn-danger" pending="…" confirm="Retirer votre proposition ?">
                  Retirer la proposition
                </SubmitButton>
              </form>
            )}
          </div>
        )}
      </div>

      {/* Validation d'une proposition */}
      {!approved && !cancelled && (
        <div className="card mb-6 space-y-3 border-wait p-5">
          {o.approval === "rejected" && o.rejection_reason && (
            <p className="text-sm text-danger">
              <span className="font-semibold">Motif du refus :</span> {o.rejection_reason}
            </p>
          )}
          {staff ? (
            <>
              <p className="text-sm text-ink">
                Proposé par <strong>{o.instructor.full_name}</strong>. Les membres ne voient cet événement qu&apos;une fois validé.
              </p>
              <div className="flex flex-wrap items-end gap-3">
                <form action={reviewOuting.bind(null, id, true)}>
                  <SubmitButton pending="Publication…">Valider et publier</SubmitButton>
                </form>
                <form action={reviewOuting.bind(null, id, false)} className="flex flex-wrap items-end gap-2">
                  <input name="reason" className="field w-64" placeholder="Motif du refus (envoyé au proposant)" maxLength={300} />
                  <SubmitButton className="btn-secondary" pending="…">
                    Refuser
                  </SubmitButton>
                </form>
              </div>
            </>
          ) : (
            <p className="text-sm text-ink">
              Votre proposition attend la validation d&apos;un instructeur ou d&apos;un administrateur. Vous pouvez encore la modifier.
            </p>
          )}
        </div>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          {/* Infos */}
          <div className="card space-y-2 p-5 text-sm">
            <Info label="Départ" value={formatDateTime(o.departure_at)} />
            {o.return_at && <Info label="Retour" value={formatDateTime(o.return_at)} />}
            {o.destination && <Info label={isFlight ? "Destination" : "Lieu"} value={o.destination} />}
            {o.meeting_point && <Info label="Rendez-vous" value={o.meeting_point} />}
            {o.registration_deadline && <Info label="Inscriptions jusqu'au" value={formatDateTime(o.registration_deadline)} />}
            <p className="flex items-center gap-2">
              <span className="font-medium text-muted">Organisateur :</span>
              <Avatar url={o.instructor.avatar_url} name={o.instructor.full_name} size="xs" />
              <span className="text-ink">{o.instructor.full_name}</span>
              {o.instructor.phone && (
                <a href={`tel:${o.instructor.phone}`} className="text-sky hover:underline">
                  {o.instructor.phone}
                </a>
              )}
            </p>
            {capacity != null && (
              <Info
                label="Places"
                value={`${occupants.length} / ${capacity}${free === 0 ? " — complet" : ""}${o.waitlist.length ? ` · ${o.waitlist.length} en liste d'attente` : ""}`}
              />
            )}
            {o.description && <p className="whitespace-pre-line pt-2 text-ink">{o.description}</p>}
          </div>

          {/* Mon inscription */}
          {!cancelled && approved && (
            <div className="card p-5">
              {mine ? (
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <p className="text-sm text-ink">
                    {mine.status === "confirmed"
                      ? "Votre place est confirmée."
                      : `Vous êtes en liste d'attente (position ${o.waitlist.find((w) => w.registration_id === mine.id)?.position ?? "?"}). Vous serez prévenu par email si une place se libère.`}
                  </p>
                  {!started && (
                    <form action={cancelRegistration.bind(null, id, mine.id, true)}>
                      <SubmitButton className="btn-secondary text-danger" pending="…" confirm="Annuler votre inscription ?">
                        Se désinscrire
                      </SubmitButton>
                    </form>
                  )}
                </div>
              ) : null}
              {mine && o.guests_allowed && !started && (
                <GuestBox o={o} isFlight={isFlight} outingId={id} />
              )}
              {mine ? null : isMeOrganizerOnboard ? (
                <p className="text-sm text-muted">Vous êtes à bord en tant qu&apos;organisateur.</p>
              ) : canRegister ? (
                <form action={registerSelf.bind(null, id)} className="flex flex-wrap items-center justify-between gap-3">
                  <p className="text-sm text-muted">
                    {free === 0 ? "C'est complet : vous serez placé en liste d'attente." : "Places attribuées dans l'ordre d'inscription."}
                  </p>
                  <SubmitButton pending="Inscription…">{free === 0 ? "Rejoindre la liste d'attente" : "S'inscrire"}</SubmitButton>
                </form>
              ) : (
                <p className="text-sm text-muted">{started ? "L'événement a eu lieu." : "Les inscriptions sont closes."}</p>
              )}
            </div>
          )}

          {/* Avions et équipages */}
          {isFlight && o.aircraft.length > 0 && (
            <div className="grid gap-4 sm:grid-cols-2">
              {o.aircraft.map((a) => (
                <div key={a.id} className="card overflow-hidden">
                  <div className="flex items-center justify-between border-b border-line px-4 py-3">
                    <h2 className="font-semibold text-navy-2">
                      {a.registration} <span className="text-sm font-normal text-muted">· {a.model}</span>
                    </h2>
                    <span className="text-xs text-muted">
                      {a.occupants.length + (a.instructor_onboard ? 1 : 0)} / {a.seats} sièges
                    </span>
                  </div>
                  <ul className="divide-y divide-line">
                    {a.instructor_onboard && (
                      <li className="flex items-center gap-2 px-4 py-2 text-sm">
                        <Avatar url={o.instructor.avatar_url} name={o.instructor.full_name} size="xs" />
                        <span className="text-ink">{o.instructor.full_name}</span>
                        <span className="pill bg-sky-soft text-navy-2">Organisateur</span>
                        {organizer && !started && <MoveForm outingId={id} who="organizer" from={a.id} o={o} />}
                      </li>
                    )}
                    {a.occupants.map((p) => (
                      <PersonRow key={p.registration_id} p={p} outingId={id} canRemove={staff && !started}>
                        {!p.released && a.type && <span className="pill bg-wait-soft text-wait">non lâché {a.type}</span>}
                        {organizer && !started && <MoveForm outingId={id} who={p.registration_id} from={a.id} o={o} />}
                      </PersonRow>
                    ))}
                    {Array.from({ length: Math.max(a.capacity - a.occupants.length, 0) }).map((_, i) => (
                      <li key={i} className="px-4 py-2 text-sm text-muted">Place libre</li>
                    ))}
                  </ul>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="space-y-4">
          {!isFlight && (
            <PeopleCard title={`Participants (${occupants.length})`} empty="Aucun inscrit pour l'instant.">
              {occupants.map((p) => (
                <PersonRow key={p.registration_id} p={p} outingId={id} canRemove={staff && !started} />
              ))}
            </PeopleCard>
          )}

          {o.waitlist.length > 0 && (
            <PeopleCard title={`Liste d'attente (${o.waitlist.length})`}>
              {o.waitlist.map((p) => (
                <PersonRow key={p.registration_id} p={p} outingId={id} canRemove={staff && !started}>
                  <span className="text-xs text-muted">n° {p.position}</span>
                </PersonRow>
              ))}
            </PeopleCard>
          )}

          {addable.length > 0 && (
            <form action={addMember.bind(null, id)} className="card space-y-2 p-4">
              <label htmlFor="add-member" className="block text-sm font-medium text-ink">
                Inscrire un membre
              </label>
              <select id="add-member" name="user_id" className="field" defaultValue="" required>
                <option value="" disabled>
                  Choisir…
                </option>
                {addable.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.full_name}
                  </option>
                ))}
              </select>
              <SubmitButton className="btn-secondary w-full" pending="…">
                Inscrire
              </SubmitButton>
            </form>
          )}
        </div>
      </div>
    </>
  );
}

function Info({ label, value }: { label: string; value: string }) {
  return (
    <p>
      <span className="font-medium text-muted">{label} :</span> <span className="text-ink">{value}</span>
    </p>
  );
}

function PeopleCard({ title, empty, children }: { title: string; empty?: string; children: React.ReactNode[] }) {
  return (
    <div className="card overflow-hidden">
      <div className="border-b border-line px-4 py-3">
        <h2 className="font-semibold text-navy-2">{title}</h2>
      </div>
      {children.length === 0 ? (
        <p className="px-4 py-4 text-sm text-muted">{empty}</p>
      ) : (
        <ul className="divide-y divide-line">{children}</ul>
      )}
    </div>
  );
}

function PersonRow({
  p,
  outingId,
  canRemove,
  children,
}: {
  p: Person;
  outingId: string;
  canRemove: boolean;
  children?: React.ReactNode;
}) {
  return (
    <li className="flex flex-wrap items-center gap-2 px-4 py-2 text-sm">
      <Avatar url={p.avatar_url} name={p.full_name} size="xs" />
      <span className="text-ink">{p.full_name}</span>
      {p.phone && (
        <a href={`tel:${p.phone}`} className="text-xs text-sky hover:underline">
          {p.phone}
        </a>
      )}
      {p.is_guest && <span className="pill bg-paper text-muted">accompagnant{p.host_name ? ` de ${p.host_name}` : ""}</span>}
      {p.weight_kg != null && <span className="text-xs text-muted">{p.weight_kg} kg</span>}
      {children}
      {canRemove && (
        <form action={cancelRegistration.bind(null, outingId, p.registration_id, false)} className="ml-auto">
          <SubmitButton className="text-xs text-danger hover:underline" pending="…" confirm={`Retirer ${p.full_name} ?`}>
            Retirer
          </SubmitButton>
        </form>
      )}
    </li>
  );
}

/** Choix d'un autre avion : place libre, ou échange avec une personne déjà à bord. */
function MoveForm({ outingId, who, from, o }: { outingId: string; who: string; from: string; o: OutingDetail }) {
  const options: { value: string; label: string }[] = [];
  for (const a of o.aircraft) {
    if (a.id === from) continue;
    const used = a.occupants.length + (a.instructor_onboard ? 1 : 0);
    if (used < a.seats && !(who === "organizer" && a.occupants.length >= a.seats - 1)) {
      options.push({ value: a.id, label: `→ ${a.registration} (place libre)` });
    }
    if (a.instructor_onboard && who !== "organizer") {
      options.push({ value: `${a.id}|organizer`, label: `⇄ ${o.instructor.full_name} (${a.registration})` });
    }
    for (const p of a.occupants) {
      options.push({ value: `${a.id}|${p.registration_id}`, label: `⇄ ${p.full_name} (${a.registration})` });
    }
  }
  if (!options.length) return null;
  return (
    <form action={moveCrew.bind(null, outingId)} className="ml-auto flex items-center gap-1">
      <input type="hidden" name="who" value={who} />
      <select name="target" className="field py-1 text-xs" defaultValue="" required aria-label="Changer d'avion">
        <option value="" disabled>
          Changer d&apos;avion…
        </option>
        {options.map((op) => (
          <option key={op.value} value={op.value}>
            {op.label}
          </option>
        ))}
      </select>
      <SubmitButton className="btn-secondary px-2 py-1 text-xs" pending="…">
        OK
      </SubmitButton>
    </form>
  );
}

/** Mes accompagnants : 1 (nom + poids) pour une sortie avion, 0 à 5 pour un événement sans avion. */
function GuestBox({ o, isFlight, outingId }: { o: OutingDetail; isFlight: boolean; outingId: string }) {
  if (isFlight) {
    const g = o.my_guest;
    return (
      <div className="mt-4 border-t border-line pt-4">
        {g ? (
          <div className="flex flex-wrap items-center justify-between gap-3 text-sm">
            <p className="text-ink">
              Votre accompagnant : <strong>{g.name}</strong>
              {g.weight_kg != null && <> ({g.weight_kg} kg)</>} —{" "}
              {g.status === "confirmed" ? "place confirmée" : "en liste d'attente"}.
            </p>
            <form action={cancelRegistration.bind(null, outingId, g.id, true)}>
              <SubmitButton className="btn-secondary text-danger" pending="…" confirm={`Retirer ${g.name} ?`}>
                Retirer
              </SubmitButton>
            </form>
          </div>
        ) : (
          <form action={addGuest.bind(null, outingId)} className="flex flex-wrap items-end gap-2">
            <div className="min-w-48 flex-1">
              <label htmlFor="guest_name" className="label">Ajouter un accompagnant (+1, ne pilote pas)</label>
              <input id="guest_name" name="guest_name" className="field" placeholder="Prénom et nom" required maxLength={120} />
            </div>
            <div className="w-28">
              <label htmlFor="guest_weight" className="label">Poids (kg)</label>
              <input id="guest_weight" name="guest_weight" className="field" inputMode="decimal" placeholder="75" required />
            </div>
            <SubmitButton className="btn-secondary" pending="…">Ajouter</SubmitButton>
            <p className="w-full text-xs text-muted">
              Il/elle prend un siège libre, après vous. Le poids sert au calcul de masse et centrage. Une participation pourra être demandée.
            </p>
          </form>
        )}
      </div>
    );
  }
  const n = o.my_guest_count ?? 0;
  return (
    <form action={setGuestCount.bind(null, outingId)} className="mt-4 flex flex-wrap items-end gap-2 border-t border-line pt-4">
      <div>
        <label htmlFor="guests" className="label">Je viens avec</label>
        <select id="guests" name="guests" className="field" defaultValue={String(n)}>
          {[0, 1, 2, 3, 4, 5].map((k) => (
            <option key={k} value={k}>
              {k === 0 ? "personne (je viens seul·e)" : `${k} accompagnant${k > 1 ? "s" : ""}`}
            </option>
          ))}
        </select>
      </div>
      <SubmitButton className="btn-secondary" pending="…">Enregistrer</SubmitButton>
    </form>
  );
}
