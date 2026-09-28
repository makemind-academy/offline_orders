#!/usr/bin/env python3
"""offline-orders: the till process is killed; the pad still takes orders, and when the till is back they arrive in order, once."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from appplayer import AppPlayer  # noqa: E402
from mcpclient import HttpServer, serve_http  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PAD = os.path.join(HERE, "pad_server")
TILL = os.path.join(HERE, "till_server")
CAP = os.path.join(HERE, "captures")
PORT, URL = 8766, "http://localhost:8766/mcp"
TILL_CMD = ["dart", "run", "bin/server.dart", f"--http={PORT}"]

for f in (os.path.join(PAD, "outbox.json"), os.path.join(TILL, "ledger.json")):
    if os.path.exists(f):
        os.remove(f)

ap = AppPlayer()
ap.register_server("com.makemind.sample.pad", "Order pad", cwd=PAD,
                   args=["run", "bin/server.dart", f"--till={URL}"])

with serve_http(TILL_CMD, cwd=TILL, port=PORT):
    ap.restart()
    ap.open_server("com.makemind.sample.pad")
    ap.wait_text("TILL LINKED")
    ap.tap("Take coffee")
    ap.wait_text("delivered")
    ap.expect_text("pad1-001")
    ap.shot(f"{CAP}/01_online.png")

# The till is gone. The pad is on its own.
for item, n in (("Take sandwich", "1"), ("Take juice", "2"), ("Take coffee", "3")):
    ap.tap(item)
    ap.wait_text("kept on the pad")
ap.wait_text("NO TILL")
ap.expect_text("pad1-002")
ap.shot(f"{CAP}/02_offline.png")

with serve_http(TILL_CMD, cwd=TILL, port=PORT):
    ap.tap("Retry link")
    ap.wait_text("delivered 3")
    ap.wait_text("TILL LINKED")
    ap.expect_aligned("$", min_rows=4)
    ap.shot(f"{CAP}/03_reconnected.png")
    till = HttpServer(URL)
    st = till.call("till.state")
    assert st["takenCount"] == 4, st
    assert st["ids"] == "pad1-001 pad1-002 pad1-003 pad1-004", st["ids"]
    again = till.call("till.take", {"id": "pad1-002", "item": "sandwich"})
    assert again["takenCount"] == 4 and "already" in again["notice"], again
print("offline-orders: 1 online, 3 taken with no till, all 4 on the till in order, a replay not charged twice")
