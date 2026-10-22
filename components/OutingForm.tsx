"use client";

import Link from "next/link";
import { useActionState, useMemo, useState } from "react";
import { saveOuting } from "@/app/sorties/actions";
import { FormMessage, SubmitButton, keepValues } from "@/components/ui";
import type { Aircraft, OutingKind } from "@/lib/types";

export type OutingFormValues = {
  id?: string;
  kind?: OutingKind;
  title: string;
  destination: string;
  meeting_point: string;
  description: string;
  departure_at: string; // datetime-local, heure de Paris
  return_at: string;
  registration_deadline: string;
  aircraft: string[];
  instructor_aircraft: string | null;
  max_participants?: number | null;
  registered_count?: number;
};

const KINDS: { kind: OutingKind; label: string; hint: string; icon: string }[] = [
  { kind: "vol", label: "Sortie avion", hint: "Navigation, sortie club : on attribue des avions", icon: "✈️" },
  { kind: "activite", label: "Activité", hint: "Sans avion : moto, randonnée, visite…", icon: "🏍️" },
  { kind: "evenement", label: "Événement convivial", hint: "Apéro, barbecue, dîner, soirée…", icon: "🥂" },
  { kind: "formation", label: "Formation", hint: "Briefing, soirée théorique, révision, sécurité…", icon: "🎓" },
];

