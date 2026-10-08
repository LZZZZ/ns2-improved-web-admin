// A map's name, with its minimap on hover or focus.
//
// Only the stock maps have one: their overviews ship in the mod, converted by
// tools/make-minimaps.sh. A mod map's overview is inside its mod, out of the
// web root's reach, so hovering one says so. The image is fetched only when a
// name is hovered, and from the game server like the rest of the panel.

import { useState } from "preact/hooks";

const files = import.meta.glob<string>("../minimaps/*.png",
  { eager: true, query: "?url", import: "default" });

const MINIMAPS = new Map(Object.entries(files).map(([path, url]) =>
  [path.replace(/^.*\/|\.png$/g, ""), url]));

/** Room the popup needs: the image's 320 px plus its frame. */
const kSize = 340;

export function MapName({ name }: { name: string }) {
  const [at, setAt] = useState<{ x: number; y: number } | null>(null);
  const url = MINIMAPS.get(name);

  // Fixed, beside the name: the tables scroll sideways, and would clip it.
  const show = (e: Event) => {
    const box = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const width = url ? kSize : 200;
    const x = box.right + 12 + width <= window.innerWidth
      ? box.right + 12 : Math.max(8, box.left - 12 - width);
    const y = Math.max(8, Math.min(box.top - 40, window.innerHeight - (url ? kSize : 40) - 8));
    setAt({ x, y });
  };
  const hide = () => setAt(null);

  return (
    <span class="map-name" tabIndex={0} onMouseEnter={show} onMouseLeave={hide}
          onFocus={show} onBlur={hide}>
      {name}
      {at && (
        <span class="minimap-pop" role="tooltip" style={{ left: `${at.x}px`, top: `${at.y}px` }}>
          {url
            ? <img src={url} alt={`Minimap of ${name}`} />
            : <span class="muted">No minimap: the panel has the stock maps' only.</span>}
        </span>
      )}
    </span>
  );
}
