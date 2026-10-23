// Télécharge tous les fichiers du stockage Supabase (tous les espaces) dans un dossier.
// Usage : SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/sauvegarde-fichiers.mjs <dossier>
import { createClient } from "@supabase/supabase-js";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

const out = process.argv[2] || "fichiers";
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error("SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont nécessaires.");
  process.exit(1);
}
const supabase = createClient(url, key, { auth: { persistSession: false } });

async function walk(bucket, prefix = "") {
  const files = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await supabase.storage.from(bucket).list(prefix, { limit: 1000, offset });
    if (error) throw new Error(`${bucket}/${prefix} : ${error.message}`);
    for (const item of data) {
      const path = prefix ? `${prefix}/${item.name}` : item.name;
      if (item.id === null) files.push(...(await walk(bucket, path))); // dossier
      else files.push(path);
    }
    if (data.length < 1000) break;
  }
  return files;
}

const { data: buckets, error } = await supabase.storage.listBuckets();
if (error) throw error;
let total = 0;
for (const b of buckets) {
  const files = await walk(b.id);
  for (const f of files) {
    const { data, error: e } = await supabase.storage.from(b.id).download(f);
    if (e) {
      console.error(`Échec ${b.id}/${f} : ${e.message}`);
      process.exitCode = 1;
      continue;
    }
    const dest = join(out, b.id, f);
    await mkdir(dirname(dest), { recursive: true });
    await writeFile(dest, Buffer.from(await data.arrayBuffer()));
    total++;
  }
  console.log(`${b.id} : ${files.length} fichier(s)`);
}
console.log(`Total : ${total} fichier(s) sauvegardé(s) dans ${out}`);
