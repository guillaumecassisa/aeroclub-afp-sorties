import type { Metadata } from "next";
import { getClubInfo } from "@/lib/clubInfo";

export const metadata: Metadata = { title: "Mentions légales" };

export default async function Page() {
  const info = await getClubInfo();

  return (
    <article className="max-w-3xl">
      <h1 className="text-2xl font-bold tracking-tight text-navy-2">Mentions légales</h1>
      <p className="mb-6 text-sm text-muted">Conformément à la loi n° 2004-575 du 21 juin 2004 pour la confiance en l'économie numérique.</p>

      <Block title="Éditeur du site">
        <p>
          <strong>{info.association_name}</strong>
          {info.address && (
            <>
              <br />
              {info.address}
            </>
          )}
          {info.publication_director && (
            <>
              <br />
              Directeur de la publication : {info.publication_director}
            </>
          )}
          {info.contact_email && (
            <>
              <br />
              Contact :{" "}
              <a href={`mailto:${info.contact_email}`} className="font-medium text-sky hover:underline">
                {info.contact_email}
              </a>
            </>
          )}
        </p>
      </Block>

      <Block title="Hébergeur">
        <p>
          <strong>Vercel Inc.</strong>
          <br />
          440 N Barranca Ave #4133, Covina, CA 91723, États-Unis
          <br />
          <a href="https://vercel.com" target="_blank" rel="noopener noreferrer" className="text-sky hover:underline">
            vercel.com
          </a>
        </p>
        <p className="mt-2">
          Base de données hébergée par <strong>Supabase, Inc.</strong> —{" "}
          <a href="https://supabase.com" target="_blank" rel="noopener noreferrer" className="text-sky hover:underline">
            supabase.com
          </a>
        </p>
      </Block>

      <Block title="Propriété intellectuelle">
        <p>
          L'ensemble des contenus présents sur ce site (textes, images, logotypes) est la propriété exclusive de{" "}
          {info.association_name}. Toute reproduction, représentation, modification ou adaptation, totale ou partielle, est
          interdite sans accord préalable.
        </p>
      </Block>

      <Block title="Données personnelles">
        <p>
          Le traitement des données personnelles est décrit dans notre{" "}
          <a href="/confidentialite" className="font-medium text-sky hover:underline">
            Politique de confidentialité
          </a>
          . Conformément au RGPD, vous disposez d'un droit d'accès, de rectification et de suppression de vos données.
        </p>
      </Block>

      <Block title="Responsabilité">
        <p>
          {info.association_name} s'efforce d'assurer l'exactitude et la mise à jour des informations diffusées sur ce site, mais
          ne peut garantir l'exactitude, la complétude ou l'actualité des informations diffusées. Les liens externes sont fournis
          à titre informatif ; nous ne sommes pas responsables de leur contenu.
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
