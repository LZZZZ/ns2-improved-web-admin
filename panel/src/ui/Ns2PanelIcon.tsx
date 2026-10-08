// The ns2panel.com mark beside a player's Steam id: an SVG (2026-10-07), inline and drawn in `currentColor`, so its
// orange comes from the --ns2panel token (styles.css) and follows the theme.
// Inline, not a file, so the engine's content type for .svg never matters.

export function Ns2PanelIcon() {
  return (
    <svg width={15} height={15} viewBox="0 0 24 24" fill="none" stroke="currentColor"
         stroke-width={2} stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d="M11 3.055A9.001 9.001 0 1020.945 13H11V3.055z" />
      <path d="M20.488 9H15V3.512A9.025 9.025 0 0120.488 9z" />
    </svg>
  );
}
