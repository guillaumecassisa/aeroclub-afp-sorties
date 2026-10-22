import type { Metadata } from "next";
import Link from "next/link";
import { requireAdmin } from "@/lib/auth";
import { getClubInfo } from "@/lib/clubInfo";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { saveClubInfo } from "./actions";

export const metadata: Metadata = { title: "Informations du club" };
export const dynamic = "force-dynamic";

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  await requireAdmin();
  const sp = await searchParams;
  const info = await getClubInfo();
  const missing = [
    !info.address && "adresse du siège",
    !info.publication_director && "directeur de la publication",
    !info.contact_email && "email de contact",
  ].filter(Boolean) as string[];

  return (
    <div className="max-w-2xl">
      <Banner ok={sp.ok} erreur={sp.erreur} />
      <h1 className="text-2xl font-bold tracking-tight text-navy-2">Informations du club</h1>
      <p className="mb-5 text-sm text-muted">
        Utilisées dans les{" "}
        <Link href="/mentions-legales" className="text-sky hover:underline">mentions légales</Link> et la{" "}
        <Link href="/confidentialite" className="text-sky hover:underline">politique de confidentialité</Link>.
      </p>
      {missing.length > 0 && (
        <p className="mb-5 rounded-lg bg-wait-soft px-4 py-3 text-sm text-wait">
          Obligatoire pour un site public (loi pour la confiance dans l&apos;économie numérique) : {missing.join(", ")}.
        </p>
      )}
      <form action={saveClubInfo} className="card space-y-4 p-5">
        <Field name="association_name" label="Nom de l'association" value={info.association_name} required />
        <Field name="legal_form" label="Forme juridique" value={info.legal_form} />
        <Field name="address" label="Adresse du siège" value={info.address} />
        <Field name="registration_number" label="N° RNA ou SIRET" value={info.registration_number} />
        <Field name="publication_director" label="Directeur de la publication (en général le président)" value={info.publication_director} />
        <Field name="contact_email" label="Email de contact" value={info.contact_email} type="email" />
        <Field name="contact_phone" label="Téléphone (facultatif)" value={info.contact_phone} />
        <SubmitButton pending="Enregistrement…">Enregistrer</SubmitButton>
      </form>
    </div>
  );
}

function Field({
  name,
  label,
  value,
  type = "text",
  required,
}: {
  name: string;
  label: string;
  value: string | null;
  type?: string;
  required?: boolean;
}) {
  return (
    <div>
      <label htmlFor={name} className="label">{label}</label>
      <input id={name} name={name} type={type} defaultValue={value ?? ""} className="field" required={required} maxLength={300} />
    </div>
  );
}
