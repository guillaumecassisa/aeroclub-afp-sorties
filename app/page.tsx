import Link from "next/link";
import type { Metadata } from "next";
import { getCurrentProfile, canOrganize } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import type { OutingSummary } from "@/lib/types";
import { Clocks } from "@/components/Clocks";
import { WeatherCard } from "@/components/WeatherCard";
import { getMetar } from "@/lib/metar";
import { CLUB_NAME } from "@/lib/email";
import { formatDate, formatTime, dayBadge } from "@/lib/dates";
import { euros, currentMonthKey } from "@/lib/money";
import { createAnnouncement, deleteAnnouncement } from "@/app/annonces/actions";
import { SubmitButton } from "@/components/ui";
import { QuizPopup, type DailyQuestion } from "@/components/QuizPopup";
import { submitQuizAnswer } from "@/app/quiz/actions";

export const metadata: Metadata = { title: `Accueil — ${CLUB_NAME}` };
export const dynamic = "force-dynamic";

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const sp = await searchParams;
  const profile = await getCurrentProfile();
  const approved = profile && profile.role !== "pending";
  const supabase = await createClient();
  const metar = await getMetar();

  // Événements à venir (visibilité et compteurs calculés par la base)
  const { data: upRaw } = approved ? await supabase.rpc("list_outings", { p_past: false }) : { data: [] };
  const sorties = ((upRaw ?? []) as OutingSummary[])
    .filter((o) => o.status === "open" && (!o.approval || o.approval === "approved"))
    .slice(0, 5);
  const myRegMap = new Map(sorties.map((o) => [o.id, o.my_status]));

  // Ardoise du mois
  const nowKey = currentMonthKey();
  const { data: ardoiseRaw } = approved && profile
    ? await supabase
        .from("bar_consumptions")
        .select("unit_price_cents, quantity, created_at")
        .eq("user_id", profile.id)
        .gte("created_at", `${nowKey}-01`)
    : { data: [] };
  const ardoiseTotal = (ardoiseRaw ?? []).reduce(
    (s: number, c: { unit_price_cents: number; quantity: number }) => s + c.unit_price_cents * c.quantity,
    0,
  );

  // Membres actifs (un membre ne peut lire que sa propre fiche : on passe par la base)
  const { data: stats } = approved ? await supabase.rpc("club_stats") : { data: null };
  const membresActifs = (stats as { active_members?: number } | null)?.active_members ?? null;

  // Avions de la flotte
  const { data: flotteRaw } = await supabase
    .from("aircraft")
    .select("id, registration, model, type, active, available, unavailable_reason")
    .eq("active", true)
    .order("registration");
  const flotte = flotteRaw ?? [];

  // Annonces
  const { data: annoncesRaw } = await supabase
    .from("announcements")
    .select("*")
    .or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`)
    .order("important", { ascending: false })
    .order("created_at", { ascending: false });
  const annonces = annoncesRaw ?? [];

  // Équipage de l'année : top 3 du bar, en respectant ceux qui refusent d'apparaître au classement
  const { data: rankRaw } = approved ? await supabase.rpc("bar_ranking", { p_year: null }) : { data: [] };
  const topEquipage = (rankRaw ?? []) as { rank: number; name: string; consos: number; avatar_url: string | null }[];

  const KIND_ICON: Record<string, string> = { vol: "✈️", activite: "🏍️", evenement: "🥂" };

  const now = new Date();
  const dateStr = now.toLocaleDateString("fr-FR", {
    timeZone: "Europe/Paris",
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  });

  // Question du jour : choisie par la base (jour de Paris), sans la bonne réponse
  const { data: quizRaw } = approved ? await supabase.rpc("quiz_today") : { data: null };
  const dailyQuestion = quizRaw as DailyQuestion | null;
  const alreadyAnswered = !!dailyQuestion?.already_answered;

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />

      {/* Quiz du jour */}
      {dailyQuestion && profile && (
        <QuizPopup
          question={dailyQuestion}
          alreadyAnswered={alreadyAnswered}
          submitAnswer={submitQuizAnswer}
        />
      )}

      {/* Hero */}
      <div className="mb-6 overflow-hidden rounded-2xl bg-navy-2 px-6 py-6 text-white">
        <div className="flex flex-wrap items-start justify-between gap-6">
          <div>
            {profile && (
              <p className="mb-1 text-sm font-medium text-white/70">
                Bonjour {profile.full_name?.split(" ")[0] ?? ""} —{" "}
                {now.getHours() < 12 ? "bonjour" : now.getHours() < 18 ? "bon après-midi" : "bonne nuit"}
              </p>
            )}
            <p className="text-xl font-bold capitalize">{dateStr}</p>
            <Clocks initial={now.toISOString()} />
          </div>
          <div className="min-w-[220px] rounded-xl bg-white/10 px-4 py-3">
            <p className="mb-1 text-[10px] font-semibold tracking-widest text-white/60 uppercase">
              METAR LFML · {metar ? `il y a ${Math.round((Date.now() - new Date(metar.observedAt).getTime()) / 60000)} min` : "—"}
            </p>
            <WeatherCard metar={metar} compact dark />
          </div>
        </div>
      </div>

      {/* Stats */}
      {approved && (
        <div className="mb-6 grid grid-cols-3 gap-3">
          <Link href="/bar" className="card flex items-center gap-3 p-4 transition hover:shadow-md">
            <span className="text-2xl" aria-hidden>🍺</span>
            <div>
              <p className="text-lg font-bold text-navy-2">{euros(ardoiseTotal)}</p>
              <p className="text-xs text-muted">Ardoise {nowKey.slice(0, 7).replace("-", "/")}</p>
              {ardoiseTotal === 0 && <p className="text-xs text-ok">rien à régler</p>}
            </div>
          </Link>
          <Link href="/sorties" className="card flex items-center gap-3 p-4 transition hover:shadow-md">
            <span className="text-2xl" aria-hidden>📅</span>
            <div>
              <p className="text-lg font-bold text-navy-2">
                {myRegMap.size}
              </p>
              <p className="text-xs text-muted">
                {myRegMap.size === 0 ? "Événement où je suis inscrit" : myRegMap.size === 1 ? "Événement inscrit" : "Événements inscrits"}
              </p>
            </div>
          </Link>
          <Link href="/annuaire" className="card flex items-center gap-3 p-4 transition hover:shadow-md">
            <span className="text-2xl" aria-hidden>👥</span>
            <div>
              <p className="text-lg font-bold text-navy-2">{membresActifs ?? 0}</p>
              <p className="text-xs text-muted">Membres actifs</p>
            </div>
          </Link>
        </div>
      )}

      {/* Annonces */}
      {approved && (
        <section className="card mb-6 p-5">
          <div className="mb-3 flex items-center justify-between gap-3">
            <h2 className="font-bold text-navy-2">Annonces</h2>
            {canOrganize(profile) && (
              <details className="relative">
                <summary className="cursor-pointer text-sm font-medium text-sky-600 hover:underline">+ Publier une annonce</summary>
                <form action={createAnnouncement} className="mt-2 space-y-2">
                  <input name="title" placeholder="Titre" required className="field" />
                  <textarea name="body" placeholder="Contenu (optionnel)" className="field h-20 resize-none" />
                  <div className="flex items-center gap-3">
                    <label className="flex items-center gap-1 text-sm">
                      <input type="checkbox" name="important" className="accent-navy-2" /> Important
                    </label>
                    <input type="date" name="expires_at" className="field w-auto" />
                    <SubmitButton className="btn-primary ml-auto" pending="…">Publier</SubmitButton>
                  </div>
                </form>
              </details>
            )}
          </div>
          {annonces.length === 0 ? (
            <p className="text-sm text-muted">Aucune annonce en ce moment.</p>
          ) : (
            <ul className="space-y-3">
              {annonces.map((a: { id: string; title: string; body: string | null; important: boolean; expires_at: string | null }) => (
                <li key={a.id} className={`rounded-xl p-3 text-sm ${a.important ? "bg-wait-soft" : "bg-paper"}`}>
                  <p className="font-semibold text-ink">{a.important && "⚠️ "}{a.title}</p>
                  {a.body && <p className="mt-1 whitespace-pre-wrap text-muted">{a.body}</p>}
                  {canOrganize(profile) && (
                    <form action={deleteAnnouncement.bind(null, a.id)} className="mt-1">
                      <SubmitButton className="text-xs text-danger hover:underline" pending="…" confirm="Supprimer cette annonce ?">
                        Supprimer
                      </SubmitButton>
                    </form>
                  )}
                </li>
              ))}
            </ul>
          )}
        </section>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        {/* Flotte */}
        <div className="card overflow-hidden">
          <div className="flex items-center justify-between border-b border-line px-4 py-3">
            <h2 className="font-bold text-navy-2">✈️ Flotte AFPA</h2>
            <span className="pill bg-ok-soft text-ok">
              {flotte.filter((a: { available?: boolean; unavailable_reason?: string | null }) => a.available !== false && !a.unavailable_reason).length} dispos
            </span>
          </div>
          <div className="grid grid-cols-2 gap-px bg-line p-px">
            {flotte.map((a: { id: string; registration: string; model: string; available?: boolean; unavailable_reason?: string | null }) => {
              const dispo = a.available !== false && !a.unavailable_reason;
              return (
                <Link
                  key={a.id}
                  href={`/flotte/${a.id}`}
                  className="flex flex-col gap-0.5 bg-white p-3 text-sm transition hover:bg-paper"
                >
                  <span className={`font-bold ${dispo ? "text-ok" : "text-muted"}`}>● {a.registration}</span>
                  <span className="text-xs text-muted">{a.model}</span>
                  {!dispo && <span className="text-xs text-danger">{a.unavailable_reason ?? "Indisponible"}</span>}
                  {dispo && <span className="text-xs text-ok">Dispo</span>}
                </Link>
              );
            })}
          </div>
          <div className="border-t border-line px-4 py-2 text-right">
            <Link href="/flotte" className="text-xs font-medium text-sky-600 hover:underline">Voir la flotte →</Link>
          </div>
        </div>

        {/* Prochaines sorties */}
        <div className="card overflow-hidden">
          <div className="flex items-center justify-between border-b border-line px-4 py-3">
            <h2 className="font-bold text-navy-2">📅 Prochains événements</h2>
            <Link href="/sorties" className="text-xs font-medium text-sky-600 hover:underline">Voir tout →</Link>
          </div>
          {sorties.length === 0 ? (
            <p className="px-4 py-6 text-sm text-muted">Aucun événement à venir.</p>
          ) : (
            <ul className="divide-y divide-line">
              {sorties.map((o) => {
                const badge = dayBadge(o.departure_at);
                const myStatus = myRegMap.get(o.id);
                return (
                  <li key={o.id}>
                    <Link href={`/sorties/${o.id}`} className="flex items-center gap-3 px-4 py-3 transition hover:bg-paper">
                      <div className="flex w-9 shrink-0 flex-col items-center rounded-lg bg-sky-soft py-1 text-navy-2">
                        <span className="text-[9px] font-semibold uppercase">{badge.weekday}</span>
                        <span className="text-base font-bold leading-none">{badge.day}</span>
                        <span className="text-[9px] uppercase">{badge.month}</span>
                      </div>
                      <div className="min-w-0">
                        <p className="truncate text-sm font-semibold text-ink">
                          {KIND_ICON[o.kind ?? "vol"]} {o.title}
                        </p>
                        <p className="text-xs text-muted">{formatTime(o.departure_at)}{o.destination ? ` · ${o.destination}` : ""}</p>
                      </div>
                      {myStatus === "confirmed" && <span className="ml-auto text-xs text-ok">✓</span>}
                    </Link>
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        {/* Équipage de l'année */}
        <div className="card overflow-hidden">
          <div className="flex items-center justify-between border-b border-line px-4 py-3">
            <h2 className="font-bold text-navy-2">🏆 Équipage de l&apos;année</h2>
            <span className="pill bg-paper text-muted">{now.getFullYear()}</span>
          </div>
          {topEquipage.length === 0 ? (
            <p className="px-4 py-6 text-sm text-muted">Pas encore de consommations au bar cette année.</p>
          ) : (
            <ul className="divide-y divide-line">
              {topEquipage.map((m, i) => (
                <li key={m.rank} className="flex items-center gap-3 px-4 py-3 text-sm">
                  <span className="text-xl" aria-hidden>{["🥇", "🥈", "🥉"][i]}</span>
                  <span className="min-w-0 flex-1 truncate font-medium text-ink">{m.name}</span>
                  <span className="font-bold text-navy-2">{m.consos} conso{m.consos > 1 ? "s" : ""}</span>
                </li>
              ))}
            </ul>
          )}
          <div className="border-t border-line px-4 py-2 text-right">
            <Link href="/bar" className="text-xs font-medium text-sky-600 hover:underline">Ouvrir l&apos;Espace Bar →</Link>
          </div>
        </div>
      </div>

      {/* Espace Club - boutons circulaires */}
      <section className="mt-8">
        <div className="mb-4 flex items-center gap-2">
          <div className="h-px flex-1 bg-line" />
          <span className="text-xs font-semibold tracking-widest text-muted uppercase">Espace Club</span>
          <div className="h-px flex-1 bg-line" />
        </div>
        <div className="flex flex-wrap justify-center gap-4">
          {[
            { href: "/bar", icon: "🍺", label: "Espace Bar", sub: "Consommations & solde" },
            { href: "/sorties", icon: "📅", label: "Événements", sub: "Sorties, activités & inscriptions" },
            { href: "/annuaire", icon: "👤", label: "Annuaire", sub: "Trombinoscope & contacts" },
            { href: "/bons-plans", icon: "💡", label: "Bons plans", sub: "Réductions & avantages" },
            { href: "/shop", icon: "🛍️", label: "Le shop", sub: "Vêtements & accessoires" },
            { href: "/preparer-son-vol", icon: "🗺️", label: "Préparer son vol", sub: "Météo, NOTAM, outils" },
            { href: "/flotte", icon: "✈️", label: "Flotte", sub: "Avions & disponibilités" },
            { href: "/centrage", icon: "⚖️", label: "Centrage", sub: "Masse & centrage" },
          ].map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="group flex w-32 flex-col items-center gap-2 rounded-2xl p-4 text-center transition hover:bg-sky-soft"
            >
              <div className="flex h-16 w-16 items-center justify-center rounded-full bg-sky-soft text-3xl shadow-sm transition group-hover:bg-white group-hover:shadow-md">
                {item.icon}
              </div>
              <div>
                <p className="text-sm font-semibold text-navy-2">{item.label}</p>
                <p className="text-[11px] text-muted">{item.sub}</p>
              </div>
            </Link>
          ))}
        </div>
      </section>
    </>
  );
}
