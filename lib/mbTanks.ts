/**
 * Réservoirs d'aile gauche et droite (même règle que supabase/migration-48-reservoirs-ailes.sql) :
 *   PS28, B23, DA40 : la contenance totale devient « aile gauche » + « aile droite »
 *   DR400 : le poste « réservoirs d'aile » est scindé en gauche + droite, le réservoir principal reste
 * Utilisé par le bouton de mise à jour de la page Flotte (si l'éditeur SQL n'est pas disponible).
 */
import type { MbData, Station } from "@/lib/mb";

type Row = Pick<MbData, "stations" | "fuel_capacity_l" | "fuel_arm">;
export type TankChange = { stations: Station[]; fuel_capacity_l: number | null; fuel_arm: number | null };

const tanks = (arm: number, max: number): Station[] => [
  { label: "Réservoir aile gauche", arm, max, fuel: true, wing: true },
  { label: "Réservoir aile droite", arm, max, fuel: true, wing: true },
];

export function wingTankChange(type: string, d: Row): TankChange | null {
  const st = d.stations ?? [];
  if (st.some((s) => s.fuel && /aile gauche/i.test(s.label))) return null; // déjà converti (réservoir, pas casier)
  const t = type.toUpperCase();
  if (t === "PS28" || t === "B23" || t === "DA40") {
    const fuelSt = st.filter((s) => s.fuel);
    const total = (d.fuel_capacity_l && d.fuel_capacity_l > 0 ? d.fuel_capacity_l : null) ?? (fuelSt.length ? Math.max(...fuelSt.map((s) => s.max ?? 0)) : null);
    const arm = fuelSt[0]?.arm ?? d.fuel_arm;
    if (!total || arm == null) return null;
    return { stations: [...st.filter((s) => !s.fuel), ...tanks(Number(arm), total / 2)], fuel_capacity_l: null, fuel_arm: Number(arm) };
  }
  if (t === "DR400") {
    const wing = st.find((s) => s.fuel && s.wing);
    if (!wing || wing.max == null) return null;
    return {
      stations: [...st.filter((s) => s !== wing), ...tanks(wing.arm, wing.max / 2)],
      fuel_capacity_l: d.fuel_capacity_l,
      fuel_arm: d.fuel_arm,
    };
  }
  return null;
}
