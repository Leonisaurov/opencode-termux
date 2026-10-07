import os from "os"
import path from "path"

const home = os.homedir()
const data = process.env.XDG_DATA_HOME || (home ? path.join(home, ".local", "share") : undefined)
const cache = process.env.XDG_CACHE_HOME || (home ? path.join(home, ".cache") : undefined)
const config = process.env.XDG_CONFIG_HOME || (home ? path.join(home, ".config") : undefined)
const state = process.env.XDG_STATE_HOME || (home ? path.join(home, ".local", "state") : undefined)

/** The XDG base directories that root opencode's global paths. */
export function roots(app: string) {
  // Android/Termux does not always export TMPDIR into the app process. Fall
  // back to the Termux prefix instead of the unwritable /tmp so every temp path
  // (log, repos, sockets) stays inside the app sandbox.
  const tmpRoot = process.env.TMPDIR ?? (process.env.PREFIX ? path.join(process.env.PREFIX, "tmp") : os.tmpdir())
  return {
    data: path.join(data!, app),
    cache: path.join(cache!, app),
    config: path.join(config!, app),
    state: path.join(state!, app),
    tmp: path.join(tmpRoot, app),
  }
}
