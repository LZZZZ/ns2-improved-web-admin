import { Ban as BanIcon, Plug } from "lucide-preact";
import { Fragment } from "preact";
import { useMemo, useState } from "preact/hooks";
import type { Ban, RecentPlayer, RecentPlayers, ServerState } from "../api/types";
import { banCommand, sendCommand } from "../store/commands";
import { useResource } from "../store/poll";
import { bans as bansResource, recentPlayers } from "../store/resources";
import { updateSettings, useSettings } from "../store/settings";
import { BanFields, DEFAULT_TERMS, banMinutes, banSpan } from "../ui/BanFields";
import { IconButton, StatusIcon } from "../ui/Icon";
import { Masked } from "../ui/Masked";
import { PlayerLinks } from "../ui/PlayerLinks";
import { dateTime, maskSteamId, parseSteamId, span } from "../ui/format";

type SortKey = "seen" | "name" | "first" | "played";

const ALREADY_BANNED = "Already banned. Unban from the Bans tab.";

function compare(a: RecentPlayer, b: RecentPlayer, key: SortKey): number {
  switch (key) {
    case "name":
      return a.name.localeCompare(b.name, undefined, { sensitivity: "base" })
        || a.steamId - b.steamId;
    case "first":
      return a.firstSeen - b.firstSeen || a.steamId - b.steamId;
    case "played":
      return a.playedSeconds - b.playedSeconds || a.steamId - b.steamId;
    default:
      // Who is here now, then whoever left most recently.
      return Number(b.connected) - Number(a.connected)
        || b.lastSeen - a.lastSeen || a.steamId - b.steamId;
  }
}

function matches(p: RecentPlayer, needle: string, id: number | null): boolean {
  if (!needle) return true;
  if (id !== null && p.steamId === id) return true;
  const n = needle.toLowerCase();
  return p.name.toLowerCase().includes(n)
    || p.formerNames.some((f) => f.toLowerCase().includes(n))
    || p.ip.includes(needle)
    || String(p.steamId).includes(needle);
}

/** "24 hours", "90 minutes", "2 days": the window as the server set it. */
function windowText(seconds: number): string {
  if (seconds % 86400 === 0 && seconds > 86400) return `${seconds / 86400} days`;
  if (seconds % 3600 === 0) return `${seconds / 3600} hours`;
  return `${Math.round(seconds / 60)} minutes`;
}

/** What the server said about the file the list is kept in, when it matters. */
function storageNotes(data: RecentPlayers): string[] {
  const notes: string[] = [];
  if (data.loaded === "fallback") {
    notes.push("The newest save of this list was torn, so it was restored "
      + "from the one before: up to a minute of comings and goings may be missing.");
  } else if (data.loaded === "unreadable") {
    notes.push("The saved list could not be read, so it started empty on this map.");
  }
  if (data.saveError) {
    notes.push(`The list is not being saved (${data.saveError}), so it will `
      + "not survive the next map change.");
  }
  return notes;
}

/**
 * Everyone seen in the last day, connected or not, so a player who has left
 * can still be found and banned. The mod's Lua keeps the list in a file, since
 * a map change wipes everything held in Lua.
 *
 * IPs are shown in the clear here, by design (docs/DESIGN.md, "What the panel
 * deliberately does not do"):
 * spotting a returning player under another account is what they are for.
 */
export function Recent({ state }: { state: ServerState }) {
  if (state.modVersion === null) {
    return (
      <section class="wrap">
        <div class="banner">
          <h2>This server keeps no list of recent players</h2>
          <p>
            The stock web interface only knows who is connected right now, and
            forgets even that at every map change. Mount this mod's{" "}
            <code>lua/</code> on the server and this tab lists everyone seen in
            the last day, with a ban button for each.
          </p>
        </div>
      </section>
    );
  }
  return <RecentList state={state} />;
}

