import { Ban, LogOut, Mic, MicOff, Skull, UserX, Users } from "lucide-preact";
import { useMemo, useState } from "preact/hooks";
import type { Player, ServerState } from "../api/types";
import { TEAM_NAMES } from "../api/types";
import { banCommand, sendCommand } from "../store/commands";
import { updateSettings, useSettings } from "../store/settings";
import { IconButton, StatusIcon } from "../ui/Icon";
import { Masked } from "../ui/Masked";
import { PlayerLinks } from "../ui/PlayerLinks";
import { maskIp, maskSteamId } from "../ui/format";

type SortKey = "name" | "team" | "skill" | "score" | "kills" | "assists" | "deaths"
  | "resources" | "ping";

const COLUMNS: { key: SortKey; label: string; num?: boolean; title?: string }[] = [
  { key: "name", label: "Player" },
  { key: "team", label: "Team" },
  { key: "skill", label: "Skill", num: true,
    title: "Hive skill, as the server holds it, with the game's badge for its tier. Hover "
      + "a value for the tier, and the marine, alien and commander figures." },
  { key: "score", label: "Score", num: true },
  { key: "kills", label: "K", num: true },
  { key: "assists", label: "A", num: true },
  { key: "deaths", label: "D", num: true },
  { key: "resources", label: "Res", num: true },
  { key: "ping", label: "Ping", num: true },
];

// Bots report steamid 0 and every per-player command resolves through
// GetPlayerMatching(steamid), so none of them can ever match a bot. The 2012
// panel rendered the buttons anyway and they silently did nothing; here they
// are disabled and say why.
const BOT_REASON =
  "Bots report Steam id 0, which matches no player. The server cannot act on this row.";

// The 2012 panel's Mute sent `sv_mute`, which no server has: the game has no
// mute command at all (CURRENT-UI defect 18). Shine's basecommands does.
const MUTE_REASON =
  "The game has no mute command. Muting needs Shine, with its basecommands plugin.";

// ForceEvenTeams() (TeamJoin.lua) has no check of its own: mid-round it would
// move players between teams in the middle of play.
const EVEN_REASON =
  "A round is on: forcing even teams now would move players mid-round. Reset the round first.";

// The 09-26+ engine's two counts (its CHANGELOG), shown only by an engine
// that has them.
const REJECTED_TITLE =
  "Moves the server rejected: for time credit (usually a modified client) · "
  + "for anything else (a poor connection can cause these).";

const SHARED_TITLE =
  "Steam Family Sharing: the player is on a copy another account owns, shown "
  + "beside it. Reported by the 09-26+ engine.";

/** The 2012 panel's round buttons, with the commands that exist. */
const ROUND_ACTIONS = [
  // It sent `sv_resetround`, which does not exist (defect 17). sv_reset does.
  { label: "Reset round", command: "sv_reset", danger: true,
    confirm: "Reset the round? Everyone goes back to the start." },
  { label: "All to ready room", command: "sv_rrall",
    confirm: "Send everyone to the ready room?" },
  { label: "Random teams", command: "sv_randomall",
    confirm: "Put everyone on a random team?" },
  { label: "Force even teams", command: "sv_forceeventeams", even: true,
    confirm: "Balance the teams by Hive skill?" },
] as const;

function compare(a: Player, b: Player, key: SortKey): number {
  if (key === "skill") {
    const skill = (p: Player) => p.skill && p.skill.skill >= 0 ? p.skill.skill : -Infinity;
    return skill(a) - skill(b) || 0;
  }
  const x = a[key];
  const y = b[key];
  if (typeof x === "string" && typeof y === "string") {
    return x.localeCompare(y, undefined, { sensitivity: "base" });
  }
  return Number(x) - Number(y);
}

