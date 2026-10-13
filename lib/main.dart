
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const XtremeApp());
}

const secureStore = FlutterSecureStorage();

class Channel {
  final String id, name, url, category, epgId, logo;

  const Channel({
    required this.id,
    required this.name,
    required this.url,
    this.category = 'عام',
    this.epgId = '',
    this.logo = '',
  });
}

class XtremeApp extends StatelessWidget {
  const XtremeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Xtreme IPTV',
    theme: ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.red,
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF101116),
      useMaterial3: true,
    ),
    home: const PlayerHome(),
  );
}

class PlayerHome extends StatefulWidget {
  const PlayerHome({super.key});

  @override
  State<PlayerHome> createState() => _PlayerHomeState();
}

class _PlayerHomeState extends State<PlayerHome> {
  final server = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final playlistUrl = TextEditingController();
  final search = TextEditingController();

  List<Channel> channels = [];
  List<Map<String, dynamic>> categories = [];
  Set<String> favorites = {};
  Channel? selected;
  VideoPlayerController? video;
  List<dynamic> epg = [];

  String category = 'الكل';
  String status = 'أضف قائمة أو حسابًا مرخّصًا للبدء.';
  bool busy = false;
  int page = 0;

  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final favs = prefs.getStringList('favorites') ?? [];
    server.text = await secureStore.read(key: 'server') ?? '';
    username.text = await secureStore.read(key: 'username') ?? '';
    password.text = await secureStore.read(key: 'password') ?? '';
    playlistUrl.text = await secureStore.read(key: 'playlist') ?? '';

