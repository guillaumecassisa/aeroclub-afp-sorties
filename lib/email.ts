import { formatDateTime } from "@/lib/dates";
import type { SeatChange } from "@/lib/types";

import { CLUB_NAME } from "@/lib/club";
export { CLUB_NAME };
const SITE_URL = (process.env.NEXT_PUBLIC_SITE_URL || "").replace(/\/$/, "");

type Mail = { to?: string; bcc?: string[]; subject: string; text: string };

/**
 * Envoi d'email. Deux possibilités (variables d'environnement Vercel) :
 *  - SMTP (ex. une adresse Gmail du club + mot de passe d'application) : SMTP_USER, SMTP_PASS
 *    (SMTP_HOST / SMTP_PORT facultatifs, Gmail par défaut) ;
 *  - Resend : RESEND_API_KEY + EMAIL_FROM (domaine vérifié).
 * Sans configuration, rien n'est envoyé (journal seulement) et le site fonctionne normalement.
 */
async function send(mail: Mail) {
  const smtpUser = process.env.SMTP_USER;
  const smtpPass = process.env.SMTP_PASS;
  const resendKey = process.env.RESEND_API_KEY;
  const label = mail.to ?? `${mail.bcc?.length ?? 0} destinataire(s) en copie cachée`;

  if (smtpUser && smtpPass) {
    const nodemailer = await import("nodemailer");
    const port = Number(process.env.SMTP_PORT || 465);
    const transport = nodemailer.createTransport({
      host: process.env.SMTP_HOST || "smtp.gmail.com",
      port,
      secure: port === 465,
      auth: { user: smtpUser, pass: smtpPass },
    });
    const from = process.env.EMAIL_FROM || `"${CLUB_NAME}" <${smtpUser}>`;
    try {
      await transport.sendMail({
        from,
        to: mail.to ?? from,
        bcc: mail.bcc,
        subject: mail.subject,
        text: mail.text,
      });
    } catch (e) {
      console.error(`[email] échec d'envoi (${label}) :`, e);
    }
    return;
  }

  const from = process.env.EMAIL_FROM;
  if (resendKey && from) {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to: [mail.to ?? from], bcc: mail.bcc, subject: mail.subject, text: mail.text }),
    });
    if (!res.ok) console.error(`[email] échec d'envoi (${label}) : ${res.status} ${await res.text()}`);
    return;
  }

  console.info(`[email désactivé] ${label} — ${mail.subject}`);
}

export function emailConfigured() {
  return !!((process.env.SMTP_USER && process.env.SMTP_PASS) || (process.env.RESEND_API_KEY && process.env.EMAIL_FROM));
}

async function sendAll(mails: Mail[]) {
  // Un échec d'email ne doit jamais faire échouer l'action de l'utilisateur
  await Promise.allSettled(mails.map(send));
}

type OutingInfo = { id: string; title: string; departure_at: string };

function link(o: OutingInfo) {
  return SITE_URL ? `${SITE_URL}/sorties/${o.id}` : "";
}

export async function notifySeatChanges(changes: SeatChange[] | null | undefined, outing: OutingInfo) {
  if (!changes?.length) return;
  const when = formatDateTime(outing.departure_at);
  await sendAll(
    changes
      .filter((c) => c.email)
      .map((c) =>
        c.change === "promoted"
          ? {
              to: c.email,
              subject: `✈️ Place confirmée : ${outing.title}`,
              text:
                `Bonjour ${c.full_name || ""},\n\n` +
                `Bonne nouvelle : une place s'est libérée. Vous passez de la liste d'attente à la liste des participants ` +
                `pour la sortie « ${outing.title} » du ${when}.\n\n` +
                `Si vous ne pouvez plus y participer, merci de vous désinscrire rapidement pour laisser la place au suivant.\n\n` +
                `${link(outing)}\n\n— ${CLUB_NAME}`,
            }
          : {
              to: c.email,
              subject: `Sortie modifiée : ${outing.title}`,
              text:
                `Bonjour ${c.full_name || ""},\n\n` +
                `Suite à une modification des avions de la sortie « ${outing.title} » du ${when}, ` +
                `le nombre de places a diminué et vous repassez en tête de liste d'attente. ` +
                `Vous serez prévenu(e) automatiquement si une place se libère.\n\n` +
                `${link(outing)}\n\n— ${CLUB_NAME}`,
            },
      ),
  );
}

export async function notifyNewProposal(
  staff: { email: string; full_name: string }[] | null | undefined,
  outing: OutingInfo,
  proposer: string,
) {
  if (!staff?.length) return;
  const when = formatDateTime(outing.departure_at);
  await sendAll(
    staff
      .filter((s) => s.email)
      .map((s) => ({
        to: s.email,
        subject: `Événement proposé à valider : ${outing.title}`,
        text:
          `Bonjour ${s.full_name || ""},\n\n` +
          `${proposer} propose la sortie « ${outing.title} » le ${when}.\n` +
          `Elle ne sera visible des membres qu'après validation par un instructeur ou un administrateur.\n\n` +
          `${link(outing)}\n\n— ${CLUB_NAME}`,
      })),
  );
}

