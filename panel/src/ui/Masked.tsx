import { useState } from "preact/hooks";
import { useSettings } from "../store/settings";

/**
 * A value that is hidden until the admin asks for it.
 *
 * Player rows carry full IP addresses and Steam ids over plain HTTP, so they
 * are masked by default and revealed per row. Revealing is per component
 * instance and does not survive a tab change -- the sticky version is a
 * setting, not a click.
 */
export function Masked(props: { value: string; masked: string; label: string }) {
  const settings = useSettings();
  const [revealed, setRevealed] = useState(false);

  if (!settings.maskIdentifiers || revealed) {
    return <span class="revealed" title={props.label}>{props.value}</span>;
  }
  return (
    <button
      class="masked"
      title={`Show ${props.label}`}
      onClick={() => setRevealed(true)}
    >
      {props.masked}
    </button>
  );
}
