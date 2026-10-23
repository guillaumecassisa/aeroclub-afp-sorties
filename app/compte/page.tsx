import Link from "next/link";
import type { Metadata } from "next";
import { isTreasurer, requireMember } from "@/lib/auth";
import { currentMonthKey, euros, monthLabel } from "@/lib/money";
import { createClient } from "@/lib/supabase/server";
import { ROLE_LABELS, type Aircraft } from "@/lib/types";
import { AvatarForm } from "./AvatarForm";
import { ProfileForm } from "./ProfileForm";
import { ReleasesForm } from "./ReleasesForm";
import { WeightForm } from "./WeightForm";
import { setEventEmails } from "./notifications";
import { requestDeletion, setBarRankingVisibility, setPhoneVisibility } from "./rgpd";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";

export const metadata: Metadata = { title: "Mon compte" };

const RELEASE_TYPES = ["DR400", "DA40", "PS28", "WT9", "B23"];

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const me = await requireMember();
  const sp = await searchParams;
  const emailsOn = me.notify_events !== false;
  const phoneShown = me.show_phone !== false;
  const deletionAsked = !!me.deletion_requested_at;
  const inRanking = me.show_in_bar_ranking !== false;
  const supabase = await createClient();
  const [{ data: fleet }, { data: rel }, { data: w }] = await Promise.all([
    supabase.from("aircraft").select("*").order("registration"),
    supabase.from("pilot_types").select("aircraft_type").eq("user_id", me.id),
    supabase.from("pilot_weights").select("weight_kg").eq("user_id", me.id).maybeSingle(),
  ]);
  const monthStart = new Date(`${currentMonthKey()}-01T00:00:00+01:00`);
  const { data: cons } = await supabase
    .from("bar_consumptions")
    .select("unit_price_cents, quantity")
    .eq("user_id", me.id)
    .gte("created_at", monthStart.toISOString());
  const barTotal = (cons ?? []).reduce((s, c) => s + c.unit_price_cents * c.quantity, 0);
  const barCount = (cons ?? []).reduce((s, c) => s + c.quantity, 0);
  const weight = w?.weight_kg != null ? Number(w.weight_kg) : null;
  const released = (rel ?? []).map((r) => r.aircraft_type as string);
  // Les trois types de lâcher du club, avec pour info les immatriculations correspondantes
  const types = RELEASE_TYPES.map((type) => ({
    type,
    registrations: ((fleet ?? []) as Aircraft[])
      .filter((a) => a.active && a.type === type)
      .map((a) => a.registration),
  }));

  return (
    <div className="max-w-3xl space-y-5">
      <Banner ok={sp.ok} erreur={sp.erreur} />
      <div>
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">Mon compte</h1>
        <p className="text-sm text-muted">
          {me.email} · <span className="font-semibold text-sky">{ROLE_LABELS[me.role]}</span>
        </p>
      </div>

      <Section title="Photo de profil">
        <AvatarForm url={me.avatar_url} name={me.full_name} />
      </Section>

      <Section title="Mes coordonnées">
        <ProfileForm me={me} hasReleases={released.length > 0} />
      </Section>

      <Section
        title="Types d'avions sur lesquels je suis lâché"
        subtitle="Cochez chaque type d'avion sur lequel vous êtes lâché. Lors des sorties, vous n'êtes placé dans un avion que si vous êtes lâché sur son type ou si un instructeur est à bord."
      >
        <div id="lachers" className="scroll-mt-24">
          <ReleasesForm types={types} released={released} />
        </div>
      </Section>

      <Section
        title="Mon poids"
        subtitle="Facultatif. Il sert uniquement à répartir les équipages dans les avions lors des sorties (masse et centrage). Il n'est visible ni dans l'annuaire ni par les autres membres : seul l'instructeur référent d'une sortie à laquelle vous êtes inscrit peut le consulter pour l'organisation finale."
      >
        <WeightForm weight={weight} />
      </Section>

      <Section title="Emails du club">
        <div id="emails" className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-sm text-ink">
            {emailsOn
              ? "Vous recevez un email à chaque nouvel événement publié (sortie avion, activité, soirée…)."
              : "Vous ne recevez pas les emails annonçant les nouveaux événements."}
          </p>
          <form action={setEventEmails.bind(null, !emailsOn)}>
            <SubmitButton className={emailsOn ? "btn-secondary" : "btn-primary"} pending="…">
              {emailsOn ? "Ne plus recevoir" : "Recevoir les annonces"}
            </SubmitButton>
          </form>
        </div>
        <p className="mt-2 text-xs text-muted">
          Les emails liés à vos inscriptions (place confirmée, annulation…) restent toujours envoyés.
        </p>
      </Section>

      <Section
        title="Mes données personnelles"
        subtitle="Vous gardez la main sur vos données : consultation, correction, visibilité et suppression (RGPD)."
      >
        <div id="donnees" className="space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <p className="text-sm text-ink">
              {phoneShown
                ? "Votre téléphone est visible des membres dans l'annuaire."
                : "Votre téléphone est masqué dans l'annuaire (les organisateurs d'un événement le voient toujours)."}
            </p>
            <form action={setPhoneVisibility.bind(null, !phoneShown)}>
              <SubmitButton className="btn-secondary" pending="…">
                {phoneShown ? "Masquer mon téléphone" : "Afficher mon téléphone"}
              </SubmitButton>
            </form>
          </div>
          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
            <p className="text-sm text-ink">
              {inRanking
                ? "Vous pouvez apparaître dans l'« Équipage de l'année » (top 3 du bar : prénom et nombre de consommations, jamais les montants)."
                : "Vous n'apparaissez pas dans l'« Équipage de l'année »."}
            </p>
            <form action={setBarRankingVisibility.bind(null, !inRanking)}>
              <SubmitButton className="btn-secondary" pending="…">
                {inRanking ? "Ne pas apparaître" : "Apparaître au classement"}
              </SubmitButton>
            </form>
          </div>
          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
            <p className="text-sm text-ink">Télécharger toutes les données que le site conserve sur vous.</p>
            <a href="/compte/export" className="btn-secondary" download>
              Télécharger mes données
            </a>
          </div>
          <div className="flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
            <p className="text-sm text-ink">
              {deletionAsked ? (
                <span className="font-semibold text-wait">
                  Demande de suppression envoyée le {new Date(me.deletion_requested_at!).toLocaleDateString("fr-FR")}. Un
                  administrateur va effacer vos données personnelles.
                </span>
              ) : (
                "Supprimer mon compte : vos données personnelles seront effacées par un administrateur. L'historique comptable (bar) est conservé de façon anonyme."
              )}
            </p>
            <form action={requestDeletion.bind(null, !deletionAsked)}>
              <SubmitButton
                className={deletionAsked ? "btn-secondary" : "btn-danger"}
                pending="…"
                confirm={deletionAsked ? undefined : "Demander la suppression de votre compte et de vos données personnelles ?"}
              >
                {deletionAsked ? "Annuler ma demande" : "Demander la suppression"}
              </SubmitButton>
            </form>
          </div>
          <p className="text-xs text-muted">
            Pour en savoir plus : <Link href="/confidentialite" className="text-sky hover:underline">politique de confidentialité</Link>.
          </p>
        </div>
      </Section>

      <Section title="Bar : mes consommations">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-sm text-ink">
            <span className="first-letter:uppercase">{monthLabel(currentMonthKey())}</span> :{" "}
            <span className="text-lg font-bold text-navy-2">{euros(barTotal)}</span>
            <span className="text-muted"> · {barCount} boisson{barCount > 1 ? "s" : ""}</span>
          </p>
          <div className="flex flex-wrap gap-2">
            <Link href="/bar" className="btn-secondary">
              Détail de mes consommations
            </Link>
            {isTreasurer(me) && (
              <Link href="/bar/tresorerie" className="btn-primary">
                Trésorerie : comptes de tous les membres
              </Link>
            )}
          </div>
        </div>
        <p className="mt-2 text-xs text-muted">
          Vous ne voyez que vos propres consommations. Seul le trésorier du club a accès aux comptes de tous les membres.
        </p>
      </Section>

      <Link href="/compte/mot-de-passe" className="btn-secondary">
        Changer mon mot de passe
      </Link>
    </div>
  );
}

function Section({ title, subtitle, children }: { title: string; subtitle?: string; children: React.ReactNode }) {
  return (
    <section className="card p-5">
      <h2 className="font-bold text-navy-2">{title}</h2>
      {subtitle && <p className="mt-0.5 text-sm text-muted">{subtitle}</p>}
      <div className="mt-4">{children}</div>
    </section>
  );
}
