import type { Metadata } from "next";
import Link from "next/link";
import { canOrganize, canTeach, requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner, StatusPill } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { dayBadge, formatDate, formatTime } from "@/lib/dates";
import { PEDA_BUCKET, PEDA_CATEGORIES, REX_PHASES, REX_STATUS, phaseLabel } from "@/lib/pedagogie";
import type { OutingSummary } from "@/lib/types";
import { QUIZ_CATEGORIES } from "@/lib/quiz";
import { PedaUploader } from "./PedaUploader";
import {
  archivePedaDocument,
  archivePost,
  createPost,
  restorePedaDocument,
  reviewRex,
  saveQuizQuestion,
  toggleQuizQuestion,
  submitRex,
} from "./actions";

export const metadata: Metadata = { title: "Espace pédagogique" };
export const dynamic = "force-dynamic";

const TABS = [
  { key: "annonces", label: "Annonces", icon: "📣" },
  { key: "documents", label: "Documents", icon: "📚" },
  { key: "rex", label: "Retours d'expérience", icon: "🛡️" },
  { key: "formations", label: "Formations", icon: "🎓" },
  { key: "quiz", label: "Questions du quiz", icon: "❓" },
] as const;
type Tab = (typeof TABS)[number]["key"];

type Post = { id: string; title: string; body: string; important: boolean; created_at: string; archived_at: string | null };
type Doc = {
  id: string;
  category: string;
  title: string;
  file_path: string;
  file_name: string;
  size_bytes: number | null;
  created_at: string;
  archived_at: string | null;
};
type Rex = {
  id: string;
  author_id: string | null;
  anonymous: boolean;
  occurred_on: string | null;
  phase: string;
  title: string;
  description: string;
  status: string;
  public_summary: string | null;
  lessons: string | null;
  created_at: string;
};
type PublishedRex = { id: string; title: string; phase: string; month: string; summary: string; lessons: string | null; published_at: string };

export default async function Page({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const me = await requireMember();
  const sp = await searchParams;
  const teacher = canTeach(me);
  const tabs = TABS.filter((t) => t.key !== "quiz" || teacher);
  const tab: Tab = (tabs.find((t) => t.key === sp.onglet)?.key ?? "annonces") as Tab;

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />
      <div className="mb-5">
        <h1 className="text-2xl font-bold tracking-tight text-navy-2">🎓 Espace pédagogique</h1>
        <p className="text-sm text-muted">
          Consignes, documents de formation, retours d&apos;expérience et séances proposées par le chef pilote et le responsable conformité.
        </p>
      </div>

      <nav className="mb-6 flex flex-wrap gap-2" aria-label="Rubriques">
        {tabs.map((t) => (
          <Link
            key={t.key}
            href={`/pedagogie?onglet=${t.key}`}
            aria-current={tab === t.key ? "page" : undefined}
            className={`rounded-full border px-4 py-1.5 text-sm font-medium transition-colors ${
              tab === t.key ? "border-navy-2 bg-navy-2 text-white" : "border-line bg-white text-navy-2 hover:bg-sky-soft"
            }`}
          >
            <span aria-hidden>{t.icon}</span> {t.label}
          </Link>
        ))}
      </nav>

      {tab === "annonces" && <Annonces teacher={teacher} />}
      {tab === "documents" && <Documents teacher={teacher} />}
      {tab === "rex" && <RexTab teacher={teacher} myId={me.id} />}
      {tab === "formations" && <Formations organizer={canOrganize(me)} />}
      {tab === "quiz" && teacher && <QuizAdmin cat={sp.cat} />}
    </>
  );
}

// ── Annonces ────────────────────────────────────────────────────────────────

