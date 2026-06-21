import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:chewie/chewie.dart';
import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_to_airplay/flutter_to_airplay.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() async {
  _selfCheck();
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(BrowserApp(
    blockers: await _loadBlockers(),
    initialTabs: prefs.getStringList('tabs') ?? const [],
    initialActive: prefs.getInt('active') ?? 0,
  ));
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
  final List<String> initialTabs;
  final int initialActive;
  const BrowserApp(
      {super.key, required this.blockers, this.initialTabs = const [], this.initialActive = 0});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Browser',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: BrowserScreen(blockers: blockers, initialTabs: initialTabs, initialActive: initialActive),
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

class DetectedVideo {
  final String url;
  String title;
  String quality;
  String? poster;
  DetectedVideo(this.url, this.title, {this.quality = '', this.poster});
}

bool _isVideoUrl(String u) => RegExp(r'\.(m3u8|mp4|mpd)(\?|$)', caseSensitive: false).hasMatch(u);

class BrowserTab {
  final int id;
  InAppWebViewController? controller;
  String title = 'New Tab';
  String url;
  bool canBack = false;
  bool canForward = false;
  bool allowNext = true; // a nav we triggered (URL bar / new tab) — don't treat as popup
  final List<DetectedVideo> videos = [];
  final Set<String> seen = {};
  String? poster;
  bool sheetAutoShown = false; // auto-open the video sheet once per page load
  BrowserTab(this.id, this.url);
}

class BrowserScreen extends StatefulWidget {
  final List<ContentBlocker> blockers;
  final List<String> initialTabs;
  final int initialActive;
  const BrowserScreen(
      {super.key, required this.blockers, this.initialTabs = const [], this.initialActive = 0});
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final _tabs = <BrowserTab>[];
  final _urlBar = TextEditingController();
  int _active = 0;
  int _nextId = 0;
  bool _adBlock = true;
  String _player = 'media_kit'; // 'native' | 'video_player' | 'media_kit'
  CastService? _cast;
  final ValueNotifier<int> _videosTick = ValueNotifier(0); // bumps so an open sheet refreshes

  BrowserTab get _tab => _tabs[_active];

  @override
  void dispose() {
    _cast?.dispose();
    _videosTick.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Restore last session's tabs (and active tab); fall back to a single tab.
    final urls = widget.initialTabs.isEmpty ? ['https://www.google.com'] : widget.initialTabs;
    for (final u in urls) {
      _tabs.add(BrowserTab(_nextId++, u));
    }
    _active = widget.initialActive.clamp(0, _tabs.length - 1);
    _urlBar.text = _tab.url;
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        if (p.getBool('adblock') == false) _adBlock = false;
        _player = p.getString('player') ?? 'media_kit';
      });
    });
  }

  InAppWebViewSettings get _settings => InAppWebViewSettings(
        contentBlockers: _adBlock ? widget.blockers : <ContentBlocker>[],
        supportMultipleWindows: true,
        javaScriptCanOpenWindowsAutomatically: false,
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
        iframeAllowFullscreen: true,
        // Platform-correct UA: real iPhone Safari on iOS, real Chrome on Android.
        // ponytail: Android WebView's default UA has the "wv" token that anti-WebView
        // scripts sniff; iOS WKWebView is already Safari-like. A *mismatched* UA (Android
        // string on iOS) makes sites serve incompatible video players, so keep them apart.
        userAgent: Platform.isIOS
            ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
                'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'
            : 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
        thirdPartyCookiesEnabled: true,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        // Video fixes (Android): composite the video surface, and don't block HTTP
        // media segments served inside an HTTPS page.
        useHybridComposition: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useShouldOverrideUrlLoading: true,
        useOnLoadResource: true,
      );

  // ponytail: minimal "stealth" — patch the checks anti-WebView scripts use. webdriver
  // everywhere; window.chrome only on Android (real iOS Safari has none, so faking it
  // would be its own tell that triggers redirects).
  UnmodifiableListView<UserScript> get _stealth => UnmodifiableListView([
        UserScript(
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          source: '''
            Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
            ${Platform.isIOS ? '' : "if (!window.chrome) { window.chrome = { runtime: {} }; }"}
          ''',
        ),
        // Video sniffer: hook fetch / XHR / <video> loadstart, report media URLs + poster.
        UserScript(
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          source: r'''
            (function(){
              function poster(){
                var v=document.querySelector('video');
                var og=document.querySelector('meta[property="og:image"]');
                return (v&&v.poster)||(og&&og.content)||'';
              }
              function vid(u){ return u && /\.(m3u8|mp4|mpd)(\?|$)/i.test(u); }
              function report(u){
                if(!vid(u)) return;
                try{ u=new URL(u, location.href).href; }catch(e){}
                window.flutter_inappwebview.callHandler('video',{url:u,poster:poster(),title:document.title});
              }
              var of=window.fetch;
              window.fetch=function(){ try{var a=arguments[0]; report(a&&(a.url||a));}catch(e){} return of.apply(this,arguments); };
              var oo=XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open=function(m,u){ try{report(u);}catch(e){} return oo.apply(this,arguments); };
              document.addEventListener('loadstart',function(e){ try{var t=e.target; if(t&&t.currentSrc) report(t.currentSrc);}catch(e){} },true);
            })();
          ''',
        ),
      ]);

  Future<void> _toggleAdBlock() async {
    setState(() => _adBlock = !_adBlock);
    (await SharedPreferences.getInstance()).setBool('adblock', _adBlock);
    for (final t in _tabs) {
      await t.controller?.setSettings(settings: _settings);
      t.controller?.reload();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_adBlock ? 'Ad blocking on' : 'Ad blocking off')),
      );
    }
  }

  // Persist open tab URLs + active index so the app reopens the last session.
  void _persistTabs() {
    SharedPreferences.getInstance().then((p) {
      p.setStringList('tabs', _tabs.map((t) => t.url).toList());
      p.setInt('active', _active);
    });
  }

  void _addTab([String? url]) {
    setState(() {
      _tabs.add(BrowserTab(_nextId++, url ?? 'https://www.google.com'));
      _active = _tabs.length - 1;
      _urlBar.text = _tabs[_active].url;
    });
    _persistTabs();
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
    _persistTabs();
  }

  void _go() {
    _tab.allowNext = true;
    _tab.controller?.loadUrl(urlRequest: URLRequest(url: WebUri(toLoadUrl(_urlBar.text))));
  }

  void _popupBlocked(WebUri? url) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Popup blocked'),
      duration: const Duration(seconds: 2),
      action: url == null
          ? null
          : SnackBarAction(label: 'Open', onPressed: () => _addTab(url.toString())),
    ));
  }

  void _clearVideos(BrowserTab tab) {
    if (tab.videos.isEmpty && tab.seen.isEmpty && tab.poster == null) return;
    tab.videos.clear();
    tab.seen.clear();
    tab.poster = null;
    tab.sheetAutoShown = false;
    _videosTick.value++;
    if (mounted) setState(() {});
  }

  void _addVideo(BrowserTab tab, String url, {String? poster, String? title}) {
    if (!_isVideoUrl(url) || tab.seen.contains(url)) return;
    tab.seen.add(url);
    if (poster != null && poster.isNotEmpty) tab.poster = poster;
    final v = DetectedVideo(url, (title != null && title.isNotEmpty) ? title : tab.title,
        poster: (poster != null && poster.isNotEmpty) ? poster : tab.poster);
    tab.videos.add(v);
    _videosTick.value++;
    if (mounted) setState(() {});
    // Auto-open the sheet once when the active tab gets its first video.
    if (identical(tab, _tab) && !tab.sheetAutoShown && tab.videos.length == 1) {
      tab.sheetAutoShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openVideoSheet();
      });
    }
    _detectQuality(v).then((q) {
      v.quality = q;
      _videosTick.value++;
      if (mounted) setState(() {});
    });
  }

  // ponytail: best-effort quality label, not a full HLS/DASH parser.
  Future<String> _detectQuality(DetectedVideo v) async {
    final lower = v.url.toLowerCase();
    if (lower.contains('.mpd')) return 'DASH';
    if (lower.contains('.mp4')) {
      final m = RegExp(r'(2160|1440|1080|720|480|360)').firstMatch(lower);
      return m != null ? '${m.group(1)}p' : 'MP4';
    }
    if (lower.contains('.m3u8')) {
      try {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(v.url));
        req.headers.set('User-Agent', 'Mozilla/5.0');
        final resp = await req.close();
        final body = await resp.transform(const Utf8Decoder(allowMalformed: true)).join();
        client.close();
        final heights = RegExp(r'RESOLUTION=\d+x(\d+)', caseSensitive: false)
            .allMatches(body)
            .map((m) => int.parse(m.group(1)!))
            .toList();
        if (heights.isNotEmpty) return '${heights.reduce((a, b) => a > b ? a : b)}p';
        return 'HLS';
      } catch (_) {
        return 'HLS';
      }
    }
    return '';
  }

  CastService _castService() => _cast ??= CastService(
        discoveryProviders: [
          DlnaDiscoveryProvider(),
          ChromecastDiscoveryProvider(),
          AirPlayDiscoveryProvider(),
        ],
        sessionFactory: (device) {
          switch (device.protocol) {
            case CastProtocol.chromecast:
              return ChromecastSession(device: device);
            case CastProtocol.airplay:
              return AirPlaySession(device);
            case CastProtocol.dlna:
              return DlnaSession.fromDevice(device);
          }
        },
      );

  CastMediaType _mediaTypeFor(String url) {
    final l = url.toLowerCase();
    if (l.contains('.m3u8')) return CastMediaType.hls;
    if (l.contains('.mkv')) return CastMediaType.mkv;
    if (l.contains('.ts')) return CastMediaType.mpegTs;
    return CastMediaType.mp4;
  }

  Future<void> _castVideo(DetectedVideo v) async {
    final service = _castService();
    final device = await Navigator.of(context).push<CastDevice>(
      MaterialPageRoute(builder: (_) => CastScreen(service: service)),
    );
    if (device != null && mounted) await _connectAndPlay(service, device, v);
  }

  Future<void> _connectAndPlay(CastService service, CastDevice device, DetectedVideo v) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Connecting to ${device.name}…')));
    try {
      final session = await service.connect(device);
      await session.loadMedia(CastMedia(
        url: v.url,
        type: _mediaTypeFor(v.url),
        httpHeaders: {'Referer': _tab.url}, // dodge CDN 403s on protected streams
        title: v.title,
        imageUrl: v.poster,
      ));
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text('Casting to ${device.name}'),
        action: SnackBarAction(label: 'Stop', onPressed: () => session.disconnect()),
        duration: const Duration(seconds: 8),
      ));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Cast failed: $e')));
    }
  }

  void _showVideoActions(DetectedVideo v) {
    showDialog(
      context: context,
      builder: (dctx) => SimpleDialog(
        title: Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        children: [
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: const Text('Play in app'),
            onTap: () {
              Navigator.of(dctx).pop(); // dialog
              Navigator.of(context).pop(); // bottom sheet
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => PlayerScreen(url: v.url, title: v.title, referer: _tab.url, kind: _player)),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.cast),
            title: const Text('Cast to TV'),
            onTap: () {
              Navigator.of(dctx).pop();
              _castVideo(v);
            },
          ),
          ListTile(
            leading: const Icon(Icons.share),
            title: const Text('Share link'),
            onTap: () {
              Navigator.of(dctx).pop();
              SharePlus.instance.share(ShareParams(text: v.url));
            },
          ),
        ],
      ),
    );
  }

  Future<void> _openVideoSheet() async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      // Rebuilds live as videos are detected/cleared while the sheet is open.
      builder: (_) => ValueListenableBuilder<int>(
        valueListenable: _videosTick,
        builder: (_, tick, child) {
          final vids = _tab.videos;
          if (vids.isEmpty) {
            return const SizedBox(height: 160, child: Center(child: Text('No videos detected on this page')));
          }
          return ListView.separated(
            shrinkWrap: true,
            itemCount: vids.length,
            separatorBuilder: (_, i) => const Divider(height: 0),
            itemBuilder: (_, i) {
              final v = vids[i];
              return ListTile(
                leading: SizedBox(
                  width: 64,
                  height: 40,
                  child: v.poster == null
                      ? const Icon(Icons.movie)
                      : Image.network(v.poster!, fit: BoxFit.cover,
                          errorBuilder: (c, e, s) => const Icon(Icons.movie)),
                ),
                title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(v.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: v.quality.isEmpty ? null : Chip(label: Text(v.quality)),
                onTap: () => _showVideoActions(v),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildWebView(BrowserTab tab) => InAppWebView(
        key: ValueKey(tab.id),
        initialUrlRequest: URLRequest(url: WebUri(tab.url)),
        initialSettings: _settings,
        initialUserScripts: _stealth,
        onWebViewCreated: (c) {
          tab.controller = c;
          c.addJavaScriptHandler(
            handlerName: 'video',
            callback: (args) {
              if (args.isEmpty || args[0] is! Map) return;
              final m = args[0] as Map;
              _addVideo(tab, '${m['url']}', poster: m['poster']?.toString(), title: m['title']?.toString());
            },
          );
        },
        onTitleChanged: (c, t) => setState(() => tab.title = (t == null || t.isEmpty) ? tab.title : t),
        onLoadStart: (c, uri) => _clearVideos(tab),
        onLoadResource: (c, resource) {
          final u = resource.url?.toString();
          if (u != null) _addVideo(tab, u);
        },
        onLoadStop: (c, uri) async {
          tab.url = uri?.toString() ?? tab.url;
          tab.canBack = await c.canGoBack();
          tab.canForward = await c.canGoForward();
          if (uri != null) History.add(uri.toString(), tab.title);
          if (identical(tab, _tab) && mounted) setState(() => _urlBar.text = tab.url);
          _persistTabs(); // remember the latest URL per tab
        },
        onUpdateVisitedHistory: (c, uri, isReload) {
          // Clear on any URL change too (covers SPA pushState navigations).
          if (uri != null && uri.toString() != tab.url) {
            _clearVideos(tab);
            tab.url = uri.toString(); // keep in sync so the same URL doesn't re-clear
          }
          if (identical(tab, _tab) && uri != null && mounted) {
            setState(() => _urlBar.text = uri.toString());
          }
        },
        // In-page HTML5 fullscreen (non-YouTube sites): lock landscape + immersive.
        onEnterFullscreen: (c) {
          SystemChrome.setPreferredOrientations(
              [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        },
        onExitFullscreen: (c) {
          SystemChrome.setPreferredOrientations(DeviceOrientation.values);
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        },
        // Layer 1: new-window/new-tab popups (window.open / target=_blank).
        onCreateWindow: (c, action) async {
          _popupBlocked(action.request.url);
          return true; // discard the popup; snackbar's Open loads it in a new tab
        },
        // Layer 2: same-tab popunder/redirect ads. Cancel ONLY main-frame navigations
        // the user didn't trigger that jump to a different site. Real clicks, typed
        // URLs, back/forward, and same-site redirects pass through; in-page overlays
        // (not navigations) are never affected.
        shouldOverrideUrlLoading: (c, action) async {
          final uri = action.request.url;
          if (uri == null || action.isForMainFrame == false) {
            return NavigationActionPolicy.ALLOW;
          }
          if (tab.allowNext) {
            tab.allowNext = false;
            return NavigationActionPolicy.ALLOW;
          }
          final t = action.navigationType;
          final userDriven = action.hasGesture == true ||
              t == NavigationType.LINK_ACTIVATED ||
              t == NavigationType.BACK_FORWARD ||
              t == NavigationType.RELOAD ||
              t == NavigationType.FORM_SUBMITTED;
          if (userDriven) return NavigationActionPolicy.ALLOW;
          final cur = Uri.tryParse(tab.url)?.host ?? '';
          if (uri.host.isEmpty || uri.host == cur) {
            return NavigationActionPolicy.ALLOW; // same-site redirect, not a popup
          }
          // ponytail: main-frame + no gesture + cross-host = popunder/redirect ad.
          // Ceiling: tap "Open" if it ever catches a legit cross-site redirect.
          _popupBlocked(uri);
          return NavigationActionPolicy.CANCEL;
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
            tooltip: _adBlock ? 'Ad blocking on' : 'Ad blocking off',
            icon: Icon(_adBlock ? Icons.shield : Icons.shield_outlined),
            onPressed: _toggleAdBlock,
          ),
          IconButton(
            tooltip: 'Detected videos',
            icon: _tab.videos.isEmpty
                ? const Icon(Icons.movie_outlined)
                : Badge(label: Text('${_tab.videos.length}'), child: const Icon(Icons.movie)),
            onPressed: _openVideoSheet,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'history') _openHistory();
              if (v == 'settings') _openSettings();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'history', child: Text('History')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
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
                    onTap: () {
                      setState(() {
                        _active = i;
                        _urlBar.text = t.url;
                      });
                      _persistTabs();
                    },
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

  Future<void> _openSettings() async {
    final chosen = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => SettingsScreen(current: _player)),
    );
    if (chosen != null && mounted) {
      setState(() => _player = chosen);
      (await SharedPreferences.getInstance()).setString('player', chosen);
    }
  }
}

class _UrlBar extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSubmit;
  final VoidCallback onReload;
  const _UrlBar({required this.controller, required this.onSubmit, required this.onReload});

  @override
  State<_UrlBar> createState() => _UrlBarState();
}

class _UrlBarState extends State<_UrlBar> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // Select all on focus so typing replaces the current URL.
      if (_focus.hasFocus) {
        widget.controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.controller.text.length,
        );
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        focusNode: _focus,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => widget.onSubmit(),
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          hintText: 'Search or enter address',
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Clear button — only when there's text to clear.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: widget.controller,
                builder: (_, value, child) => value.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Clear',
                        onPressed: () {
                          widget.controller.clear();
                          _focus.requestFocus();
                        },
                      ),
              ),
              IconButton(icon: const Icon(Icons.refresh), onPressed: widget.onReload),
            ],
          ),
        ),
      );
}

