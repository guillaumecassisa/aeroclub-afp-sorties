"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export function NavLink({
  href,
  exact,
  icon,
  children,
}: {
  href: string;
  exact?: boolean;
  icon?: string;
  children: React.ReactNode;
}) {
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
      aria-current={active ? "page" : undefined}
      className={`group flex shrink-0 items-center gap-1.5 rounded-full px-3 py-2 text-[15px] min-[1600px]:px-3.5 font-semibold whitespace-nowrap transition-all ${
        active
          ? "bg-navy-2 text-white shadow-sm"
          : "text-navy-2/75 hover:-translate-y-px hover:bg-sky-soft hover:text-navy-2"
      }`}
    >
      {icon && (
        <span aria-hidden className={`hidden text-base leading-none transition-transform min-[1600px]:inline ${active ? "" : "group-hover:scale-110"}`}>
          {icon}
        </span>
      )}
      {children}
    </Link>
  );
}
