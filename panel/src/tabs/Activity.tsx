import { useActivity } from "../ui/activity";
import { clock } from "../ui/format";

/**
 * Every command this page has sent, newest first, and what is known about
 * each. The tab a command was sent from shows only its latest.
 *
 * Kept in this page's memory, not in the browser's storage: a reload starts
 * it empty, and another admin's commands never appear here. The Console and
 * Log tabs are the server's own record.
 */
export function Activity({ tabLabel }: { tabLabel: (id: string) => string }) {
  const entries = useActivity();
  return (
    <section class="wrap activity-tab">
      <p class="muted form-hint">
        The last {entries.length === 1 ? "command" : `${entries.length} commands`} this
        page sent, newest first, up to 100. A reload clears the list, and it
        holds only what was sent from here; the Console and Log tabs show what
        the server ran.
      </p>
      {entries.length === 0 ? (
        <p class="muted">Nothing sent from this page yet.</p>
      ) : (
        <div class="table-wrap">
          <table class="activity-table">
            <thead>
              <tr>
                <th class="static">Time</th>
                <th class="static">From</th>
                <th class="static">Command</th>
                <th class="static">Result</th>
              </tr>
            </thead>
            <tbody>
              {entries.map((e) => (
                <tr key={e.id}>
                  <td class="mono muted"><time>{clock(e.at)}</time></td>
                  <td class="muted">{tabLabel(e.tab)}</td>
                  <td class="mono cmd">{e.command}</td>
                  <td class={`note${e.tone === "error" ? " tone-error" : ""}`}>{e.note}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
