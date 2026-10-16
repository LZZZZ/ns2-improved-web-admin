// Whether loading a mod keeps the server ranked: the engine's verdict
// (Server.GetIsModWhitelisted), on each installed mod and workshop result. It
// covers the hotfix mods too.

import { ShieldCheck, ShieldX } from "lucide-preact";
import { StatusIcon } from "./Icon";

export function WhitelistIcon({ whitelisted }: { whitelisted: boolean }) {
  return whitelisted
    ? <StatusIcon icon={ShieldCheck} label="whitelisted" tone="ok" title="ranked servers can load it" />
    : <StatusIcon icon={ShieldX} label="not whitelisted" tone="warn" title="loading it turns ranking off" />;
}
