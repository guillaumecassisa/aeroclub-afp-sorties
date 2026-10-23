"use server";

import { after } from "next/server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { parisLocalToISO } from "@/lib/dates";
import { requireMember } from "@/lib/auth";
import {
  emailConfigured,
  notifyEventPublished,
  notifyNewProposal,
  notifyOutingCancelled,
  notifyReview,
  notifySeatChanges,
} from "@/lib/email";
import type { FormState, OutingDetail, OutingKind, SeatChange } from "@/lib/types";

/*
 * Toutes les écritures passent par les fonctions de la base (save_outing, register_for_outing,
 * cancel_registration, cancel_outing, review_outing, move_crew) : ce sont elles qui appliquent
 * les droits, l'ordre d'inscription, la liste d'attente et la répartition dans les avions.
 * Les tables outings / registrations / outing_aircraft sont en lecture seule pour le site.
 */

function back(id: string, key: "ok" | "erreur", msg: string): never {
  revalidatePath("/");
  revalidatePath("/sorties");
  revalidatePath(`/sorties/${id}`);
  redirect(`/sorties/${id}?${key}=${encodeURIComponent(msg)}`);
}

type OutingInfo = { id: string; title: string; departure_at: string };

async function outingInfo(id: string): Promise<OutingInfo | null> {
  const supabase = await createClient();
  const { data } = await supabase.from("outings").select("id, title, departure_at").eq("id", id).maybeSingle();
  return (data as OutingInfo | null) ?? null;
}

/** Prévient tous les membres (qui l'acceptent) qu'un événement vient d'être publié. */
async function announcePublished(outingId: string): Promise<string> {
  const supabase = await createClient();
  const [{ data: rec }, { data: o }] = await Promise.all([
    supabase.rpc("event_mail_recipients", { p_outing: outingId }),
    supabase
      .from("outings")
      .select("title, kind, departure_at, destination, meeting_point, description, max_participants, instructor_id")
      .eq("id", outingId)
      .maybeSingle(),
  ]);
  const recipients = (rec ?? []) as { email: string; full_name: string }[];
  if (!o || !recipients.length) return "";
  const { data: dir } = await supabase.rpc("member_directory");
  const organizer =
    ((dir ?? []) as { id: string; full_name: string }[]).find((m) => m.id === o.instructor_id)?.full_name ?? null;
  const kind = (o.kind as string) ?? "vol";
  after(() =>
    notifyEventPublished(recipients, {
      id: outingId,
      title: o.title as string,
      kind,
      dates: [o.departure_at as string],
      destination: o.destination as string | null,
      meeting_point: o.meeting_point as string | null,
      description: o.description as string | null,
      places: kind === "vol" ? null : o.max_participants ? String(o.max_participants) : "illimitées",
      organizer,
    }),
  );
  return emailConfigured() ? ` ${recipients.length} membre(s) prévenu(s) par email.` : "";
}

