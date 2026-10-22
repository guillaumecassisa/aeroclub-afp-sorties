"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { requireMember } from "@/lib/auth";

export type QuizResult = { correct: boolean; answer: string; explanation: string | null; error?: string };

/** Enregistre la réponse du jour : la base vérifie la question, la date (Paris) et l'unicité. */
export async function submitQuizAnswer(questionId: number, answer: string): Promise<QuizResult> {
  await requireMember();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("quiz_answer", { p_question: questionId, p_answer: answer });
  if (error) return { correct: false, answer: "", explanation: null, error: error.message };
  revalidatePath("/quiz");
  return data as QuizResult;
}
