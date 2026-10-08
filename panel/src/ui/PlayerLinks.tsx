// A player's pages elsewhere, beside the Steam id on the Players and Recent
// players tabs. Plain links, opened in a new tab without a referrer: the panel
// itself fetches nothing from either site.
// Both marks are inline SVG drawn in `currentColor`, so their colour comes from
// a token (styles.css) and follows the theme. Inline, not files, so the
// engine's content type for .svg never matters.
import { steamId64 } from "./format";

/** The ns2panel.com mark (2026-10-07), in its orange (--ns2panel). */
function Ns2PanelIcon() {
  return (
    <svg width={15} height={15} viewBox="0 0 24 24" fill="none" stroke="currentColor"
         stroke-width={2} stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d="M11 3.055A9.001 9.001 0 1020.945 13H11V3.055z" />
      <path d="M20.488 9H15V3.512A9.025 9.025 0 0120.488 9z" />
    </svg>
  );
}

// Valve's own Steam mark, the round one from its lockup in steam_brandAssets.eps
// (partner.steamgames.com/doc/marketing/branding, Illustrator, 2024-11-21),
// cut out of the vector and scaled to 24 units. Unaltered and on its own, as
// that page asks; one colour, as Valve draws it.
const STEAM_MARK =
  "M13.97 7.58C13.73 7.95 13.59 8.38 13.59 8.83C13.59 9.12 13.64 9.41 13.75 9.68C13.86 9.96"
  + " 14.03 10.2 14.24 10.41C14.45 10.63 14.7 10.79 14.97 10.9C15.25 11.02 15.54 11.07 15.84"
  + " 11.07C16.28 11.07 16.72 10.94 17.08 10.69C17.45 10.45 17.74 10.09 17.91 9.69C18.08 9.27"
  + " 18.13 8.82 18.04 8.39C17.95 7.95 17.74 7.55 17.42 7.24C17.11 6.92 16.71 6.71 16.28 6.62C15.84"
  + " 6.54 15.39 6.58 14.98 6.75C14.57 6.92 14.22 7.21 13.97 7.58ZM18.32 7.16C18.65 7.66 18.82 8.24"
  + " 18.82 8.83C18.82 9.62 18.51 10.37 17.94 10.93C17.39 11.49 16.63 11.81 15.83 11.81C15.24 11.81"
  + " 14.67 11.64 14.17 11.31C13.68 10.98 13.3 10.51 13.07 9.97C12.85 9.42 12.79 8.82 12.9 8.24C13.02"
  + " 7.66 13.3 7.13 13.72 6.71C14.14 6.29 14.67 6 15.25 5.89C15.83 5.78 16.43 5.84 16.98 6.06C17.52"
  + " 6.29 17.99 6.67 18.32 7.16ZM7.5 18.04L6.04 17.43C6.25 17.88 6.59 18.25 7.01 18.5C7.43 18.76"
  + " 7.91 18.88 8.4 18.87C8.89 18.85 9.36 18.69 9.76 18.41C10.16 18.13 10.48 17.74 10.66 17.28C10.84"
  + " 16.83 10.88 16.33 10.79 15.85C10.69 15.37 10.46 14.93 10.12 14.58C9.77 14.23 9.34 13.99 8.86"
  + " 13.88C8.38 13.77 7.88 13.81 7.42 13.98L8.93 14.6C9.39 14.8 9.75 15.16 9.94 15.61C10.12 16.07"
  + " 10.12 16.58 9.93 17.04C9.74 17.49 9.38 17.86 8.93 18.04C8.47 18.23 7.96 18.23 7.5 18.04ZM11.9"
  + " 0C8.91 0 6.03 1.13 3.84 3.15C1.64 5.18 0.29 7.96 0.05 10.93L6.42 13.57C6.98 13.19 7.64 12.98"
  + " 8.32 12.98L8.5 12.98L11.34 8.88L11.34 8.82C11.34 7.93 11.61 7.07 12.1 6.33C12.6 5.6 13.3 5.02"
  + " 14.12 4.69C14.94 4.35 15.84 4.26 16.71 4.44C17.58 4.61 18.37 5.04 19 5.67C19.63 6.3 20.05 7.1"
  + " 20.22 7.97C20.39 8.84 20.3 9.74 19.96 10.56C19.62 11.37 19.05 12.07 18.31 12.57C17.57 13.06"
  + " 16.71 13.32 15.82 13.32L15.72 13.32L11.69 16.2L11.69 16.36C11.69 17.2 11.38 18.01 10.82"
  + " 18.63C10.26 19.25 9.49 19.64 8.66 19.72C7.83 19.8 6.99 19.57 6.32 19.08C5.65 18.58 5.19 17.85"
  + " 5.02 17.03L0.47 15.15C1.07 17.27 2.26 19.19 3.89 20.68C5.52 22.18 7.54 23.18 9.71 23.59C11.89"
  + " 24 14.13 23.79 16.19 22.99C18.26 22.2 20.06 20.84 21.39 19.07C22.73 17.31 23.54 15.21 23.75"
  + " 13.01C23.95 10.81 23.54 8.59 22.55 6.61C21.57 4.63 20.05 2.96 18.17 1.8C16.29 0.63 14.12 0.02"
  + " 11.9 0Z";

function SteamIcon() {
  return (
    <svg width={15} height={15} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d={STEAM_MARK} />
    </svg>
  );
}

/** ns2panel.com keys a player by the Steam account id, which is NS2's id. */
const ns2PanelUrl = (steamId: number) => `https://ns2panel.com/player/${steamId}`;

/** Steam keys a profile by SteamID64 (account id + 76561197960265728). */
const steamProfileUrl = (steamId: number) =>
  `https://steamcommunity.com/profiles/${steamId64(steamId)}`;

/** The player's Steam profile and ns2panel.com page. Not for bots. */
export function PlayerLinks({ steamId }: { steamId: number }) {
  return (
    <>
      <a class="player-link steam-link" href={steamProfileUrl(steamId)}
         target="_blank" rel="noreferrer noopener"
         title="Open the Steam profile (leaves this panel)">
        <SteamIcon />
        <span class="sr-only">Steam profile</span>
      </a>
      <a class="player-link ns2panel-link" href={ns2PanelUrl(steamId)}
         target="_blank" rel="noreferrer noopener"
         title="Open on ns2panel.com (leaves this panel)">
        <Ns2PanelIcon />
        <span class="sr-only">ns2panel</span>
      </a>
    </>
  );
}
