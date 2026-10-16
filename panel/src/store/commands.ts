import { runCommand } from "../api/client";
import type { ServerState } from "../api/types";
import { record } from "../ui/activity";
import { consoleArg, slotName } from "../ui/format";
import type { Resource } from "./poll";
import { serverState } from "./resources";

// Shine ends every command it runs with this receipt. Like the vanilla audit
// line it proves the command ran, and it repeats the command line, so it is
// not what the command said.
const kShineReceipt = /^Console\[N\/A\] ran command \S+ with arguments:/;

/**
 * Send a console command and report what it printed.
 *
 * Note what an empty result means: the command ran and printed nothing. That is the normal case for a kick that worked -- only the failure
 * branch prints -- so it is reported as "no output", never as success.
 */
export interface CommandOutcome {
  command: string;
  note: string;
  tone: "sent" | "error";
  /** What the command printed, line by line; empty when it printed nothing. */
  output: string[];
}

export async function sendCommand(
  command: string,
  /** Lists the command may have changed, re-read once it has run. */
  refresh: Resource<unknown>[] = [],
): Promise<CommandOutcome> {
  const finish = (note: string, tone: "sent" | "error", output: string[] = [])
    : CommandOutcome => {
    record(command, note, tone);
    return { command, note, tone, output };
  };

  try {
    let outcome: CommandOutcome;
    const result = await runCommand(command);

    const receipt = result.lines.some((l) => kShineReceipt.test(l.text));
    const output = result.lines.filter((l) =>
      l.src !== "audit" && !kShineReceipt.test(l.text));
    if (output.length > 0) {
      outcome = finish(output.map((l) => l.text).join(" | "), "sent",
        output.map((l) => l.text));
    } else if (result.dispatched || receipt) {
      // The ordinary case for a command that worked: only failure branches
      // print. Said plainly, and not dressed up as success.
      outcome = finish("ran, and printed nothing.", "sent");
    } else {
      outcome = finish(
        "is not an admin command. Either a plain console command, or no "
        + "such command -- the server does not distinguish the two.", "error");
    }

    // Re-read the state so the tables reflect whatever did happen. This is a
    // refresh, not a result: the server may not have caught up yet.
    await Promise.all([serverState, ...refresh].map((r) => r.refresh()));
    return outcome;
  } catch (e) {
    return finish(`could not be sent: ${(e as Error).message}`, "error");
  }
}

// ------------------------------------------------------- command lines
//
// Which command does a job depends on who owns it. Under Shine's ban plugin a
// vanilla sv_ban of an id that is not connected prints "has been banned" and
// lands only in the vanilla list, which nothing enforces -- a phantom ban.
// So Shine's own commands are used whenever the server says Shine owns the
// job.

/** Ban an id for `minutes` (0 is permanent). Kicks the player if connected. */
export function banCommand(state: ServerState, steamId: number, minutes: number,
                           reason: string): string {
  const why = consoleArg(reason) || "WebUI";
  const verb = state.shine?.bans ? "sh_banid" : "sv_ban";
  return `${verb} ${steamId} ${Math.max(0, Math.round(minutes))} ${why}`;
}

export function unbanCommand(state: ServerState, steamId: number): string {
  return `${state.shine?.bans ? "sh_unban" : "sv_unban"} ${steamId}`;
}

/**
 * Set the reserved slot count. sv_reserved_slots, not the
 * setreservedslotamount request: the command says what it did.
 */
export function slotAmountCommand(state: ServerState, amount: number): string {
  const n = Math.max(0, Math.round(amount));
  return state.shine?.reservedSlots ? `sh_setresslots ${n}` : `sv_reserved_slots ${n}`;
}

export function addSlotCommand(name: string, steamId: number): string {
  return `sv_add_reserved_slot ${slotName(name) || "None"} ${steamId}`;
}

export function removeSlotCommand(steamId: number): string {
  return `sv_remove_reserved_slot ${steamId}`;
}

/** No argument removes it: SetPassword passes "" for a missing one. */
export function passwordCommand(password: string): string {
  return password === "" ? "sv_password" : `sv_password ${password}`;
}