export async function notifyReview(
  proposer: { email: string; full_name: string } | null | undefined,
  outing: OutingInfo,
  approved: boolean,
  reason?: string | null,
) {
  if (!proposer?.email) return;
  const when = formatDateTime(outing.departure_at);
  await sendAll([
    approved
      ? {
          to: proposer.email,
          subject: `✈️ Sortie validée : ${outing.title}`,
          text:
            `Bonjour ${proposer.full_name || ""},\n\n` +
            `Votre proposition « ${outing.title} » du ${when} a été validée : elle est maintenant publiée et les membres peuvent s'inscrire.\n\n` +
            `${link(outing)}\n\n— ${CLUB_NAME}`,
        }
      : {
          to: proposer.email,
          subject: `Sortie non retenue : ${outing.title}`,
          text:
            `Bonjour ${proposer.full_name || ""},\n\n` +
            `Votre proposition « ${outing.title} » du ${when} n'a pas été validée.` +
            (reason ? `\nMotif : ${reason}` : "") +
            `\n\nVous pouvez la modifier depuis le site : elle repartira alors en validation.\n\n${link(outing)}\n\n— ${CLUB_NAME}`,
        },
  ]);
}

export async function notifyOutingCancelled(
  recipients: { email: string; full_name: string }[] | null | undefined,
  outing: OutingInfo,
) {
  if (!recipients?.length) return;
  const when = formatDateTime(outing.departure_at);
  await sendAll(
    recipients
      .filter((r) => r.email)
      .map((r) => ({
        to: r.email,
        subject: `Sortie annulée : ${outing.title}`,
        text:
          `Bonjour ${r.full_name || ""},\n\n` +
          `La sortie « ${outing.title} » prévue le ${when} est annulée.\n\n` +
          `${link(outing)}\n\n— ${CLUB_NAME}`,
      })),
  );
}

const KIND_MAIL: Record<string, { icon: string; label: string }> = {
  vol: { icon: "✈️", label: "Nouvelle sortie avion" },
  activite: { icon: "🏍️", label: "Nouvelle activité" },
  evenement: { icon: "🥂", label: "Nouvel événement" },
  formation: { icon: "🎓", label: "Nouvelle séance de formation" },
};

export type PublishedEvent = {
  id: string;
  title: string;
  kind: string;
  dates: string[]; // ISO, une par date de la série
  destination?: string | null;
  meeting_point?: string | null;
  description?: string | null;
  places?: string | null;
  organizer?: string | null;
};

/** Prévient tous les membres (copie cachée, par lots) qu'un événement vient d'être publié. */
export async function notifyEventPublished(
  recipients: { email: string; full_name: string }[] | null | undefined,
  ev: PublishedEvent,
) {
  const emails = [...new Set((recipients ?? []).map((r) => r.email).filter(Boolean))];
  if (!emails.length || !ev.dates.length) return;
  const k = KIND_MAIL[ev.kind] ?? KIND_MAIL.evenement;
  const when =
    ev.dates.length === 1
      ? `Le ${formatDateTime(ev.dates[0])}`
      : `${ev.dates.length} dates :\n${ev.dates.map((d) => `  • ${formatDateTime(d)}`).join("\n")}`;
  const lines = [
    `Bonjour,`,
    ``,
    `${k.label} au club : « ${ev.title} »`,
    ``,
    when,
    ev.destination ? `${ev.kind === "vol" ? "Destination" : "Lieu"} : ${ev.destination}` : null,
    ev.meeting_point ? `Rendez-vous : ${ev.meeting_point}` : null,
    ev.places ? `Places : ${ev.places}` : null,
    ev.organizer ? `Organisé par : ${ev.organizer}` : null,
    ev.description ? `\n${ev.description.length > 600 ? `${ev.description.slice(0, 600)}…` : ev.description}` : null,
    ``,
    `Inscriptions sur le site, dans l'ordre d'arrivée :`,
    link({ id: ev.id, title: ev.title, departure_at: ev.dates[0] }) || "(rubrique Événements)",
    ``,
    `— ${CLUB_NAME}`,
    ``,
    `Vous ne souhaitez plus recevoir ces annonces ? Désactivez-les dans « Mon compte » sur le site.`,
  ].filter((l): l is string => l !== null);
  const subject = `${k.icon} ${k.label} : ${ev.title}`;
  const text = lines.join("\n");
  // Copie cachée par lots de 45 (limites des fournisseurs), envoyés l'un après l'autre
  for (let i = 0; i < emails.length; i += 45) {
    await send({ bcc: emails.slice(i, i + 45), subject, text });
  }
}

/** Prévient le chef pilote et le responsable conformité qu'un REX vient d'être déposé. */
export async function notifyRexSubmitted(
  reviewers: { email: string; full_name: string }[] | null | undefined,
  title: string,
  author: string | null,
) {
  if (!reviewers?.length) return;
  const url = SITE_URL ? `${SITE_URL}/pedagogie?onglet=rex` : "(Espace pédagogique, onglet REX)";
  await sendAll(
    reviewers
      .filter((r) => r.email)
      .map((r) => ({
        to: r.email,
        subject: `🛡️ Nouveau retour d'expérience : ${title}`,
        text:
          `Bonjour ${r.full_name || ""},\n\n` +
          `Un nouveau REX a été déposé ${author ? `par ${author}` : "de façon anonyme"} : « ${title} ».\n\n` +
          `${url}\n\n— ${CLUB_NAME}`,
      })),
  );
}
