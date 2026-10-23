// Renvoie dans le stockage Supabase les fichiers d'une sauvegarde (dossier <espace>/<chemin>).
// Usage : SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/restauration-fichiers.mjs <dossier>
import { createClient } from "@supabase/supabase-js";
import { readdir, readFile } from "node:fs/promises";
import { join, relative, sep } from "node:path";

const dir = process.argv[2] || "fichiers";
const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

async function* files(d) {
  for (const e of await readdir(d, { withFileTypes: true })) {
    const p = join(d, e.name);
    if (e.isDirectory()) yield* files(p);
    else yield p;
  }
}

let n = 0;
for await (const f of files(dir)) {
  const [bucket, ...rest] = relative(dir, f).split(sep);
  const path = rest.join("/");
  const { error } = await supabase.storage.from(bucket).upload(path, await readFile(f), { upsert: true });
  if (error) console.error(`Échec ${bucket}/${path} : ${error.message}`);
  else n++;
}
console.log(`${n} fichier(s) restauré(s).`);
