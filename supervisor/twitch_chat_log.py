"""Read-only Twitch chat logger (anonymous IRC, no account or token needed).

Usage: python -u twitch_chat_log.py <channel> [<channel> ...]
Appends every chat line to %LOCALAPPDATA%/hermes/cache/twitch_chat.log as
"YYYY-mm-dd HH:MM:SS #channel user: message". Reconnects on drop. It never
sends chat messages (justinfan logins can't).
"""
import os
import random
import socket
import sys
import time

LOG = os.path.join(os.environ.get("LOCALAPPDATA", "."), "hermes", "cache", "twitch_chat.log")


def log(line):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + line + "\n")


def run(channels):
    nick = "justinfan%d" % random.randint(10000, 99999)
    s = socket.create_connection(("irc.chat.twitch.tv", 6667), timeout=330)
    s.sendall(("NICK %s\r\n" % nick).encode())
    for c in channels:
        s.sendall(("JOIN #%s\r\n" % c.lower()).encode())
    log("[logger] connected as %s to %s" % (nick, ", ".join("#" + c for c in channels)))
    buf = b""
    while True:
        data = s.recv(4096)
        if not data:
            raise ConnectionError("closed")
        buf += data
        while b"\r\n" in buf:
            raw, buf = buf.split(b"\r\n", 1)
            line = raw.decode("utf-8", "replace")
            if line.startswith("PING"):
                s.sendall(("PONG" + line[4:] + "\r\n").encode())
            elif " PRIVMSG #" in line:
                # :user!user@user.tmi.twitch.tv PRIVMSG #chan :message
                user = line[1:line.index("!")] if "!" in line else "?"
                rest = line.split(" PRIVMSG ", 1)[1]
                chan, _, msg = rest.partition(" :")
                log("%s %s: %s" % (chan, user, msg))


if __name__ == "__main__":
    chans = sys.argv[1:] or ["tediusprocesses"]
    while True:
        try:
            run(chans)
        except Exception as e:  # network drop: wait and reconnect
            log("[logger] disconnected (%s); reconnecting in 30 s" % e)
            time.sleep(30)
