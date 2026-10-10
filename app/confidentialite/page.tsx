import Link from "next/link";
import type { Metadata } from "next";
import { getClubInfo } from "@/lib/clubInfo";

export const metadata: Metadata = { title: "Politique de confidentialité" };

export default async function Page() {
  const info = await getClubInfo();
  const contact = info.contact_email ? (
    <a className="font-semibold text-sky hover:underline" href={`mailto:${info.contact_email}`}>
      {info.contact_email}
    </a>
  ) : (
    "un administrateur du club"
  );

  return (
    <article className="max-w-3xl">
      <h1 className="text-2xl font-bold tracking-tight text-navy-2">Politique de confidentialité</h1>
      <p className="mb-6 text-sm text-muted">
        Règlement général sur la protection des données (RGPD, UE 2016/679) et loi Informatique et Libertés. Version de
        septembre 2026.
      </p>

      <Block title="1. Responsable du traitement">
        <p>
          {info.association_name}
          {info.address ? `, ${info.address}` : ""}, représenté par son président
          {info.publication_director ? ` (${info.publication_director})` : ""}. Contact pour toute question sur vos données :{" "}
          {contact}.
        </p>
      </Block>

      <Block title="2. Données collectées">
        <ul className="list-disc space-y-1 pl-5">
          <li>
            <strong>Identité et contact</strong> : nom, prénom, email, téléphone, adresse postale, personne à prévenir en cas
            d&apos;urgence, photo de profil (facultative).
          </li>
          <li>
            <strong>Vie aéronautique</strong> : types d&apos;avions sur lesquels vous êtes lâché, fonctions au club.
          </li>
          <li>
            <strong>Poids</strong> (facultatif) : uniquement pour la répartition des équipages (masse et centrage). Vous pouvez
            l&apos;effacer à tout moment dans « Mon compte ».
          </li>
          <li>
            <strong>Activité</strong> : inscriptions aux événements, événements proposés, consommations et règlements du bar.
          </li>
          <li>
            <strong>Technique</strong> : date de création du compte et de dernière connexion, cookies de session.
          </li>
        </ul>
      </Block>

      <Block title="3. Finalités et bases légales">
        <ul className="list-disc space-y-1 pl-5">
          <li>Gestion des membres, des événements et des sorties avion : exécution de votre adhésion (art. 6.1.b).</li>
          <li>Annuaire interne entre membres, sécurité des vols, contact d&apos;urgence : intérêt légitime du club (art. 6.1.f).</li>
          <li>Comptes du bar : exécution de l&apos;adhésion et obligations comptables (art. 6.1.b et c).</li>
          <li>Poids et emails d&apos;annonce des événements : votre consentement, retirable à tout moment (art. 6.1.a).</li>
        </ul>
      </Block>

      <Block title="4. Qui voit vos données ?">
        <ul className="list-disc space-y-1 pl-5">
          <li>
            <strong>Les membres validés</strong> : votre nom, votre photo, vos lâchers et votre téléphone (sauf si vous le
            masquez), votre participation aux événements, et — sauf si vous le désactivez dans « Mon compte » — votre prénom et
            votre nombre de consommations si vous êtes dans le top 3 annuel du bar (« Équipage de l&apos;année »), jamais les montants.
          </li>
          <li>
            <strong>L&apos;organisateur d&apos;un événement</strong> : téléphone des participants ; poids des participants à une
            sortie avion (lui seul).
          </li>
          <li>
            <strong>Le trésorier</strong> : les consommations du bar de tous les membres. Chaque membre ne voit que les siennes.
          </li>
          <li>
            <strong>Les administrateurs et instructeurs</strong> : les fiches des membres pour la gestion du club.
          </li>
          <li>Aucune donnée n&apos;est vendue, louée ni utilisée à des fins publicitaires.</li>
        </ul>
      </Block>

      <Block title="5. Sous-traitants et transferts">
        <p>
          Le site est hébergé par <strong>Vercel Inc.</strong> (États-Unis) ; la base de données et les fichiers par{" "}
          <strong>Supabase, Inc.</strong> ; les emails peuvent être envoyés via le service de messagerie du club (par ex. Google).
          Lorsque des données sont traitées hors de l&apos;Union européenne, ces prestataires s&apos;engagent par des clauses
          contractuelles types de la Commission européenne et/ou le cadre UE–États-Unis de protection des données (Data Privacy
          Framework).
        </p>
      </Block>

      <Block title="6. Durées de conservation">
        <ul className="list-disc space-y-1 pl-5">
          <li>Compte et profil : pendant votre adhésion, puis effacement sur demande ou au plus tard 3 ans après votre dernière activité.</li>
          <li>Comptes du bar : durée légale de conservation des pièces comptables (10 ans), sous forme anonymisée après départ.</li>
          <li>Poids : jusqu&apos;à ce que vous l&apos;effaciez ou la suppression de votre compte.</li>
          <li>Journal des modifications (sécurité) : il ne contient aucune coordonnée personnelle.</li>
        </ul>
      </Block>

      <Block title="7. Vos droits">
        <p>
          Vous disposez d&apos;un droit d&apos;accès, de rectification, d&apos;effacement, de limitation, d&apos;opposition et de
          portabilité de vos données, ainsi que du droit de retirer votre consentement. Directement depuis{" "}
          <Link href="/compte" className="font-semibold text-sky hover:underline">
            Mon compte
          </Link>{" "}
          :
        </p>
        <ul className="list-disc space-y-1 pl-5">
          <li>corriger vos coordonnées, votre photo, vos lâchers, votre poids ;</li>
          <li>masquer votre téléphone dans l&apos;annuaire, vous désabonner des emails d&apos;annonce ;</li>
          <li>télécharger toutes vos données (fichier JSON) ;</li>
          <li>demander la suppression de votre compte (traitée sous un mois maximum).</li>
        </ul>
        <p>
          Pour toute autre demande : {contact}. Si vous estimez que vos droits ne sont pas respectés, vous pouvez adresser une
          réclamation à la CNIL (www.cnil.fr).
        </p>
      </Block>

      <Block title="8. Cookies">
        <p>
          Le site utilise uniquement des cookies strictement nécessaires à votre connexion (session sécurisée). Ils sont exemptés
          de consentement. Aucun cookie publicitaire, de réseau social ou de mesure d&apos;audience n&apos;est déposé.
        </p>
      </Block>

      <Block title="9. Sécurité">
        <p>
          Connexion chiffrée (HTTPS), mots de passe chiffrés et jamais visibles du club, accès limité selon les fonctions de
          chacun, documents des avions privés (liens temporaires), aucune suppression définitive de données du club possible
          depuis le site, et journal inaltérable de toutes les modifications sensibles.
        </p>
      </Block>
    </article>
  );
}

function Block({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="mb-6">
      <h2 className="mb-1.5 text-lg font-bold text-navy-2">{title}</h2>
      <div className="space-y-2 text-sm leading-relaxed text-ink">{children}</div>
    </section>
  );
}
