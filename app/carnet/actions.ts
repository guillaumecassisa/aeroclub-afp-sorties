"use server";

import { revalidatePath } from "next/cache";
import { requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { blockMinutes, parseDuration } from "@/lib/carnet";
import { dupKey, type ImportRow } from "@/lib/carnetImport";

export type CarnetState = { ok?: string; error?: string; savedId?: string } | undefined;

const str = (fd: FormData, k: string, max: number) => {
  const v = String(fd.get(k) ?? "").trim().slice(0, max);
  return v || null;
};
const int = (fd: FormData, k: string) => Math.max(0, Math.min(100000, Math.round(Number(String(fd.get(k) ?? "").replace(",", ".")) || 0)));
const time = (fd: FormData, k: string) => {
  const v = String(fd.get(k) ?? "").trim();
  return /^\d{1,2}:\d{2}$/.test(v) ? v : null;
};

/** Ajouter ou modifier une ligne du carnet (vol ou report d'heures antérieures) */
export async function saveEntry(_: CarnetState, fd: FormData): Promise<CarnetState> {
  await requireMember();
  const id = String(fd.get("id") ?? "") || null;
  const kind = String(fd.get("kind") ?? "") === "report" && id ? "report" : "vol"; // nouvelles lignes : toujours des vols (tout le carnet depuis le début)
  const date = String(fd.get("flight_date") ?? "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return { error: "Date invalide." };
  if (kind === "vol" && date > new Date(Date.now() + 86400000).toISOString().slice(0, 10)) return { error: "La date du vol est dans le futur." };

  const dur = (k: string, label: string) => {
    const m = parseDuration(String(fd.get(k) ?? ""));
    if (m == null) throw new Error(`${label} : durée illisible (format HH:MM, par exemple 1:35).`);
    return m;
  };
  try {
    const dep_time = time(fd, "dep_time");
    const arr_time = time(fd, "arr_time");
    let total = dur("total", "Durée totale");
    if (!total && kind === "vol") total = blockMinutes(dep_time, arr_time) ?? 0;
    if (kind === "vol" && !total && !parseDuration(String(fd.get("sim") ?? "")))
      return { error: "Indiquez la durée totale du vol, ou les heures de départ et d'arrivée." };

    const row: Record<string, unknown> = {
      kind,
      flight_date: date,
      dep_place: str(fd, "dep_place", 40)?.toUpperCase() ?? null,
      dep_time,
      arr_place: str(fd, "arr_place", 40)?.toUpperCase() ?? null,
      arr_time,
      aircraft_model: str(fd, "aircraft_model", 40),
      aircraft_reg: str(fd, "aircraft_reg", 20)?.toUpperCase() ?? null,
      total_min: total,
      pic_name: str(fd, "pic_name", 80),
      landings_day: int(fd, "landings_day"),
      landings_night: int(fd, "landings_night"),
      ifr_approaches: int(fd, "ifr_approaches"),
      night_min: Math.min(total, dur("night", "Temps de nuit")),
      ifr_min: Math.min(total, dur("ifr", "Temps IFR")),
      remarks: str(fd, "remarks", 500),
    };

    if (kind === "report") {
      // Report : chaque cumul est saisi tel quel
      Object.assign(row, {
        pic_min: dur("pic", "Temps CDB"),
        dual_min: dur("dual", "Temps en double commande"),
        instructor_min: dur("instructor", "Temps instructeur"),
        copilot_min: dur("copilot", "Temps copilote"),
        se_min: fd.get("multi") === "on" ? 0 : total,
        me_min: fd.get("multi") === "on" ? total : 0,
        multi_pilot_min: 0,
        night_min: dur("night", "Temps de nuit"),
        ifr_min: dur("ifr", "Temps IFR"),
      });
    } else {
      // Vol : chaque colonne du carnet est saisie comme sur le carnet papier
      const sim_date = String(fd.get("sim_date") ?? "");
      Object.assign(row, {
        se_min: dur("se", "SE"),
        me_min: dur("me", "ME"),
        multi_pilot_min: dur("multi_pilot", "Multi-pilote"),
        pic_min: dur("pic", "CDB"),
        copilot_min: dur("copilot", "COPI"),
        dual_min: dur("dual", "DC"),
        instructor_min: dur("instructor", "INST"),
        night_min: dur("night", "Nuit"),
        ifr_min: dur("ifr", "IFR"),
        sim_date: /^\d{4}-\d{2}-\d{2}$/.test(sim_date) ? sim_date : null,
        sim_type: str(fd, "sim_type", 40),
        sim_min: dur("sim", "Durée simulateur"),
      });
    }

    const supabase = await createClient();
    const q = id
      ? supabase.from("logbook_entries").update({ ...row, updated_at: new Date().toISOString() }).eq("id", id).select("id").single()
      : supabase.from("logbook_entries").insert(row).select("id").single();
    const { data, error } = await q;
    if (error) return { error: "Enregistrement impossible : " + error.message };
    revalidatePath("/carnet");
    return { ok: id ? "Ligne modifiée." : kind === "report" ? "Heures antérieures ajoutées." : "Vol ajouté au carnet.", savedId: data.id };
  } catch (e) {
    return { error: (e as Error).message };
  }
}

export async function deleteEntry(id: string): Promise<CarnetState> {
  await requireMember();
  const supabase = await createClient();
  const { error } = await supabase.from("logbook_entries").delete().eq("id", id);
  if (error) return { error: "Suppression impossible : " + error.message };
  revalidatePath("/carnet");
  return { ok: "Ligne supprimée." };
}

/** Licence du pilote : type, numéro, délivrance, qualification de nuit, échéance SEP (PPL) */
export async function saveLicence(_: CarnetState, fd: FormData): Promise<CarnetState> {
  const me = await requireMember();
  const date = (k: string) => {
    const v = String(fd.get(k) ?? "");
    return /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null;
  };
  const type = fd.get("licence_type") === "LAPL" ? "LAPL" : "PPL";
  const supabase = await createClient();
  const { error } = await supabase.from("logbook_settings").upsert(
    {
      user_id: me.id,
      licence_type: type,
      licence_number: str(fd, "licence_number", 40)?.toUpperCase() ?? null,
      licence_issued: date("licence_issued"),
      night_rating: fd.get("night_rating") === "on",
      sep_expiry: type === "PPL" ? date("sep_expiry") : null,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "user_id" },
  );
  if (error) return { error: "Enregistrement impossible : " + error.message };
  revalidatePath("/carnet");
  return { ok: "Licence enregistrée." };
}

/** Import en lot (CSV Aerogest ou tableur) : lignes déjà converties côté navigateur, revalidées ici, doublons ignorés */
export async function importEntries(json: string): Promise<CarnetState & { inserted?: number; skipped?: number }> {
  await requireMember();
  let input: ImportRow[];
  try {
    input = JSON.parse(json);
  } catch {
    return { error: "Données d'import illisibles." };
  }
  if (!Array.isArray(input) || !input.length) return { error: "Aucun vol à importer." };
  if (input.length > 5000) return { error: "5 000 vols maximum par import." };

  const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
  const s = (v: unknown, n: number) => (typeof v === "string" && v.trim() ? v.trim().slice(0, n) : null);
  const n = (v: unknown, max = 600000) => Math.max(0, Math.min(max, Math.round(Number(v) || 0)));
  const t = (v: unknown) => (typeof v === "string" && /^\d{2}:\d{2}$/.test(v) ? v : null);

  const supabase = await createClient();
  const { data: existing } = await supabase.from("logbook_entries").select("flight_date, aircraft_reg, dep_time, total_min");
  const seen = new Set((existing ?? []).map((e) => dupKey(e as Parameters<typeof dupKey>[0])));

  const rows: Record<string, unknown>[] = [];
  let skipped = 0;
  for (const r of input) {
    if (typeof r?.flight_date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(r.flight_date) || r.flight_date > tomorrow) {
      skipped++;
      continue;
    }
    const total = n(r.total_min);
    if (!total) {
      skipped++;
      continue;
    }
    const row = {
      kind: "vol",
      flight_date: r.flight_date,
      dep_place: s(r.dep_place, 40)?.toUpperCase() ?? null,
      dep_time: t(r.dep_time),
      arr_place: s(r.arr_place, 40)?.toUpperCase() ?? null,
      arr_time: t(r.arr_time),
      aircraft_model: s(r.aircraft_model, 40),
      aircraft_reg: s(r.aircraft_reg, 20)?.toUpperCase() ?? null,
      se_min: total,
      total_min: total,
      pic_name: s(r.pic_name, 80),
      landings_day: n(r.landings_day, 999),
      landings_night: n(r.landings_night, 999),
      night_min: Math.min(total, n(r.night_min)),
      ifr_min: Math.min(total, n(r.ifr_min)),
      pic_min: Math.min(total, n(r.pic_min)),
      dual_min: Math.min(total, n(r.dual_min)),
      instructor_min: Math.min(total, n(r.instructor_min)),
      remarks: s(r.remarks, 500),
    };
    const key = dupKey(row);
    if (seen.has(key)) {
      skipped++;
      continue;
    }
    seen.add(key);
    rows.push(row);
  }

  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await supabase.from("logbook_entries").insert(rows.slice(i, i + 500));
    if (error) return { error: `Import interrompu après ${i} vols : ${error.message}`, inserted: i, skipped };
  }
  revalidatePath("/carnet");
  return { ok: `${rows.length} vol${rows.length > 1 ? "s" : ""} importé${rows.length > 1 ? "s" : ""}.`, inserted: rows.length, skipped };
}
