import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  _selfCheck();
  WidgetsFlutterBinding.ensureInitialized();
  runApp(BrowserApp(blockers: await _loadBlockers()));
}

// ponytail: trimmed rule set; swap easylist.json for full converted EasyList
// (under iOS WKContentRuleList's 50k-rule cap) if blocking falls short.
// Any failure -> empty list so the browser still opens (never a stuck spinner).
Future<List<ContentBlocker>> _loadBlockers() async {
  try {
    final raw = await rootBundle.loadString('assets/easylist.json');
    final list = jsonDecode(raw) as List;
    return list.map((e) {
      final m = Map<String, dynamic>.from(e);
      return ContentBlocker(
        trigger: ContentBlockerTrigger.fromMap(Map<String, dynamic>.from(m['trigger'])),
        action: ContentBlockerAction.fromMap(Map<String, dynamic>.from(m['action'])),
      );
    }).toList();
  } catch (e) {
    debugPrint('ad-list load failed, continuing without blockers: $e');
    return [];
  }
}

// ponytail: only non-trivial logic in the app — the URL-vs-search guess.
bool isUrl(String s) {
  s = s.trim();
  if (s.isEmpty) return false;
  if (s.startsWith('http://') || s.startsWith('https://')) return true;
  if (s.contains(' ')) return false;
  return s.contains('.'); // has a dot, no spaces -> treat as a host
}

String toLoadUrl(String input) {
  final s = input.trim();
  if (isUrl(s)) {
    return (s.startsWith('http://') || s.startsWith('https://')) ? s : 'https://$s';
  }
  return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(s)}';
}

void _selfCheck() {
  assert(isUrl('example.com') == true);
  assert(isUrl('https://x.org') == true);
  assert(isUrl('cute cats') == false);
  assert(isUrl('') == false);
  assert(toLoadUrl('example.com') == 'https://example.com');
  assert(toLoadUrl('cute cats').startsWith('https://www.google.com/search?q='));
}

class BrowserApp extends StatelessWidget {
  final List<ContentBlocker> blockers;
  const BrowserApp({super.key, required this.blockers});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Browser',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: BrowserScreen(blockers: blockers),
      );
}

// ponytail: history as a JSON list in prefs; move to sqflite only if it lags.
class History {
  static const _key = 'history';
  static Future<void> add(String url, String title) async {
    if (url.startsWith('https://www.google.com/search')) return; // skip search noise
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_key) ?? [];
    list.insert(0, jsonEncode({'url': url, 'title': title, 'ts': DateTime.now().toIso8601String()}));
    if (list.length > 2000) list.removeRange(2000, list.length);
    await p.setStringList(_key, list);
  }

  static Future<List<Map<String, dynamic>>> all() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_key) ?? []).map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_key);
  }
}

class BrowserTab {
  final int id;
  final int? windowId; // set when this tab adopts a blocked popup window
  InAppWebViewController? controller;
  String title = 'New Tab';
  String url;
  bool canBack = false;
  bool canForward = false;
  BrowserTab(this.id, this.url, {this.windowId});
}

class BrowserScreen extends StatefulWidget {
  final List<ContentBlocker> blockers;
  const BrowserScreen({super.key, required this.blockers});
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final _tabs = <BrowserTab>[];
  final _urlBar = TextEditingController();
  int _active = 0;
  int _nextId = 0;

  BrowserTab get _tab => _tabs[_active];

  @override
  void initState() {
    super.initState();
    _tabs.add(BrowserTab(_nextId++, 'https://www.google.com'));
    _urlBar.text = _tabs[0].url;
  }

  InAppWebViewSettings get _settings => InAppWebViewSettings(
        contentBlockers: widget.blockers,
        supportMultipleWindows: true,
        javaScriptCanOpenWindowsAutomatically: false,
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
        iframeAllowFullscreen: true,
      );

  void _addTab([String? url]) {
    setState(() {
      _tabs.add(BrowserTab(_nextId++, url ?? 'https://www.google.com'));
      _active = _tabs.length - 1;
      _urlBar.text = _tabs[_active].url;
    });
  }

  void _closeTab(int i) {
    if (_tabs.length == 1) {
      _tabs[0].controller?.loadUrl(urlRequest: URLRequest(url: WebUri('https://www.google.com')));
      return;
    }
    setState(() {
      _tabs.removeAt(i);
      if (_active >= _tabs.length) _active = _tabs.length - 1;
      _urlBar.text = _tab.url;
    });
  }

