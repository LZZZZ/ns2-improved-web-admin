// What the panel has done, and what it can honestly say about the result.
//
// Every command sent from the panel lands here. On a stock server the entry
// says the result is unverified, because it is: the reply to a command is the
// ordinary state blob, built before the command's effect lands. The 2012
// panel's timed refresh, which implied success it never checked, is the thing
// this exists to not repeat.
//
// The full list is the Activity tab's. The tab a command was sent from shows
// its own latest one in a single line, so an entry remembers the tab that was
// open when it was recorded. A command answers within a second or two, so
// that is the tab it was sent from; an install that lands minutes later is
// reported on whichever tab is open then.

import { useEffect, useState } from "preact/hooks";

export interface Entry {
  id: number;
  at: number;
  /** The tab open when it was recorded. */
  tab: string;
  command: string;
  note: string;
  tone: "sent" | "error";
}

const MAX = 100;
let entries: Entry[] = [];
let nextId = 1;
let currentTab = "";
const listeners = new Set<() => void>();

function emit() {
  for (const l of listeners) l();
}

export function record(command: string, note: string, tone: Entry["tone"] = "sent") {
  entries = [{ id: nextId++, at: Date.now(), tab: currentTab, command, note, tone },
             ...entries].slice(0, MAX);
  emit();
}

/** Which tab is open, for the entries recorded from now on. */
export function setActivityTab(tab: string) {
  currentTab = tab;
}

export function useActivity(): Entry[] {
  const [, force] = useState(0);
  useEffect(() => {
    const listener = () => force((n) => n + 1);
    listeners.add(listener);
    return () => { listeners.delete(listener); };
  }, []);
  return entries;
}
