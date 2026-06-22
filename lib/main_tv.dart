// Android TV entry point (flavor: tv). Reuses the players/models from main.dart;
// adds a D-pad-driven virtual-cursor browser shell with no cast (Play/Share only).
// ponytail: ad-block/sniffer/settings are re-stated here to avoid destabilizing the
// working mobile main.dart; fold both into lib/core/ once the TV shell is proven.
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:media_kit/media_kit.dart';
import 'package:share_plus/share_plus.dart';

import 'main.dart' show toLoadUrl, youtubeId, DetectedVideo, PlayerScreen, YoutubeScreen;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(TvApp(blockers: await _loadBlockers()));
}

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
  } catch (_) {
    return [];
  }
}

bool _isVideoUrl(String u) =>
    RegExp(r'\.(m3u8|mp4|mpd)(\?|$)', caseSensitive: false).hasMatch(u);

class TvApp extends StatelessWidget {
  final List<ContentBlocker> blockers;
  const TvApp({super.key, required this.blockers});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TV Browser',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
        home: TvBrowser(blockers: blockers),
      );
}

class TvBrowser extends StatefulWidget {
  final List<ContentBlocker> blockers;
  const TvBrowser({super.key, required this.blockers});
  @override
  State<TvBrowser> createState() => _TvBrowserState();
}

class _TvBrowserState extends State<TvBrowser> {
  InAppWebViewController? _controller;
  final _urlBar = TextEditingController(text: 'https://www.google.com');
  final _focus = FocusNode();
  final List<DetectedVideo> _videos = [];
  final Set<String> _seen = {};
  String _pageUrl = 'https://www.google.com';
  String _title = '';
  String? _lastYoutubeId;

  // Virtual cursor (logical px), only active in cursor mode.
  bool _cursorMode = false;
  double _cx = 200, _cy = 200;
  static const _step = 36.0;

  InAppWebViewSettings get _settings => InAppWebViewSettings(
        contentBlockers: widget.blockers,
        supportMultipleWindows: false,
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
        useHybridComposition: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useOnLoadResource: true,
        userAgent: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      );

  UnmodifiableListView<UserScript> get _sniffer => UnmodifiableListView([
        UserScript(
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          source: r'''
            (function(){
              function poster(){var v=document.querySelector('video');var og=document.querySelector('meta[property="og:image"]');return (v&&v.poster)||(og&&og.content)||'';}
              function vid(u){return u && /\.(m3u8|mp4|mpd)(\?|$)/i.test(u);}
              function report(u){if(!vid(u))return;try{u=new URL(u,location.href).href;}catch(e){}window.flutter_inappwebview.callHandler('video',{url:u,poster:poster(),title:document.title});}
              var of=window.fetch;window.fetch=function(){try{var a=arguments[0];report(a&&(a.url||a));}catch(e){}return of.apply(this,arguments);};
              var oo=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){try{report(u);}catch(e){}return oo.apply(this,arguments);};
              document.addEventListener('loadstart',function(e){try{var t=e.target;if(t&&t.currentSrc)report(t.currentSrc);}catch(e){}},true);
            })();
          ''',
        ),
      ]);

