import { Unplug } from "lucide-preact";
import { useEffect, useState } from "preact/hooks";
// The N/S monogram, 32x32 (2026-10-07); a drop-in file, and
// the favicon too (index.html). Shown at its own size: scaled up, it blurs.
import logoUrl from "../assets/ns2-logo.png";
import { Activity } from "../tabs/Activity";
import { Bans } from "../tabs/Bans";
import { Chat } from "../tabs/Chat";
import { Log } from "../tabs/Log";
import { Maps } from "../tabs/Maps";
import { Performance } from "../tabs/Performance";
import { Mods } from "../tabs/Mods";
import { Players } from "../tabs/Players";
import { Recent } from "../tabs/Recent";
import { Settings } from "../tabs/Settings";
import { Slots } from "../tabs/Slots";
import { Workshop } from "../tabs/Workshop";
import { serverState } from "../store/resources";
import { useResource } from "../store/poll";
import {
  getSettings, REFRESH_CHOICES, updateSettings, useSettings,
} from "../store/settings";
import { setActivityTab, useActivity } from "./activity";
import { clock, duration } from "./format";

// The six tabs the shipped panel has, plus what the mod's Lua makes possible:
// recent players, and the server's log with its command line (one tab since
// 2026-10-07; it was Console and Log). The 2012 Mods tab is two here:
// Mods loads and unloads what is installed, Workshop finds and downloads; and
// the chat its Players tab carried is a tab of its own. In the order
// settled on 2026-10-07.
// Activity lists every command the page sent; the tab a command came from
// shows its latest in one line at the foot, except on chat and the log,
// which already show what a command did. Settings is last, and the one tab
// that needs no server data. Tabs not built yet are listed so the shape of the
// finished panel is visible, and disabled so nothing claims to work yet.
const TABS = [
  { id: "players", label: "Players", ready: true },
  { id: "recent", label: "Recent players", ready: true },
  { id: "bans", label: "Bans", ready: true },
  { id: "chat", label: "Chat", ready: true },
  { id: "maps", label: "Maps", ready: true },
  { id: "mods", label: "Mods", ready: true },
  { id: "workshop", label: "Workshop", ready: true },
  { id: "slots", label: "Reserved Slots", ready: true },
  { id: "performance", label: "Performance", ready: true },
  { id: "log", label: "Console", ready: true },
  { id: "activity", label: "Activity", ready: true },
  { id: "settings", label: "Settings", ready: true },
] as const;

type TabId = (typeof TABS)[number]["id"];

/** Tabs that show what a command did themselves, or are the list. */
const NO_CONFIRMATION = new Set<string>(["chat", "log", "activity", "settings"]);

const tabLabel = (id: string) => TABS.find((t) => t.id === id)?.label ?? id;

/** The last tab used, if the setting asks for it and it is still a tab. */
function initialTab(): TabId {
  const { reopenLastTab, lastTab } = getSettings();
  // Console merged into the log tab (2026-10-07).
  const wanted = lastTab === "console" ? "log" : lastTab;
  const found = TABS.find((t) => t.id === wanted && t.ready);
  return reopenLastTab && found ? found.id : "players";
}