IconData protocolIcon(CastProtocol p) => switch (p) {
      CastProtocol.airplay => Icons.airplay,
      CastProtocol.chromecast => Icons.cast,
      CastProtocol.dlna => Icons.tv,
    };

// --- Manual LAN discovery (works on iOS without the multicast entitlement) ---
// Multicast SSDP is blocked by the iOS sandbox; *unicast* UDP to each host is not.
// We M-SEARCH every address in the /24, read LOCATION headers, fetch the device
// description, and keep the DLNA media renderers.

Future<String?> _subnetPrefix() async {
  final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false);
  for (final ni in ifaces) {
    for (final a in ni.addresses) {
      final ip = a.address;
      if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) {
        final p = ip.split('.');
        return '${p[0]}.${p[1]}.${p[2]}.';
      }
    }
  }
  return null;
}

Future<DlnaDeviceDescription?> _fetchDescription(String loc) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(Uri.parse(loc));
    final resp = await req.close().timeout(const Duration(seconds: 3));
    final body = await resp.transform(const Utf8Decoder(allowMalformed: true)).join();
    return DlnaDeviceDescription.parse(body, loc);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

class LanScanResult {
  final List<CastDevice> devices; // DLNA media renderers (castable)
  final int responders; // how many hosts answered SSDP at all
  const LanScanResult(this.devices, this.responders);
}

