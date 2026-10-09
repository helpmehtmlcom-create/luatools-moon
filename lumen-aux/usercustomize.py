# luatools-moon: DroidDeck session autostart (managed by install.sh; safe to delete)
#
# DroidDeck rewrites /usr/local/bin and /etc/xdg/labwc/autostart at every launch
# and has no user startup hook, so a shell autostart line never survives. Python
# imports usercustomize from the user site-packages at the start of every python3
# process, and DroidDeck's own session daemons are python3 programs that start with
# each session. When one of them boots, make sure the LuaTools supervisor runs.
#
# Narrow on purpose: only those daemons trigger it, nothing is imported, errors
# are swallowed so they can never break the host program, and the supervisor is
# only started when it is not already alive (its `start` command re-checks that).
import os
import sys

_DAEMONS = {
    "droiddeck-agent",
    "droiddeck-netmanager",
    "droiddeck-login1",
    "droiddeck-steam-compat",
}


def _autostart():
    if os.environ.get("LUATOOLS_NO_AUTOSTART") or not sys.argv:
        return
    if os.path.basename(sys.argv[0]) not in _DAEMONS:
        return
    home = os.environ.get("HOME") or "/root"
    hook = os.path.join(
        os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share"),
        "Lumen", "droiddeck-luatools-hook.sh",
    )
    if not os.access(hook, os.X_OK):
        return
    import subprocess

    env = dict(os.environ, LUATOOLS_NO_AUTOSTART="1")
    log = open(os.path.join(home, ".lumen.log"), "ab")
    subprocess.Popen(
        ["bash", hook, "start"],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log,
        env=env, start_new_session=True, close_fds=True,
    )


try:
    _autostart()
except Exception:
    pass
