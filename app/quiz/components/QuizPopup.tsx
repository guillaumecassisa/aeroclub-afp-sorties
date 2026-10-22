"use client";

import { useState, useEffect, useTransition } from "react";

type Question = {
  id: number;
  question: string;
  option_a: string;
  option_b: string;
  option_c: string;
  option_d: string;
  correct: string;
  explanation: string | null;
  category: string;
};

type Props = {
  question: Question;
  alreadyAnswered: boolean;
  submitAnswer: (questionId: number, answer: string) => Promise<{ correct: boolean }>;
};

const OPTIONS = ["a", "b", "c", "d"] as const;
const OPTION_LABELS = { a: "A", b: "B", c: "C", d: "D" };
const OPTION_KEYS = { a: "option_a", b: "option_b", c: "option_c", d: "option_d" } as const;

const CATEGORY_LABELS: Record<string, string> = {
  meteo: "☁️ Météo", reglementation: "📋 Réglementation", navigation: "🗺️ Navigation",
  mecanique: "✈️ Mécanique du vol", moteur: "🔧 Moteur", lfma: "🛬 LFMA",
  instruments: "🎛️ Instruments", radio: "📻 Radio", documents: "📄 Documents",
  aerodynamique: "🌊 Aérodynamique", performances: "📊 Performances", culture: "🌍 Culture aviation",
  flotte: "🛩️ Flotte AFP", securite: "🛡️ Sécurité", sol: "⛽ Procédures sol", general: "✈️ Aviation",
};

export function QuizPopup({ question, alreadyAnswered, submitAnswer }: Props) {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [result, setResult] = useState<{ correct: boolean } | null>(null);
  const [isPending, startTransition] = useTransition();
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    if (alreadyAnswered) return;
    const key = `quiz_dismissed_${new Date().toISOString().slice(0, 10)}`;
    if (localStorage.getItem(key)) return;
    const t = setTimeout(() => setOpen(true), 1500);
    return () => clearTimeout(t);
  }, [alreadyAnswered]);

  function dismiss() {
    const key = `quiz_dismissed_${new Date().toISOString().slice(0, 10)}`;
    localStorage.setItem(key, "1");
    setOpen(false);
    setDismissed(true);
  }

  function handleSelect(opt: string) {
    if (result || isPending) return;
    setSelected(opt);
    startTransition(async () => {
      const res = await submitAnswer(question.id, opt);
      setResult(res);
    });
  }

  if (alreadyAnswered || dismissed) return null;
  if (!open) {
    return (
      <button
        onClick={() => setOpen(true)}
        className="fixed bottom-4 right-4 z-40 flex items-center gap-2 rounded-full bg-navy-2 px-4 py-2.5 text-sm font-semibold text-white shadow-lg hover:bg-navy-2/90 transition-all"
      >
        <span>✈️</span>
        <span>Question du jour</span>
        <span className="h-2 w-2 rounded-full bg-emerald-400 animate-pulse" />
      </button>
    );
  }

  const catLabel = CATEGORY_LABELS[question.category] ?? "✈️ Aviation";

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-end p-4 sm:items-start sm:justify-end sm:pt-20 pointer-events-none">
      <div className="pointer-events-auto w-full max-w-md rounded-2xl bg-white shadow-2xl ring-1 ring-black/5" role="dialog">
        <div className="flex items-center justify-between gap-3 border-b border-line px-4 py-3">
          <div className="flex items-center gap-2">
            <span className="text-lg">✈️</span>
            <div>
              <div className="text-xs font-semibold tracking-wide text-muted uppercase">Question du jour</div>
              <div className="text-xs text-muted">{catLabel}</div>
            </div>
          </div>
          <button onClick={dismiss} className="rounded-full p-1.5 text-muted hover:bg-sky-soft hover:text-navy-2 transition-colors" aria-label="Fermer">
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="px-4 pt-4 pb-2">
          <p className="text-sm font-semibold leading-snug text-ink">{question.question}</p>
        </div>

        <div className="space-y-2 px-4 pb-4">
          {OPTIONS.map((opt) => {
            const text = question[OPTION_KEYS[opt]];
            const isSelected = selected === opt;
            const isCorrect = opt === question.correct;
            const showResult = result !== null;
            let cls = "w-full flex items-start gap-2.5 rounded-xl border px-3 py-2.5 text-left text-sm transition-all ";
            if (!showResult) {
              cls += isSelected ? "border-sky bg-sky/10 text-sky font-medium" : "border-line hover:border-sky/50 hover:bg-sky-soft cursor-pointer";
            } else {
              if (isCorrect) cls += "border-emerald-400 bg-emerald-50 text-emerald-700 font-medium";
              else if (isSelected && !isCorrect) cls += "border-red-300 bg-red-50 text-red-600";
              else cls += "border-line text-muted";
            }
            return (
              <button key={opt} className={cls} onClick={() => handleSelect(opt)} disabled={showResult || isPending}>
                <span className="mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-current text-xs font-bold">
                  {OPTION_LABELS[opt]}
                </span>
                <span className="flex-1 leading-snug">{text}</span>
                {showResult && isCorrect && <span className="shrink-0 text-emerald-500">✓</span>}
                {showResult && isSelected && !isCorrect && <span className="shrink-0 text-red-400">✗</span>}
              </button>
            );
          })}
        </div>

        {result && (
          <div className="border-t border-line px-4 py-3">
            <div className={`mb-2 flex items-center gap-2 text-sm font-semibold ${result.correct ? "text-emerald-600" : "text-red-500"}`}>
              {result.correct ? "🎉 Bonne réponse !" : "❌ Pas tout à fait…"}
            </div>
            {question.explanation && <p className="text-xs leading-relaxed text-muted">{question.explanation}</p>}
            <div className="mt-3 flex items-center gap-2">
              <a href="/quiz" className="text-xs font-semibold text-sky hover:underline">Voir le classement →</a>
              <button onClick={() => setOpen(false)} className="ml-auto text-xs text-muted hover:text-navy-2">Fermer</button>
            </div>
          </div>
        )}

        {isPending && <div className="border-t border-line px-4 py-3 text-center text-xs text-muted">Enregistrement…</div>}
      </div>
    </div>
  );
}
