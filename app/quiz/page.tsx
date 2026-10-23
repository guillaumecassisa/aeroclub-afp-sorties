import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Avatar } from "@/components/Avatar";
import { QUIZ_CATEGORIES } from "@/lib/quiz";
import { QuizPopup, type DailySet } from "@/components/QuizPopup";
import { submitQuizAnswer } from "@/app/quiz/actions";

export const dynamic = "force-dynamic";
export const metadata = { title: "Questions du jour — Classement" };

type LeaderRow = {
  user_id: string;
  full_name: string | null;
  avatar_url: string | null;
  total: number;
  correct: number;
};

const MEDALS = ["🥇", "🥈", "🥉"];
const CATEGORY_LABELS = QUIZ_CATEGORIES;

export default async function QuizPage() {
  const profile = await requireMember();
  const supabase = await createClient();

  // Classement et historique calculés par la base (les noms des autres membres n'y sont pas lisibles directement)
  const [{ data: leaderRaw }, { data: historyRaw }, { data: statsRaw }, { data: setRaw }] = await Promise.all([
    supabase.rpc("quiz_leaderboard"),
    supabase.rpc("quiz_my_history"),
    supabase.rpc("quiz_my_stats"),
    supabase.rpc("quiz_today_set"),
  ]);
  const dailySet = setRaw as DailySet | null;
  const stats = statsRaw as { total: number; correct: number } | null;
  const leaderboard = (leaderRaw ?? []) as LeaderRow[];
  const myAnswers = (historyRaw ?? []) as {
    question_id: number;
    answered_on: string;
    is_correct: boolean;
    question: string;
    category: string | null;
  }[];

  // Totaux sur toutes mes réponses (l'historique affiché se limite aux plus récentes)
  const myTotal = stats?.total ?? myAnswers.length;
  const myCorrect = stats?.correct ?? myAnswers.filter((a) => a.is_correct).length;
  const myRank = leaderboard.findIndex((r) => r.user_id === profile.id) + 1;

  return (
    <div className="space-y-8">
      {dailySet?.questions?.length ? <QuizPopup set={dailySet} submitAnswer={submitQuizAnswer} /> : null}
      <div>
        <h1 className="text-2xl font-bold text-navy-2">✈️ Questions du jour</h1>
        <p className="mt-1 text-sm text-muted">
          Chaque jour, 3 nouvelles questions (QCM) pour réviser le pilotage, la météo, la réglementation et la navigation. Le classement est mis à jour en temps réel.
        </p>
      </div>

      {myTotal > 0 && (
        <div className="rounded-2xl bg-sky-soft border border-sky/20 p-4 flex flex-wrap items-center gap-6">
          <div className="text-center">
            <div className="text-3xl font-bold text-navy-2">{myCorrect}</div>
            <div className="text-xs text-muted mt-0.5">Bonnes réponses</div>
          </div>
          <div className="text-center">
            <div className="text-3xl font-bold text-navy-2">{myTotal}</div>
            <div className="text-xs text-muted mt-0.5">Questions répondues</div>
          </div>
          <div className="text-center">
            <div className="text-3xl font-bold text-navy-2">
              {myTotal > 0 ? Math.round((myCorrect / myTotal) * 100) : 0}%
            </div>
            <div className="text-xs text-muted mt-0.5">Taux de réussite</div>
          </div>
          {myRank > 0 && (
            <div className="text-center">
              <div className="text-3xl font-bold text-navy-2">
                {myRank <= 3 ? MEDALS[myRank - 1] : `#${myRank}`}
              </div>
              <div className="text-xs text-muted mt-0.5">Mon classement</div>
            </div>
          )}
        </div>
      )}

      <div>
        <h2 className="text-lg font-semibold text-navy-2 mb-3">🏆 Classement général</h2>
        {leaderboard.length === 0 ? (
          <p className="text-sm text-muted">Personne n&apos;a encore répondu. Sois le premier !</p>
        ) : (
          <div className="divide-y divide-line rounded-2xl border border-line overflow-hidden">
            {leaderboard.map((row, i) => {
              const isMe = row.user_id === profile.id;
              const pct = row.total > 0 ? Math.round((row.correct / row.total) * 100) : 0;
              return (
                <div
                  key={row.user_id}
                  className={`flex items-center gap-3 px-4 py-3 ${isMe ? "bg-sky-soft" : "bg-white"}`}
                >
                  <div className="w-8 text-center text-sm font-bold text-muted shrink-0">
                    {i < 3 ? MEDALS[i] : <span className="text-xs">#{i + 1}</span>}
                  </div>
                  <Avatar url={row.avatar_url} name={row.full_name ?? "?"} size="sm" />
                  <div className="flex-1 min-w-0">
                    <div className={`text-sm font-medium truncate ${isMe ? "text-sky" : "text-ink"}`}>
                      {row.full_name ?? "Membre"}{isMe && " (moi)"}
                    </div>
                    <div className="text-xs text-muted">
                      {row.correct}/{row.total} correctes — {pct}%
                    </div>
                  </div>
                  <div className="hidden sm:block w-24 shrink-0">
                    <div className="h-1.5 rounded-full bg-line overflow-hidden">
                      <div
                        className="h-full rounded-full bg-emerald-400"
                        style={{ width: `${pct}%` }}
                      />
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {(myAnswers?.length ?? 0) > 0 && (
        <div>
          <h2 className="text-lg font-semibold text-navy-2 mb-3">📅 Mes réponses récentes</h2>
          <div className="divide-y divide-line rounded-2xl border border-line overflow-hidden">
            {myAnswers.map((a) => {
              return (
                <div key={`${a.question_id}-${a.answered_on}`} className="flex items-start gap-3 px-4 py-3 bg-white">
                  <span className="shrink-0 text-base mt-0.5">{a.is_correct ? "✅" : "❌"}</span>
                  <div className="flex-1 min-w-0">
                    <div className="text-sm text-ink leading-snug">{a.question}</div>
                    <div className="text-xs text-muted mt-0.5">
                      {CATEGORY_LABELS[a.category ?? ""] ?? ""} · {a.answered_on}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}

      <p className="text-xs text-muted">
        De nombreuses questions s&apos;appuient sur le Guide de l&apos;instructeur VFR de l&apos;ENAC (éd. 3, amdt 2,
        licence CC BY-NC-ND) et, pour le terrain, sur la carte VAC de l&apos;AIP France. En cas de doute, la
        documentation officielle en vigueur fait foi.
      </p>
    </div>
  );
}
