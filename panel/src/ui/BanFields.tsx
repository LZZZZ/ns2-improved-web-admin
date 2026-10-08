import { span } from "./format";

// The terms of a ban, shared by every form that bans: the Bans tab's own and
// the Recent players tab's per-row one. Which command carries them is decided
// in one place only, banCommand in store/commands.ts.

// Presets in minutes, the unit both sv_ban and sh_banid take. 0 is permanent.
const DURATIONS: { minutes: number; label: string }[] = [
  { minutes: 60, label: "1 hour" },
  { minutes: 1440, label: "1 day" },
  { minutes: 10080, label: "1 week" },
  { minutes: 43200, label: "30 days" },
  { minutes: 0, label: "Permanent" },
];

export interface BanTerms {
  /** A preset, or -1 for the custom field. */
  minutes: number;
  custom: string;
  reason: string;
}

export const DEFAULT_TERMS: BanTerms = { minutes: 1440, custom: "", reason: "" };

/** The duration in minutes, or null while the custom field is not a count. */
export function banMinutes(terms: BanTerms): number | null {
  const minutes = terms.minutes === -1 ? Number(terms.custom) : terms.minutes;
  return Number.isInteger(minutes) && minutes >= 0 ? minutes : null;
}

/** "permanently" or "for 1d", for a confirmation. */
export function banSpan(minutes: number): string {
  return minutes === 0 ? "permanently" : `for ${span(minutes * 60)}`;
}

/** Duration, custom minutes and reason, as labels for a `.form-row`. */
export function BanFields(
  { terms, onChange }: { terms: BanTerms; onChange: (terms: BanTerms) => void },
) {
  return (
    <>
      <label>
        Duration
        <select
          name="duration"
          value={String(terms.minutes)}
          onChange={(e) => onChange({
            ...terms, minutes: Number((e.target as HTMLSelectElement).value),
          })}
        >
          {DURATIONS.map((d) => (
            <option key={d.minutes} value={String(d.minutes)}>{d.label}</option>
          ))}
          <option value="-1">Minutes...</option>
        </select>
      </label>
      {terms.minutes === -1 && (
        <label>
          Minutes
          <input
            type="text"
            name="minutes"
            inputMode="numeric"
            value={terms.custom}
            onInput={(e) => onChange({
              ...terms, custom: (e.target as HTMLInputElement).value,
            })}
          />
        </label>
      )}
      <label class="grow">
        Reason
        <input
          type="text"
          name="reason"
          placeholder="WebUI"
          value={terms.reason}
          onInput={(e) => onChange({
            ...terms, reason: (e.target as HTMLInputElement).value,
          })}
        />
      </label>
    </>
  );
}
