export type Role = "pending" | "member" | "instructor" | "admin";

export const ROLE_LABELS: Record<Role, string> = {
  pending: "En attente de validation",
  member: "Membre",
  instructor: "Instructeur",
  admin: "Administrateur",
};

export type Profile = {
  id: string;
  full_name: string;
  email: string;
  phone: string | null;
  role: Role;
  created_at: string;
  avatar_url: string | null;
  address: string | null;
  emergency_name: string | null;
  emergency_phone: string | null;
  is_treasurer?: boolean;
  is_secretary?: boolean;
  is_maintenance?: boolean;
  is_board?: boolean;
  is_chief_pilot?: boolean;
  is_compliance?: boolean;
  is_instructor?: boolean;
  notify_events?: boolean;
  show_phone?: boolean;
  deletion_requested_at?: string | null;
  anonymized_at?: string | null;
  show_in_bar_ranking?: boolean;
};

export type Aircraft = {
  id: string;
  registration: string;
  model: string;
  type: string;
  seats: 2 | 4;
  active: boolean;
  available?: boolean;
  unavailable_reason?: string | null;
  unavailable_from?: string | null;
  unavailable_until?: string | null;
  notes: string | null;
};

export type RegStatus = "confirmed" | "waitlist";

export type OutingSummary = {
  id: string;
  title: string;
  destination: string | null;
  departure_at: string;
  return_at: string | null;
  registration_deadline: string | null;
  status: "open" | "cancelled";
  instructor_name: string;
  instructor_flies: boolean;
  total_capacity: number | null;
  kind?: OutingKind;
  max_participants?: number | null;
  meeting_point?: string | null;
  confirmed_count: number;
  waitlist_count: number;
  aircraft_summary: string | null;
  my_status: RegStatus | null;
  i_am_instructor: boolean;
  approval?: Approval;
  rejection_reason?: string | null;
};

export type OutingKind = "vol" | "activite" | "evenement" | "formation";

export const KIND_LABELS: Record<OutingKind, string> = {
  vol: "Sortie avion",
  activite: "Activité",
  evenement: "Événement convivial",
  formation: "Formation",
};

export type Approval = "pending" | "approved" | "rejected";

export type Person = {
  registration_id: string;
  user_id: string;
  full_name: string;
  phone: string | null;
  avatar_url?: string | null;
  released?: boolean;
  weight_kg?: number | null;
  /** Accompagnant (+1) amené par un membre */
  is_guest?: boolean;
  host_name?: string | null;
};

export type OutingDetail = {
  id: string;
  title: string;
  destination: string | null;
  description: string | null;
  meeting_point: string | null;
  departure_at: string;
  return_at: string | null;
  registration_deadline: string | null;
  status: "open" | "cancelled";
  instructor_aircraft_id: string | null;
  instructor: { id: string; full_name: string; phone: string | null; avatar_url?: string | null };
  can_manage: boolean;
  approval?: Approval;
  rejection_reason?: string | null;
  can_edit?: boolean;
  is_organizer?: boolean;
  organizer_weight_kg?: number | null;
  kind?: OutingKind;
  max_participants?: number | null;
  participants?: Person[];
  aircraft: {
    id: string;
    registration: string;
    model: string;
    type?: string;
    seats: number;
    capacity: number;
    instructor_onboard: boolean;
    occupants: Person[];
  }[];
  waitlist: (Person & { position: number })[];
  my_registration: { id: string; status: RegStatus; aircraft_id: string | null } | null;
  guests_allowed?: boolean;
  /** Sortie avion : mon accompagnant */
  my_guest?: { id: string; name: string; weight_kg: number | null; status: RegStatus; aircraft_id: string | null } | null;
  /** Événement sans avion : nombre d'accompagnants annoncés */
  my_guest_count?: number;
};

export type SeatChange = {
  user_id: string;
  email: string;
  full_name: string;
  change: "promoted" | "demoted";
};

export type FormState = { error?: string; ok?: string } | undefined;

export type BarProduct = {
  id: string;
  name: string;
  price_cents: number;
  active: boolean;
  position: number;
  category?: "boissons" | "snacks";
};

export const BAR_SECTIONS = [
  { key: "boissons", label: "Boissons" },
  { key: "snacks", label: "Snacks" },
] as const;

export type BarConsumption = {
  id: string;
  user_id: string;
  product_name: string;
  unit_price_cents: number;
  quantity: number;
  created_at: string;
};

export type BarMonthSummary = {
  month: string;
  total_cents: number;
  products: { name: string; quantity: number; total_cents: number }[];
  members: {
    user_id: string;
    full_name: string;
    email: string;
    avatar_url: string | null;
    total_cents: number;
    items: Record<string, number>;
    paid: boolean;
    paid_at: string | null;
  }[];
};
