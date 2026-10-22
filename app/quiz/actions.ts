"use server";

import { createClient } from "@/lib/supabase/server";
import { requireMember } from "@/lib/auth";

export async function submitQuizAnswer(
  questionId: number,
  answer: string
): Promise<{ correct: boolean }> {
  const profile = await requireMember();
  const supabase = await createClient();

  const { data: q } = await supabase
    .from("quiz_questions")
    .select("correct")
    .eq("id", questionId)
    .single();

  if (!q) throw new Error("Question introuvable");

  const isCorrect = q.correct === answer;
  const today = new Date().toISOString().slice(0, 10);

  await supabase.from("quiz_answers").upsert(
    {
      user_id: profile.id,
      question_id: questionId,
      answered_on: today,
      is_correct: isCorrect,
    },
    { onConflict: "user_id,answered_on", ignoreDuplicates: true }
  );

  return { correct: isCorrect };
}
