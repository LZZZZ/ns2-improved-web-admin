import { useEffect, useState } from "preact/hooks";
import {
  REFRESH_CHOICES, resetSettings, storageOk, systemTheme, updateSettings,
  useSettings,
} from "../store/settings";
import type { ClockFormat, Settings as SettingsShape, Theme } from "../store/settings";
import { clock } from "../ui/format";

/**
 * Everything the panel remembers, in one place, with what each one costs.
 *
 * The tabs keep their own shortcuts (the mask checkbox, the footer's refresh
 * and theme); they write the same values. Workshop thumbnails have none, by
 * a decision of 2026-10-07: they are set here only. This tab needs no
 * server data, so it works while the server cannot be reached -- which is
 * when turning refresh off matters most.
 */
export function Settings() {
  const settings = useSettings();
  const now = useNow();

  const checkbox = (key: keyof SettingsShape, name: string, label: string) => (
    <label class="check">
      <input type="checkbox" name={name} checked={settings[key] as boolean}
             onChange={(e) => updateSettings({
               [key]: (e.target as HTMLInputElement).checked })} />
      {label}
    </label>
  );

  const refreshSelect = (key: "refreshSeconds" | "consoleRefreshSeconds" | "logRefreshSeconds",
                         name: string, label: string) => (
    <label>
      {label}
      <select name={name} value={String(settings[key])}
              onChange={(e) => updateSettings({
                [key]: Number((e.target as HTMLSelectElement).value) })}>
        {REFRESH_CHOICES.map((s) => (
          <option key={s} value={String(s)}>{s === 0 ? "off" : `every ${s} s`}</option>
        ))}
      </select>
    </label>
  );

  const THEMES: { value: Theme; label: string }[] = [
    { value: "dark", label: "Dark" },
    { value: "light", label: "Light" },
    { value: "system", label: `As the system is (now ${systemTheme()})` },
  ];

  const CLOCKS: { value: ClockFormat; label: string }[] = [
    { value: "locale", label: "As this browser writes times" },
    { value: "24h", label: "24-hour" },
    { value: "utc", label: "UTC, 24-hour" },
  ];

  const reset = () => {
    if (confirm("Put every setting back to its default? This cannot be undone.")) {
      resetSettings();
    }
  };

  return (
    <section class="wrap settings-tab">
      <div class="form-card">
        <h2>Privacy</h2>
        {checkbox("hideIdentifiers", "mask", "Mask Steam ids and IPs")}
      </div>

      <div class="form-card">
        <h2>Refresh</h2>
        <div class="form-row">
          {refreshSelect("refreshSeconds", "refresh-state",
            "Server state: the header and Players")}
          {refreshSelect("consoleRefreshSeconds", "refresh-chat", "Chat")}
          {refreshSelect("logRefreshSeconds", "refresh-log", "Console, while its tab is open")}
        </div>
      </div>

      <div class="form-card">
        <h2>Appearance</h2>
        <div class="settings-choices">
          <div role="radiogroup" aria-label="Theme">
            <h3>Theme</h3>
            {THEMES.map((t) => (
              <label key={t.value} class="check">
                <input type="radio" name="theme" value={t.value}
                       checked={settings.theme === t.value}
                       onChange={() => updateSettings({ theme: t.value })} />
                {t.label}
              </label>
            ))}
          </div>
          <div role="radiogroup" aria-label="Times">
            <h3>Times</h3>
            {CLOCKS.map((c) => (
              <label key={c.value} class="check">
                <input type="radio" name="clock" value={c.value}
                       checked={settings.clock === c.value}
                       onChange={() => updateSettings({ clock: c.value })} />
                {c.label}{" "}
                <span class="muted mono clock-sample" data-clock={c.value}>
                  {clock(now, c.value)}{c.value === "utc" && " UTC"}
                </span>
              </label>
            ))}
          </div>
        </div>
      </div>

      <div class="form-card">
        <h2>Workshop</h2>
        {checkbox("modThumbnails", "thumbnails", "Show thumbnails, loaded from Steam")}
      </div>

      <div class="form-card">
        <h2>Remembered</h2>
        <div class="settings-stack">
          {checkbox("reopenLastTab", "reopen", "Open on the tab last used, rather than Players")}
          {checkbox("playersHideBots", "hide-bots", "Players: hide bots")}
        </div>
      </div>

      <div class="settings-foot">
        {!storageOk && (
          <p class="tone-error settings-storage">
            This browser refuses to keep them (a private window, or site data
            blocked), so they last until this page closes.
          </p>
        )}
        <button class="btn settings-reset" onClick={reset}>Reset to defaults</button>
      </div>
    </section>
  );
}

/** The time now, ticking while the tab is open, for the clock samples. */
function useNow(): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  return now;
}
