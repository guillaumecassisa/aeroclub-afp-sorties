import { redirect } from "next/navigation";
import { getCurrentProfile } from "@/lib/auth";
import { AuthCard } from "@/components/AuthCard";

export default async function Page() {
  const profile = await getCurrentProfile();
  if (!profile) redirect("/connexion");
  if (profile.role !== "pending") redirect("/");
  return (
    <AuthCard title="Compte en attente de validation">
      <p className="text-sm leading-relaxed text-ink">
        Bonjour {profile.full_name || profile.email}, votre compte est bien créé. Un administrateur du club doit
        maintenant le valider ; vous pourrez ensuite consulter les sorties et vous y inscrire.
      </p>
      <p className="mt-4 text-sm text-muted">Revenez sur cette page une fois prévenu, ou rechargez-la plus tard.</p>
    </AuthCard>
  );
}
