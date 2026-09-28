import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_server/mcp_server.dart';


/// till_server — the till in a food truck.
///
/// The point of this sample is what happens when this process is *not there*.
/// So two things matter about it:
///
///  1. It writes what it has taken to a file. A till that forgets the morning
///     when it restarts cannot tell you whether the tablet's queued orders
///     arrived twice.
///  2. It refuses orders it has already seen. Every order carries an id minted
///     by the tablet, and a replayed id is answered, not re-counted. Without
///     this, "flush the queue after reconnect" turns into double charges the
///     first time an ack is lost.
void main(List<String> args) async {
  const config = McpServerConfig(
    name: 'Truck Till',
    version: '1.0.0',
    capabilities: ServerCapabilities(
      tools: ToolsCapability(listChanged: true),
      resources: ResourcesCapability(listChanged: true),
    ),
  );
  final server = McpServer.createServer(config);
  TillServer(server, File(Platform.environment['TILL_LEDGER'] ?? 'ledger.json'))
    ..restore()
    ..register();
    // The screen next door: AppPlayer reads it from here and sends the pages'
    // tool calls back to the tools above.
  final transport = await McpServer.createTransport(transportFor(args)).get();
  server.connect(transport);
  await Completer<void>().future;
}

class TillServer {
  TillServer(this.server, this.ledger);

  final Server server;
  final File ledger;

  static const _prices = {'coffee': 350, 'sandwich': 600, 'juice': 450};

  final _taken = <Map<String, dynamic>>[];
  final _seenIds = <String>{};

  /// Read back what this till already took. Called before the first request,
  /// so a restarted till answers with the morning it actually had.
  void restore() {
    if (!ledger.existsSync()) return;
    for (final line in ledger.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final row = jsonDecode(line) as Map<String, dynamic>;
      _taken.add(row);
      _seenIds.add(row['id'] as String);
    }
  }

  void register() {
    server.addTool(
      name: 'till.take',
      description: 'Take one order. Safe to send twice — the id decides.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
          'item': {'type': 'string'},
        },
        'required': ['id', 'item'],
      },
      handler: (args) async {
        final id = args['id'] as String;
        final item = args['item'] as String;

        // The tablet may send the same order again after a reconnect, because
        // from its side an unanswered send and a lost answer look identical.
        // The till is the one that can tell, so the till decides.
        if (_seenIds.contains(id)) {
          return _state(notice: 'already had $id — not counted twice');
        }
        final price = _prices[item];
        if (price == null) return _state(notice: 'no such item: $item');

        final row = {'id': id, 'item': item, 'price': price};
        _taken.add(row);
        _seenIds.add(id);
        ledger.writeAsStringSync('${jsonEncode(row)}\n', mode: FileMode.append);
        return _state(notice: 'took $id ($item)');
      },
    );

    server.addTool(
      name: 'till.state',
      description: 'What this till has taken today',
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (args) async => _state(),
    );
  }

  CallToolResult _state({String notice = ''}) {
    final total = _taken.fold<int>(0, (a, r) => a + (r['price'] as int));
    return CallToolResult(content: [
      TextContent(
        text: jsonEncode({
          'takenCount': _taken.length,
          // Rows, not a joined string: the pad shows what was taken line by
          // line, and the id is what the till matches on when it hears about
          // them later.
          'takenRows': [
            for (final r in _taken)
              {
                'id': r['id'],
                'item': r['item'],
                'priceLabel': '\$${((r['price'] as int) / 100).toStringAsFixed(2)}',
              },
          ],
          // The rule that makes an offline pad safe. It belongs with the till,
          // because the till is what would double-charge if it were wrong.
          'queueRule': 'Each order carries its own id · the till takes an id once',
          'takenLine': _taken.isEmpty
              ? 'nothing yet'
              : _taken.map((r) => r['item']).join(', '),
          'ids': _taken.map((r) => r['id']).join(' '),
          'total': '\$${(total / 100).toStringAsFixed(2)}',
          'notice': notice,
        }),
      )
    ]);
  }
}

/// `--http=<port>` serves over streamable HTTP so the pad (and a second
/// party) can reach this one till process; without it the till speaks stdio.
TransportConfig transportFor(List<String> args) {
  final http = args.firstWhere((a) => a.startsWith('--http='), orElse: () => '');
  if (http.isEmpty) return const TransportConfig.stdio();
  return TransportConfig.streamableHttp(
    host: 'localhost',
    port: int.parse(http.substring('--http='.length)),
    endpoint: '/mcp',
  );
}