Future<LanScanResult> _probeDlna(List<String> hosts, {Duration wait = const Duration(seconds: 5)}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final locations = <String>{};
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final dg = socket.receive();
    if (dg == null) return;
    final resp = String.fromCharCodes(dg.data);
    final loc = RegExp(r'LOCATION:\s*(\S+)', caseSensitive: false).firstMatch(resp)?.group(1);
    if (loc != null) locations.add(loc.trim());
  });
  // Try several search targets — some devices answer only specific STs over unicast.
  const targets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:schemas-upnp-org:service:AVTransport:1',
    'ssdp:all',
  ];
  for (final host in hosts) {
    for (final st in targets) {
      final msg = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $host:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'ST: $st\r\n\r\n';
      try {
        socket.send(msg.codeUnits, InternetAddress(host), 1900);
      } catch (_) {}
    }
  }
  await Future.delayed(wait);
  socket.close();

  final devices = <CastDevice>[];
  final seen = <String>{};
  for (final loc in locations) {
    final desc = await _fetchDescription(loc);
    if (desc != null && (desc.avTransportControlUrl?.isNotEmpty ?? false) && seen.add(desc.udn)) {
      devices.add(desc.toCastDevice());
    }
  }
  return LanScanResult(devices, locations.length);
}

Future<LanScanResult> scanLanDlna({Duration wait = const Duration(seconds: 5)}) async {
  final prefix = await _subnetPrefix();
  if (prefix == null) return const LanScanResult([], 0);
  final hosts = [for (var i = 1; i <= 254; i++) '$prefix$i', '239.255.255.250'];
  return _probeDlna(hosts, wait: wait);
}