export async function saveOuting(_prev: FormState, formData: FormData): Promise<FormState> {
  const me = await requireMember();

  const id = String(formData.get("id") ?? "").trim() || null;
  const kind = (String(formData.get("kind") ?? "vol") || "vol") as OutingKind;
  const title = String(formData.get("title") ?? "").trim();
  const destination = String(formData.get("destination") ?? "").trim() || null;
  const meeting_point = String(formData.get("meeting_point") ?? "").trim() || null;
  const description = String(formData.get("description") ?? "").trim() || null;
  const departure_at = parisLocalToISO(String(formData.get("departure_at") ?? ""));
  const return_at = parisLocalToISO(String(formData.get("return_at") ?? "")) || null;
  const deadline = parisLocalToISO(String(formData.get("registration_deadline") ?? "")) || null;
  const flies = formData.get("instructor_flies") === "on";
  const aircraft = kind === "vol" ? formData.getAll("aircraft").map(String).filter(Boolean) : [];
  let instructorAircraft = flies ? String(formData.get("instructor_aircraft") ?? "").trim() || null : null;
  if (instructorAircraft && !aircraft.includes(instructorAircraft)) instructorAircraft = aircraft[0] ?? null;
  const maxRaw = String(formData.get("max_participants") ?? "").trim();
  const max = kind !== "vol" && maxRaw ? Number(maxRaw) : null;

  if (!title) return { error: "Le titre est obligatoire." };
  if (!departure_at) return { error: "La date de départ est obligatoire." };
  if (return_at && return_at < departure_at) return { error: "Le retour doit être après le départ." };
  if (kind === "vol" && aircraft.length === 0) return { error: "Sélectionnez au moins un avion." };
  if (max !== null && (!Number.isInteger(max) || max < 1)) return { error: "Le nombre de places doit être un entier positif." };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_outing", {
    p_id: id,
    p_title: title,
    p_destination: destination,
    p_description: description,
    p_meeting_point: meeting_point,
    p_departure_at: departure_at,
    p_return_at: return_at,
    p_deadline: deadline,
    p_aircraft: aircraft,
    p_instructor_aircraft: kind === "vol" ? instructorAircraft : null,
    p_kind: kind,
    p_max_participants: max,
  });
  if (error) return { error: error.message };

  const res = data as {
    outing_id: string;
    approval: "approved" | "pending" | "rejected";
    changes: SeatChange[];
    notify_staff?: { email: string; full_name: string }[];
  };
  const info: OutingInfo = { id: res.outing_id, title, departure_at };
  await notifySeatChanges(res.changes, info);

  let msg: string;
  if (res.approval !== "approved") {
    await notifyNewProposal(res.notify_staff, info, me.full_name ?? "Un membre");
    msg = id
      ? "Proposition modifiée : elle repart en validation auprès des instructeurs."
      : "Proposition envoyée : un instructeur ou un administrateur va la valider avant publication.";
  } else if (id) {
    msg = "Événement mis à jour.";
  } else {
    msg = "Événement créé : les membres peuvent s'inscrire." + (await announcePublished(res.outing_id));
  }
  const promoted = (res.changes ?? []).filter((c) => c.change === "promoted").length;
  const demoted = (res.changes ?? []).filter((c) => c.change === "demoted").length;
  if (promoted) msg += ` ${promoted} personne(s) sortie(s) de la liste d'attente.`;
  if (demoted) msg += ` ${demoted} personne(s) repassée(s) en liste d'attente faute de place.`;

  revalidatePath("/");
  revalidatePath("/sorties");
  revalidatePath(`/sorties/${res.outing_id}`);
  redirect(`/sorties/${res.outing_id}?ok=${encodeURIComponent(msg)}`);
}

export async function registerSelf(outingId: string) {
  await requireMember();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("register_for_outing", { p_outing: outingId });
  if (error) back(outingId, "erreur", error.message);
  const res = data as { status: string; waitlist_position: number | null };
  if (res.status === "confirmed") back(outingId, "ok", "Vous êtes inscrit : votre place est confirmée.");

  // En attente alors qu'il reste des sièges : aucun avion compatible avec ses lâchers
  const { data: o } = await supabase.rpc("get_outing", { p_id: outingId });
  const detail = o as OutingDetail | null;
  const free = (detail?.aircraft ?? []).some((a) => a.occupants.length < a.capacity);
  back(
    outingId,
    "ok",
    free
      ? `Vous êtes en liste d'attente (position ${res.waitlist_position}) : il reste des sièges, mais sur des avions où vous n'êtes pas lâché et sans instructeur à bord. ` +
          "Vérifiez vos lâchers dans « Mon compte » ; vous serez placé automatiquement dès qu'un siège compatible se libère ou qu'un instructeur rejoint un avion."
      : `C'est complet : vous êtes en liste d'attente (position ${res.waitlist_position}). Vous serez prévenu par email si une place se libère.`,
  );
}

