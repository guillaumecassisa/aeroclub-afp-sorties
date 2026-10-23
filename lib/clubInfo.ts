import { createClient } from "@/lib/supabase/server";
import { CLUB_NAME } from "@/lib/club";

export type ClubInfo = {
  association_name: string;
  legal_form: string | null;
  address: string | null;
  registration_number: string | null;
  publication_director: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  updated_at?: string;
};

export async function getClubInfo(): Promise<ClubInfo> {
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_club_info");
  return {
    association_name: CLUB_NAME,
    legal_form: "Association régie par la loi du 1er juillet 1901",
    address: null,
    registration_number: null,
    publication_director: null,
    contact_email: null,
    contact_phone: null,
    ...((data ?? {}) as Partial<ClubInfo>),
  };
}