export function OutingForm({
  fleet,
  initial,
  submitLabel,
}: {
  fleet: Aircraft[];
  initial: OutingFormValues;
  submitLabel?: string;
}) {
  const [state, action, busy] = useActionState(saveOuting, undefined);
  const [kind, setKind] = useState<OutingKind>(initial.kind ?? "vol");
  const [selected, setSelected] = useState<string[]>(initial.aircraft);
  const [flies, setFlies] = useState(!!initial.instructor_aircraft);
  const [myAircraft, setMyAircraft] = useState<string>(initial.instructor_aircraft ?? "");

  const isFlight = kind === "vol";
  const byId = useMemo(() => new Map(fleet.map((a) => [a.id, a])), [fleet]);
  const chosen = fleet.filter((a) => selected.includes(a.id));
  const effectiveMine = flies && selected.includes(myAircraft) ? myAircraft : flies ? chosen[0]?.id ?? "" : "";
  const capacity = chosen.reduce((s, a) => s + a.seats - (a.id === effectiveMine ? 1 : 0), 0);

  const toggle = (id: string) =>
    setSelected((cur) => (cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id]));

  return (
    <form onSubmit={keepValues(action)} className="space-y-6">
      {initial.id && <input type="hidden" name="id" value={initial.id} />}
      <input type="hidden" name="kind" value={kind} />

      <fieldset className="card p-5">
        <legend className="sr-only">Type</legend>
        <h2 className="mb-3 font-bold text-navy-2">Type d&apos;événement</h2>
        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
          {KINDS.map((k) => (
            <button
              key={k.kind}
              type="button"
              onClick={() => setKind(k.kind)}
              aria-pressed={kind === k.kind}
              className={`rounded-lg border px-4 py-3 text-left transition-colors ${
                kind === k.kind ? "border-navy-2 bg-sky-soft ring-1 ring-navy-2" : "border-line bg-white hover:bg-paper"
              }`}
            >
              <span className="text-xl" aria-hidden>
                {k.icon}
              </span>
              <span className="mt-1 block font-semibold text-navy-2">{k.label}</span>
              <span className="block text-xs text-muted">{k.hint}</span>
            </button>
          ))}
        </div>
      </fieldset>

      <fieldset className="card space-y-4 p-5">
        <legend className="sr-only">Informations</legend>
        <div>
          <label className="label" htmlFor="title">Titre *</label>
          <input
            className="field"
            id="title"
            name="title"
            defaultValue={initial.title}
            required
            placeholder={isFlight ? "Ex. Déjeuner à Calvi" : kind === "activite" ? "Ex. Balade moto dans le Luberon" : "Ex. Barbapéro du vendredi"}
          />
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label className="label" htmlFor="destination">{isFlight ? "Destination" : "Lieu"}</label>
            <input
              className="field"
              id="destination"
              name="destination"
              defaultValue={initial.destination}
              placeholder={isFlight ? "Ex. LFKC Calvi" : "Ex. Club-house"}
            />
          </div>
          <div>
            <label className="label" htmlFor="meeting_point">Lieu de rendez-vous</label>
            <input className="field" id="meeting_point" name="meeting_point" defaultValue={initial.meeting_point} placeholder="Ex. Club-house, 8h30" />
          </div>
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <div>
            <label className="label" htmlFor="departure_at">{isFlight ? "Départ *" : "Début *"}</label>
            <input
              className="field"
              id="departure_at"
              name="departure_at"
              type="datetime-local"
              defaultValue={initial.departure_at}
              required
            />
          </div>
          <div>
            <label className="label" htmlFor="return_at">{isFlight ? "Retour prévu" : "Fin"}</label>
            <input className="field" id="return_at" name="return_at" type="datetime-local" defaultValue={initial.return_at} />
          </div>
          <div>
            <label className="label" htmlFor="registration_deadline">Inscriptions jusqu&apos;au</label>
            <input className="field" id="registration_deadline" name="registration_deadline" type="datetime-local" defaultValue={initial.registration_deadline} />
          </div>
        </div>
        <div>
          <label className="label" htmlFor="description">{isFlight ? "Programme / informations" : "Description"}</label>
          <textarea
            className="field min-h-28"
            id="description"
            name="description"
            defaultValue={initial.description}
            placeholder={isFlight ? "Itinéraire, repas, participation aux frais, météo de repli…" : "Programme, ce qu'il faut apporter, participation…"}
          />
        </div>

      </fieldset>

      {isFlight ? (
        <fieldset className="card p-5">
          <legend className="sr-only">Avions</legend>
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <h2 className="font-bold text-navy-2">Avions attribués *</h2>
            <p className="text-sm">
              <span className="font-bold text-navy-2">{capacity}</span> place{capacity > 1 ? "s" : ""} ouverte{capacity > 1 ? "s" : ""} aux membres
            </p>
          </div>
          {fleet.length === 0 ? (
            <p className="mt-3 text-sm text-muted">
              Aucun avion dans la flotte. <Link href="/maintenance" className="text-sky underline">Ajoutez-en un</Link> d&apos;abord.
            </p>
          ) : (
            <div className="mt-3 grid gap-2 sm:grid-cols-2">
              {fleet.map((a) => {
                const on = selected.includes(a.id);
                return (
                  <label
                    key={a.id}
                    className={`flex cursor-pointer items-center gap-3 rounded-lg border px-3 py-2.5 ${
                      on ? "border-sky bg-sky-soft" : "border-line bg-white hover:bg-paper"
                    }`}
                  >
                    <input type="checkbox" name="aircraft" value={a.id} checked={on} onChange={() => toggle(a.id)} className="h-4 w-4 accent-sky" />
                    <span className="font-mono font-bold text-navy-2">{a.registration}</span>
                    <span className="text-sm text-muted">{a.model}</span>
                    <span className={`pill ml-auto ${a.seats === 4 ? "bg-navy-2 text-white" : "bg-line text-ink"}`}>{a.seats} places</span>
                    {!a.active && <span className="pill bg-wait-soft text-wait">inactif</span>}
                    {a.active && a.available === false && <span className="pill bg-danger-soft text-danger">indispo</span>}
                  </label>
                );
              })}
            </div>
          )}

          <div className="mt-5 rounded-lg bg-paper p-4">
            <label className="flex cursor-pointer items-start gap-3">
              <input type="checkbox" name="instructor_flies" checked={flies} onChange={(e) => setFlies(e.target.checked)} className="mt-0.5 h-4 w-4 accent-sky" />
              <span>
                <span className="block text-sm font-semibold text-ink">L&apos;organisateur vole et occupe un siège</span>
                <span className="block text-xs text-muted">Ce siège est retiré des places proposées aux membres.</span>
              </span>
            </label>
            {flies && (
              <div className="mt-3 sm:max-w-xs">
                <label className="label" htmlFor="instructor_aircraft">Dans quel avion ?</label>
                <select
                  id="instructor_aircraft"
                  name="instructor_aircraft"
                  className="field"
                  value={effectiveMine}
                  onChange={(e) => setMyAircraft(e.target.value)}
                >
                  {chosen.length === 0 && <option value="">Sélectionnez d&apos;abord un avion</option>}
                  {chosen.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.registration} ({byId.get(a.id)?.model})
                    </option>
                  ))}
                </select>
              </div>
            )}
          </div>

          {!!initial.registered_count && initial.registered_count > capacity && (
            <p className="mt-4 rounded-lg bg-wait-soft px-3 py-2 text-sm text-wait">
              Attention : {initial.registered_count} participants confirmés pour {capacity} places. Les derniers inscrits
              repasseront en liste d&apos;attente et seront prévenus par email.
            </p>
          )}
        </fieldset>
      ) : (
        <fieldset className="card p-5">
          <legend className="sr-only">Participants</legend>
          <h2 className="font-bold text-navy-2">Participants</h2>
          <div className="mt-3 sm:max-w-xs">
            <label className="label" htmlFor="max_participants">Nombre de places</label>
            <input
              className="field"
              id="max_participants"
              name="max_participants"
              type="number"
              min={1}
              defaultValue={initial.max_participants ?? ""}
              placeholder="Illimité"
            />
            <p className="mt-1 text-xs text-muted">
              Laissez vide si le nombre n&apos;est pas limité. Sinon, les inscrits au-delà passent en liste d&apos;attente.
            </p>
          </div>
        </fieldset>
      )}

      <FormMessage state={state} />
      <div className="flex flex-wrap gap-2">
        <SubmitButton busy={busy} pending="Enregistrement…">
          {submitLabel ?? (initial.id ? "Enregistrer les modifications" : "Créer l'événement")}
        </SubmitButton>
        <Link href={initial.id ? `/sorties/${initial.id}` : "/sorties"} className="btn-secondary">
          Annuler
        </Link>
      </div>
    </form>
  );
}
