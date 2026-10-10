"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export function NavLink({ href, exact, children }: { href: string; exact?: boolean; children: React.ReactNode }) {
  const path = usePathname();
  const active =
    href === "/sorties"
      ? path === "/sorties" || path.startsWith("/sorties/")
      : exact
        ? path === href
        : path === href || path.startsWith(href + "/");
  return (
    <Link
      href={href}
      className={`relative shrink-0 px-3 py-2.5 font-medium transition-colors ${
        active
          ? "text-navy-2 after:absolute after:inset-x-3 after:bottom-0 after:h-0.5 after:bg-red"
          : "text-muted hover:text-navy-2"
      }`}
    >
      {children}
    </Link>
  );
}
