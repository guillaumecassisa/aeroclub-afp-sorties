"use client";

import { useState, useEffect } from "react";

/** Une question du jour telle que renvoyée par la base : la bonne réponse n'y figure qu'après avoir répondu. */
export type DailyQuestion = {
  id: number;
  question: string;
  option_a: string;
  option_b: string;
  option_c: string;
  option_d: string;
  category: string | null;
  already_answered: boolean;
  my_answer?: string | null;
  is_correct?: boolean | null;
  correct: string | null;
  explanation: string | null;
};

/** Les questions du jour (3 par défaut). */
export type DailySet = { day: string; questions: DailyQuestion[] };

type Result = { correct: boolean; answer: string; explanation: string | null; error?: string };

type Props = {
  set: DailySet;
  submitAnswer: (questionId: number, answer: string) => Promise<Result>;
};

const OPTIONS = ["a", "b", "c", "d"] as const;

export function QuizPopup({ set, submitAnswer }: Props) {
  const total = set.questions.length;
  // Réponses déjà données aujourd'hui (au chargement), puis complétées au fil des clics
  const [answers, setAnswers] = useState<Record<number, { choice: string; result: Result }>>(() => {
    const init: Record<number, { choice: string; result: Result }> = {};
    for (const q of set.questions) {
      if (q.already_answered && q.correct) {
        init[q.id] = {
          choice: q.my_answer ?? "",
          result: { correct: !!q.is_correct, answer: q.correct, explanation: q.explanation },
        };
      }
    }
    return init;
  });
  const answeredCount = set.questions.filter((q) => answers[q.id] && !answers[q.id].result.error).length;
  const firstOpen = set.questions.findIndex((q) => !answers[q.id]);
  const [index, setIndex] = useState(firstOpen === -1 ? 0 : firstOpen);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const allDone = answeredCount >= total;

  const dismissKey = `quiz_dismissed_${set.day}`;

  useEffect(() => {
    if (allDone) return;
    try {
      if (localStorage.getItem(dismissKey)) return;
    } catch {}
    const t = setTimeout(() => setOpen(true), 1500);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dismissKey]);

  function dismiss() {
    try {
      localStorage.setItem(dismissKey, "1");
    } catch {}
    setOpen(false);
  }

  const q = set.questions[index];
  const current = q ? answers[q.id] : undefined;

  async function handleAnswer(opt: string) {
    if (!q || current || loading) return;
    setLoading(true);
    try {
      const res = await submitAnswer(q.id, opt);
      if (res.error) {
        setAnswers((a) => ({ ...a, [q.id]: { choice: "", result: res } }));
        // une erreur n'est pas une réponse : on permet de réessayer
        setTimeout(() => setAnswers((a) => {
          const next = { ...a };
          delete next[q.id];
          return next;
        }), 4000);
      } else {
        setAnswers((a) => ({ ...a, [q.id]: { choice: opt, result: res } }));
      }
    } finally {
      setLoading(false);
    }
  }

  const score = set.questions.filter((x) => answers[x.id]?.result.correct).length;
  const label: Record<string, string> = q
    ? { a: q.option_a, b: q.option_b, c: q.option_c, d: q.option_d }
    : {};

  return (
    <>
      {/* Bouton flottant */}
      <button
        onClick={() => setOpen((v) => !v)}
        className="fixed bottom-6 right-6 z-50 flex items-center gap-2 rounded-full bg-navy-2 px-4 py-2.5 text-sm font-semibold text-white shadow-lg transition hover:bg-navy-2/90"
      >
        ✈️ Questions du jour
        <span className="rounded-full bg-white/20 px-1.5 text-xs">
          {answeredCount}/{total}
        </span>
        {!allDone && (
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-sky-400 opacity-75" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-sky-400" />
          </span>
        )}
      </button>

      {open && q && (
        <div
          role="dialog"
          aria-label="Questions du jour"
          className="fixed bottom-20 right-4 left-4 z-50 max-h-[75vh] overflow-y-auto rounded-2xl border border-line bg-white p-5 shadow-2xl sm:left-auto sm:w-96"
        >
          <div className="mb-3 flex items-center justify-between gap-2">
            <p className="text-xs font-semibold tracking-widest text-muted uppercase">
              Question {index + 1} / {total}
            </p>
            <div className="flex items-center gap-1.5">
              {set.questions.map((x, i) => {
                const r = answers[x.id]?.result;
                const color = !r || r.error ? "bg-line" : r.correct ? "bg-emerald-400" : "bg-red-400";
                return (
                  <button
                    key={x.id}
                    onClick={() => setIndex(i)}
                    aria-label={`Question ${i + 1}`}
                    className={`h-2.5 w-2.5 rounded-full ${color} ${i === index ? "ring-2 ring-navy-2 ring-offset-1" : ""}`}
                  />
                );
              })}
              <button onClick={dismiss} aria-label="Fermer" className="ml-2 text-lg leading-none text-muted hover:text-ink">
                ×
              </button>
            </div>
          </div>

          <p className="mb-4 text-sm leading-snug font-medium text-ink">{q.question}</p>

          <div className="space-y-2">
            {OPTIONS.map((opt) => {
              const done = current && !current.result.error;
              const isGood = done && current.result.answer === opt;
              const isMine = done && current.choice === opt;
              let cls = "w-full rounded-xl border px-3 py-2 text-left text-sm transition ";
              if (!done) cls += "border-line hover:border-sky-400 hover:bg-sky-soft";
              else if (isGood) cls += "border-emerald-400 bg-emerald-50 font-semibold text-emerald-700";
              else if (isMine) cls += "border-red-400 bg-red-50 text-red-700";
              else cls += "border-line text-muted";
              return (
                <button key={opt} className={cls} onClick={() => handleAnswer(opt)} disabled={!!done || loading}>
                  <span className="mr-2 font-bold uppercase">{opt}.</span>
                  {label[opt]}
                </button>
              );
            })}
          </div>

          {current?.result.error && (
            <p className="mt-3 rounded-xl bg-red-50 p-3 text-sm text-red-700">{current.result.error}</p>
          )}
          {current && !current.result.error && (
            <div
              className={`mt-3 rounded-xl p-3 text-sm ${current.result.correct ? "bg-emerald-50 text-emerald-700" : "bg-red-50 text-red-700"}`}
            >
              <p className="font-semibold">{current.result.correct ? "✅ Bonne réponse !" : "❌ Raté !"}</p>
              {current.result.explanation && <p className="mt-1 text-xs opacity-80">{current.result.explanation}</p>}
            </div>
          )}

          <div className="mt-4 flex items-center justify-between gap-2">
            {allDone ? (
              <p className="text-sm font-semibold text-navy-2">
                Score du jour : {score}/{total}. Revenez demain !
              </p>
            ) : (
              <span className="text-xs text-muted">{total - answeredCount} question(s) restante(s)</span>
            )}
            {current && !current.result.error && index < total - 1 ? (
              <button onClick={() => setIndex(index + 1)} className="btn-primary text-sm">
                Question suivante →
              </button>
            ) : (
              <a href="/quiz" className="text-xs font-medium underline opacity-70 hover:opacity-100">
                Voir le classement →
              </a>
            )}
          </div>
        </div>
      )}
    </>
  );
}
