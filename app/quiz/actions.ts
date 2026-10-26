"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { requireMember } from "@/lib/auth";

export type QuizResult = { correct: boolean; answer: string; explanation: string | null; error?: string };

/** Enregistre une réponse : la base vérifie que la question fait partie des questions du jour (Paris) et qu'elle n'a pas déjà été répondue. */
export async function submitQuizAnswer(questionId: number, answer: string): Promise<QuizResult> {
  await requireMember();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("quiz_answer", { p_question: questionId, p_answer: answer });
  if (error) return { correct: false, answer: "", explanation: null, error: error.message };
  revalidatePath("/compte");
  revalidatePath("/");
  return data as QuizResult;
}