function RecentList({ state }: { state: ServerState }) {
  const settings = useSettings();
  const list = useResource(recentPlayers);
  const banList = useResource(bansResource);
  const data = list.data;

  const [filter, setFilter] = useState("");
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>({ key: "seen", dir: 1 });
  const [banning, setBanning] = useState<number | null>(null);
  const [terms, setTerms] = useState(DEFAULT_TERMS);
  const [busy, setBusy] = useState(false);

  const now = Date.now() / 1000 + (data?.skewSeconds ?? 0);
  const minutes = banMinutes(terms);

  const banned = useMemo(() => {
    const byId = new Map<number, Ban>();
    for (const b of banList.data?.bans ?? []) byId.set(b.steamId, b);
    return byId;
  }, [banList.data]);

  const rows = useMemo(() => {
    const needle = filter.trim();
    const id = parseSteamId(needle);
    return (data?.players ?? [])
      .filter((p) => matches(p, needle, id))
      .slice()
      .sort((a, b) => compare(a, b, sort.key) * sort.dir);
  }, [data, filter, sort]);

  const toggleSort = (key: SortKey) =>
    setSort((s) => s.key === key
      ? { key, dir: s.dir === 1 ? -1 : 1 }
      : { key, dir: key === "first" || key === "played" ? -1 : 1 });

  const header = (key: SortKey, label: string) => (
    <th
      aria-sort={sort.key === key ? (sort.dir === 1 ? "ascending" : "descending") : "none"}
      onClick={() => toggleSort(key)}
    >
      {label}{sort.key === key ? (sort.dir === 1 ? " ▲" : " ▼") : ""}
    </th>
  );

  const openBan = (p: RecentPlayer) => {
    setBanning(banning === p.steamId ? null : p.steamId);
    setTerms(DEFAULT_TERMS);
  };

  const submitBan = async (e: Event, p: RecentPlayer) => {
    e.preventDefault();
    if (minutes === null || busy) return;
    const who = p.name ? `${p.name} (${p.steamId})` : String(p.steamId);
    if (!confirm(`Ban ${who} ${banSpan(minutes)}?`)) return;
    setBusy(true);
    const outcome = await sendCommand(
      banCommand(state, p.steamId, minutes, terms.reason), true,
      [bansResource, recentPlayers]);
    setBusy(false);
    if (outcome.tone !== "error") setBanning(null);
  };

  const notes = data ? storageNotes(data) : [];
  const columns = 7;

  return (
    <section class="wrap recent-tab">
      <div class="toolbar">
        <input
          type="search"
          class="filter-wide"
          placeholder="Filter by name, former name, Steam id or IP"
          value={filter}
          onInput={(e) => setFilter((e.target as HTMLInputElement).value)}
        />
        <span class="muted recent-count">
          {data
            ? `${rows.length} of ${data.players.length} players seen in the last `
              + `${windowText(data.windowSeconds)} (keeps up to ${data.capacity})`
            : (list.loading ? "Loading recent players..." : "")}
        </span>
        <span class="spacer" />
        {list.error && <span class="tone-error">{list.error.message}</span>}
        <label>
          <input
            type="checkbox"
            checked={!settings.maskIdentifiers}
            onChange={(e) => updateSettings({
              maskIdentifiers: !(e.target as HTMLInputElement).checked,
            })}
          />{" "}
          Show Steam ids
        </label>
      </div>

      {notes.map((n) => <p key={n} class="tone-error storage-note">{n}</p>)}

      <div class="table-wrap">
        <table class="recent-table">
          <thead>
            <tr>
              {header("name", "Player")}
              <th class="static">Steam id</th>
              <th class="static">IP</th>
              {header("seen", "Status")}
              {header("first", "First seen")}
              {header("played", "Played")}
              <th class="static">Actions</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((p) => {
              const ban = banned.get(p.steamId);
              return (
                <Fragment key={p.steamId}>
                  <tr data-steamid={p.steamId}>
                    <td class="name-cell">
                      {p.name || <span class="muted">(no name seen)</span>}
                      {p.formerNames.length > 0 && (
                        <div class="muted former-names">
                          was {p.formerNames.join(", ")}
                        </div>
                      )}
                    </td>
                    <td>
                      <span class="icon-row">
                        <Masked
                          value={String(p.steamId)}
                          masked={maskSteamId(p.steamId)}
                          label="Steam id"
                        />
                        <PlayerLinks steamId={p.steamId} />
                      </span>
                    </td>
                    <td class="ip-cell">
                      <span class="revealed">{p.ip || "-"}</span>
                    </td>
                    <td class="status-cell" title={dateTime(p.lastSeen)}>
                      {p.connected
                        ? <StatusIcon icon={Plug} label="connected" tone="ok"
                                      title="on the server now" />
                        : `left ${span(now - p.lastSeen)} ago`}
                      {ban && (
                        <>
                          {" "}
                          <span
                            class="tag tag-danger"
                            title={ban.permanent || ban.expiresAt === null
                              ? "Banned permanently"
                              : `Banned until ${dateTime(ban.expiresAt)}`}
                          >banned</span>
                        </>
                      )}
                    </td>
                    <td title={dateTime(p.firstSeen)}>{span(now - p.firstSeen)} ago</td>
                    <td>{span(p.playedSeconds)}</td>
                    <td>
                      <IconButton icon={BanIcon} label="Ban..." extraClass="ban" danger
                                  disabled={ban !== undefined}
                                  reason={ban ? ALREADY_BANNED : undefined}
                                  expanded={banning === p.steamId}
                                  onClick={() => openBan(p)} />
                    </td>
                  </tr>
                  {banning === p.steamId && !ban && (
                    <tr class="ban-row">
                      <td colSpan={columns}>
                        <form class="form-row" onSubmit={(e) => void submitBan(e, p)}>
                          <BanFields terms={terms} onChange={setTerms} />
                          <button class="btn btn-danger" type="submit"
                                  disabled={busy || minutes === null}>
                            Ban {p.name || p.steamId}
                          </button>
                          <button class="btn" type="button" onClick={() => setBanning(null)}>
                            Cancel
                          </button>
                        </form>
                        <p class="muted form-hint">
                          {p.connected ? "Kicks the player too. " : ""}
                          Sent as {state.shine?.bans ? "sh_banid (Shine)" : "sv_ban"}.
                        </p>
                      </td>
                    </tr>
                  )}
                </Fragment>
              );
            })}
            {data && rows.length === 0 && (
              <tr>
                <td colSpan={columns} class="muted" style="padding: 16px">
                  {data.players.length === 0
                    ? `Nobody has been seen in the last ${windowText(data.windowSeconds)}.`
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