// Targeted: M-SEARCH a single IP the user typed. Faster and bypasses subnet guessing.
Future<LanScanResult> probeDlnaHost(String ip) =>
    _probeDlna([ip], wait: const Duration(seconds: 3));

/// Cast device picker — two tabs: LAN scan (works now on iOS) and the
/// standard multicast discovery (works on a signed App Store build).
class CastScreen extends StatefulWidget {
  final CastService service;
  const CastScreen({super.key, required this.service});
  @override
  State<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends State<CastScreen> {
  Future<LanScanResult>? _scan;
  final _ipCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scan = scanLanDlna();
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    widget.service.stopDiscovery();
    super.dispose();
  }

  Widget _deviceTile(CastDevice d) => ListTile(
        leading: Icon(protocolIcon(d.protocol)),
        title: Text(d.name),
        subtitle: Text('${d.protocol.name} · ${d.address.address}'),
        onTap: () => Navigator.of(context).pop(d),
      );

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Cast to TV'),
            bottom: const TabBar(tabs: [
              Tab(text: 'Find on network'),
              Tab(text: 'Standard'),
            ]),
          ),
          body: TabBarView(
            children: [
              // Tab 1: LAN unicast scan (works on the current unsigned iOS build).
              FutureBuilder<LanScanResult>(
                future: _scan,
                builder: (_, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Scanning your Wi-Fi for TVs…', textAlign: TextAlign.center),
                        ])));
                  }
                  final result = snap.data ?? const LanScanResult([], 0);
                  final devices = result.devices;
                  // Tailored message tells us which failure we're hitting.
                  final emptyMsg = result.responders == 0
                      ? 'No devices responded on your Wi-Fi.\n\n'
                          '• Allow Local Network: iOS Settings → (this app) → Local Network = ON\n'
                          '• Phone and TV must be on the SAME Wi-Fi (not guest network)'
                      : 'Found ${result.responders} network device(s), but none expose a DLNA player.\n\n'
                          'Your LG TV may have DLNA off or removed on newer webOS.\n'
                          'Try: TV Settings → enable Screen/Smart Share — or use AirPlay in the player.';
                  return Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                      child: Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _ipCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              labelText: 'TV IP address',
                              hintText: 'e.g. 192.168.1.20',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            final ip = _ipCtrl.text.trim();
                            if (ip.isNotEmpty) setState(() => _scan = probeDlnaHost(ip));
                          },
                          child: const Text('Connect'),
                        ),
                      ]),
                    ),
                    Expanded(
                      child: devices.isEmpty
                          ? Center(child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(emptyMsg, textAlign: TextAlign.center)))
                          : ListView(children: devices.map(_deviceTile).toList()),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: FilledButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Rescan'),
                        onPressed: () => setState(() => _scan = scanLanDlna()),
                      ),
                    ),
                  ]);
                },
              ),
              // Tab 2: standard multicast discovery (needs a signed/store build on iOS).
              StreamBuilder<List<CastDevice>>(
                stream: widget.service.startDiscovery(timeout: const Duration(seconds: 15)),
                builder: (_, snap) {
                  final devices = snap.data ?? const <CastDevice>[];
                  if (devices.isEmpty) {
                    return Center(child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        snap.connectionState == ConnectionState.done
                            ? 'No devices found.\nOn iPhone this works only in the App Store build.'
                            : 'Searching…',
                        textAlign: TextAlign.center),
                    ));
                  }
                  return ListView(children: devices.map(_deviceTile).toList());
                },
              ),
            ],
          ),
        ),
      );
}

