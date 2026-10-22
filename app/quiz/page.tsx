import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Avatar } from "@/components/Avatar";

export const dynamic = "force-dynamic";
export const metadata = { title: "Question du jour — Classement" };

type LeaderRow = {
  user_id: string;
  full_name: string | null;
  avatar_url: string | null;
  total: number;
  correct: number;
};

const MEDALS = ["🥇", "🥈", "🥉"];
const CATEGORY_LABELS: Record<string, string> = {
  meteo: "☁️ Météo", reglementation: "📋 Réglementation", navigation: "🗺️ Navigation",
  mecanique: "✈️ Mécanique", moteur: "🔧 Moteur", lfma: "🛬 LFMA",
  instruments: "🎛️ Instruments", radio: "📻 Radio", documents: "📄 Documents",
  aerodynamique: "🌊 Aérodynamique", performances: "📊 Performances", culture: "🌍 Culture",
  flotte: "🛩️ Flotte", securite: "🛡️ Sécurité", sol: "⛽ Sol", general: "✈️ Général",
};

export default async function QuizPage() {
  const profile = await requireMember();
  const supabase = await createClient();

  const { data: leaderRaw } = await supabase
    .from("quiz_answers")
    .select("user_id, is_correct, profiles(full_name, avatar_url)")
    .order("answered_on", { ascending: false });

  const byUser = new Map<string, LeaderRow>();
  for (const row of leaderRaw ?? []) {
    const uid = row.user_id;
    if (!byUser.has(uid)) {
      const p = (row as { profiles?: { full_name: string | null; avatar_url: string | null } | null }).profiles;
      byUser.set(uid, { user_id: uid, full_name: p?.full_name ?? null, avatar_url: p?.avatar_url ?? null, total: 0, correct: 0 });
    }
    const entry = byUser.get(uid)!;
    entry.total++;
    if (row.is_correct) entry.correct++;
  }

  const leaderboard = Array.from(byUser.values())
    .sort((a, b) => b.correct - a.correct || b.total - a.total)
    .slice(0, 50);

  const { data: myAnswers } = await supabase
    .from("quiz_answers")
    .select("answered_on, is_correct, question_id, quiz_questions(question, category, correct)")
    .eq("user_id", profile.id)
    .order("answered_on", { ascending: false })
    .limit(30);

  const myTotal = myAnswers?.length ?? 0;
  const myCorrect = myAnswers?.filter((a) => a.is_correct).length ?? 0;
  const myRank = leaderboard.findIndex((r) => r.user_id === profile.id) + 1;

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold text-navy-2">✈️ Question du jour</h1>
        <p className="mt-1 text-sm text-muted">Chaque jour, une nouvelle question de culture aéronautique. Le classement est mis à jour en temps réel.</p>
      </div>

      {myTotal > 0 && (
        <div className="rounded-2xl bg-sky-soft border border-sky/20 p-4 flex flex-wrap items-center gap-6">
          <div className="text-center">
            <div className="text-3xl font-bold text-navy-2">{myCorrect}</div>
            <div className="text-xs text-muted mt-0.5">Bonnes réponses</div>
          </div>
          <div className="text-center">
            <div