  void _go() {
    _tab.controller?.loadUrl(urlRequest: URLRequest(url: WebUri(toLoadUrl(_urlBar.text))));
  }

  void _popupBlocked(BrowserTab tab) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Popup blocked'),
      action: SnackBarAction(
        label: 'Open',
        onPressed: () {
          final i = _tabs.indexOf(tab);
          if (i != -1) {
            setState(() {
              _active = i;
              _urlBar.text = tab.url;
            });
          }
        },
      ),
    ));
  }

  Widget _buildWebView(BrowserTab tab) => InAppWebView(
        key: ValueKey(tab.id),
        windowId: tab.windowId,
        // windowId tabs receive their URL from the adopted popup window, not here.
        initialUrlRequest: tab.windowId == null ? URLRequest(url: WebUri(tab.url)) : null,
        initialSettings: _settings,
        onWebViewCreated: (c) => tab.controller = c,
        onTitleChanged: (c, t) => setState(() => tab.title = (t == null || t.isEmpty) ? tab.title : t),
        onLoadStop: (c, uri) async {
          tab.url = uri?.toString() ?? tab.url;
          tab.canBack = await c.canGoBack();
          tab.canForward = await c.canGoForward();
          if (uri != null) History.add(uri.toString(), tab.title);
          if (identical(tab, _tab) && mounted) setState(() => _urlBar.text = tab.url);
        },
        onUpdateVisitedHistory: (c, uri, isReload) {
          if (identical(tab, _tab) && uri != null && mounted) {
            setState(() => _urlBar.text = uri.toString());
          }
        },
        // ponytail: every window.open / target=_blank is parked in a hidden tab,
        // never the current one. Returning true stops the WebView's default
        // (which would load it inline). The snackbar's Open reveals the tab.
        onCreateWindow: (c, action) async {
          final popup = BrowserTab(
            _nextId++,
            action.request.url?.toString() ?? 'Popup',
            windowId: action.windowId,
          );
          setState(() => _tabs.add(popup)); // added but not made active = hidden
          _popupBlocked(popup);
          return true; // we handle the window; do not load it inline
        },
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _UrlBar(
          controller: _urlBar,
          onSubmit: _go,
          onReload: () => _tab.controller?.reload(),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _tab.canBack ? () => _tab.controller?.goBack() : null,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: _tab.canForward ? () => _tab.controller?.goForward() : null,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: _openHistory,
          ),
        ],
      ),
      body: Column(
        children: [
          _tabStrip(),
          Expanded(
            child: IndexedStack(
              index: _active,
              children: _tabs.map(_buildWebView).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabStrip() => SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _tabs.length,
                itemBuilder: (_, i) {
                  final t = _tabs[i];
                  final selected = i == _active;
                  return InkWell(
                    onTap: () => setState(() {
                      _active = i;
                      _urlBar.text = t.url;
                    }),
                    child: Container(
                      width: 150,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
                        border: const Border(right: BorderSide(width: 0.5, color: Colors.black26)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(t.title,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13)),
                          ),
                          InkWell(
                            onTap: () => _closeTab(i),
                            child: const Icon(Icons.close, size: 16),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            IconButton(icon: const Icon(Icons.add), onPressed: () => _addTab()),
          ],
        ),
      );

  Future<void> _openHistory() async {
    final url = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const HistoryScreen()),
    );
    if (url != null) _addTab(url);
  }
}

class _UrlBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;
  final VoidCallback onReload;
  const _UrlBar({required this.controller, required this.onSubmit, required this.onReload});

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => onSubmit(),
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          hintText: 'Search or enter address',
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          suffixIcon: IconButton(icon: const Icon(Icons.refresh), onPressed: onReload),
        ),
      );
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<Map<String, dynamic>>> _future = History.all();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('History'),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await History.clear();
                setState(() => _future = History.all());
              },
            ),
          ],
        ),
        body: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (_, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final items = snap.data!;
            if (items.isEmpty) return const Center(child: Text('No history yet'));
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, i) => const Divider(height: 0),
              itemBuilder: (_, i) {
                final h = items[i];
                return ListTile(
                  title: Text(h['title'] ?? h['url'], maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(h['url'], maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.of(context).pop(h['url'] as String),
                );
              },
            );
          },
        ),
      );
}