async function Annonces({ teacher }: { teacher: boolean }) {
  const supabase = await createClient();
  const { data } = await supabase
    .from("pedagogy_posts")
    .select("id, title, body, important, created_at, archived_at")
    .is("archived_at", null)
    .order("important", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(50);
  const posts = (data ?? []) as Post[];

  return (
    <div className="grid gap-6 lg:grid-cols-3">
      <div className="space-y-3 lg:col-span-2">
        {posts.length === 0 && <div className="card p-6 text-sm text-muted">Aucune annonce pour le moment.</div>}
        {posts.map((p) => (
          <article key={p.id} className={`card p-5 ${p.important ? "border-l-4 border-l-red" : ""}`}>
            <div className="mb-1 flex flex-wrap items-start justify-between gap-2">
              <h2 className="font-bold text-navy-2">
                {p.important && <span className="pill mr-2 bg-danger-soft text-danger">Important</span>}
                {p.title}
              </h2>
              <span className="text-xs text-muted">{formatDate(p.created_at)}</span>
            </div>
            <p className="whitespace-pre-line text-sm text-ink">{p.body}</p>
            {teacher && (
              <form action={archivePost.bind(null, p.id)} className="mt-3">
                <SubmitButton className="text-xs text-danger hover:underline" pending="…" confirm="Retirer cette annonce ?">
                  Retirer
                </SubmitButton>
              </form>
            )}
          </article>
        ))}
      </div>
      {teacher && (
        <form action={createPost} className="card h-fit space-y-3 p-5">
          <h2 className="font-semibold text-navy-2">Nouvelle annonce</h2>
          <div>
            <label htmlFor="post-title" className="label">Titre</label>
            <input id="post-title" name="title" className="field" required maxLength={200} />
          </div>
          <div>
            <label htmlFor="post-body" className="label">Texte</label>
            <textarea id="post-body" name="body" className="field min-h-36" required maxLength={5000} />
          </div>
          <label className="flex items-center gap-2 text-sm text-ink">
            <input type="checkbox" name="important" className="h-4 w-4 accent-sky" /> Important (affichée en tête)
          </label>
          <SubmitButton pending="Publication…">Publier</SubmitButton>
        </form>
      )}
    </div>
  );
}

// ── Documents ───────────────────────────────────────────────────────────────

function size(n: number | null) {
  if (!n) return "";
  return n > 1024 * 1024 ? `${(n / 1024 / 1024).toFixed(1)} Mo` : `${Math.max(1, Math.round(n / 1024))} Ko`;
}

async function Documents({ teacher }: { teacher: boolean }) {
  const supabase = await createClient();
  const { data } = await supabase
    .from("pedagogy_documents")
    .select("id, category, title, file_path, file_name, size_bytes, created_at, archived_at")
    .order("title");
  const all = (data ?? []) as Doc[];
  const docs = all.filter((d) => !d.archived_at);
  const archived = teacher ? all.filter((d) => d.archived_at) : [];

  // Liens de téléchargement temporaires (1 h) : les fichiers restent privés au club
  const urls = new Map<string, string>();
  if (docs.length) {
    const { data: signed } = await supabase.storage.from(PEDA_BUCKET).createSignedUrls(
      docs.map((d) => d.file_path),
      3600,
    );
    for (const s of signed ?? []) if (s.path && s.signedUrl) urls.set(s.path, s.signedUrl);
  }
  const groups = PEDA_CATEGORIES.map((c) => ({ ...c, docs: docs.filter((d) => d.category === c.key) })).filter(
    (g) => g.docs.length > 0,
  );

  return (
    <div className="space-y-6">
      {teacher && <PedaUploader />}
      {groups.length === 0 && <div className="card p-6 text-sm text-muted">Aucun document pour le moment.</div>}
      {groups.map((g) => (
        <section key={g.key} className="card overflow-hidden">
          <h2 className="border-b border-line px-4 py-3 font-semibold text-navy-2">
            <span aria-hidden>{g.icon}</span> {g.label}
          </h2>
          <ul className="divide-y divide-line">
            {g.docs.map((d) => (
              <li key={d.id} className="flex flex-wrap items-center gap-3 px-4 py-2.5 text-sm">
                <a
                  href={urls.get(d.file_path) ?? "#"}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="min-w-0 flex-1 font-medium text-sky hover:underline"
                >
                  {d.title}
                </a>
                <span className="text-xs text-muted">{size(d.size_bytes)} · {formatDate(d.created_at)}</span>
                {teacher && (
                  <form action={archivePedaDocument.bind(null, d.id)}>
                    <SubmitButton className="text-xs text-danger hover:underline" pending="…" confirm={`Retirer « ${d.title} » ?`}>
                      Retirer
                    </SubmitButton>
                  </form>
                )}
              </li>
            ))}
          </ul>
        </section>
      ))}
      {archived.length > 0 && (
        <details className="card p-4 text-sm">
          <summary className="cursor-pointer font-medium text-muted">Documents retirés ({archived.length})</summary>
          <ul className="mt-2 divide-y divide-line">
            {archived.map((d) => (
              <li key={d.id} className="flex items-center gap-3 py-2">
                <span className="flex-1 text-muted">{d.title}</span>
                <form action={restorePedaDocument.bind(null, d.id)}>
                  <SubmitButton className="text-xs text-sky hover:underline" pending="…">
                    Remettre en ligne
                  </SubmitButton>
                </form>
              </li>
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}

// ── Retours d'expérience ────────────────────────────────────────────────────

async function RexTab({ teacher, myId }: { teacher: boolean; myId: string }) {
  const supabase = await createClient();
  const [{ data: pub }, { data: rows }] = await Promise.all([
    supabase.rpc("rex_published"),
    // la base ne renvoie que ses propres REX signés à un membre, et tous au chef pilote / resp. conformité
    supabase
      .from("rex_reports")
      .select("id, author_id, anonymous, occurred_on, phase, title, description, status, public_summary, lessons, created_at")
      .order("created_at", { ascending: false })
      .limit(200),
  ]);
  const published = (pub ?? []) as PublishedRex[];
  const reports = (rows ?? []) as Rex[];
  const mine = reports.filter((r) => r.author_id === myId);
  const inbox = teacher ? reports.filter((r) => r.status === "nouveau" || r.status === "en_analyse") : [];
  const done = teacher ? reports.filter((r) => r.status === "publie" || r.status === "clos") : [];

  return (
    <div className="grid gap-6 lg:grid-cols-3">
      <div className="space-y-6 lg:col-span-2">
        {teacher && (
          <section>
            <h2 className="mb-3 text-lg font-bold text-navy-2">À traiter ({inbox.length})</h2>
            {inbox.length === 0 && <div className="card p-5 text-sm text-muted">Aucun REX en attente.</div>}
            <div className="space-y-3">
              {inbox.map((r) => (
                <RexReview key={r.id} r={r} />
              ))}
            </div>
          </section>
        )}

        <section>
          <h2 className="mb-3 text-lg font-bold text-navy-2">Enseignements publiés</h2>
          {published.length === 0 && (
            <div className="card p-5 text-sm text-muted">Aucun retour d&apos;expérience publié pour le moment.</div>
          )}
          <div className="space-y-3">
            {published.map((r) => (
              <article key={r.id} className="card p-5">
                <div className="mb-1 flex flex-wrap items-center gap-2">
                  <h3 className="font-bold text-navy-2">{r.title}</h3>
                  <span className="pill bg-sky-soft text-navy-2">{phaseLabel(r.phase)}</span>
                </div>
                <p className="whitespace-pre-line text-sm text-ink">{r.summary}</p>
                {r.lessons && (
                  <div className="mt-3 rounded-lg bg-ok-soft px-4 py-3 text-sm text-ink">
                    <p className="mb-1 font-semibold text-ok">À retenir</p>
                    <p className="whitespace-pre-line">{r.lessons}</p>
                  </div>
                )}
              </article>
            ))}
          </div>
        </section>

        {teacher && done.length > 0 && (
          <details className="card p-4 text-sm">
            <summary className="cursor-pointer font-medium text-muted">REX traités ({done.length})</summary>
            <div className="mt-3 space-y-3">
              {done.map((r) => (
                <RexReview key={r.id} r={r} />
              ))}
            </div>
          </details>
        )}
      </div>

      <div className="space-y-4">
        <form action={submitRex} className="card space-y-3 p-5">
          <h2 className="font-semibold text-navy-2">Déposer un retour d&apos;expérience</h2>
          <p className="text-xs text-muted">
            Erreur, incident, situation inhabituelle : le partager aide tout le monde. Pas de jugement, pas de sanction —
            seuls le chef pilote et le responsable conformité lisent votre récit.
          </p>
          <div>
            <label htmlFor="rex-title" className="label">En une phrase</label>
            <input id="rex-title" name="title" className="field" required maxLength={200} placeholder="Ex. Oubli de réchauffage carbu en descente" />
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label htmlFor="rex-phase" className="label">Phase</label>
              <select id="rex-phase" name="phase" className="field" defaultValue="autre">
                {REX_PHASES.map((p) => (
                  <option key={p.key} value={p.key}>{p.label}</option>
                ))}
              </select>
            </div>
            <div>
              <label htmlFor="rex-date" className="label">Date (facultatif)</label>
              <input id="rex-date" name="occurred_on" type="date" className="field" />
            </div>
          </div>
          <div>
            <label htmlFor="rex-desc" className="label">Que s&apos;est-il passé ?</label>
            <textarea
              id="rex-desc"
              name="description"
              className="field min-h-36"
              required
              maxLength={5000}
              placeholder="Contexte, ce qui s'est passé, ce que vous avez fait, ce qui aurait pu l'éviter…"
            />
          </div>
          <label className="flex items-start gap-2 text-sm text-ink">
            <input type="checkbox" name="anonymous" className="mt-0.5 h-4 w-4 accent-sky" />
            <span>
              Anonyme <span className="block text-xs text-muted">Votre nom n&apos;est pas enregistré ; vous ne pourrez pas suivre ce REX.</span>
            </span>
          </label>
          <SubmitButton pending="Envoi…">Envoyer</SubmitButton>
        </form>

        {!teacher && mine.length > 0 && (
          <div className="card overflow-hidden">
            <h2 className="border-b border-line px-4 py-3 font-semibold text-navy-2">Mes REX</h2>
            <ul className="divide-y divide-line">
              {mine.map((r) => (
                <li key={r.id} className="flex items-center justify-between gap-2 px-4 py-2 text-sm">
                  <span className="min-w-0 truncate text-ink">{r.title}</span>
                  <span className={`pill ${REX_STATUS[r.status]?.cls ?? ""}`}>{REX_STATUS[r.status]?.label ?? r.status}</span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>
    </div>
  );
}

function RexReview({ r }: { r: Rex }) {
  return (
    <form action={reviewRex.bind(null, r.id)} className="card space-y-3 p-5">
      <div className="flex flex-wrap items-center gap-2">
        <h3 className="font-bold text-navy-2">{r.title}</h3>
        <span className="pill bg-sky-soft text-navy-2">{phaseLabel(r.phase)}</span>
        <span className={`pill ${REX_STATUS[r.status]?.cls ?? ""}`}>{REX_STATUS[r.status]?.label}</span>
      </div>
      <p className="text-xs text-muted">
        Déposé le {formatDate(r.created_at)}
        {r.occurred_on && <> · survenu le {formatDate(r.occurred_on)}</>}
        {r.anonymous ? " · anonyme" : " · signé"}
      </p>
      <blockquote className="whitespace-pre-line rounded-lg bg-paper px-4 py-3 text-sm text-ink">{r.description}</blockquote>
      <div>
        <label className="label" htmlFor={`sum-${r.id}`}>Résumé publié aux membres (sans éléments permettant d&apos;identifier qui que ce soit)</label>
        <textarea id={`sum-${r.id}`} name="public_summary" className="field min-h-24" defaultValue={r.public_summary ?? ""} maxLength={5000} />
      </div>
      <div>
        <label className="label" htmlFor={`les-${r.id}`}>À retenir / enseignements</label>
        <textarea id={`les-${r.id}`} name="lessons" className="field min-h-20" defaultValue={r.lessons ?? ""} maxLength={5000} />
      </div>
      <div className="flex flex-wrap items-end gap-2">
        <div>
          <label className="label" htmlFor={`st-${r.id}`}>Statut</label>
          <select id={`st-${r.id}`} name="status" className="field" defaultValue={r.status}>
            {Object.entries(REX_STATUS).map(([k, v]) => (
              <option key={k} value={k}>{v.label}</option>
            ))}
          </select>
        </div>
        <SubmitButton pending="…">Enregistrer</SubmitButton>
      </div>
    </form>
  );
}

// ── Formations ──────────────────────────────────────────────────────────────

async function Formations({ organizer }: { organizer: boolean }) {
  const supabase = await createClient();
  const { data } = await supabase.rpc("list_outings", { p_past: false });
  const sessions = ((data ?? []) as OutingSummary[]).filter(
    (o) => o.kind === "formation" && o.status === "open" && (!o.approval || o.approval === "approved"),
  );

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-muted">Briefings, soirées théoriques et séances de révision. Inscription dans l&apos;ordre d&apos;arrivée.</p>
        <Link href="/sorties/nouvelle?type=formation" className="btn-primary">
          {organizer ? "+ Programmer une formation" : "+ Proposer une formation"}
        </Link>
      </div>
      {sessions.length === 0 && <div className="card p-6 text-sm text-muted">Aucune séance programmée.</div>}
      {sessions.map((o) => {
        const b = dayBadge(o.departure_at);
        const left = o.total_capacity == null ? null : Math.max(o.total_capacity - o.confirmed_count, 0);
        return (
          <Link key={o.id} href={`/sorties/${o.id}`} className="card flex gap-4 p-4 transition hover:shadow-md">
            <div className="flex w-12 shrink-0 flex-col items-center justify-center rounded-xl bg-sky-soft py-2 text-navy-2">
              <span className="text-[10px] font-semibold uppercase">{b.weekday}</span>
              <span className="text-2xl font-bold leading-none">{b.day}</span>
              <span className="text-[11px] font-medium uppercase">{b.month}</span>
            </div>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-start justify-between gap-1">
                <p className="font-semibold text-ink">🎓 {o.title}</p>
                <StatusPill status={o.my_status} />
              </div>
              <p className="text-xs text-muted">
                {formatDate(o.departure_at)} · {formatTime(o.departure_at)}
                {o.destination && <> · {o.destination}</>} · par {o.instructor_name}
                {left != null && <> · {left === 0 ? "complet" : `${left} place${left > 1 ? "s" : ""} libre${left > 1 ? "s" : ""}`}</>}
              </p>
            </div>
          </Link>
        );
      })}
    </div>
  );
}

// ── Questions du quiz (chef pilote, resp. conformité, admins) ───────────────

type QuizQ = {
  id: number;
  question: string;
  option_a: string;
  option_b: string;
  option_c: string;
  option_d: string;
  correct: string;
  explanation: string | null;
  category: string;
  active: boolean;
};

async function QuizAdmin({ cat }: { cat?: string }) {
  const supabase = await createClient();
  const { data, error } = await supabase.from("quiz_questions").select("*").order("category").order("id");
  const all = (data ?? []) as QuizQ[];
  const shown = cat ? all.filter((q) => q.category === cat) : all;
  const counts = new Map<string, number>();
  for (const q of all) counts.set(q.category, (counts.get(q.category) ?? 0) + 1);

  return (
    <div className="space-y-5">
      <p className="text-sm text-muted">
        Une question par jour est tirée parmi les questions actives ({all.filter((q) => q.active).length}). Vérifiez chaque
        réponse avec les documents de référence (VAC, AIP, manuels de vol) : le quiz sert à apprendre.
      </p>
      {error && (
        <p className="rounded-lg bg-wait-soft px-4 py-3 text-sm text-wait">
          La base n&apos;est pas à jour : exécutez la mise à jour n°33 dans Supabase pour gérer les questions.
        </p>
      )}

      <details className="card p-5">
        <summary className="cursor-pointer font-semibold text-navy-2">+ Ajouter une question</summary>
        <QuizForm action={saveQuizQuestion.bind(null, null)} />
      </details>

      <nav className="flex flex-wrap gap-2 text-sm" aria-label="Catégories">
        <Link href="/pedagogie?onglet=quiz" className={`pill ${!cat ? "bg-navy-2 text-white" : "bg-white text-navy-2"}`}>
          Toutes ({all.length})
        </Link>
        {Object.entries(QUIZ_CATEGORIES)
          .filter(([k]) => counts.has(k))
          .map(([k, label]) => (
            <Link key={k} href={`/pedagogie?onglet=quiz&cat=${k}`} className={`pill ${cat === k ? "bg-navy-2 text-white" : "bg-white text-navy-2"}`}>
              {label} ({counts.get(k)})
            </Link>
          ))}
      </nav>

      <ul className="space-y-2">
        {shown.map((q) => (
          <li key={q.id} className={`card p-4 ${q.active ? "" : "opacity-60"}`}>
            <details>
              <summary className="cursor-pointer list-none">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <p className="min-w-0 flex-1 text-sm font-medium text-ink">{q.question}</p>
                  <span className="pill bg-sky-soft text-navy-2">{QUIZ_CATEGORIES[q.category] ?? q.category}</span>
                  {!q.active && <span className="pill bg-paper text-muted">retirée</span>}
                </div>
                <p className="mt-1 text-xs text-ok">
                  Réponse : {q.correct.toUpperCase()}. {q[`option_${q.correct}` as "option_a"]}
                </p>
              </summary>
              <QuizForm q={q} action={saveQuizQuestion.bind(null, q.id)} />
              <form action={toggleQuizQuestion.bind(null, q.id, !q.active)} className="mt-2">
                <SubmitButton className="text-xs text-muted hover:underline" pending="…">
                  {q.active ? "Retirer du quiz" : "Remettre dans le quiz"}
                </SubmitButton>
              </form>
            </details>
          </li>
        ))}
      </ul>
    </div>
  );
}

function QuizForm({ q, action }: { q?: QuizQ; action: (fd: FormData) => Promise<void> }) {
  const p = q?.id ?? "new";
  return (
    <form action={action} className="mt-4 space-y-3">
      <div>
        <label className="label" htmlFor={`q-${p}`}>Question</label>
        <textarea id={`q-${p}`} name="question" className="field min-h-16" defaultValue={q?.question} required maxLength={500} />
      </div>
      <div className="grid gap-2 sm:grid-cols-2">
        {(["a", "b", "c", "d"] as const).map((k) => (
          <div key={k}>
            <label className="label" htmlFor={`o${k}-${p}`}>Réponse {k.toUpperCase()}</label>
            <input id={`o${k}-${p}`} name={`option_${k}`} className="field" defaultValue={q?.[`option_${k}`]} required maxLength={300} />
          </div>
        ))}
      </div>
      <div className="flex flex-wrap items-end gap-3">
        <div>
          <label className="label" htmlFor={`c-${p}`}>Bonne réponse</label>
          <select id={`c-${p}`} name="correct" className="field" defaultValue={q?.correct ?? ""} required>
            <option value="" disabled>…</option>
            {["a", "b", "c", "d"].map((k) => (
              <option key={k} value={k}>{k.toUpperCase()}</option>
            ))}
          </select>
        </div>
        <div>
          <label className="label" htmlFor={`cat-${p}`}>Catégorie</label>
          <select id={`cat-${p}`} name="category" className="field" defaultValue={q?.category ?? "general"}>
            {Object.entries(QUIZ_CATEGORIES).map(([k, label]) => (
              <option key={k} value={k}>{label}</option>
            ))}
          </select>
        </div>
        <label className="flex items-center gap-2 pb-2 text-sm text-ink">
          <input type="checkbox" name="active" defaultChecked={q?.active ?? true} className="h-4 w-4 accent-sky" /> Active
        </label>
      </div>
      <div>
        <label className="label" htmlFor={`e-${p}`}>Explication (affichée après la réponse)</label>
        <textarea id={`e-${p}`} name="explanation" className="field min-h-16" defaultValue={q?.explanation ?? ""} maxLength={1500} />
      </div>
      <SubmitButton pending="Enregistrement…">{q ? "Enregistrer" : "Ajouter"}</SubmitButton>
    </form>
  );
}
