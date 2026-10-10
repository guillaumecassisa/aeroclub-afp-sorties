import Link from "next/link";
import type { Metadata } from "next";
import { AuthCard } from "@/components/AuthCard";
import { Banner } from "@/components/Banner";
import { LoginForm } from "./LoginForm";

export const metadata: Metadata = { title: "Connexion" };

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  return (
    <AuthCard title="Connexion">
      <Banner erreur={sp.erreur} ok={sp.ok} />
      <LoginForm next={sp.next ?? "/"} />
      <div className="mt-6 flex flex-col gap-2 text-sm text-muted">
        <Link href="/mot-de-passe-oublie" className="text-sky hover:underline">
          Mot de passe oublié ?
        </Link>
        <span>
          Pas encore de compte ?{" "}
          <Link href="/inscription" className="font-semibold text-sky hover:underline">
            Créer un compte
          </Link>
        </span>
      </div>
    </AuthCard>
  );
}