    if (mounted) setState(() => favorites = favs.toSet());
  }

  Future<void> saveSettings() async {
    await secureStore.write(key: 'server', value: server.text.trim());
    await secureStore.write(key: 'username', value: username.text);
    await secureStore.write(key: 'password', value: password.text);
    await secureStore.write(key: 'playlist', value: playlistUrl.text.trim());
  }

  Future<void> saveFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorites', favorites.toList());
  }

  Uri apiUri([Map<String, String>? extra]) {
    final base = server.text.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse(base);
    final params = <String, String>{
      'username': username.text.trim(),
      'password': password.text,
      if (extra != null) ...extra,
    };
    return uri.replace(
      path: '${uri.path}/player_api.php'.replaceAll('//player_api.php',
          '/player_api.php'),
      queryParameters: params,
    );
  }

  Future<dynamic> getJson(Uri uri) async {
    final response = await http.get(uri).timeout(
      const Duration(seconds: 25),
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<void> loadXtream() async {
    setState(() {
      busy = true;
      status = 'جاري التحقق وتحميل القنوات...';
    });

    try {
      final base = Uri.parse(server.text.trim());
      if (!{'https'}.contains(base.scheme) || base.host.isEmpty) {
        throw Exception('استخدم عنوان HTTPS صحيحًا للمزود.');
      }
      if (username.text.trim().isEmpty || password.text.isEmpty) {
        throw Exception('أدخل بيانات الدخول.');
      }

      final auth = await getJson(apiUri());
      if (auth is! Map || auth['user_info'] is! Map ||
          auth['user_info']['auth'].toString() != '1') {
        throw Exception('بيانات الدخول غير مقبولة.');
      }

      final cats = await getJson(apiUri({
        'action': 'get_live_categories',
      }));
      final streams = await getJson(apiUri({
        'action': 'get_live_streams',
      }));

      if (cats is! List || streams is! List) {
        throw Exception('صيغة بيانات المزود غير متوقعة.');
      }

      final catList = cats.map<Map<String, dynamic>>((c) => {
        'id': '${c['category_id'] ?? ''}',
        'name': '${c['category_name'] ?? 'عام'}',
      }).toList();

      final catNames = {
        for (final c in catList) c['id']!: c['name']!,
      };

      final baseUrl = base.replace(path: '', query: '', fragment: '')
          .toString().replaceAll(RegExp(r'/$'), '');

      final result = <Channel>[];
      for (final s in streams) {
        if (s is! Map) continue;
        final id = '${s['stream_id'] ?? ''}';
        if (id.isEmpty) continue;

        final ext = '${s['container_extension'] ?? 'm3u8'}';
        final categoryId = '${s['category_id'] ?? ''}';
        final encodedUser = Uri.encodeComponent(username.text.trim());
        final encodedPass = Uri.encodeComponent(password.text);

        result.add(Channel(
          id: id,
          name: '${s['name'] ?? 'قناة $id'}',
          url: '$baseUrl/live/$encodedUser/$encodedPass/$id.'
              '${ext == 'ts' ? 'ts' : 'm3u8'}',
          category: catNames[categoryId] ?? 'عام',
          epgId: '${s['epg_channel_id'] ?? ''}',
          logo: '${s['stream_icon'] ?? ''}',
        ));
      }

      await saveSettings();
      setState(() {
        categories = catList;
        channels = result;
        category = 'الكل';
        status = 'تم تحميل ${result.length} قناة.';
      });
    } catch (_) {
      setState(() {
        status = 'تعذّر الاتصال. تحقق من HTTPS وبيانات المزود.';
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> loadM3u() async {
    setState(() {
      busy = true;
      status = 'جاري تحميل قائمة M3U...';
    });

    try {
      final uri = Uri.parse(playlistUrl.text.trim());
      if (uri.scheme != 'https' || uri.host.isEmpty) {
        throw Exception('HTTPS required');
      }

      final response = await http.get(uri).timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode != 200) throw Exception('HTTP error');

      final lines = utf8.decode(response.bodyBytes).split(RegExp(r'\r?\n'));
      final result = <Channel>[];
      String name = 'قناة';
      String group = 'عام';
      String logo = '';
      String epgId = '';

      for (final raw in lines) {
        final line = raw.trim();

        if (line.startsWith('#EXTINF:')) {
          final comma = line.lastIndexOf(',');
          name = comma >= 0 ? line.substring(comma + 1).trim() : 'قناة';
          group = RegExp(r'group-title="([^"]*)"')
              .firstMatch(line)?.group(1) ?? 'عام';
          logo = RegExp(r'tvg-logo="([^"]*)"')
              .firstMatch(line)?.group(1) ?? '';
          epgId = RegExp(r'tvg-id="([^"]*)"')
              .firstMatch(line)?.group(1) ?? '';
        } else if (line.startsWith('https://') &&
            !line.startsWith('#')) {
          final uri = Uri.tryParse(line);
          if (uri != null && uri.host.isNotEmpty &&
              (uri.path.endsWith('.m3u8') ||
               uri.path.endsWith('.mp4') ||
               uri.path.endsWith('.ts'))) {
            result.add(Channel(
              id: '${result.length}',
              name: name,
              url: line,
              category: group,
              logo: logo,
              epgId: epgId,
            ));
          }
          name = 'قناة';
          group = 'عام';
          logo = '';
          epgId = '';
        }
      }

      await secureStore.write(
        key: 'playlist',
        value: playlistUrl.text.trim(),
      );

      setState(() {
        channels = result;
        categories = result.map((c) => {
          'id': c.category,
          'name': c.category,
        }).toSet().toList();
        category = 'الكل';
        status = 'تم تحميل ${result.length} قناة.';
      });
    } catch (_) {
      setState(() => status =
          'تعذّر تحميل القائمة. تحقق من الرابط وتنسيق M3U.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> play(Channel channel) async {
    final uri = Uri.tryParse(channel.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      setState(() => status = 'رابط القناة غير صالح أو غير آمن.');
      return;
    }

    final old = video;
    setState(() {
      selected = channel;
      video = null;
      epg = [];
      status = 'جاري تشغيل ${channel.name}...';
    });
    await old?.dispose();

    final next = VideoPlayerController.networkUrl(uri);
    try {
      await next.initialize().timeout(const Duration(seconds: 30));
      if (!mounted) {
        await next.dispose();
        return;
      }
      setState(() {
        video = next;
        status = 'يتم تشغيل ${channel.name}';
      });
      await next.play();
      await loadEpg(channel);
    } catch (_) {
      await next.dispose();
      if (mounted) setState(() {
        status = 'فشل التشغيل. تحقق من صيغة البث وصلاحية الرابط.';
      });
    }
  }

  Future<void> loadEpg(Channel channel) async {
    if (username.text.isEmpty || password.text.isEmpty ||
        channel.id.isEmpty) return;

    try {
      final data = await getJson(apiUri({
        'action': 'get_short_epg',
        'stream_id': channel.id,
        'limit': '8',
      }));
      if (!mounted) return;
      setState(() {
        epg = data is Map && data['epg_listings'] is List
            ? data['epg_listings'] as List
            : [];
      });
    } catch (_) {
      if (mounted) setState(() => epg = []);
    }
  }

  Future<void> toggleFavorite(Channel c) async {
    setState(() {
      if (!favorites.add(c.url)) favorites.remove(c.url);
    });
    await saveFavorites();
  }

  @override
  void dispose() {
    server.dispose();
    username.dispose();
    password.dispose();
    playlistUrl.dispose();
    search.dispose();
    video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = channels.where((c) {
      final matchSearch = c.name.toLowerCase()
          .contains(search.text.trim().toLowerCase());
      final matchCategory = category == 'الكل' || c.category == category;
      final matchPage = page != 1 || favorites.contains(c.url);
      return matchSearch && matchCategory && matchPage;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('XTREME IPTV'),
        actions: [
          IconButton(
            onPressed: () => setState(() => page = 2),
            icon: const Icon(Icons.settings),
            tooltip: 'الإعدادات',
          ),
        ],
      ),
      body: SafeArea(
        child: page == 2
            ? settingsScreen()
            : ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  if (selected != null) ...[
                    Text(selected!.name,
                      style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: video != null && video!.value.isInitialized
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  VideoPlayer(video!),
                                  IconButton.filled(
                                    iconSize: 44,
                                    onPressed: () => setState(() {
                                      video!.value.isPlaying
                                          ? video!.pause()
                                          : video!.play();
                                    }),
                                    icon: Icon(video!.value.isPlaying
                                        ? Icons.pause : Icons.play_arrow),
                                  ),
                                  Positioned(
                                    bottom: 4, left: 8, right: 8,
                                    child: VideoProgressIndicator(
                                      video!,
                                      allowScrubbing: true,
                                      colors: const VideoProgressColors(
                                        playedColor: Colors.red,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : const Center(child: CircularProgressIndicator()),
                    ),
                    const SizedBox(height: 12),
                    const Text('دليل البرامج EPG',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                    ...epg.map((p) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.schedule),
                      title: Text('${p['title'] ?? 'برنامج'}'),
                      subtitle: Text('${p['start'] ?? ''}'),
                    )),
                    const Divider(),
                  ],
                  Text(status),
                  const SizedBox(height: 8),
                  TextField(
                    controller: search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'ابحث عن قناة',
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: category,
                    decoration: const InputDecoration(
                      labelText: 'التصنيف',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'الكل', child: Text('كل القنوات')),
                      ...categories.map((c) {
                        final name = '${c['name']}';
                        return DropdownMenuItem(
                          value: name, child: Text(name));
                      }).toList(),
                    ],
                    onChanged: (v) =>
                        setState(() => category = v ?? 'الكل'),
                  ),
                  const SizedBox(height: 8),
                  if (busy)
                    const Center(child: CircularProgressIndicator()),
                  ...visible.map((c) => Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.live_tv)),
                      title: Text(c.name),
                      subtitle: Text(c.category),
                      onTap: () => play(c),
                      trailing: IconButton(
                        icon: Icon(
                          favorites.contains(c.url)
                              ? Icons.favorite : Icons.favorite_border,
                          color: Colors.red),
                        onPressed: () => toggleFavorite(c),
                      ),
                    ),
                  )),
                ],
              ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: page == 2 ? 2 : page,
        onDestinationSelected: (v) => setState(() => page = v),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.live_tv), label: 'القنوات'),
          NavigationDestination(
            icon: Icon(Icons.favorite), label: 'المفضّلة'),
          NavigationDestination(
            icon: Icon(Icons.settings), label: 'الإعدادات'),
        ],
      ),
    );
  }

  Widget settingsScreen() {
    Widget field(String label, TextEditingController controller,
        {bool secret = false, String? hint}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        obscureText: secret,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('إعدادات الاتصال',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        field('عنوان الخادم HTTPS', server,
          hint: 'https://provider.example'),
        field('اسم المستخدم', username),
        field('كلمة المرور', password, secret: true),
        FilledButton(
          onPressed: busy ? null : loadXtream,
          child: const Text('الاتصال عبر Xtream'),
        ),
        const Divider(height: 30),
        field('رابط قائمة M3U عبر HTTPS', playlistUrl),
        FilledButton.tonal(
          onPressed: busy ? null : loadM3u,
          child: const Text('تحميل قائمة M3U'),
        ),
        const SizedBox(height: 18),
        OutlinedButton(
          onPressed: () async {
            await secureStore.deleteAll();
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove('favorites');
            setState(() {
              favorites.clear();
              channels.clear();
              categories.clear();
              selected = null;
              page = 0;
              status = 'تم مسح الإعدادات المحفوظة.';
            });
          },
          child: const Text('مسح بيانات الاتصال والمفضّلة'),
        ),
        const SizedBox(height: 10),
        const Text(
          'هذه صفحة إدارة محلية لإعدادات التطبيق. '
          'لا تمنح صلاحية إدارة خادم مزود الخدمة.',
          style: TextStyle(color: Colors.white70),
        ),
      ],
    );
  }
}
