import { UserMinus } from "lucide-preact";
import { useState } from "preact/hooks";
import type { ServerState } from "../api/types";
import {
  addSlotCommand, removeSlotCommand, sendCommand, slotAmountCommand,
} from "../store/commands";
import { useResource } from "../store/poll";
import { reservedSlots } from "../store/resources";
import { updateSettings, useSettings } from "../store/settings";
import { IconButton } from "../ui/Icon";
import { Masked } from "../ui/Masked";
import { maskSteamId, parseSteamId, slotName } from "../ui/format";

const SHINE_REASON =
  "Shine's reservedslots plugin grants access by permission; this list is not enforced.";

export function Slots({ state }: { state: ServerState }) {
  const settings = useSettings();
  const res = useResource(reservedSlots);
  const hasMod = state.modVersion !== null;
  const shineOwns = state.shine?.reservedSlots === true;
  const data = res.data;
  const refresh = [reservedSlots];

  const current = shineOwns ? (data?.shineSlots ?? null) : (data?.amount ?? null);
  const [amount, setAmount] = useState("");
  const [name, setName] = useState("");
  const [idInput, setIdInput] = useState("");
  const [busy, setBusy] = useState(false);

  const amountValue = Number(amount);
  const amountValid = amount.trim() !== "" && Number.isInteger(amountValue)
    && amountValue >= 0
    && (state.maxPlayers === null || shineOwns || amountValue <= state.maxPlayers);
  const parsedId = parseSteamId(idInput);
  const cleanName = slotName(name);
  const existing = data?.slots.find((s) => s.name === cleanName && cleanName !== "");
  const addHint = existing
    ? `A slot named ${cleanName} exists and will be replaced: the server keys slots by name.`
    : cleanName !== name.trim() && name.trim() !== ""
      ? `Saved as ${cleanName}: a slot name is one console argument, so it cannot hold spaces or quotes.`
      : idInput.trim() !== "" && parsedId === null
        ? "Not a Steam id this panel recognises."
        : null;

  const run = async (command: string) => {
    setBusy(true);
    const outcome = await sendCommand(command, hasMod, refresh);
    setBusy(false);
    return outcome;
  };

  const setSlots = async (e: Event) => {
    e.preventDefault();
    if (!amountValid || busy) return;
    const outcome = await run(slotAmountCommand(state, amountValue));
    if (outcome.tone !== "error") setAmount("");
  };

  const add = async (e: Event) => {
    e.preventDefault();
    if (parsedId === null || cleanName === "" || busy) return;
    if (existing && !confirm(
      `A slot named ${cleanName} already exists (Steam id ${existing.steamId}). `
      + "The server keys slots by name, so it will be replaced. Continue?")) return;
    const outcome = await run(addSlotCommand(cleanName, parsedId));
    if (outcome.tone !== "error") {
      setName("");
      setIdInput("");
    }
  };

  const remove = (steamId: number, slot: string) => {
    if (!confirm(`Remove the reserved slot for ${slot}?`)) return;
    void run(removeSlotCommand(steamId));
  };

  const connected = state.players.filter((p) => !p.isBot);

  return (
    <section class="wrap slots-tab">
      {shineOwns && (
        <div class="banner shine-banner">
          <h2>Shine decides reserved slots here</h2>
          <p>
            Shine's reservedslots plugin is on. It sets the slot count itself
            and grants a slot to anyone with the <code>sh_reservedslot</code>{" "}
            permission in its user config, so the list below is not what the
            server enforces. It is shown for reference and cannot be edited
            here; the count below is Shine's.
          </p>
        </div>
      )}
      {!hasMod && (
        <div class="banner">
          <h2>Stock server Lua</h2>
          <p>
            Changes are sent unverified. On the stock Lua a removed slot is
            not saved to disk until something else saves the slot config, so
            a restart before then brings it back. The mod fixes that.
          </p>
        </div>
      )}
      {data && !data.configured && !shineOwns && (
        <div class="banner">
          <h2>No reserved-slot config</h2>
          <p>
            The server reports no reserved-slot configuration, so neither the
            count nor the list can be set until it has one.
          </p>
        </div>
      )}

      <form class="form-card" onSubmit={setSlots}>
        <h2>Reserved slots</h2>
        <div class="form-row">
          <div class="read-field">
            Reserved
            <span class="read-field-value slot-count">
              {current === null ? "--" : current}
              {state.maxPlayers !== null && (
                <span class="muted">of {state.maxPlayers} player slots</span>
              )}
            </span>
          </div>
          <label>
            Set to
            <input
              type="text"
              name="amount"
              inputMode="numeric"
              value={amount}
              onInput={(e) => setAmount((e.target as HTMLInputElement).value)}
            />
          </label>
          <button class="btn" type="submit" disabled={busy || !amountValid}>Set</button>
        </div>
        {amount.trim() !== "" && !amountValid && (
          <p class="muted form-hint">
            {state.maxPlayers !== null && amountValue > state.maxPlayers
              ? `At most ${state.maxPlayers}: the server ignores anything above its player limit, without a word.`
              : "A whole number, 0 or more."}
          </p>
        )}
      </form>

      <div class="toolbar">
        <span class="muted">
          {data ? `${data.slots.length} Steam id${data.slots.length === 1 ? "" : "s"} with a slot`
            : (res.loading ? "Loading reserved slots..." : "")}
        </span>
        <span class="spacer" />
        {res.error && <span class="tone-error">{res.error.message}</span>}
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

      <div class={shineOwns ? "table-wrap read-only" : "table-wrap"}>
        <table class="slots-table">
          <thead>
            <tr>
              <th class="static">Name</th>
              <th class="static">Steam id</th>
              <th class="static">Actions</th>
            </tr>
          </thead>
          <tbody>
            {(data?.slots ?? []).map((s) => (
              <tr key={`${s.name}\u0000${s.steamId}`} data-steamid={s.steamId}>
                <td class="name-cell">{s.name}</td>
                <td>
                  <Masked value={String(s.steamId)} masked={maskSteamId(s.steamId)}
                          label="Steam id" />
                </td>
                <td>
                  <IconButton icon={UserMinus} label="Remove" danger
                              disabled={shineOwns || busy}
                              reason={shineOwns ? SHINE_REASON : undefined}
                              onClick={() => remove(s.steamId, s.name)} />
                </td>
              </tr>
            ))}
            {data && data.slots.length === 0 && (
              <tr>
                <td colSpan={3} class="muted" style="padding: 16px">
                  No Steam id has a reserved slot.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {!shineOwns && (
        <form class="form-card" onSubmit={add}>
          <h2>Give a Steam id a slot</h2>
          <div class="form-row">
            {connected.length > 0 && (
              <label>
                A connected player
                <select
                  value=""
                  onChange={(e) => {
                    const el = e.target as HTMLSelectElement;
                    const p = connected.find((x) => String(x.steamId) === el.value);
                    if (p) {
                      setName(slotName(p.name));
                      setIdInput(String(p.steamId));
                    }
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
            <label>
              Name
              <input
                type="text"
                name="slotname"
                spellcheck={false}
                autocomplete="off"
                value={name}
                onInput={(e) => setName((e.target as HTMLInputElement).value)}
              />
            </label>
            <label>
              Steam id
              <input
                type="text"
                name="slotid"
                spellcheck={false}
                autocomplete="off"
                value={idInput}
                onInput={(e) => setIdInput((e.target as HTMLInputElement).value)}
              />
            </label>
            <button class="btn" type="submit"
                    disabled={busy || parsedId === null || cleanName === ""}>
              Add
            </button>
          </div>
          {addHint && <p class="muted form-hint">{addHint}</p>}
        </form>
      )}
    </section>
  );
}
