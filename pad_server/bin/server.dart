import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_server/mcp_server.dart';

import 'serve_bundle.dart';

/// pad_server — the tablet's side of a till that may be gone.
///
/// Taking an order never waits on the network. Every order goes into a spool
/// file first, then the pad tries to hand it to the till over HTTP. When the
/// till cannot be reached the order stays in the spool, the screen says how
/// many are waiting, and `pad.flush` sends them in order once the till is back.
/// The till decides about duplicates by id, so a resend is safe.
///
/// Run:  dart run bin/server.dart --till=http://localhost:8766/mcp
void main(List<String> args) async {
  final till = args
      .firstWhere((a) => a.startsWith('--till='),
          orElse: () => '--till=http://localhost:8766/mcp')
      .substring('--till='.length);
  const config = McpServerConfig(
    name: 'Order Pad',
    version: '1.0.0',
    capabilities: ServerCapabilities(
      tools: ToolsCapability(listChanged: true),
      resources: ResourcesCapability(listChanged: true),
    ),
  );
  final server = McpServer.createServer(config);
  Pad(server, TillLink(Uri.parse(till)), File('outbox.json')).register();
  registerBundleUi(server, '../orders.mbd');

  final transport = McpServer.createStdioTransport().get();
  server.connect(transport);
  await Completer<void>().future;
}

class Pending {
  Pending(this.id, this.item);
  final String id;
  final String item;
  Map<String, dynamic> toJson() => {'id': id, 'item': item};
}

/// A JSON-RPC client just wide enough to call one tool on the till.
class TillLink {
  TillLink(this.url);
  final Uri url;
  String? _session;
  var _id = 0;

  Future<Map<String, dynamic>?> _post(Map<String, dynamic> msg) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.postUrl(url);
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'application/json, text/event-stream');
      if (_session != null) req.headers.set('Mcp-Session-Id', _session!);
      req.write(jsonEncode(msg));
      final res = await req.close().timeout(const Duration(seconds: 3));
      _session = res.headers.value('mcp-session-id') ?? _session;
      var raw = await res.transform(utf8.decoder).join();
      if (raw.contains('data:')) {
        raw = raw
            .split('\n')
            .where((l) => l.startsWith('data:'))
            .map((l) => l.substring(5).trim())
            .join('\n');
      }
      return raw.trim().isEmpty ? null : jsonDecode(raw) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _initialize() async {
    await _post({
      'jsonrpc': '2.0',
      'id': ++_id,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'capabilities': {},
        'clientInfo': {'name': 'order pad', 'version': '1.0.0'},
      },
    });
    await _post({'jsonrpc': '2.0', 'method': 'notifications/initialized', 'params': {}});
  }

  /// Calls `till.<name>`; returns the till's state map, or null when the till
  /// cannot be reached. The pad treats every failure the same way: not sent.
  Future<Map<String, dynamic>?> call(String name, Map<String, dynamic> args) async {
    try {
      if (_session == null) await _initialize();
      final res = await _post({
        'jsonrpc': '2.0',
        'id': ++_id,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': args},
      });
      final result = res?['result'] as Map<String, dynamic>?;
      final content = (result?['content'] as List?)?.cast<Map<String, dynamic>>();
      final text = content?.firstWhere((c) => c['type'] == 'text', orElse: () => {})['text'];
      if (text is! String) return null;
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      _session = null;
      return null;
    }
  }
}

class Pad {
  Pad(this.server, this.till, this.spool) {
    if (spool.existsSync()) {
      for (final row in jsonDecode(spool.readAsStringSync()) as List) {
        _pending.add(Pending(row['id'] as String, row['item'] as String));
      }
    }
  }

  final Server server;
  final TillLink till;
  final File spool;
  static const _device = 'pad1';
  final _pending = <Pending>[];
  var _minted = 0;
  Map<String, dynamic>? _tillState;
  bool _linked = false;

  void _write() =>
      spool.writeAsStringSync(jsonEncode(_pending.map((p) => p.toJson()).toList()));

  /// Send what is waiting, in order, stopping at the first order the till
  /// does not answer. Returns how many were delivered.
  Future<int> _flush() async {
    var sent = 0;
    while (_pending.isNotEmpty) {
      final p = _pending.first;
      final state = await till.call('till.take', {'id': p.id, 'item': p.item});
      if (state == null) break;
      _tillState = state;
      _pending.removeAt(0);
      _write();
      sent++;
    }
    _linked = _pending.isEmpty && (_tillState != null || await _ping());
    return sent;
  }

  Future<bool> _ping() async {
    final s = await till.call('till.state', {});
    if (s != null) _tillState = s;
    return s != null;
  }

  void register() {
    server.addTool(
      name: 'pad.state',
      description: 'The pad: the link, what is waiting, what the till has',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async {
        _linked = await _ping();
        return _state();
      },
    );

    server.addTool(
      name: 'pad.take',
      description: 'Take an order. Never waits on the till.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'item': {'type': 'string'},
        },
        'required': ['item'],
      },
      handler: (args) async {
        final p = Pending('$_device-${(++_minted).toString().padLeft(3, '0')}', args['item'] as String);
        _pending.add(p);
        _write();
        final sent = await _flush();
        return _state(
            notice: sent > 0 ? 'took ${p.id} — delivered' : 'took ${p.id} — kept on the pad');
      },
    );

    server.addTool(
      name: 'pad.flush',
      description: 'Try the till again and send what is waiting, in order',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async {
        final sent = await _flush();
        return _state(notice: sent > 0 ? 'delivered $sent' : 'till not reachable');
      },
    );
  }

  CallToolResult _state({String notice = ''}) {
    final t = _tillState ?? const {};
    return CallToolResult(content: [
      TextContent(
        text: jsonEncode({
          'link': _linked ? 'TILL LINKED' : 'NO TILL — orders kept here',
          'linkColor': _linked ? '#2f6b3a' : '#a06a06',
          'pending': _pending.length,
          'pendingLine': _pending.isEmpty
              ? 'nothing waiting'
              : _pending.map((p) => p.id).join(' '),
          'takenCount': t['takenCount'] ?? 0,
          'takenLine': t['takenLine'] ?? '-',
          'takenRows': t['takenRows'] ?? const [],
          'total': t['total'] ?? r'$0.00',
          'queueRule': 'An order is taken the moment it is written down · '
              'the till is told when it can be told',
          'notice': notice,
        }),
      ),
    ]);
  }
}
