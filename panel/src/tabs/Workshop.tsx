import { CircleCheck, HardDriveDownload } from "lucide-preact";
import { useEffect, useState } from "preact/hooks";
import type { InstalledMod, ServerState, WorkshopItem } from "../api/types";
import { useResource } from "../store/poll";
import { installedMods } from "../store/resources";
import { useSettings } from "../store/settings";
import {
  requestInstall, runSearch, stopSearch, useWorkshop, type Install, type SearchState,
} from "../store/workshop";
import { dateTime, duration, fileSize } from "../ui/format";
import { StatusIcon } from "../ui/Icon";
import {
  useWhitelist, whitelistVerdict, WhitelistIcon, WhitelistSource, type Whitelist,
} from "../ui/whitelist";
import { workshopId } from "./Mods";

// Search the Steam workshop through the server, read a mod's details, and
// download it. Loading a downloaded mod is the Mods tab's: it is a map cycle
// edit, with rules (engine mods, map mods, dependents) that live there.
//
// Measured on the 09-26 rig (REQUIREMENTS item 4), and each one shapes what
// this tab says:
//
//   * a search returns its first 50 hits and nothing more. The page is
//     ignored, so there is no paging, only a narrower search.
//   * an empty result is no matches or a search Steam failed; the server
//     cannot tell them apart, so the tab says both.
//   * a download is proved only by the installed list, which lists a mod once
//     it is downloaded and never before.
//
// Nothing here fetches from Steam in this browser unless the operator turns
// thumbnails on, in Settings (off by default, REQUIREMENTS items 4 and 9). The
// search does not start until the tab is opened.
//
// Each result says whether it is whitelisted before it is installed: from
// Steam's list as the server read it, or the copy the panel ships.

/** Where to find a mod the first 50 do not reach. */
const kWorkshopUrl = "https://steamcommunity.com/app/4920/workshop/";

/** Steam BBCode as plain text. Rendered as a text node, so markup stays text. */
export function bbcodeToText(source: string): string {
  return source
    .replace(/\r\n?/g, "\n")
    .replace(/\[img\][\s\S]*?\[\/img\]/gi, "")
    .replace(/\[url=([^\]]*)\]([\s\S]*?)\[\/url\]/gi,
             (_, href: string, text: string) => {
               const label = text.trim();
               return label && label !== href.trim() ? `${label} (${href.trim()})` : href.trim();
             })
    .replace(/\[\*\]/g, "\n• ")
    .replace(/\[\/?(?:b|i|u|s|strike|h[1-6]|list|olist|code|quote|spoiler|noparse|hr|table|tr|th|td|url|img)(?:=[^\]]*)?\]/gi, "")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Long enough for any real query; a 3000-character one failed Digest auth. */
const kMaxQuery = 200;

