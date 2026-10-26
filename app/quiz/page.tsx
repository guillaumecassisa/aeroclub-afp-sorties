import { redirect } from "next/navigation";

// Les résultats personnels du quiz sont dans « Mon compte »
export default function QuizPage() {
  redirect("/compte#quiz");
}
