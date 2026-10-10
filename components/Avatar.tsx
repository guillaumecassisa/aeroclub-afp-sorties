/* eslint-disable @next/next/no-img-element */

const SIZES = {
  xs: "h-6 w-6 text-[10px]",
  sm: "h-8 w-8 text-xs",
  md: "h-11 w-11 text-sm",
  lg: "h-24 w-24 text-2xl",
} as const;

function initials(name: string) {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return "?";
  return ((parts[0][0] ?? "") + (parts.length > 1 ? parts[parts.length - 1][0] : "")).toUpperCase();
}

/** Photo de profil ronde, ou initiales sur fond marine si pas de photo. */
export function Avatar({
  url,
  name,
  size = "sm",
  className = "",
}: {
  url?: string | null;
  name: string;
  size?: keyof typeof SIZES;
  className?: string;
}) {
  const base = `inline-flex shrink-0 items-center justify-center overflow-hidden rounded-full ${SIZES[size]} ${className}`;
  if (url) return <img src={url} alt="" className={`${base} object-cover`} loading="lazy" />;
  return (
    <span aria-hidden className={`${base} bg-navy-2 font-semibold text-white`}>
      {initials(name)}
    </span>
  );
}