  void _go() {
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(toLoadUrl(_urlBar.text))));
    setState(() => _cursorMode = true);
    _focus.requestFocus();
  }

  void _addVideo(String url, {String? poster, String? title}) {
    if (!_isVideoUrl(url) || _seen.contains(url)) return;
    _seen.add(url);
    setState(() => _videos.add(DetectedVideo(url, (title?.isNotEmpty ?? false) ? title! : _title,
        poster: poster?.isNotEmpty ?? false ? poster : null)));
  }

  void _clearVideos() {
    if (_videos.isEmpty && _seen.isEmpty) return;
    setState(() {
      _videos.clear();
      _seen.clear();
    });
  }

  void _maybeYoutube(String url) {
    final id = youtubeId(url);
    if (id == null) {
      _lastYoutubeId = null;
      return;
    }
    if (id == _lastYoutubeId || !mounted) return;
    _lastYoutubeId = id;
    _controller?.evaluateJavascript(
        source: "document.querySelectorAll('video,audio').forEach(function(m){m.pause();});");
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => YoutubeScreen(videoId: id, title: _title, kind: 'media_kit')));
  }

  // D-pad handling while in cursor mode.
  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (!_cursorMode || e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final size = MediaQuery.sizeOf(context);
    if (k == LogicalKeyboardKey.arrowUp) {
      if (_cy <= 60) {
        _controller?.scrollBy(x: 0, y: -200);
      } else {
        setState(() => _cy = (_cy - _step).clamp(0, size.height));
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (_cy >= size.height - 60) {
        _controller?.scrollBy(x: 0, y: 200);
      } else {
        setState(() => _cy = (_cy + _step).clamp(0, size.height));
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      setState(() => _cx = (_cx - _step).clamp(0, size.width));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      setState(() => _cx = (_cx + _step).clamp(0, size.width));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA) {
      _controller?.evaluateJavascript(
          source: "(function(){var el=document.elementFromPoint(${_cx.round()},${_cy.round()});"
              "if(el){el.click(); if(el.focus) el.focus();}})();");
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      setState(() => _cursorMode = false); // leave cursor mode -> toolbar focus
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _focus.dispose();
    _urlBar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _toolbar(),
            Expanded(
              child: Focus(
                focusNode: _focus,
                onKeyEvent: _onKey,
                child: Stack(
                  children: [
                    InAppWebView(
                      initialUrlRequest: URLRequest(url: WebUri('https://www.google.com')),
                      initialSettings: _settings,
                      initialUserScripts: _sniffer,
                      onWebViewCreated: (c) {
                        _controller = c;
                        c.addJavaScriptHandler(
                          handlerName: 'video',
                          callback: (args) {
                            if (args.isEmpty || args[0] is! Map) return;
                            final m = args[0] as Map;
                            _addVideo('${m['url']}',
                                poster: m['poster']?.toString(), title: m['title']?.toString());
                          },
                        );
                      },
                      onTitleChanged: (c, t) => _title = (t?.isEmpty ?? true) ? _title : t!,
                      onLoadStart: (c, uri) => _clearVideos(),
                      onLoadResource: (c, r) {
                        final u = r.url?.toString();
                        if (u != null) _addVideo(u);
                      },
                      onLoadStop: (c, uri) {
                        if (uri != null) {
                          _pageUrl = uri.toString();
                          _urlBar.text = _pageUrl;
                          _maybeYoutube(_pageUrl);
                        }
                      },
                      onUpdateVisitedHistory: (c, uri, isReload) {
                        if (uri != null) {
                          _pageUrl = uri.toString();
                          _maybeYoutube(_pageUrl);
                        }
                      },
                    ),
                    if (_cursorMode)
                      Positioned(
                        left: _cx,
                        top: _cy,
                        child: IgnorePointer(
                          child: Icon(Icons.navigation,
                              color: Colors.tealAccent, size: 28, shadows: const [
                            Shadow(color: Colors.black, blurRadius: 4),
                          ]),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => _controller?.goBack()),
            IconButton(icon: const Icon(Icons.arrow_forward), onPressed: () => _controller?.goForward()),
            IconButton(icon: const Icon(Icons.refresh), onPressed: () => _controller?.reload()),
            Expanded(
              child: TextField(
                controller: _urlBar,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _go(),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: 'Search or enter address',
                ),
              ),
            ),
            FilledButton(onPressed: _go, child: const Text('Go')),
            const SizedBox(width: 8),
            // Enter cursor mode to point at the page.
            FilledButton.tonalIcon(
              onPressed: () {
                setState(() => _cursorMode = true);
                _focus.requestFocus();
              },
              icon: const Icon(Icons.mouse),
              label: const Text('Pointer'),
            ),
            const SizedBox(width: 8),
            Badge(
              isLabelVisible: _videos.isNotEmpty,
              label: Text('${_videos.length}'),
              child: IconButton(icon: const Icon(Icons.movie), onPressed: _openVideoSheet),
            ),
          ],
        ),
      );

  void _openVideoSheet() {
    showModalBottomSheet(
      context: context,
      builder: (_) => _videos.isEmpty
          ? const SizedBox(height: 140, child: Center(child: Text('No videos detected')))
          : ListView(
              children: _videos
                  .map((v) => ListTile(
                        leading: const Icon(Icons.movie),
                        title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(v.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                        // No cast on TV — Play + Share only.
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            icon: const Icon(Icons.play_arrow),
                            onPressed: () {
                              Navigator.of(context).pop();
                              Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => PlayerScreen(
                                      url: v.url, title: v.title, referer: _pageUrl, kind: 'media_kit')));
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.share),
                            onPressed: () => SharePlus.instance.share(ShareParams(text: v.url)),
                          ),
                        ]),
                      ))
                  .toList(),
            ),
    );
  }
}
