// The shared resources. Tabs subscribe to these rather than fetching for
// themselves, so two tabs open on the same data cost one request. A resource
// polls only while something is subscribed, so the ban and slot lists cost
// nothing until their tab is open.

import {
  getBans, getInstalledMods, getMapList, getMapVote, getRecentPlayers,
  getReservedSlots, getServerState, getWhitelist,
} from "../api/client";
import { createResource } from "./poll";
import { getSettings } from "./settings";

export const serverState = createResource(
  getServerState, getSettings().refreshSeconds * 1000);

// Lists that change only when someone acts on them, and the panel refreshes
// them itself after each command it sends. A slow poll catches the rest.
export const kListIntervalMs = 10_000;

// Which request answers depends on the server: getbans needs the mod.
export const bans = createResource(
  (signal) => getBans(serverState.get().data?.modVersion != null, signal),
  kListIntervalMs);

export const reservedSlots = createResource(getReservedSlots, kListIntervalMs);

// Mod only; the tab does not subscribe on a stock server.
export const recentPlayers = createResource(getRecentPlayers, kListIntervalMs);

// What the server can load. Changes only when a mod is installed, so polled
// rarely; the Maps tab refreshes them itself when it opens.
export const kCatalogueIntervalMs = 60_000;
export const mapList = createResource(getMapList, kCatalogueIntervalMs);
export const installedMods = createResource(getInstalledMods, kCatalogueIntervalMs);

// Mod only, and only asked while Shine's mapvote is on. Its next map moves
// when a vote ends, so it keeps the list pace.
export const mapVote = createResource(getMapVote, kListIntervalMs);

// Mod only. The server reads Steam at most once an hour, so the list moves
// rarely; while a read runs, the whitelist hook asks again sooner.
export const whitelist = createResource(getWhitelist, kCatalogueIntervalMs);