export function Workshop({ state, onOpenMods, onOpenSettings }: {
  state: ServerState;
  onOpenMods: (id: string) => void;
  onOpenSettings: () => void;
}) {
  const hasMod = state.modVersion !== null;
  const settings = useSettings();
  const { search, installs } = useWorkshop();
  const mods = useResource(installedMods);
  const whitelist = useWhitelist(hasMod);
  const [query, setQuery] = useState(search.status === "idle" ? "" : search.query);
  const [open, setOpen] = useState<string | null>(null);

  // Opening the tab is what starts a search: the 2012 panel searched on every
  // page load, for a tab nobody had opened (CURRENT-UI defect 13). Coming back
  // shows the last result without asking again.
  useEffect(() => {
    if (search.status === "idle") void runSearch("");
    void installedMods.refresh();
    return () => stopSearch();
  }, []);

  // A download in progress says how long ago it was asked for.
  const downloading = [...installs.values()].some((i) => i.state === "downloading");
  const [, tick] = useState(0);
  useEffect(() => {
    if (!downloading) return;
    const t = setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(t);
  }, [downloading]);

  const installed = new Map((mods.data ?? []).map((m) => [m.id.toLowerCase(), m]));

  const submit = (e: Event) => {
    e.preventDefault();
    // What the box holds now, not the last render's copy of it.
    const input = (e.currentTarget as HTMLFormElement)
      .elements.namedItem("workshop-query") as HTMLInputElement;
    setQuery(input.value);
    setOpen(null);
    void runSearch(input.value.trim());
  };

  const install = (item: WorkshopItem) => {
    const verdict = whitelistVerdict(whitelist, item.id);
    if (!confirm(
      `Download "${item.title}" to the server?\n\n`
      + "This only downloads it. It loads once the Mods tab adds it, at the next "
      + "map change.\n"
      + "Nothing in the game can delete a downloaded mod afterwards.\n"
      + (verdict === "not"
        ? "It is not whitelisted: loading it turns ranking off."
        : verdict === "unknown"
          ? "Loading a mod that is not whitelisted turns ranking off."
          : "It is whitelisted: loading it keeps the server ranked."))) {
      return;
    }
    void requestInstall(item, hasMod);
  };

  return (
    <section class="wrap workshop-tab">
      <div class="form-card">
        <form class="form-row" onSubmit={submit}>
          <label class="grow">
            Search the workshop
            <input type="text" name="workshop-query" value={query} maxLength={kMaxQuery}
                   placeholder="Title or words from the description"
                   onInput={(e) => setQuery((e.target as HTMLInputElement).value)} />
          </label>
          <button class="btn" type="submit">Search</button>
        </form>
        <p class="muted form-hint">
          Looking for a particular mod? Find it on the{" "}
          <a href={kWorkshopUrl} target="_blank" rel="noreferrer noopener"
             title="Opens Steam (leaves this panel)">Steam Workshop</a>, then search
          here for its title. Installing downloads a mod to the server; the Mods
          tab loads it, at the next map change.
          {!settings.modThumbnails && (
            <>
              {" "}Thumbnails are off; they load from Steam, and{" "}
              <button type="button" class="link-button" onClick={onOpenSettings}>
                Settings
              </button>{" "}turns them on.
            </>
          )}
        </p>
        <WhitelistSource list={whitelist} hasMod={hasMod} />
      </div>

      <SearchStatus search={search} hasMod={hasMod} onRetry={() => void runSearch(
        search.status === "idle" ? "" : search.query)} />

      {search.status === "results" && search.items.length > 0 && (
        <div class="table-wrap">
          <table class="workshop-table">
            <thead>
              <tr>
                {settings.modThumbnails && <th class="static" aria-label="Thumbnail" />}
                <th class="static">Mod</th>
                <th class="static num">Size</th>
                <th class="static">Updated</th>
                <th class="static">Status</th>
                <th class="static">Actions</th>
              </tr>
            </thead>
            <tbody>
              {search.items.map((item) => {
                const id = item.id.toLowerCase();
                return (
                  <ResultRow key={id} item={item} thumbnails={settings.modThumbnails}
                             open={open === id}
                             whitelist={whitelist}
                             installed={installed.get(id) ?? null}
                             install={installs.get(id) ?? null}
                             onToggle={() => setOpen(open === id ? null : id)}
                             onInstall={() => install(item)}
                             onOpenMods={() => onOpenMods(id)} />
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function SearchStatus(
  { search, hasMod, onRetry }: { search: SearchState; hasMod: boolean; onRetry: () => void },
) {
  const what = (q: string) => (q ? <>for <b class="query">{q}</b></> : "for everything");
  switch (search.status) {
    case "idle":
      return null;
    case "loading":
      return <p class="search-status muted">Searching the workshop {what(search.query)}...</p>;
    case "results":
      if (search.items.length === 0) {
        return (
          <p class="search-status note-warn">
            Nothing found {what(search.query)}. Either nothing matches, or the
            server could not reach Steam: it cannot tell the two apart.
          </p>
        );
      }
      return (
        <p class="search-status">
          <b>{search.items.length}</b> {search.items.length === 1 ? "result" : "results"}{" "}
          {what(search.query)}.
          {search.capped && (
            <span class="muted">
              {" "}Only the first 50: if the mod is not here, find it on the{" "}
              <a href={kWorkshopUrl} target="_blank" rel="noreferrer noopener"
                 title="Opens Steam (leaves this panel)">Steam Workshop</a> and
              search for its title.
            </span>
          )}
        </p>
      );
    case "error":
      return (
        <p class="search-status tone-error">
          Search {what(search.query)} failed: {search.error}{" "}
          <button class="btn btn-sm" onClick={onRetry}>Retry</button>
        </p>
      );
    case "gave-up":
      return (
        <p class="search-status tone-error">
          No answer {what(search.query)} after 35 s.{" "}
          {hasMod ? "" : "A stock server cannot tell a failed search from a slow one. "}
          <button class="btn btn-sm" onClick={onRetry}>Retry</button>
        </p>
      );
  }
}

interface RowProps {
  item: WorkshopItem;
  thumbnails: boolean;
  open: boolean;
  whitelist: Whitelist;
  installed: InstalledMod | null;
  install: Install | null;
  onToggle: () => void;
  onInstall: () => void;
  onOpenMods: () => void;
}

function ResultRow(p: RowProps) {
  const { item, installed, install } = p;
  const cols = p.thumbnails ? 6 : 5;

  let status;
  let action;
  if (installed) {
    status = (
      <>
        <StatusIcon icon={HardDriveDownload} label="installed" tone="ok"
                    title="On the server; the Mods tab loads it" />
        {installed.active === true && <StatusIcon icon={CircleCheck} label="loaded now" tone="ok" />}
      </>
    );
    action = <button class="btn btn-sm" onClick={p.onOpenMods}>Open in Mods</button>;
  } else if (install?.state === "downloading") {
    status = (
      <span class="note-warn">
        Downloading: asked {duration((Date.now() - install.askedAt) / 1000)} ago,
        not listed yet.
      </span>
    );
    action = <button class="btn btn-sm" disabled>Install</button>;
  } else {
    if (install?.state === "not-arrived") {
      status = (
        <span class="tone-error">
          Not installed after 3 minutes. The download may have failed; the
          server does not say why.
        </span>
      );
    } else if (install?.state === "refused" || install?.state === "failed") {
      status = <span class="tone-error">{install.note}</span>;
    } else {
      status = <span class="muted">not installed</span>;
    }
    action = (
      <button class="btn btn-sm" onClick={p.onInstall}>
        {install ? "Install again" : "Install"}
      </button>
    );
  }

  return (
    <>
      <tr data-mod={item.id.toLowerCase()} class={p.open ? "open" : undefined}>
        {p.thumbnails && (
          <td class="thumb-cell">
            {item.thumbnailUrl && <Thumbnail url={item.thumbnailUrl} size={48} />}
          </td>
        )}
        <td class="name-cell">
          <button class="link-button" aria-expanded={p.open} onClick={p.onToggle}
                  title="Show the details">
            {item.title || <span class="muted">(no title)</span>}
          </button>
          {item.steamResult !== 1 && (
            <span class="tag tag-danger" title={`Steam result ${item.steamResult}`}>
              Steam problem
            </span>
          )}
        </td>
        <td class="num">{fileSize(item.fileSize)}</td>
        <td>{item.updatedAt ? dateTime(item.updatedAt) : <span class="muted">--</span>}</td>
        <td class="notes-cell status-cell">
          <span class="icon-row">
            <WhitelistIcon list={p.whitelist} hexId={item.id} />
            {status}
          </span>
        </td>
        <td>
          <div class="actions">
            <button class="btn btn-sm" onClick={p.onToggle}>
              {p.open ? "Hide details" : "Details"}
            </button>
            {action}
          </div>
        </td>
      </tr>
      {p.open && (
        <tr class="detail-row">
          <td colSpan={cols}><Details item={item} thumbnails={p.thumbnails} /></td>
        </tr>
      )}
    </>
  );
}

function Thumbnail({ url, size }: { url: string; size: number }) {
  const [broken, setBroken] = useState(false);
  if (broken) return null;
  // Steam's CDN, and only because the operator turned thumbnails on.
  return (
    <img class="thumb" src={url} width={size} height={size} alt="" loading="lazy"
         referrerpolicy="no-referrer" onError={() => setBroken(true)} />
  );
}

function Details({ item, thumbnails }: { item: WorkshopItem; thumbnails: boolean }) {
  const ws = workshopId(item.id);
  const text = bbcodeToText(item.description);
  return (
    <div class="workshop-detail">
      {thumbnails && item.thumbnailUrl && <Thumbnail url={item.thumbnailUrl} size={160} />}
      <div class="detail-body">
        <dl class="detail-facts">
          <dt>Workshop id</dt>
          <dd>
            {ws ? (
              <a class="mono" href={`https://steamcommunity.com/sharedfiles/filedetails/?id=${ws}`}
                 target="_blank" rel="noreferrer noopener"
                 title="Open the workshop page (leaves this panel)">{ws}</a>
            ) : <span class="muted">--</span>}
            {" "}<span class="muted">hex</span>{" "}
            <span class="mono selectable" title="Click to select">{item.id}</span>
          </dd>
          <dt>Author</dt>
          <dd>
            {/^\d{17}$/.test(item.authorId) ? (
              <a class="mono" href={`https://steamcommunity.com/profiles/${item.authorId}`}
                 target="_blank" rel="noreferrer noopener"
                 title="Open the author's Steam profile (leaves this panel)">{item.authorId}</a>
            ) : <span class="mono">{item.authorId || "--"}</span>}
          </dd>
          <dt>Size</dt>
          <dd>{fileSize(item.fileSize)}</dd>
          <dt>Updated</dt>
          <dd>{item.updatedAt ? dateTime(item.updatedAt) : "--"}</dd>
          {item.tags.length > 0 && (
            <>
              <dt>Tags</dt>
              <dd>{item.tags.map((t) => <span key={t} class="tag">{t}</span>)}</dd>
            </>
          )}
          {item.childCount > 0 && (
            <>
              <dt>Requires</dt>
              <dd>
                {item.childCount} other workshop {item.childCount === 1 ? "item" : "items"},
                listed on its workshop page.
              </dd>
            </>
          )}
          {item.steamResult !== 1 && (
            <>
              <dt>Steam</dt>
              <dd class="tone-error">
                Steam reported a problem with this item (result {item.steamResult}).
              </dd>
            </>
          )}
        </dl>
        {text
          ? <div class="description">{text}</div>
          : <p class="muted">No description.</p>}
      </div>
    </div>
  );
}
