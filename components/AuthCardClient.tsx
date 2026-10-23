"use client";

import Image from "next/image";

import { CLUB_NAME } from "@/lib/club";

export function AuthCardClient({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="mx-auto mt-4 max-w-md">
      <div className="card border-t-[3px] border-t-navy-2 p-6 sm:p-8">
        <Image src="/logo.png" alt={CLUB_NAME} width={112} height={112} priority className="mx-auto mb-4 h-28 w-28" />
        <h1 className="mb-1 text-center text-2xl font-bold tracking-tight text-navy-2">{title}</h1>
        <div className="mx-auto mb-6 h-0.5 w-10 bg-red" />
        {children}
      </div>
    </div>
  );
}