export function Players({ state }: { state: ServerState }) {
  const settings = useSettings();
  const [filter, setFilter] = useState("");
  const hideBots = settings.playersHideBots;
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>(
    { key: "score", dir: -1 });

  // Sort and filter are component state, so a poll replacing the data does not
  // disturb either -- the 2012 panel rebuilt the table and lost both.
  const rows = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    return state.players
      .filter((p) => !(hideBots && p.isBot))
      .filter((p) => !needle
        || p.name.toLowerCase().includes(needle)
        || String(p.steamId).includes(needle))
      .slice()
      .sort((a, b) => compare(a, b, sort.key) * sort.dir);
  }, [state.players, filter, hideBots, sort]);

  const toggleSort = (key: SortKey) =>
    setSort((s) => s.key === key
      ? { key, dir: s.dir === 1 ? -1 : 1 }
      : { key, dir: key === "name" || key === "team" ? 1 : -1 });

  const act = (command: string, confirmText?: string) => {
    if (confirmText && !confirm(confirmText)) return;
    // With the mod's Lua the result comes back with the command; without it,
    // nothing does. sendCommand says which, rather than assuming.
    void sendCommand(command, state.modVersion !== null);
  };

  const canMute = state.shine?.baseCommands === true;
  const showRejected = state.players.some((p) => p.movesRejected !== null);
  const showShared = state.players.some((p) => p.familyShared !== null);
  // The mod sends skill; a stock server does not, and gets no column.
  const showSkill = state.players.some((p) => p.skill !== null);
  const columns = COLUMNS.filter((c) => c.key !== "skill" || showSkill);
  const columnCount = columns.length + 3 + (showRejected ? 1 : 0) + (showShared ? 1 : 0);

  return (
    <section class="wrap">
      <div class="toolbar round-controls">
        <span class="muted">Round</span>
        {ROUND_ACTIONS.map((a) => {
          const blocked = "even" in a && state.gameStarted;
          return (
            <button
              key={a.command}
              class={"danger" in a ? "btn btn-sm btn-danger" : "btn btn-sm"}
              data-command={a.command}
              disabled={blocked}
              title={blocked ? EVEN_REASON : a.command}
              onClick={() => act(a.command, a.confirm)}
            >{a.label}</button>
          );
        })}
      </div>

      <div class="toolbar">
        <input
          type="search"
          placeholder="Filter by name or Steam id"
          value={filter}
          onInput={(e) => setFilter((e.target as HTMLInputElement).value)}
        />
        <label>
          <input
            type="checkbox"
            checked={hideBots}
            onChange={(e) => updateSettings({
              playersHideBots: (e.target as HTMLInputElement).checked,
            })}
          />{" "}
          Hide bots
        </label>
        <span class="muted">
          {rows.length} of {state.players.length} shown
          {state.players.length !== state.playersOnline
            && ` · server reports ${state.playersOnline}`}
        </span>
        <span class="spacer" />
        <label>
          <input
            type="checkbox"
            checked={!settings.maskIdentifiers}
            onChange={(e) => updateSettings({
              maskIdentifiers: !(e.target as HTMLInputElement).checked,
            })}
          />{" "}
          Show Steam ids and IPs
        </label>
      </div>

      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              {columns.map((c) => (
                <th
                  key={c.key}
                  class={c.num ? "num" : undefined}
                  title={c.title}
                  aria-sort={sort.key === c.key
                    ? (sort.dir === 1 ? "ascending" : "descending")
                    : "none"}
                  onClick={() => toggleSort(c.key)}
                >
                  {c.label}
                  {sort.key === c.key ? (sort.dir === 1 ? " ▲" : " ▼") : ""}
                </th>
              ))}
              {showRejected && (
                <th class="static num" title={REJECTED_TITLE}>Rejected</th>
              )}
              {showShared && <th class="static" title={SHARED_TITLE}>Shared</th>}
              <th class="static">Steam id</th>
              <th class="static">IP</th>
              <th class="static">Actions</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((p) => (
              <tr key={p.key}>
                <td class="name-cell">
                  {p.name}{" "}
                  {p.isBot && <span class="tag">BOT</span>}{" "}
                  {p.isCommander && <span class="tag">COMM</span>}{" "}
                  {p.gagged && <span class="tag" title="Muted by Shine">MUTED</span>}
                </td>
                <td class={`team-${p.team}`}>{TEAM_NAMES[p.team]}</td>
                {showSkill && <SkillCell p={p} />}
                <td class="num">{p.score}</td>
                <td class="num">{p.kills}</td>
                <td class="num">{p.assists}</td>
                <td class="num">{p.deaths}</td>
                <td class="num">{Math.round(p.resources)}</td>
                <td class="num">{p.ping}</td>
                {showRejected && (
                  <td
                    class={p.movesRejected && p.movesRejected.time > 0
                      ? "num rejected-cell tone-error" : "num rejected-cell"}
                    title={REJECTED_TITLE}
                  >
                    {p.movesRejected
                      ? `${p.movesRejected.time} · ${p.movesRejected.other}`
                      : "--"}
                  </td>
                )}
                {showShared && (
                  <td class="shared-cell">
                    {p.familyShared ? (
                      <span class="icon-row">
                        <StatusIcon icon={Users} label="shared copy" tone="warn"
                                    title="playing a Family Shared copy" />
                        {p.ownerSteamId !== null && (
                          <span class="owner-id">
                            owner{" "}
                            <Masked
                              value={String(p.ownerSteamId)}
                              masked={maskSteamId(p.ownerSteamId)}
                              label="owner's Steam id"
                            />
                          </span>
                        )}
                      </span>
                    ) : <span class="muted">--</span>}
                  </td>
                )}
                <td>
                  {p.isBot
                    ? <span class="muted mono">--</span>
                    : (
                      <span class="icon-row">
                        <Masked
                          value={String(p.steamId)}
                          masked={maskSteamId(p.steamId)}
                          label="Steam id"
                        />
                        <PlayerLinks steamId={p.steamId} />
                      </span>
                    )}
                </td>
                <td>
                  <Masked value={p.ip} masked={maskIp(p.ip)} label="IP address" />
                </td>
                <td>
                  <div class="actions">
                    <IconButton icon={UserX} label="Kick" danger disabled={p.isBot}
                                reason={p.isBot ? BOT_REASON : undefined}
                                onClick={() => act(`sv_kick ${p.steamId}`, `Kick ${p.name}?`)} />
                    <IconButton icon={Ban} label="Ban 24h" danger disabled={p.isBot}
                                reason={p.isBot ? BOT_REASON : undefined}
                                onClick={() => act(banCommand(state, p.steamId, 1440, "WebUI"),
                                  `Ban ${p.name} for 24 hours?`)} />
                    <IconButton icon={p.gagged ? Mic : MicOff} label={p.gagged ? "Unmute" : "Mute"}
                                data={{ action: "mute" }}
                                disabled={p.isBot || !canMute}
                                reason={p.isBot ? BOT_REASON
                                  : (!canMute ? MUTE_REASON
                                    : (p.gagged ? "Shine: sh_ungag" : "Shine: sh_gag, for the rest of the map"))}
                                onClick={() => act(p.gagged
                                  ? `sh_ungag ${p.steamId}` : `sh_gag ${p.steamId}`)} />
                    <IconButton icon={Skull} label="Slay" disabled={p.isBot}
                                reason={p.isBot ? BOT_REASON : undefined}
                                onClick={() => act(`sv_slay ${p.steamId}`)} />
                    <IconButton icon={LogOut} label="Eject" disabled={p.isBot || !p.isCommander}
                                reason={p.isBot ? BOT_REASON
                                  : (!p.isCommander ? "Not commanding" : undefined)}
                                onClick={() => act(`sv_eject ${p.steamId}`,
                                  `Eject ${p.name} from the command chair?`)} />
                    <select
                      class="btn btn-sm"
                      disabled={p.isBot}
                      title={p.isBot ? BOT_REASON : "Move to team"}
                      value=""
                      onChange={(e) => {
                        const el = e.target as HTMLSelectElement;
                        const team = el.value;
                        el.value = "";
                        if (team !== "") {
                          act(`sv_switchteam ${p.steamId} ${team}`);
                        }
                      }}
                    >
                      <option value="">Move to...</option>
                      <option value="0">Ready room</option>
                      <option value="1">Marines</option>
                      <option value="2">Aliens</option>
                      <option value="3">Spectate</option>
                    </select>
                  </div>
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={columnCount} class="muted" style="padding: 16px">
                  {state.players.length === 0
                    ? "Nobody is connected."
                    : "No players match this filter."}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}

// The game's names for its tiers (gamestrings SKILLTIER_*), by
// ScoringMixin:GetSkillTier()'s number.
const TIER_NAMES: Record<number, string> = {
  [-2]: "Unknown", [-1]: "Bot", 0: "Rookie", 1: "Recruit", 2: "Frontiersman",
  3: "Squad Leader", 4: "Veteran", 5: "Commandant", 6: "Special Ops", 7: "Sanji Survivor",
};

/**
 * The game's skill badge for the server's tier: GUIScoreboard's sprite sheet,
 * row tier + 2. Nothing for no tier.
 */
function SkillBadge({ tier }: { tier: number | null }) {
  if (tier === null) return null;
  return (
    <span class="skill-badge" style={`--row: ${tier + 2}`}>
      <span class="sr-only">{TIER_NAMES[tier]}</span>
    </span>
  );
}

/**
 * The game's badge, then plain skill; the tier and the figures the server
 * plays with on hover (P1). The server reports -1 in all four fields when it
 * holds no Hive skill (every bot, on the rig 2026-10-07), so a negative skill
 * is shown as none.
 */
function SkillCell({ p }: { p: Player }) {
  const k = p.skill;
  if (k === null) return <td class="num muted skill-cell"><span class="skill-value">--</span></td>;
  // A tier the sheet has no row for gets no badge.
  const tier = k.tier !== null && k.tier in TIER_NAMES ? k.tier : null;
  if (p.isBot || k.skill < 0) {
    const title = p.isBot ? "Bot" : "The server holds no Hive skill for this player";
    return (
      <td class="num muted skill-cell" title={title}>
        <SkillBadge tier={tier} /><span class="skill-value">--</span>
      </td>
    );
  }
  const lines = [
    ...(tier !== null ? [`${TIER_NAMES[tier]}${tier > 0 ? ` (tier ${tier})` : ""}`] : []),
    `Marines ${Math.round(k.skill + k.offset)} · Aliens ${Math.round(k.skill - k.offset)}`,
    k.comm !== null && k.comm > 0
      ? `Commander ${Math.round(k.comm)} (marines ${Math.round(k.comm + k.commOffset)}, `
        + `aliens ${Math.round(k.comm - k.commOffset)})`
      : "No commander skill yet",
  ];
  return (
    <td class="num skill-cell" title={lines.join("\n")}>
      <SkillBadge tier={tier} /><span class="skill-value">{Math.round(k.skill)}</span>
    </td>
  );
}
