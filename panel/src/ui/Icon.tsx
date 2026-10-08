// Icons for table buttons and statuses, from Lucide, bundled
// like every other dependency: only the icons imported here end up in the
// build.
//
// An icon never stands alone. Each one carries its words twice: as `title`,
// for the pointer, and as visually hidden text, for screen readers, copy and
// paste, and the gates, which match on the words and not on the drawing.

import type { ComponentChildren } from "preact";
import type { LucideIcon } from "lucide-preact";

export type { LucideIcon };

type Tone = "ok" | "warn" | "danger" | "dim";

interface ButtonProps {
  icon: LucideIcon;
  /** What the button does, in words: its title and its accessible name. */
  label: string;
  /** Why it is disabled, when it is; added to the title. */
  reason?: string | undefined;
  disabled?: boolean;
  danger?: boolean;
  /** More classes, for the row's own styling and the gates. */
  extraClass?: string;
  /** data-* attributes, as given. */
  data?: Record<string, string>;
  /** For a button that opens something below it. */
  expanded?: boolean;
  onClick: () => void;
}

export function IconButton(
  { icon: I, label, reason, disabled, danger, extraClass, data, expanded, onClick }: ButtonProps,
) {
  const attrs = Object.fromEntries(Object.entries(data ?? {}).map(([k, v]) => [`data-${k}`, v]));
  return (
    <button type="button"
            class={`btn btn-sm btn-icon${danger ? " btn-danger" : ""}${extraClass ? ` ${extraClass}` : ""}`}
            title={reason ? `${label}: ${reason}` : label}
            disabled={disabled}
            aria-expanded={expanded}
            onClick={onClick}
            {...attrs}>
      <I size={15} aria-hidden="true" />
      <span class="sr-only">{label}</span>
    </button>
  );
}

interface StatusProps {
  icon: LucideIcon;
  /** The status in words. */
  label: string;
  /** A longer explanation for the tooltip; the label when absent. */
  title?: string | undefined;
  tone?: Tone;
  children?: ComponentChildren;
}

/** A status shown as an icon, with its words on hover and to assistive tech. */
export function StatusIcon({ icon: I, label, title, tone, children }: StatusProps) {
  return (
    <span class={`status-icon${tone ? ` tone-${tone}` : ""}`}
          title={title ? `${label}: ${title}` : label}>
      <I size={16} aria-hidden="true" />
      <span class="sr-only">{label}</span>
      {children}
    </span>
  );
}
