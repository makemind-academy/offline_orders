# offline-orders

The till process is killed; the pad still takes orders, and when the till is back they arrive in order, once.

Article: [orders-with-the-till-gone](https://makemind.dev/en/field/orders-with-the-till-gone)

## What is here

- `pad_server/` — Dart MCP server (`mcp_server` from pub.dev). It holds the data and the tools and serves the app's pages as `ui://` resources.
- `till_server/` — Dart MCP server (`mcp_server` from pub.dev). It holds the data and the tools and serves the app's pages as `ui://` resources.
- `orders.mbd/` — the app as a folder of JSON: `manifest.json` and the pages under `ui/`. No build step.
- `captures/` — screenshots taken from AppPlayer by `verify.py`.
- `verify.py`, `verify.sh` — the check.

## Open it in AppPlayer

Start the till: `dart run bin/server.dart --http=8765` in `till_server/`. Add a server app with command `dart`, arguments `run bin/server.dart`, working directory `pad_server/`. The pad keeps taking orders while the till is down and delivers them, in order, once it is back.

## Verify

```bash
bash verify.sh
```

Needs AppPlayer with the debug MCP on (see `tools/README.md`). The script builds what needs building, drives the player through the screens above, asserts the claim at the top of this file, and writes `captures/`.
