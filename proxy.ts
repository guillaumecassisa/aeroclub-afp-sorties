import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

const PUBLIC_PATHS = ["/connexion", "/inscription", "/mot-de-passe-oublie", "/auth", "/mentions-legales", "/confidentialite"];

const SETUP_PAGE = `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Mise en service</title></head>
<body style="margin:0;font-family:Helvetica Neue,Arial,sans-serif;background:#f4f5f7;color:#14213d">
<div style="height:3px;background:linear-gradient(90deg,#002157 0 72%,#e4002b 72.6% 100%)"></div>
<div style="max-width:440px;margin:64px auto;background:#fff;border:1px solid #dfe3ea;border-radius:8px;padding:32px;text-align:center">
<img src="/logo.png" alt="" width="112" height="112"><h1 style="color:#002157;font-size:22px">Site en cours de mise en service</h1>
<p style="color:#5f6b7d;line-height:1.5">La base de données du club n'est pas encore branchée. Revenez très bientôt.</p></div></body></html>`;

export async function proxy(request: NextRequest) {
  // Tant que Supabase n'est pas configuré, on affiche une page d'attente propre
  if (
    !process.env.NEXT_PUBLIC_SUPABASE_URL ||
    !(process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY)
  ) {
    return new NextResponse(SETUP_PAGE, { status: 503, headers: { "content-type": "text/html; charset=utf-8" } });
  }

  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        },
      },
    },
  );

  // Rafraîchit la session si nécessaire (ne rien mettre entre createServerClient et cet appel)
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const path = request.nextUrl.pathname;
  const isPublic = PUBLIC_PATHS.some((p) => path === p || path.startsWith(p + "/"));

  if (!user && !isPublic) {
    const url = request.nextUrl.clone();
    url.pathname = "/connexion";
    url.search = path !== "/" ? `?next=${encodeURIComponent(path)}` : "";
    return NextResponse.redirect(url);
  }

  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|icon.svg|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)"],
};
