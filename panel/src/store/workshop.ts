// The workshop search and the installs asked for from it.
//
// Both are asynchronous on the server and neither says when it is done, so
// both are polled here, measured on the 09-26 rig (REQUIREMENTS item 4):
//
//   * a search answers `loading` until it settles, 0.3-0.9 s. On a stock
//     server one that never answers restarts every 30 s and answers `loading`
//     forever, so the panel gives up on its own after 35 s. The mod settles it
//     with an error at 30 s.
//   * an install is proved only by the id appearing in getinstalledmodslist,
//     which happens once the mod is downloaded and unpacked, under its real
//     title, and never before: 1.7 s for 710 bytes, 3.8 s for 26 MB. An id
//     Steam does not have never appears, so the panel stops waiting after 3
//     minutes and says so rather than guessing.
//
// Module state, so a download keeps being watched when the tab is left.

import { useEffect, useState } from "preact/hooks";
import { ApiError, installMod, searchWorkshop } from "../api/client";
import type { WorkshopItem } from "../api/types";
import { record } from "../ui/activity";
import { installedMods } from "./resources";

export const kPollMs = 500;
const kGiveUpMs = 35_000;
const kInstallPollMs = 2_000;
const kInstallGiveUpMs = 180_000;

export type SearchState =
  | { status: "idle" }
  | { status: "loading"; query: string; startedAt: number }
  | { status: "results"; query: string; items: WorkshopItem[]; capped: boolean }
  /** The mod's timeout, or a request that failed. */
  | { status: "error"; query: string; error: string }
  /** Stock: no answer in time, and the server cannot say why. */
  | { status: "gave-up"; query: string };

export interface Install {
  id: string;
  title: string;
  askedAt: number;
  state: "downloading" | "installed" | "not-arrived" | "refused" | "failed";
  note: string | null;
}

let search: SearchState = { status: "idle" };
let installs = new Map<string, Install>();
const listeners = new Set<() => void>();

function emit() {
  for (const l of listeners) l();
}

// --------------------------------------------------------------- search

let generation = 0;
let controller: AbortController | null = null;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Start a search, abandoning any still being polled. */
export async function runSearch(query: string): Promise<void> {
  const mine = ++generation;
  controller?.abort();
  const signal = (controller = new AbortController()).signal;
  const startedAt = Date.now();
  search = { status: "loading", query, startedAt };
  emit();

  const settle = (next: SearchState) => {
    if (mine !== generation) return;
    search = next;
    emit();
  };

  while (mine === generation) {
    try {
      const r = await searchWorkshop(query, signal);
      if (mine !== generation) return;
      if (r.kind === "results") {
        return settle({ status: "results", query, items: r.items, capped: r.capped });
      }
      if (r.kind === "error") return settle({ status: "error", query, error: r.error });
    } catch (e) {
      if ((e as Error).name === "AbortError") return;
      // A busy server is ridden out; anything else ends the search.
      if (!(e instanceof ApiError && e.retryable)) {
        return settle({ status: "error", query, error: (e as Error).message });
      }
    }
    if (Date.now() - startedAt >= kGiveUpMs) return settle({ status: "gave-up", query });
    await sleep(kPollMs);
  }
}

/** Stop polling; the last result stays. Called when the tab is left. */
export function stopSearch(): void {
  generation++;
  controller?.abort();
  controller = null;
  if (search.status === "loading") {
    search = { status: "idle" };
    emit();
  }
}

// -------------------------------------------------------------- installs

let watcher: ReturnType<typeof setInterval> | null = null;

function setInstall(id: string, patch: Partial<Install>) {
  const cur = installs.get(id);
  if (!cur) return;
  installs = new Map(installs).set(id, { ...cur, ...patch });
  emit();
}

async function watch(): Promise<void> {
  await installedMods.refresh();
  const listed = new Set((installedMods.get().data ?? []).map((m) => m.id.toLowerCase()));
  const now = Date.now();
  for (const i of installs.values()) {
    if (i.state !== "downloading") continue;
    if (listed.has(i.id)) {
      setInstall(i.id, { state: "installed", note: null });
      record(`installmod ${i.id}`, `${i.title} is installed: the server lists it now.`);
    } else if (now - i.askedAt >= kInstallGiveUpMs) {
      setInstall(i.id, { state: "not-arrived", note: null });
      record(`installmod ${i.id}`,
        `${i.title} is still not installed after ${kInstallGiveUpMs / 60_000} minutes. `
        + "The download may have failed; the server does not report why.", "error");
    }
  }
  if (![...installs.values()].some((i) => i.state === "downloading") && watcher !== null) {
    clearInterval(watcher);
    watcher = null;
  }
}

/** Ask the server to download a mod, and watch the installed list for it. */
export async function requestInstall(item: WorkshopItem, hasMod: boolean): Promise<void> {
  const id = item.id.toLowerCase();
  const command = `installmod ${id}`;
  installs = new Map(installs).set(id, {
    id, title: item.title, askedAt: Date.now(), state: "downloading", note: null,
  });
  emit();

  try {
    const result = await installMod(id, hasMod);
    if (result.kind === "refused") {
      setInstall(id, { state: "refused", note: result.error });
      record(command, `refused, nothing sent: ${result.error}`, "error");
      return;
    }
    record(command, result.kind === "unverified"
      ? "sent. This server does not answer; the installed list will show whether it downloads."
      : result.alreadyInstalled
        ? "already installed. The server checks it for an update."
        : "download asked for. Waiting for the server to list it.");
  } catch (e) {
    setInstall(id, { state: "failed", note: (e as Error).message });
    record(command, `could not be sent: ${(e as Error).message}`, "error");
    return;
  }

  void watch();
  if (watcher === null) watcher = setInterval(() => void watch(), kInstallPollMs);
}

// ------------------------------------------------------------------ hook

export function useWorkshop(): { search: SearchState; installs: Map<string, Install> } {
  const [, force] = useState(0);
  useEffect(() => {
    const listener = () => force((n) => n + 1);
    listeners.add(listener);
    return () => { listeners.delete(listener); };
  }, []);
  return { search, installs };
}
