import { browserBackend } from "./backendSelection.js";

const hostedURL = import.meta.env.VITE_SUPABASE_URL?.trim();
const hostedKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim();

export const supabaseBrowserConfiguration = Object.freeze(
  browserBackend(hostedURL, hostedKey, "sb_publishable_mCtOQIg_1QFyu4bUv1giBK_Fp8VsNyK")
);
export const isSupabaseConfigured = Boolean(supabaseBrowserConfiguration.url && supabaseBrowserConfiguration.publishableKey);
