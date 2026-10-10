import { type EmailOtpType } from "@supabase/supabase-js";
import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Lien reçu par email (confirmation d'inscription ou réinitialisation du mot de passe).
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const token_hash = searchParams.get("token_hash");
  const type = searchParams.get("type") as EmailOtpType | null;
  const code = searchParams.get("code");
  const nextParam = searchParams.get("next") ?? "/";
  const next = nextParam.startsWith("/") && !nextParam.startsWith("//") ? nextParam : "/";

  const supabase = await createClient();
  let ok = false;
  if (token_hash && type) {
    ok = !(await supabase.auth.verifyOtp({ type, token_hash })).error;
  } else if (code) {
    ok = !(await supabase.auth.exchangeCodeForSession(code)).error;
  }

  if (ok) {
    const dest = type === "recovery" ? "/compte/mot-de-passe" : next;
    return NextResponse.redirect(`${origin}${dest}`);
  }
  return NextResponse.redirect(
    `${origin}/connexion?erreur=${encodeURIComponent("Lien invalide ou expiré. Réessayez.")}`,
  );
}
