import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { canManageFleet, requireMember } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Banner } from "@/components/Banner";
import { SubmitButton } from "@/components/ui";
import { envelopeToText, missingFields, stationsToText, type MbData } from "@/lib/mb";
import type { Aircraft } from "@/lib/types";
import { AircraftSwitcher } from "../AircraftSwitcher";
import { Calculator } from "./Calculator";
import { copyTypeData, saveMb } from "./actions";

export const metadata: Metadata = { title: "Masse et centrage" };

export default async function Page({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const me = await requireMember();
  const { id } = await params;
  const sp = await searchParams;
  const supabase = await createClient();
  const [{ data: a }, { data: fleet }, { data: mbRows }] = await Promise.all([
    supabase.from("aircraft").select("*").eq("id", id).maybeSingle(),
    supabase.from("aircraft").select("id, registration, model, type").eq("active", true).order("type").order("registration"),
    supabase.from("aircraft_mb").select("*"),
  ]);
  if (!a) notFound();
  const aircraft = a as Aircraft;
  const all = ((mbRows ?? []) as MbData[]).map((d) => ({
    ...d,
    empty_mass: d.empty_mass == null ? null : Number(d.empty_mass),
    empty_moment: d.empty_moment == null ? null : Number(d.empty_moment),
    mtow: d.mtow == null ? null : Number(d.mtow),
    mlw: d.mlw == null ? null : Number(d.mlw),
    mzfw: d.mzfw == null ? null : Number(d.mzfw),
    fuel_arm: d.fuel_arm == null ? null : Number(d.fuel_arm),
    fuel_density: Number(d.fuel_density ?? 0.72),
    fuel_capacity_l: d.fuel_capacity_l == null ? null : Number(d.fuel_capacity_l),
  }));
  const mb = all.find((d) => d.aircraft_id === id) ?? null;
  const missing = missingFields(mb);
  const manager = canManageFleet(me);
  const fleetList = ((fleet ?? []) as { id: string; registration: string; model: string; type: string }[]);
  if (!fleetList.some((f) => f.id === id)) fleetList.unshift({ id, registration: aircraft.registration, model: aircraft.model, type: aircraft.type });
  const copySources = fleetList.filter((f) => f.id !== id && all.some((d) => d.aircraft_id === f.id && d.envelope.length >= 3));
  const sameType = copySources.filter((f) => f.type === aircraft.type);

  return (
    <>
      <Banner ok={sp.ok} erreur={sp.erreur} />
      <AircraftSwitcher
        current={id}
        fleet={fleetList}
        tab="centrage"
        info={`${aircraft.model}${mb?.serial ? ` · S/N ${mb.serial}` : ""}`}
      />

      <div className="mb-4 hidden print:block">
        <h1 className="text-xl font-bold">
          Masse et centrage — {aircraft.registration} ({aircraft.model})
        </h1>
        <p className="text-xs">Imprimé le {new Date().toLocaleString("fr-FR", { timeZone: "Europe/Paris" })}</p>
      </div>

      {missing.length === 0 && mb ? (
        <Calculator data={mb} title={aircraft.registration} />
      ) : (
        <div className="card p-6">
          <p className="font-bold text-navy-2">Calcul pas encore disponible pour {aircraft.registration}</p>
          <p className="mt-1 text-sm text-muted">Données manquantes : {missing.join(", ")}.</p>
          <p className="mt-1 text-sm text-muted">
            {manager
              ? "Complétez-les ci-dessous à partir du manuel de vol et de la dernière fiche de pesée."
              : "Un administrateur ou le responsable maintenance doit les renseigner à partir du manuel de vol et de la fiche de pesée."}
          </p>
        </div>
      )}

      <p className="mt-4 text-xs text-muted print:mt-2">
        ⚠️ Outil d&apos;aide : le commandant de bord reste seul responsable du calcul de masse et centrage, à vérifier avec le manuel
        de vol et la fiche de pesée en vigueur.
        {mb?.source ? ` Source : ${mb.source}.` : ""}
        {mb ? ` Mis à jour le ${new Date(mb.updated_at).toLocaleDateString("fr-FR")}.` : ""}
      </p>

      {manager && (
        <details id="donnees" className="card mt-6 p-5 print:hidden" open={missing.length > 0}>
          <summary className="cursor-pointer font-bold text-navy-2">
            Données de masse et centrage de {aircraft.registration} (administrateurs et resp. maintenance)
          </summary>

          {copySources.length > 0 && (
            <form action={copyTypeData.bind(null, id)} className="mt-4 flex flex-wrap items-end gap-2 rounded-lg bg-paper p-3">
              <label className="block">
                <span className="label">Reprendre les données d&apos;un avion du même type</span>
                <select name="from" className="field w-auto" defaultValue={sameType[0]?.id ?? ""}>
                  <option value="">Choisir…</option>
                  {copySources.map((f) => (
                    <option key={f.id} value={f.id}>
                      {f.registration} — {f.model}
                    </option>
                  ))}
                </select>
              </label>
              <SubmitButton className="btn-secondary" pending="…" confirm="Remplacer les postes, le domaine, le carburant et la MTOW par ceux de cet avion ?">
                Copier
              </SubmitButton>
              <span className="text-xs text-muted">Postes, domaine, carburant et MTOW ; la masse et le moment à vide restent ceux de cet avion.</span>
            </form>
          )}

          <form action={saveMb.bind(null, id)} className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Field name="serial" label="N° de série" value={mb?.serial} />
            <Field name="empty_mass" label="Masse à vide (kg)" value={mb?.empty_mass} />
            <Field name="empty_moment" label="Moment à vide (kg.m)" value={mb?.empty_moment} />
            <Field name="mtow" label="Masse max décollage (kg)" value={mb?.mtow} />
            <Field name="mlw" label="Masse max atterrissage (kg, facultatif)" value={mb?.mlw} />
            <Field name="mzfw" label="Masse max sans carburant (kg, facultatif)" value={mb?.mzfw} />
            <Field name="fuel_arm" label="Bras du réservoir principal (m)" value={mb?.fuel_arm} />
            <Field name="fuel_capacity_l" label="Carburant utilisable, réservoir principal (L)" value={mb?.fuel_capacity_l} />
            <Field name="fuel_density" label="Densité carburant (kg/L)" value={mb?.fuel_density ?? 0.72} />
            <label className="block sm:col-span-2">
              <span className="label">
                Postes de chargement — une ligne : Libellé ; bras (m) ; max ; options. Options : « carburant » pour un réservoir
                supplémentaire saisi en litres (max = capacité en L), « aile » pour une charge dans l&apos;aile.
              </span>
              <textarea
                name="stations"
                className="field min-h-32 font-mono text-xs"
                defaultValue={mb ? stationsToText(mb.stations) : "Pilote ; 0.70 ; 115\nPassager ; 0.70 ; 115\nBagages ; 1.31 ; 18"}
              />
            </label>
            <label className="block sm:col-span-2">
              <span className="label">Domaine de centrage — une ligne par sommet : bras (m) ; masse (kg), dans l&apos;ordre du contour</span>
              <textarea
                name="envelope"
                className="field min-h-32 font-mono text-xs"
                defaultValue={mb ? envelopeToText(mb.envelope) : ""}
                placeholder={"0.420 ; 380\n0.420 ; 600\n0.525 ; 600\n0.525 ; 380"}
              />
            </label>
            <label className="block sm:col-span-2 lg:col-span-4">
              <span className="label">Source (manuel de vol, révision, date de la pesée)</span>
              <input name="source" className="field" defaultValue={mb?.source ?? ""} placeholder="Ex. Manuel de vol PS28 rév. 5 — pesée du 12/03/2025" />
            </label>
            <div className="sm:col-span-2 lg:col-span-4">
              <SubmitButton pending="Enregistrement…">Enregistrer</SubmitButton>
            </div>
          </form>
        </details>
      )}
    </>
  );
}

function Field({ name, label, value }: { name: string; label: string; value: string | number | null | undefined }) {
  return (
    <label className="block">
      <span className="label">{label}</span>
      <input name={name} inputMode="decimal" defaultValue={value ?? ""} className="field" />
    </label>
  );
}
