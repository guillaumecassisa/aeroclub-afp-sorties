import { redirect } from "next/navigation";
import { getCurrentProfile } from "@/lib/auth";
import { AuthCard } from "@/components/AuthCard";

export default async function Page() {
  const profile = await getCurrentProfile();
  if (!profile) redirect("/connexion");
  if (profile.role !== "pending") redirect("/");
  return (
    <AuthCard title="Inscription en cours de validation">
      <p className="text-center text-2xl mb-4">✈️</p>
      <p className="text-sm leading-relaxed text-ink text-center">
        Bienvenue {profile.full_name?.split(" ")[0] || "à toi"} !
      </p>
      <p className="mt-3 text-sm leading-relaxed text-muted text-center">
        Ton compte est bien créé. Reviens dans quelques tours de piste&nbsp;😉
      </p>
      <p className="mt-4 text-xs text-muted text-center">
        Un administrateur du club va valider ton inscription. Tu recevras un accès complet au site dès que c&apos;est fait.
      </p>
    </AuthCard>
  );
}
