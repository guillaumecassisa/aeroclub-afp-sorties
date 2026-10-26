import { createClient } from "@/lib/supabase/server";
import { QUIZ_CATEGORIES } from "@/lib/quiz";

const MEDALS = ["🥇", "🥈", "🥉"];

type Answer = { question_id: number; answered_on: string; is_correct: boolean; question: string; category: string | null };

/** Résultats personnels aux questions du jour (page « Mon compte »). */
export async function QuizResults({ meId }: { meId: string }) {
  const supabase = await createClient();
  const [{ data: leaderRaw }, { data: historyRaw }, { data: statsRaw }, { data: setRaw }] = await Promise.all([
    supabase.rpc("quiz_leaderboard"),
    supabase.rpc("quiz_my_history"),
    supabase.rpc("quiz_my_stats"),
    supabase.rpc("quiz_today_set"),
  ]);
  const answers = (historyRaw ?? []) as Answer[];
  const stats = statsRaw as { total: number; correct: number } | null;
  const total = stats?.total ?? answers.length;
  const correct = stats?.correct ?? answers.filter((a) => a.is_correct).length;
  const rank = ((leaderRaw ?? []) as { user_id: string }[]).findIndex((r) => r.user_id === meId) + 1;
  const today = (setRaw as { questions?: { already_answered: boolean }[] } | null)?.questions ?? [];
  const todayDone = today.filter((q) => q.already_answered).length;
  const recent = answers.slice(0, 10);
  const older = answers.slice(10);

  return (
    <div className="space-y-4">
      {today.length > 0 && (
        <p className="text-sm text-ink">
          Aujourd&apos;hui : <strong>{todayDone} / {today.length}</strong> question{today.length > 1 ? "s" : ""} répondue{todayDone > 1 ? "s" : ""}
          {todayDone < today.length && <span className="text-muted"> — les questions du jour s&apos;affichent sur la page d&apos;accueil.</span>}
        </p>
      )}

      {total === 0 ? (
        <p className="text-sm text-muted">Vous n&apos;avez pas encore répondu aux questions du jour : elles s&apos;affichent sur la page d&apos;accueil.</p>
      ) : (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Stat value={String(correct)} label="bonnes réponses" />
          <Stat value={String(total)} label="questions répondues" />
          <Stat value={`${Math.round((correct / total) * 100)} %`} label="de réussite" />
          <Stat value={rank > 0 ? (rank <= 3 ? MEDALS[rank - 1] : `#${rank}`) : "—"} label="mon classement" />
        </div>
      )}

      {recent.length > 0 && (
        <div>
          <h3 className="mb-2 text-sm font-semibold text-navy-2">Mes réponses récentes</h3>
          <AnswerList answers={recent} />
          {older.length > 0 && (
            <details className="mt-2">
              <summary className="cursor-pointer text-sm text-sky hover:underline">Voir les {older.length} précédentes</summary>
              <div className="mt-2">
                <AnswerList answers={older} />
              </div>
            </details>
          )}
        </div>
      )}

      <p className="text-xs text-muted">
        De nombreuses questions s&apos;appuient sur le Guide de l&apos;instructeur VFR de l&apos;ENAC (éd. 3, amdt 2,
        licence CC BY-NC-ND), la carte VAC de l&apos;AIP France et le règlement intérieur du club. En cas de doute, la
        documentation officielle en vigueur fait foi.
      </p>
    </div>
  );
}

function Stat({ value, label }: { value: string; label: string }) {
  return (
    <div className="rounded-xl border border-sky/20 bg-sky-soft p-3 text-center">
      <div className="text-2xl font-bold text-navy-2">{value}</div>
      <div className="mt-0.5 text-xs text-muted">{label}</div>
    </div>
  );
}

function AnswerList({ answers }: { answers: Answer[] }) {
  const fmt = (d: string) =>
    new Intl.DateTimeFormat("fr-FR", { day: "numeric", month: "short", timeZone: "UTC" }).format(new Date(`${d}T12:00:00Z`));
  return (
    <ul className="divide-y divide-line overflow-hidden rounded-xl border border-line">
      {answers.map((a) => (
        <li key={`${a.question_id}-${a.answered_on}`} className="flex items-start gap-3 bg-white px-3 py-2.5">
          <span className="mt-0.5 shrink-0">{a.is_correct ? "✅" : "❌"}</span>
          <div className="min-w-0 flex-1">
            <p className="text-sm leading-snug text-ink">{a.question}</p>
            <p className="mt-0.5 text-xs text-muted">
              {QUIZ_CATEGORIES[a.category ?? ""] ?? "Général"} · {fmt(a.answered_on)}
            </p>
          </div>
        </li>
      ))}
    </ul>
  );
}