/// Picks the player engine per the user's Settings choice.
class PlayerScreen extends StatelessWidget {
  final String url;
  final String title;
  final String? referer;
  final String kind; // 'native' | 'video_player' | 'media_kit'
  const PlayerScreen(
      {super.key, required this.url, required this.title, this.referer, this.kind = 'media_kit'});

  Widget _engine() {
    switch (kind) {
      case 'native':
        return Platform.isIOS ? FlutterAVPlayerView(urlString: url) : _ChewiePlayer(url: url);
      case 'video_player':
        return _ChewiePlayer(url: url);
      default:
        return _MediaKitPlayer(url: url, referer: referer);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: _engine(),
      );
}

class _MediaKitPlayer extends StatefulWidget {
  final String url;
  final String? referer;
  const _MediaKitPlayer({required this.url, this.referer});
  @override
  State<_MediaKitPlayer> createState() => _MediaKitPlayerState();
}

class _MediaKitPlayerState extends State<_MediaKitPlayer> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.url,
        httpHeaders: widget.referer == null ? null : {'Referer': widget.referer!}));
    // Keep the screen on only while actually playing.
    _player.stream.playing.listen((playing) => WakelockPlus.toggle(enable: playing));
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        // Lift controls off the very bottom edge (clears home-indicator/nav bar).
        padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom + 24),
        child: MaterialVideoControlsTheme(
          // Default media_kit controls, but no double-tap-to-seek (per request).
          normal: const MaterialVideoControlsThemeData(
              volumeGesture: true, brightnessGesture: true, seekOnDoubleTap: false),
          fullscreen: const MaterialVideoControlsThemeData(
              volumeGesture: true, brightnessGesture: true, seekOnDoubleTap: false),
          child: Video(controller: _controller),
        ),
      );
}

