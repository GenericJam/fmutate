"""Recipe "dinghy_fetch": an app on zvenson's Dinghy whose repository holds the app alone and whose build script
fetches Dinghy at a pinned commit and fits the app in (Miku-FM's native/build.sh: DINGHY_COMMIT, its
tools/patch_dinghy_*.py, the app's modules copied under firmware/src). That script runs as its author wrote it; it
stops at Dinghy's own device build (no JieLi toolchain here), by which point the tree it made (build/dinghy) is the
firmware's whole source, which recipes/dinghy.py then builds as any Dinghy tree. Needs git and the network (a
pinned commit: the same source every time)."""
import os
import re

from common import SRC, sh
from recipes import dinghy

ORDER = 15


def detect(d, fid):
    for s in sorted(d.glob("*/build.sh")) + sorted(d.glob("build.sh")):
        t = s.read_text(errors="replace")
        m = re.search(r'DINGHY_COMMIT="\$\{DINGHY_COMMIT:-([0-9a-f]{7,40})\}"', t)
        if m and "github.com/zvenson/dinghy" in t and re.search(r"firmware/src/dinghy\.c", t):
            tree = re.search(r'\$ROOT/(build/dinghy)\b', t)
            return {"recipe": "dinghy_fetch", "script": str(s.relative_to(d)), "commit": m.group(1),
                    "tree": tree.group(1) if tree else "build/dinghy"}
    return None


def build(fid, r, target, log, res):
    d = SRC / fid
    env = dict(os.environ, JIELI_TOOLCHAIN="/nonexistent", AC79_SDK="/nonexistent", DINGHY_COMMIT=r["commit"])
    sh(["bash", r["script"]], d, env, log)              # (fails at Dinghy's device build: the tree is made by then)
    tree = d / r["tree"]
    rd = dinghy.detect(tree, fid) if (tree / "firmware/src/dinghy.c").exists() else None
    if not rd:
        log.append(f"dinghy_fetch: no Dinghy tree at {tree} after {r['script']}")
        return None, "fetch"
    rd["root"] = str(tree.resolve() / rd.get("root", ""))   # (absolute: recipes/dinghy.py joins it to SRC / fid)
    res["dinghy"] = {k: v for k, v in rd.items() if k != "root"}
    return dinghy.build(fid, rd, target, log, res)
