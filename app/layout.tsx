import type { Metadata, Viewport } from "next";
import Image from "next/image";
import Link from "next/link";
import "./globals.css";
import { canManageFleet, getCurrentProfile } from "@/lib/auth";
import { CLUB_NAME } from "@/lib/email";
import { logout } from "@/app/auth/actions";
import { NavLink } from "@/components/NavLink";
import { Avatar } from "@/components/Avatar";

export const metadata: Metadata = {
  title: { default: `Sorties — ${CLUB_NAME}`, template: `%s — ${CLUB_NAME}` },
  description: `Organisation des sorties de ${CLUB_NAME}`,
  icons: { icon: "/logo.png", apple: "/logo.png" },
};

export const viewport: Viewport = { themeColor: "#002157", width: "device-width", initialScale: 1 };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const profile = await getCurrentProfile();
  const approved = profile && profile.role !== "pending";

  return (
    <html lang="fr">
      <body className="font-sans antialiased">
        <header className="sticky top-0 z-10 bg-white print:hidden">
          <div className="mx-auto flex max-w-5xl items-center justify-between gap-4 px-4 py-2.5">
            {approved ? (
              <Link href="/" className="flex min-w-0 items-center gap-3">
                <Image src="/logo.png" alt="" width={44} height={44} priority className="h-11 w-11 shrink-0" />
                <span className="hidden min-w-0 leading-tight min-[430px]:block">
                  <span className="block text-[10px] font-semibold tracking-[0.2em] text-muted uppercase">Aéroclub</span>
                  <span className="block truncate text-[15px] font-bold tracking-tight text-navy-2">
                    {CLUB_NAME.replace(/^Aéroclub\s+/i, "")}
                  </span>
                </span>
              </Link>
            ) : (
              <div className="flex min-w-0 items-center gap-3">
                <Image src="/logo.png" alt="" width={44} height={44} priority className="h-11 w-11 shrink-0" />
                <span className="hidden min-w-0 leading-tight min-[430px]:block">
                  <span className="block text-[10px] font-semibold tracking-[0.2em] text-muted uppercase">Aéroclub</span>
                  <span className="block truncate text-[15px] font-bold tracking-tight text-navy-2">
                    {CLUB_NAME.replace(/^Aéroclub\s+/i, "")}
                  </span>
                </span>
              </div>
            )}
            {profile && (
              <div className="flex items-center gap-1">
              {approved && (
                <Link href="/compte" className="rounded-full px-2 py-1.5 text-sm font-medium whitespace-nowrap text-navy-2 hover:bg-sky-soft sm:px-3">
                  Mon compte
                </Link>
              )}
              {approved && (
                <Link href="/compte" aria-label="Mon compte" className="rounded-full p-0.5 hover:ring-2 hover:ring-sky-soft">
                  <Avatar url={profile.avatar_url} name={profile.full_name || profile.email} size="sm" />
                </Link>
              )}
              <form action={logout}>
                <button className="rounded-full px-2 py-1.5 text-sm font-medium whitespace-nowrap text-navy-2 hover:bg-sky-soft sm:px-3">
                  Déconnexion
                </button>
              </form>
              </div>
            )}
          </div>
          {approved && (
            <nav className="border-t border-line">
              <div className="mx-auto flex max-w-5xl gap-1 overflow-x-auto px-2 text-sm">
                <NavLink href="/" exact>Accueil</NavLink>
                <NavLink href="/sorties">Événements</NavLink>
                <NavLink href="/preparer-son-vol">Préparer son vol</NavLink>
                <NavLink href="/bons-plans">Bons plans</NavLink>
                <NavLink href="/shop">Le shop</NavLink>
                {profile?.role === "admin" && <NavLink href="/shop/admin">Shop (admin)</NavLink>}
                <NavLink href="/bar" exact>Bar</NavLink>
                {(profile?.role === "admin" || profile?.is_treasurer) && <NavLink href="/stats">Stats</NavLink>}
                <NavLink href="/flotte">Flotte</NavLink>
                {canManageFleet(profile) && <NavLink href="/maintenance">Flotte (maintenance)</NavLink>}
                {profile?.role === "admin" && <NavLink href="/droits">Gestion des droits</NavLink>}
                <span className="ml-auto" aria-hidden />
                <NavLink href="/shareflight">Shareflight</NavLink>
                <NavLink href="/quiz">Quiz</NavLink>
                <NavLink href="/annuaire">Annuaire</NavLink>
              </div>
            </nav>
          )}
          <div className="af-stripe" />
        </header>
        <main className="mx-auto max-w-5xl px-4 py-6 pb-10">{children}</main>
        <footer className="border-t border-line print:hidden">
          <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-x-4 gap-y-1 px-4 py-5 text-xs text-muted">
            <span>© {new Date().getFullYear()} {CLUB_NAME}</span>
            <Link href="/mentions-legales" className="hover:text-navy-2 hover:underline">
              Mentions légales
            </Link>
            <Link href="/confidentialite" className="hover:text-navy-2 hover:underline">
              Confidentialité et données personnelles
            </Link>
          </div>
        </footer>
      </body>
    </html>
  );
}