export async function addMember(outingId: string, formData: FormData) {
  await requireMember();
  const userId = String(formData.get("user_id") ?? "");
  if (!userId) back(outingId, "erreur", "Choisissez un membre.");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("register_for_outing", { p_outing: outingId, p_user: userId });
  if (error) back(outingId, "erreur", error.message);
  const res = data as { status: string; waitlist_position: number | null };
  back(
    outingId,
    "ok",
    res.status === "confirmed"
      ? "Membre inscrit (place confirmée)."
      : `Membre ajouté en liste d'attente (position ${res.waitlist_position}).`,
  );
}

export async function cancelRegistration(outingId: string, registrationId: string, self: boolean) {
  await requireMember();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("cancel_registration", { p_registration: registrationId });
  if (error) back(outingId, "erreur", error.message);
  const changes = ((data as { changes?: SeatChange[] } | null)?.changes ?? []) as SeatChange[];
  const info = await outingInfo(outingId);
  if (info) await notifySeatChanges(changes, info);
  const promoted = changes.filter((c) => c.change === "promoted").map((c) => c.full_name);
  back(
    outingId,
    "ok",
    (self ? "Vous êtes désinscrit." : "Participant retiré.") +
      (promoted.length ? ` ${promoted.join(", ")} passe de la liste d'attente aux participants.` : ""),
  );
}

export async function cancelOuting(outingId: string) {
  await requireMember();
  const info = await outingInfo(outingId);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("cancel_outing", { p_id: outingId });
  if (error) back(outingId, "erreur", error.message);
  const recipients = ((data as { recipients?: { email: string; full_name: string }[] } | null)?.recipients ?? []);
  if (info) await notifyOutingCancelled(recipients, info);
  back(
    outingId,
    "ok",
    `Événement annulé.${recipients.length && emailConfigured() ? ` ${recipients.length} inscrit(s) prévenu(s) par email.` : ""}`,
  );
}

export async function withdrawProposal(outingId: string) {
  await requireMember();
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_outing", { p_id: outingId });
  if (error) back(outingId, "erreur", error.message);
  revalidatePath("/sorties");
  redirect(`/sorties?ok=${encodeURIComponent("Proposition retirée.")}`);
}

export async function reviewOuting(outingId: string, approve: boolean, formData: FormData) {
  await requireMember();
  const reason = String(formData.get("reason") ?? "").trim() || null;
  if (!approve && !reason) back(outingId, "erreur", "Indiquez le motif du refus pour le proposant.");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("review_outing", { p_id: outingId, p_approve: approve, p_reason: reason });
  if (error) back(outingId, "erreur", error.message);
  const r = data as { email: string; full_name: string; title: string; departure_at: string } | null;
  if (r) await notifyReview(r, { id: outingId, title: r.title, departure_at: r.departure_at }, approve, reason);
  const informed = approve ? await announcePublished(outingId) : "";
  back(
    outingId,
    "ok",
    approve
      ? `Événement validé et publié : les membres peuvent s'inscrire.${informed}`
      : "Proposition refusée. Le proposant est prévenu et peut la corriger.",
  );
}

/** Change une personne d'avion (« organizer » = l'organisateur), ou l'échange avec quelqu'un déjà à bord. */
export async function moveCrew(outingId: string, formData: FormData) {
  await requireMember();
  const who = String(formData.get("who") ?? "");
  const target = String(formData.get("target") ?? "");
  if (!who || !target) back(outingId, "erreur", "Choisissez un avion.");
  // target = "<aircraft_id>" (place libre) ou "<aircraft_id>|<registration_id ou organizer>" (échange)
  const [aircraftId, withWho] = target.split("|");
  const supabase = await createClient();
  const { error } = await supabase.rpc("move_crew", {
    p_outing: outingId,
    p_who: who,
    p_aircraft: aircraftId,
    p_with: withWho || null,
  });
  if (error) back(outingId, "erreur", error.message);
  back(outingId, "ok", withWho ? "Places échangées." : "Équipage modifié.");
}
