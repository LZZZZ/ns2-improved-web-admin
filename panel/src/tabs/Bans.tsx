import { ShieldOff } from "lucide-preact";
import { useMemo, useState } from "preact/hooks";
import type { Ban, ServerState } from "../api/types";
import { banCommand, sendCommand, unbanCommand } from "../store/commands";
import { useResource } from "../store/poll";
import { bans as bansResource } from "../store/resources";
import { updateSettings, useSettings } from "../store/settings";
import { BanFields, DEFAULT_TERMS, banMinutes, banSpan } from "../ui/BanFields";
import { IconButton } from "../ui/Icon";
import { Masked } from "../ui/Masked";
import { dateTime, maskSteamId, parseSteamId, span } from "../ui/format";

type SortKey = "order" | "name" | "expires" | "issued" | "bannedBy";

function compare(a: Ban, b: Ban, key: SortKey): number {
  switch (key) {
    case "name":
      return a.name.localeCompare(b.name, undefined, { sensitivity: "base" })
        || a.steamId - b.steamId;
    case "bannedBy":
      return (a.bannedBy ?? "").localeCompare(b.bannedBy ?? "", undefined,
        { sensitivity: "base" }) || a.order - b.order;
    case "issued":
      return (a.issuedAt ?? 0) - (b.issuedAt ?? 0) || b.steamId - a.steamId;
    case "expires": {
      // Permanent sorts after every expiry.
      const x = a.expiresAt ?? Infinity;
      const y = b.expiresAt ?? Infinity;
      return x === y ? a.steamId - b.steamId : (x < y ? -1 : 1);
    }
    default:
      return a.order - b.order;
  }
}

