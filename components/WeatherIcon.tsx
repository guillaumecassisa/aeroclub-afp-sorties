import type { Sky } from "@/lib/metar";

/** Pictogramme météo simple, aux couleurs du club. */
export function WeatherIcon({ sky, className = "h-16 w-16" }: { sky: Sky; className?: string }) {
  const sun = (
    <g>
      <circle cx="24" cy="22" r="8" fill="#F5B700" />
      {[0, 45, 90, 135, 180, 225, 270, 315].map((a) => (
        <line
          key={a}
          x1="24"
          y1="8"
          x2="24"
          y2="4"
          stroke="#F5B700"
          strokeWidth="2.5"
          strokeLinecap="round"
          transform={`rotate(${a} 24 22)`}
        />
      ))}
    </g>
  );
  const cloud = (fill: string, dx = 0, dy = 0) => (
    <path
      transform={`translate(${dx} ${dy})`}
      d="M20 44h26a9 9 0 0 0 0-18 12 12 0 0 0-23-3 8 8 0 0 0-3 21z"
      fill={fill}
      stroke="#002157"
      strokeOpacity=".15"
    />
  );
  const drops = (color: string) =>
    [22, 31, 40].map((x) => (
      <line key={x} x1={x} y1="49" x2={x - 3} y2="57" stroke={color} strokeWidth="2.5" strokeLinecap="round" />
    ));
  return (
    <svg viewBox="0 0 64 64" className={className} role="img" aria-hidden>
      {sky === "clear" && <g transform="translate(8 10)">{sun}</g>}
      {sky === "few" && (
        <>
          {sun}
          {cloud("#FFFFFF", 4, 6)}
        </>
      )}
      {sky === "cloudy" && (
        <>
          {cloud("#DCE3EE", -6, -6)}
          {cloud("#FFFFFF", 2, 2)}
        </>
      )}
      {sky === "overcast" && (
        <>
          {cloud("#B7C2D3", -6, -6)}
          {cloud("#DCE3EE", 2, 2)}
        </>
      )}
      {sky === "rain" && (
        <>
          {cloud("#DCE3EE", 0, -4)}
          {drops("#1F6FEB")}
        </>
      )}
      {sky === "storm" && (
        <>
          {cloud("#B7C2D3", 0, -4)}
          <path d="M33 44l-6 10h6l-3 9 9-13h-6l4-6z" fill="#F5B700" />
        </>
      )}
      {sky === "snow" && (
        <>
          {cloud("#DCE3EE", 0, -4)}
          {[22, 32, 42].map((x) => (
            <circle key={x} cx={x} cy="53" r="2.2" fill="#8FB3E8" />
          ))}
        </>
      )}
      {sky === "fog" && (
        <>
          {cloud("#DCE3EE", 0, -8)}
          {[42, 49, 56].map((y, i) => (
            <line key={y} x1={10 + i * 3} y1={y} x2={54 - i * 3} y2={y} stroke="#8A96A8" strokeWidth="3" strokeLinecap="round" />
          ))}
        </>
      )}
    </svg>
  );
}
