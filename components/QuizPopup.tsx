"use client";

import { useState, useEffect } from "react";

type Question = {
  id: number;
  question: string;
  option_a: string;
  option_b: string;
  option_c: string;
  option_d: string;
  correct: string;
  explanation: string | null;
  category: string | null;
};

type Props = {
  question: Question;
  alreadyAnswered: boolean;
  submitAnswer: (questionId: number, answer: string) => Promise<{ correct: boolean }>;
};

const OPTIONS = ["a", "b", "c", "d"] as const;

export function QuizPopup({ question, alreadyAnswered, submitAnswer }: Props) {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [result, setResult] = useState<{ correct: boolean } | null>(null);
  const [loading, setLoading] = useState(false);

  const today = new Date().toISOString().slice(0, 10);
  const dismissKey = `quiz_dismissed_${today}`;

  useEffect(() => {
    if (alreadyAnswered) return;
    try {
      if (localStorage.getItem(dismissKey)) return;
    } catch {}
    const t = setTimeout(() => setOpen(true), 1500);
    return () => clearTimeout(t);
  }, [alreadyAnswered, dismissKey]);

  function dismiss() {
    try { localStorage.setItem(dismissKey, "1"); } catch {}
    setOpen(false);
  }

  async function handleAnswer(opt: string) {
    if (selected || loading) return;
    setSelected(opt);
    setLoading(true);
    try {
      const res = await submitAnswer(question.id, opt);
      setResult(res);
    } finally {
      setLoading(false);
    }
  }

  const optionLabel: Record<string, string> = {
    a: question.option_a,
    b: question.option_b,
    c: question.option_c,
    d: question.option_d,
  };

  return (
    <>
      {/* Bouton flottant */}
      <button
        onClick={() => setOpen((v) => !v)}
        className="fixed bottom-6 right-6 z-50 flex items-center gap-2 rounded-full bg-navy-2 px-4 py-2.5 text-sm font-semibold text-white shadow-lg transition hover:bg-navy-2/90"
      >
        ✈️ Question du jour
        {!alreadyAnswered && !result && (
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-sky-400 opacity-75" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-sky-400" />
          </span>
        )}
      </button>

      {/* Pop-up */}
      {open && (
        <div className="fixed bottom-20 right-6 z-50 w-80 rounded-2xl bg-white p-5 shadow-2xl border border-line">
          <div className="mb-3 flex items-start justify-between gap-2">
            <p className="text-xs font-semibold tracking-widest text-muted uppercase">Question du jour</p>
            <button onClick={dismiss} className="text-muted hover:text-ink text-lg leading-none">×</button>
          </div>

          <p className="mb-4 text-sm font-medium text-ink leading-snug">{question.question}</p>

          {alreadyAnswered && !result ? (
            <p className="text-sm text-muted italic">Tu as déjà répondu aujourd'hui. Reviens demain !</p>
          ) : (
            <div className="space-y-2">
              {OPTIONS.map((opt) => {
                const isSelected = selected === opt;
                const isCorrect = question.correct === opt;
                let cls = "w-full rounded-xl border px-3 py-2 text-left text-sm transition ";
                if (!selected) {
                  cls += "border-line hover:border-sky-400 hover:bg-sky-soft";
                } else if (isCorrect) {
                  cls += "border-emerald-400 bg-emerald-50 font-semibold text-emerald-700";
                } else if (isSelected) {
                  cls += "border-red-400 bg-red-50 text-red-700";
                } else {
                  cls += "border-line text-muted";
                }
                return (
                  <button key={opt} className={cls} onClick={() => handleAnswer(opt)} disabled={!!selected || loading}>
                    <span className="mr-2 font-bold uppercase">{opt}.</span>{optionLabel[opt]}
                  </button>
                );
              })}
            </div>
          )}

          {result && (
            <div className={`mt-3 rounded-xl p-3 text-sm ${result.correct ? "bg-emerald-50 text-emerald-700" : "bg-red-50 text-red-700"}`}>
              <p className="font-semibold">{result.correct ? "✅ Bonne réponse !" : "❌ Raté !"}</p>
              {question.explanation && <p className="mt-1 text-xs opacity-80">{question.explanation}</p>}
              <a href="/quiz" className="mt-2 block text-xs font-medium underline opacity-70 hover:opacity-100">
                Voir le classement →
              </a>
            </div>
          )}
        </div>
      )}
    </>
  );
}