class _ChewiePlayer extends StatefulWidget {
  final String url;
  const _ChewiePlayer({required this.url});
  @override
  State<_ChewiePlayer> createState() => _ChewiePlayerState();
}

class _ChewiePlayerState extends State<_ChewiePlayer> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _wake() => WakelockPlus.toggle(enable: _video?.value.isPlaying ?? false);

  Future<void> _init() async {
    try {
      final v = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await v.initialize();
      if (!mounted) {
        v.dispose();
        return;
      }
      v.addListener(_wake); // screen on while playing, off when paused/ended
      setState(() {
        _video = v;
        _chewie = ChewieController(
          videoPlayerController: v,
          autoPlay: true,
          allowFullScreen: true,
          aspectRatio: v.value.aspectRatio,
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _video?.removeListener(_wake);
    WakelockPlus.disable();
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        // Lift the controls off the very bottom edge (clears the home-indicator/nav bar).
        padding: EdgeInsets.only(bottom: MediaQuery.viewPaddingOf(context).bottom + 24),
        child: Center(
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text("Can't play this video.\n$_error",
                      textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)))
              : _chewie == null
                  ? const CircularProgressIndicator()
                  : Chewie(controller: _chewie!),
        ),
      );
}

class SettingsScreen extends StatefulWidget {
  final String current;
  const SettingsScreen({super.key, required this.current});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late String _sel = widget.current;

  static const _options = {
    'media_kit': ('media_kit (recommended)', 'Plays almost any format/codec. No AirPlay.'),
    'video_player': ('video_player', 'Platform player (ExoPlayer/AVPlayer) with Chewie controls.'),
    'native': ('Native', 'iOS: native player with AirPlay. Android: same as video_player.'),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: RadioGroup<String>(
          groupValue: _sel,
          onChanged: (v) {
            if (v == null) return;
            setState(() => _sel = v);
            Navigator.of(context).pop(v); // return choice; parent saves it
          },
          child: ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Video player', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final e in _options.entries)
                RadioListTile<String>(
                  value: e.key,
                  title: Text(e.value.$1),
                  subtitle: Text(e.value.$2),
                ),
            ],
          ),
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