export function Bans({ state }: { state: ServerState }) {
  const settings = useSettings();
  const list = useResource(bansResource);
  const data = list.data;
  const shineOwns = data?.source === "shine";

  const [filter, setFilter] = useState("");
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>(
    { key: "order", dir: 1 });

  const [idInput, setIdInput] = useState("");
  const [terms, setTerms] = useState(DEFAULT_TERMS);
  const [busy, setBusy] = useState(false);

  const now = Date.now() / 1000 + (data?.skewSeconds ?? 0);
  const parsedId = parseSteamId(idInput);
  const minutes = banMinutes(terms);

  const rows = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    return (data?.bans ?? [])
      .filter((b) => !needle
        || b.name.toLowerCase().includes(needle)
        || b.reason.toLowerCase().includes(needle)
        || String(b.steamId).includes(needle))
      .slice()
      .sort((a, b) => compare(a, b, sort.key) * sort.dir);
  }, [data, filter, sort]);

  const toggleSort = (key: SortKey) =>
    setSort((s) => s.key === key
      ? { key, dir: s.dir === 1 ? -1 : 1 }
      : { key, dir: key === "issued" ? -1 : 1 });

  const header = (key: SortKey, label: string) => (
    <th
      aria-sort={sort.key === key ? (sort.dir === 1 ? "ascending" : "descending") : "none"}
      onClick={() => toggleSort(key)}
    >
      {label}{sort.key === key ? (sort.dir === 1 ? " ▲" : " ▼") : ""}
    </th>
  );

  const unban = (b: Ban) => {
    if (!confirm(`Unban ${b.name} (${b.steamId})?`)) return;
    void sendCommand(unbanCommand(state, b.steamId), [bansResource]);
  };

  const addBan = async (e: Event) => {
    e.preventDefault();
    if (parsedId === null || minutes === null || busy) return;
    if (!confirm(`Ban ${parsedId} ${banSpan(minutes)}?`)) return;
    setBusy(true);
    const outcome = await sendCommand(
      banCommand(state, parsedId, minutes, terms.reason), [bansResource]);
    setBusy(false);
    if (outcome.tone !== "error") {
      setIdInput("");
      setTerms((t) => ({ ...t, reason: "" }));
    }
  };

  const connected = state.players.filter((p) => !p.isBot);

  return (
    <section class="wrap bans-tab">

      <div class="toolbar">
        <input
          type="search"
          class="filter-wide"
          placeholder="Filter by name, reason or Steam id"
          value={filter}
          onInput={(e) => setFilter((e.target as HTMLInputElement).value)}
        />
        <span class="muted bans-count">
          {data
            ? `${rows.length} of ${data.bans.length} bans`
            : (list.loading ? "Loading bans..." : "")}
          {data && ` · ${shineOwns ? "Shine's ban list" : "the game's ban list"}`}
        </span>
        <span class="spacer" />
        {list.error && <span class="tone-error">{list.error.message}</span>}
        <label>
          <input
            type="checkbox"
            checked={!settings.hideIdentifiers}
            onChange={(e) => updateSettings({
              hideIdentifiers: !(e.target as HTMLInputElement).checked,
            })}
          />{" "}
          Show Steam ids
        </label>
      </div>

      <div class="table-wrap">
        <table class="bans-table">
          <thead>
            <tr>
              {header("name", "Player")}
              <th class="static">Steam id</th>
              <th class="static">Reason</th>
              {header("expires", "Expires")}
              {shineOwns && header("bannedBy", "Banned by")}
              {shineOwns && header("issued", "Issued")}
              <th class="static">Actions</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((b) => (
              <tr key={b.steamId} data-steamid={b.steamId}>
                <td class="name-cell">{b.name}</td>
                <td>
                  <Masked
                    value={String(b.steamId)}
                    masked={maskSteamId(b.steamId)}
                    label="Steam id"
                  />
                </td>
                <td class="reason-cell">{b.reason}</td>
                <td class="expires-cell"
                    title={b.expiresAt !== null ? dateTime(b.expiresAt) : undefined}>
                  {b.permanent || b.expiresAt === null
                    ? "Permanent"
                    : `in ${span(b.expiresAt - now)}`}
                </td>
                {shineOwns && <td>{b.bannedBy ?? ""}</td>}
                {shineOwns && (
                  <td title={b.issuedAt !== null ? dateTime(b.issuedAt) : undefined}>
                    {b.issuedAt !== null ? `${span(now - b.issuedAt)} ago` : ""}
                  </td>
                )}
                <td>
                  <IconButton icon={ShieldOff} label="Unban" extraClass="unban"
                              onClick={() => unban(b)} />
                </td>
              </tr>
            ))}
            {data && rows.length === 0 && (
              <tr>
                <td colSpan={shineOwns ? 7 : 5} class="muted" style="padding: 16px">
                  {data.bans.length === 0 ? "Nobody is banned." : "No bans match this filter."}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <form class="form-card" onSubmit={addBan}>
        <h2>Ban a Steam id</h2>
        <div class="form-row">
          <label>
            Steam id
            <input
              type="text"
              name="steamid"
              placeholder="12345678, STEAM_0:1:..., or a SteamID64"
              spellcheck={false}
              autocomplete="off"
              value={idInput}
              onInput={(e) => setIdInput((e.target as HTMLInputElement).value)}
            />
          </label>
          {connected.length > 0 && (
            <label>
              or a connected player
              <select
                value=""
                onChange={(e) => {
                  const el = e.target as HTMLSelectElement;
                  if (el.value) setIdInput(el.value);
                  el.value = "";
                }}
              >
                <option value="">Choose...</option>
                {connected.map((p) => (
                  <option key={p.key} value={String(p.steamId)}>{p.name}</option>
                ))}
              </select>
            </label>
          )}
          <BanFields terms={terms} onChange={setTerms} />
          <button class="btn btn-danger" type="submit"
                  disabled={busy || parsedId === null || minutes === null}>
            Ban
          </button>
        </div>
        <p class="muted form-hint">
          {idInput.trim() === ""
            ? "Kicks the player too if they are connected."
            : parsedId === null
              ? "Not a Steam id this panel recognises."
              : `Bans account ${parsedId}.`}
        </p>
      </form>
    </section>
  );
}