export function App() {
  const settings = useSettings();
  const state = useResource(serverState);
  const activity = useActivity();
  const [tab, setTab] = useState<TabId>(initialTab);
  // Before any command can be sent from it.
  setActivityTab(tab);
  const lastHere = activity.find((e) => e.tab === tab) ?? null;
  // What the Mods tab opens filtered to, when the Workshop tab sends it there.
  // Not remembered: a reload opens Mods unfiltered.
  const [modsFilter, setModsFilter] = useState("");

  const goTo = (id: TabId, filter = "") => {
    setModsFilter(filter);
    setTab(id);
    if (getSettings().lastTab !== id) updateSettings({ lastTab: id });
  };

  useEffect(() => {
    serverState.setIntervalMs(settings.refreshSeconds * 1000);
  }, [settings.refreshSeconds]);

  const data = state.data;

  return (
    <div class="app">
      <header class="header">
        <div class="wrap header-row">
          <img class="logo" src={logoUrl} width={32} height={32} alt="Natural Selection 2" />
          <h1 class="server-name" title={data?.serverName ?? ""}>
            {data?.serverName ?? "Connecting..."}
          </h1>
          {data && (
            <div class="stats">
              <span class="stat">map <b>{data.map}</b></span>
              <span class="stat">
                players <b>{data.playersOnline}</b>
                {" "}<span class="muted">
                  ({data.marines}v{data.aliens})
                </span>
              </span>
              <span class="stat">tickrate <b>{data.frameRate.toFixed(1)}</b></span>
              <span class="stat">uptime <b>{duration(data.uptimeSeconds)}</b></span>
              {data.gameStarted && (
                <span class="stat">round <b>{duration(data.gameTimeSeconds)}</b></span>
              )}
              {data.shine && (
                <span class="tag" title={shineTitle(data.shine)}>SHINE</span>
              )}
              {data.cheats && <span class="tag">CHEATS</span>}
              {data.devMode && <span class="tag">DEVMODE</span>}
            </div>
          )}
        </div>
      </header>

      <nav class="tabs" role="tablist">
        {TABS.map((t) => (
          <button
            key={t.id}
            class="tab"
            role="tab"
            aria-selected={tab === t.id}
            disabled={!t.ready}
            title={t.ready ? undefined : "Not built yet"}
            onClick={() => goTo(t.id)}
          >
            {t.label}
          </button>
        ))}
      </nav>

      <main>
        {state.error && (
          <div class="wrap">
            <div class="banner banner-error">
              <h2><Unplug size={16} aria-hidden="true" />Cannot reach the server</h2>
              <p>{state.error.message}. Still polling.</p>
            </div>
          </div>
        )}

        {data && data.modVersion === null && (
          <div class="wrap">
            <div class="banner">
              <h2>Stock server Lua</h2>
              <p>
                This server runs the game's own web interface, so command
                results cannot be read back, Unban cannot match a ban, and
                the panel cannot tell whether Shine owns bans or slots.
                Commands still send; the panel reports them as unverified
                rather than guessing.
              </p>
            </div>
          </div>
        )}

        {!data && state.loading && tab !== "settings" && (
          <div class="wrap"><p class="muted">Loading server state...</p></div>
        )}

        {data && tab === "players" && <Players state={data} />}
        {data && tab === "bans" && <Bans state={data} />}
        {data && tab === "recent" && <Recent state={data} />}
        {data && tab === "maps" && <Maps state={data} />}
        {data && tab === "mods" && <Mods state={data} initialFilter={modsFilter} />}
        {data && tab === "workshop" && (
          <Workshop state={data} onOpenMods={(id) => goTo("mods", id)} />
        )}
        {data && tab === "slots" && <Slots state={data} />}
        {data && tab === "performance" && (
          <Performance state={data} onOpenSettings={() => goTo("settings")} />
        )}
        {data && tab === "chat" && (
          <Chat state={data} onOpenSettings={() => goTo("settings")} />
        )}
        {data && tab === "log" && (
          <Log state={data} onOpenSettings={() => goTo("settings")} />
        )}
        {tab === "activity" && <Activity tabLabel={tabLabel} />}
        {tab === "settings" && <Settings state={state.error ? null : data} />}
      </main>

      {lastHere && !NO_CONFIRMATION.has(tab) && (
        <div class="cmd-confirm" aria-live="polite">
          <div class="wrap">
            <time>{clock(lastHere.at)}</time>
            <span class="cmd">{lastHere.command}</span>
            <span class={lastHere.tone === "error" ? "note tone-error" : "note"}>
              {lastHere.note}
            </span>
            <span class="spacer" />
            <button class="link-button" onClick={() => goTo("activity")}>
              All activity ({activity.length})
            </button>
          </div>
        </div>
      )}

      <footer class="statusbar">
        <div class="wrap">
          <span>
            <span
              class={`dot ${state.error ? "dot-error"
                : (settings.refreshSeconds > 0 ? "dot-ok" : "dot-idle")}`}
            />{" "}
            {state.updatedAt
              ? `updated ${clock(state.updatedAt)}`
              : "never updated"}
          </span>
          <label title="Server state: the header and Players. Chat and the log have their own, in Settings.">
            refresh{" "}
            <select
              value={String(settings.refreshSeconds)}
              onChange={(e) => updateSettings({
                refreshSeconds: Number((e.target as HTMLSelectElement).value),
              })}
            >
              {REFRESH_CHOICES.map((s) => (
                <option key={s} value={String(s)}>{s === 0 ? "off" : `${s}s`}</option>
              ))}
            </select>
          </label>
          <button class="btn btn-sm" onClick={() => void serverState.refresh()}>
            Refresh now
          </button>
          <span class="spacer" />
          <label>
            theme{" "}
            <select
              value={settings.theme}
              onChange={(e) => updateSettings({
                theme: (e.target as HTMLSelectElement).value as
                  "dark" | "light" | "system",
              })}
            >
              <option value="dark">dark</option>
              <option value="light">light</option>
              <option value="system">system</option>
            </select>
          </label>
          <button class="link-button muted" onClick={() => goTo("settings")}>
            settings are saved in this browser only
          </button>
        </div>
      </footer>
    </div>
  );
}

function shineTitle(shine: { bans: boolean; reservedSlots: boolean; mapVote: boolean }): string {
  const owns = [
    shine.bans && "bans",
    shine.reservedSlots && "reserved slots",
    shine.mapVote && "the map vote",
  ].filter(Boolean);
  return owns.length
    ? `Shine is loaded and owns ${owns.join(", ")}.`
    : "Shine is loaded; none of the plugins that replace the game's own are on.";
}
