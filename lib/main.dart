import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';

// --- CONSTANTS & CONFIG ---
const String kTmdbKey = '15d2ea6d0dc1d476efbca3eba2b9bbfb';
const String kTmdbBase = 'https://api.themoviedb.org/3';
const String kTmdbImg = 'https://image.tmdb.org/t/p/w500';
const String kTmdbBackdrop = 'https://image.tmdb.org/t/p/original';
const String kAnilistUrl = 'https://graphql.anilist.co';

// ABSOLUTE PATHS MAPPED FROM RELATIVE PHP
const String kBaseUrl = "https://psplay.site/lol/";
const String kLiveApi = "https://psplay.site/lol/cric.php?ps=live-events";
const String kSrcTmdb = "https://psplay.site/src/"; 
const String kSrcAnime = "https://psplay.site/lol/anisrc/";
const String kSrcLive = "https://psplay.site/lol/player.php";

// COLORS
const Color cBg = Color(0xFF050505);
const Color cSurface = Color(0xFF121212);
const Color cHighlight = Color(0xFF1E1E1E);
const Color cText = Colors.white;
const Color cTextDim = Color(0xFFA0A0A0);

// --- MODELS ---
class MediaItem {
  final int id;
  final String title;
  final String? image;
  final String? backdrop;
  final String rating;
  final String year;
  final String type; // 'movie', 'tv', 'anime', 'live'
  final String overview;
  final String status;
  final List<String> genres;
  final List<Cast> cast;
  final List<Review> reviews;
  final List<MediaItem> recommendations;
  final List<MediaItem> relations;
  final List<Season> seasons; // For TMDB
  final int episodeCount; // For Anime
  final Map<String, dynamic> raw; // Full raw data for fallbacks

  MediaItem({
    required this.id, required this.title, this.image, this.backdrop,
    required this.rating, required this.year, required this.type,
    required this.overview, this.status = '', this.genres = const [],
    this.cast = const [], this.reviews = const [], this.recommendations = const [],
    this.relations = const [], this.seasons = const [], this.episodeCount = 0,
    this.raw = const {},
  });
}

class Cast {
  final String name;
  final String image;
  Cast({required this.name, required this.image});
}

class Review {
  final String author;
  final String content;
  final String rating;
  Review({required this.author, required this.content, required this.rating});
}

class Season {
  final int number;
  final String name;
  Season({required this.number, required this.name});
}

class Episode {
  final int number;
  final String title;
  final String desc;
  final String? image;
  Episode({required this.number, required this.title, required this.desc, this.image});
}

// --- STATE ---
class AppState extends ChangeNotifier {
  String _mode = 'tmdb'; 
  String get mode => _mode;

  void setMode(String m) {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
  }

  Color get primary {
    switch (_mode) {
      case 'anime': return const Color(0xFFEC4899); // Pink
      case 'live': return const Color(0xFFEF4444); // Red
      default: return const Color(0xFF6366F1); // Indigo
    }
  }
}
final appState = AppState();

void main() {
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: cBg,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const StreamFlowApp());
}

class StreamFlowApp extends StatelessWidget {
  const StreamFlowApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        return MaterialApp(
          title: 'StreamFlow',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: cBg,
            primaryColor: appState.primary,
            useMaterial3: true,
            textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme).apply(bodyColor: cText, displayColor: cText),
            colorScheme: ColorScheme.dark(primary: appState.primary, surface: cSurface, background: cBg),
          ),
          home: const MainLayout(),
        );
      },
    );
  }
}

// --- API SERVICE ---
class Api {
  static Future<dynamic> getTmdb(String ep, [String p = '']) async {
    try {
      final r = await http.get(Uri.parse('$kTmdbBase$ep?api_key=$kTmdbKey&language=en-US$p'));
      return r.statusCode == 200 ? json.decode(r.body) : null;
    } catch (_) { return null; }
  }

  static Future<dynamic> postAni(String q, [Map<String, dynamic>? v]) async {
    try {
      final r = await http.post(Uri.parse(kAnilistUrl), headers: {'Content-Type':'application/json', 'Accept':'application/json'}, body: json.encode({'query':q, 'variables':v}));
      return r.statusCode == 200 ? json.decode(r.body)['data'] : null;
    } catch (_) { return null; }
  }

  static Future<List> getLive() async {
    try {
      final r = await http.get(Uri.parse(kLiveApi), headers: {'User-Agent': 'Mozilla/5.0'});
      if (r.statusCode == 200) {
        return json.decode(r.body.replaceAll('https://psplay.site/Sportzfy/dump.php?link=', ''));
      }
    } catch (_) {}
    return [];
  }

  // --- DATA NORMALIZERS (1:1 with JS) ---
  static MediaItem normTmdb(Map<String, dynamic> d, [bool detailed = false]) {
    List<Cast> cast = [];
    List<Review> reviews = [];
    List<MediaItem> recs = [];
    List<Season> seasons = [];
    
    if (detailed) {
      if (d['credits']?['cast'] != null) {
        cast = (d['credits']['cast'] as List).take(10).map((c) => Cast(name: c['name'], image: c['profile_path'] != null ? '$kTmdbImg${c['profile_path']}' : '')).toList();
      }
      if (d['reviews']?['results'] != null) {
        reviews = (d['reviews']['results'] as List).take(5).map((r) => Review(author: r['author'], content: r['content'], rating: r['author_details']?['rating']?.toString() ?? '')).toList();
      }
      if (d['recommendations']?['results'] != null || d['similar']?['results'] != null) {
        final src = d['recommendations']?['results'] ?? d['similar']?['results'];
        recs = (src as List).take(10).map((i) => normTmdb(i)).toList();
      }
      if (d['seasons'] != null) {
        seasons = (d['seasons'] as List).map((s) => Season(number: s['season_number'], name: s['name'])).where((s) => s.number > 0).toList();
      }
    }

    return MediaItem(
      id: d['id'],
      title: d['title'] ?? d['name'] ?? 'Unknown',
      image: d['poster_path'] != null ? '$kTmdbImg${d['poster_path']}' : null,
      backdrop: d['backdrop_path'] != null ? '$kTmdbBackdrop${d['backdrop_path']}' : null,
      rating: (d['vote_average'] ?? 0).toStringAsFixed(1),
      year: (d['release_date'] ?? d['first_air_date'] ?? 'N/A').split('-')[0],
      type: d['media_type'] ?? (d['title'] != null ? 'movie' : 'tv'),
      overview: d['overview'] ?? '',
      status: d['status'] ?? '',
      genres: d['genres'] != null ? (d['genres'] as List).map((g) => g['name'].toString()).toList() : [],
      cast: cast, reviews: reviews, recommendations: recs, seasons: seasons,
      raw: d,
    );
  }

  static MediaItem normAni(Map<String, dynamic> d) {
    List<Cast> cast = [];
    List<MediaItem> recs = [];
    List<MediaItem> rels = [];
    
    if (d['characters'] != null) {
      cast = (d['characters']['nodes'] as List).map((c) => Cast(name: c['name']['full'], image: c['image']['large'])).toList();
    }
    if (d['recommendations'] != null) {
      recs = (d['recommendations']['nodes'] as List).where((n) => n['mediaRecommendation'] != null).map((n) => normAni(n['mediaRecommendation'])).toList();
    }
    if (d['relations'] != null) {
      rels = (d['relations']['edges'] as List).where((e) => e['relationType'] != 'ADAPTATION' && e['node']['format'] != 'MANGA').map((e) {
         var node = e['node'];
         return MediaItem(
           id: node['id'], title: node['title']['english'] ?? node['title']['romaji'],
           image: node['coverImage']['large'], rating: '', year: '', type: 'anime', overview: '',
           raw: node
         );
      }).toList();
    }

    return MediaItem(
      id: d['id'],
      title: d['title']['english'] ?? d['title']['romaji'] ?? '?',
      image: d['coverImage']['extraLarge'],
      backdrop: d['bannerImage'] ?? d['coverImage']['extraLarge'],
      rating: ((d['averageScore'] ?? 0) / 10).toStringAsFixed(1),
      year: d['startDate']?['year']?.toString() ?? '?',
      type: 'anime', // Force type
      overview: (d['description'] ?? '').replaceAll(RegExp(r'<[^>]*>'), ''),
      status: d['status'] ?? '',
      genres: d['genres'] != null ? List<String>.from(d['genres']) : [],
      episodeCount: d['episodes'] ?? 12,
      cast: cast, recommendations: recs, relations: rels,
      raw: d,
    );
  }
}

// --- MAIN LAYOUT ---
class MainLayout extends StatefulWidget {
  const MainLayout({super.key});
  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  int _idx = 0;
  
  // View definitions
  late final List<Widget> _tmdbV = [const HomeView(), const GridViewPage(mode:'movie'), const GridViewPage(mode:'tv'), const SearchView()];
  late final List<Widget> _aniV = [const HomeView(), const GridViewPage(mode:'browse'), const SearchView()];
  late final List<Widget> _liveV = [const HomeView()];

  List<Widget> get _views {
    if (appState.mode == 'anime') return _aniV;
    if (appState.mode == 'live') return _liveV;
    return _tmdbV;
  }

  @override
  Widget build(BuildContext context) {
    if (_idx >= _views.length) _idx = 0;
    
    return Scaffold(
      body: Stack(
        children: [
          _views[_idx],
          // Custom Glass Header
          Positioned(top: 0, left: 0, right: 0, child: ClipRRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX:15, sigmaY:15), child: Container(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 10, 20, 10),
            decoration: BoxDecoration(color: cBg.withOpacity(0.7), border: const Border(bottom: BorderSide(color: Colors.white10))),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Row(children: [Icon(Icons.play_circle_filled_rounded, color: appState.primary, size: 28), const SizedBox(width: 8), const Text("StreamFlow", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))]),
              GestureDetector(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())), child: const Icon(Icons.settings_rounded, color: cTextDim))
            ]),
          )))),
        ],
      ),
      bottomNavigationBar: _buildNavBar(),
    );
  }

  Widget _buildNavBar() {
    List<NavigationDestination> items = [];
    if (appState.mode == 'anime') {
      items = const [NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'), NavigationDestination(icon: Icon(Icons.explore_rounded), label: 'Browse'), NavigationDestination(icon: Icon(Icons.search_rounded), label: 'Search')];
    } else if (appState.mode == 'live') {
      items = const [NavigationDestination(icon: Icon(Icons.live_tv_rounded), label: 'Live')];
    } else {
      items = const [NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'), NavigationDestination(icon: Icon(Icons.movie_rounded), label: 'Movies'), NavigationDestination(icon: Icon(Icons.tv_rounded), label: 'Series'), NavigationDestination(icon: Icon(Icons.search_rounded), label: 'Search')];
    }

    return NavigationBarTheme(
      data: NavigationBarThemeData(indicatorColor: Colors.transparent, iconTheme: MaterialStateProperty.resolveWith((s) => IconThemeData(color: s.contains(MaterialState.selected) ? appState.primary : cTextDim)), labelTextStyle: MaterialStateProperty.all(const TextStyle(fontSize: 10))),
      child: NavigationBar(height: 65, backgroundColor: cSurface.withOpacity(0.95), selectedIndex: _idx, onDestinationSelected: (i) => setState(() => _idx = i), destinations: items),
    );
  }
}

// --- HOME PAGE ---
class HomeView extends StatefulWidget {
  const HomeView({super.key});
  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  bool _loading = true;
  List<MediaItem> _hero = [];
  List<Widget> _sections = [];

  @override
  void initState() { super.initState(); _fetch(); }

  Future<void> _fetch() async {
    setState(() { _loading = true; _sections.clear(); });
    
    if (appState.mode == 'tmdb') {
      final t = await Api.getTmdb('/trending/all/week');
      final m = await Api.getTmdb('/movie/top_rated');
      final s = await Api.getTmdb('/tv/top_rated');
      if (t!=null) { _hero = (t['results'] as List).take(5).map((e) => Api.normTmdb(e)).toList(); _sections.add(_row('Trending', (t['results'] as List).map((e)=>Api.normTmdb(e)).toList())); }
      if (m!=null) _sections.add(_row('Top Movies', (m['results'] as List).map((e)=>Api.normTmdb(e)).toList()));
      if (s!=null) _sections.add(_row('Top Series', (s['results'] as List).map((e)=>Api.normTmdb(e)).toList()));
    } 
    else if (appState.mode == 'anime') {
      final d = await Api.postAni('query { trending: Page(page:1, perPage:10){media(sort:TRENDING_DESC, type:ANIME){...m}} popular: Page(page:1, perPage:10){media(sort:POPULARITY_DESC, type:ANIME){...m}} } fragment m on Media { id title{english romaji} coverImage{extraLarge} bannerImage averageScore startDate{year} format status description }');
      if (d!=null) {
         _hero = (d['trending']['media'] as List).take(5).map((e) => Api.normAni(e)).toList();
         _sections.add(_row('Trending Now', (d['trending']['media'] as List).map((e)=>Api.normAni(e)).toList()));
         _sections.add(_row('All Time Popular', (d['popular']['media'] as List).map((e)=>Api.normAni(e)).toList()));
      }
    } 
    else {
      final ev = await Api.getLive();
      List<dynamic> now = [], cats = [];
      Map<String, List> grouped = {};
      final time = DateTime.now().toUtc();

      for (var e in ev) {
        if (e['publish'] != 1) continue;
        DateTime start = DateTime.parse(e['eventInfo']['startTime'].toString().replaceAll(' +0000', ''));
        DateTime end = DateTime.parse(e['eventInfo']['endTime'].toString().replaceAll(' +0000', ''));
        String cat = e['eventInfo']['eventCat'] ?? 'Other';
        if (time.isAfter(start) && time.isBefore(end)) now.add(e);
        if (!grouped.containsKey(cat)) grouped[cat] = [];
        grouped[cat]!.add(e);
      }
      if (now.isNotEmpty) _sections.add(_liveRow('Live Now', now, true));
      for (var k in grouped.keys) _sections.add(_liveRow(k, grouped[k]!, false));
    }
    setState(() => _loading = false);
  }

  Widget _row(String t, List<MediaItem> l) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Padding(padding: const EdgeInsets.symmetric(horizontal:16, vertical:10), child: Row(children: [Container(width:4, height:18, color: appState.primary), const SizedBox(width:8), Text(t, style: const TextStyle(fontWeight: FontWeight.bold, fontSize:18))])),
    SizedBox(height: 220, child: ListView.separated(padding: const EdgeInsets.symmetric(horizontal:16), scrollDirection: Axis.horizontal, itemCount: l.length, separatorBuilder: (_,__)=>const SizedBox(width:12), itemBuilder: (_,i) => MediaCard(item: l[i])))
  ]);

  Widget _liveRow(String t, List l, bool live) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Padding(padding: const EdgeInsets.symmetric(horizontal:16, vertical:10), child: Row(children: [live ? const Icon(Icons.circle, size:10, color: Colors.red) : Container(width:4, height:18, color: appState.primary), const SizedBox(width:8), Text(t, style: const TextStyle(fontWeight: FontWeight.bold, fontSize:18))])),
    SizedBox(height: 160, child: ListView.separated(padding: const EdgeInsets.symmetric(horizontal:16), scrollDirection: Axis.horizontal, itemCount: l.length, separatorBuilder: (_,__)=>const SizedBox(width:12), itemBuilder: (_,i) => LiveCard(data: l[i], isLive: live)))
  ]);

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (appState.mode == 'live') return ListView(padding: const EdgeInsets.only(top:100, bottom:100), children: [const Padding(padding: EdgeInsets.symmetric(horizontal:20), child: Text("Live Sports", style: TextStyle(fontSize:32, fontWeight: FontWeight.bold))), const Padding(padding: EdgeInsets.symmetric(horizontal:20), child: Text("Watch live events.", style: TextStyle(color: cTextDim))), const SizedBox(height:20), ..._sections]);
    return ListView(padding: EdgeInsets.zero, children: [if(_hero.isNotEmpty) HeroCarousel(items: _hero), const SizedBox(height:20), ..._sections, const SizedBox(height:100)]);
  }
}

// --- DETAILS PAGE (1:1 UI) ---
class DetailsPage extends StatefulWidget {
  final MediaItem item;
  const DetailsPage({super.key, required this.item});
  @override
  State<DetailsPage> createState() => _DetailsPageState();
}

class _DetailsPageState extends State<DetailsPage> {
  MediaItem? fullData;

  @override
  void initState() {
    super.initState();
    _loadFull();
  }

  Future<void> _loadFull() async {
    if (appState.mode == 'tmdb') {
      final d = await Api.getTmdb('/${widget.item.type}/${widget.item.id}', '&append_to_response=images,credits,reviews,recommendations,similar');
      if (d!=null) setState(() => fullData = Api.normTmdb(d, true));
    } else {
      final d = await Api.postAni('query (\$id: Int) { Media(id: \$id) { id title { english romaji } coverImage { extraLarge } bannerImage description averageScore startDate { year } status genres format episodes characters(sort: ROLE, perPage: 10) { nodes { name { full } image { large } } } relations { edges { relationType node { id title { english romaji } coverImage { large } format } } } recommendations(sort: RATING_DESC, perPage: 10) { nodes { mediaRecommendation { id title { english romaji } coverImage { extraLarge } averageScore startDate { year } format } } } } }', {'id': widget.item.id});
      if (d!=null) setState(() => fullData = Api.normAni(d['Media']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = fullData ?? widget.item;
    return Scaffold(
      backgroundColor: cBg,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 450,
            pinned: true,
            backgroundColor: cBg,
            leading: IconButton(icon: Container(padding: const EdgeInsets.all(8), decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle), child: const Icon(Icons.close)), onPressed: () => Navigator.pop(context)),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(imageUrl: data.backdrop ?? data.image!, fit: BoxFit.cover),
                  Container(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, cBg], stops: [0.3, 1.0]))),
                  Positioned(bottom: 20, left: 0, right: 0, child: Column(children: [
                    // LOGO OR TITLE
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 40), child: Text(data.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, height: 1.1))),
                  ]))
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  // Metadata Row
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(data.year, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8), const Icon(Icons.circle, size: 4, color: cTextDim), const SizedBox(width: 8),
                    Icon(Icons.star_rounded, size: 16, color: appState.primary), const SizedBox(width: 4), Text(data.rating, style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8), const Icon(Icons.circle, size: 4, color: cTextDim), const SizedBox(width: 8),
                    Text(data.type.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 15),
                  // Genres
                  Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: data.genres.map((g) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: cHighlight, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white10)), child: Text(g, style: const TextStyle(fontSize: 12, color: cTextDim)))).toList()),
                  const SizedBox(height: 25),
                  // Play Button
                  SizedBox(width: double.infinity, height: 50, child: ElevatedButton.icon(
                    onPressed: () => Navigator.push(context, PageRouteBuilder(pageBuilder: (_,__,___) => PlayerPage(item: data), transitionsBuilder: (_,a,__,c) => SlideTransition(position: Tween(begin: const Offset(0,1), end: Offset.zero).animate(a), child: c))),
                    icon: const Icon(Icons.play_arrow_rounded, color: cBg), label: const Text("Play Now", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    style: ElevatedButton.styleFrom(backgroundColor: cText, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  )),
                  const SizedBox(height: 30),
                  // Synopsis
                  const Align(alignment: Alignment.centerLeft, child: Text("Synopsis", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                  const SizedBox(height: 8),
                  Text(data.overview, style: const TextStyle(color: cTextDim, height: 1.6), textAlign: TextAlign.justify),
                  const SizedBox(height: 30),
                  
                  // Cast
                  if (data.cast.isNotEmpty) ...[
                    _sectionHeader("Top Cast", appState.primary),
                    SizedBox(height: 120, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: data.cast.length, separatorBuilder: (_,__)=>const SizedBox(width:15), itemBuilder: (_,i) => Column(children: [
                      Container(width: 80, height: 80, decoration: BoxDecoration(shape: BoxShape.circle, image: DecorationImage(image: NetworkImage(data.cast[i].image), fit: BoxFit.cover), border: Border.all(color: Colors.white10))),
                      const SizedBox(height: 6), SizedBox(width: 80, child: Text(data.cast[i].name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)))
                    ]))),
                    const SizedBox(height: 30),
                  ],

                  // Reviews
                  if (data.reviews.isNotEmpty) ...[
                     _sectionHeader("Reviews", Colors.amber),
                     SizedBox(height: 150, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: data.reviews.length, separatorBuilder: (_,__)=>const SizedBox(width:15), itemBuilder: (_,i) => Container(
                       width: 280, padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: cHighlight, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white10)),
                       child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                         Row(children: [CircleAvatar(radius: 12, backgroundColor: appState.primary, child: Text(data.reviews[i].author[0], style: const TextStyle(fontSize: 12))), const SizedBox(width: 8), Text(data.reviews[i].author, style: const TextStyle(fontWeight: FontWeight.bold))]),
                         const SizedBox(height: 8), Expanded(child: Text(data.reviews[i].content, overflow: TextOverflow.ellipsis, maxLines: 5, style: const TextStyle(fontSize: 12, color: cTextDim, height: 1.4)))
                       ]),
                     ))),
                     const SizedBox(height: 30),
                  ],

                  // Related
                  if (data.relations.isNotEmpty) ...[
                    _sectionHeader("Related", Colors.purple),
                    SizedBox(height: 220, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: data.relations.length, separatorBuilder: (_,__)=>const SizedBox(width:12), itemBuilder: (_,i) => MediaCard(item: data.relations[i])))
                  ],
                  // Recs
                  if (data.recommendations.isNotEmpty) ...[
                    _sectionHeader("More Like This", Colors.green),
                    SizedBox(height: 220, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: data.recommendations.length, separatorBuilder: (_,__)=>const SizedBox(width:12), itemBuilder: (_,i) => MediaCard(item: data.recommendations[i])))
                  ],
                  const SizedBox(height: 50),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _sectionHeader(String t, Color c) => Padding(padding: const EdgeInsets.only(bottom: 15), child: Row(children: [Container(width: 4, height: 20, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))), const SizedBox(width: 10), Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))]));
}

// --- PLAYER PAGE (1:1 UI & LOGIC) ---
class PlayerPage extends StatefulWidget {
  final MediaItem? item; // For TMDB/Anime
  final String? url; // For Live (direct)
  final String? title; // For Live
  final bool isLive;

  const PlayerPage({super.key, this.item, this.url, this.title, this.isLive = false});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late WebViewController _web;
  bool _loading = true;
  int _season = 1;
  int _episode = 1;
  List<Episode> _episodes = [];
  
  // For Anime Pagination
  int _rangeStart = 1;
  int _rangeEnd = 100;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) => setState(() => _loading = false)));
    
    if (widget.isLive || widget.url != null) {
      _web.loadRequest(Uri.parse(widget.url!));
    } else {
      _initSource();
    }
  }

  Future<void> _initSource() async {
    if (widget.item!.type == 'movie') {
      _web.loadRequest(Uri.parse('${kSrcTmdb}?tmdbid=${widget.item!.id}'));
    } else if (appState.mode == 'tmdb') {
      // Load Seasons logic if TMDB TV
      if (widget.item!.seasons.isNotEmpty) {
        _season = widget.item!.seasons[0].number;
      }
      await _loadTmdbEps();
    } else {
      // Anime Logic
      await _loadAnimeEps();
    }
  }

  Future<void> _loadTmdbEps() async {
    setState(() { _episodes.clear(); _loading = true; }); // Loading UI for list
    final d = await Api.getTmdb('/tv/${widget.item!.id}/season/$_season');
    if (d!=null && d['episodes']!=null) {
       _episodes = (d['episodes'] as List).map((e) => Episode(number: e['episode_number'], title: e['name'], desc: e['overview'] ?? 'No Description', image: e['still_path'] != null ? '$kTmdbImg${e['still_path']}' : widget.item!.backdrop)).toList();
       _play(_episodes[0].number);
    }
    setState(() => _loading = false);
  }

  Future<void> _loadAnimeEps() async {
    // Fallback logic from JS: if no API, generate 1 to totalEp
    int total = widget.item!.episodeCount > 0 ? widget.item!.episodeCount : 12;
    _episodes = List.generate(total, (i) => Episode(number: i+1, title: 'Episode ${i+1}', desc: 'No Data', image: widget.item!.backdrop));
    
    // Attempt to load from AniList if we wanted detailed ep info, but standard JS logic often just uses numbers
    // Here we implement the range tabs logic if total > 50
    if (total > 50) {
      _rangeEnd = 50; 
    } else {
      _rangeEnd = total;
    }
    _play(1);
    setState(() {});
  }

  void _play(int ep) {
    setState(() { _episode = ep; _loading = true; });
    String link = "";
    if (appState.mode == 'tmdb') {
       link = '${kSrcTmdb}?tmdbid=${widget.item!.id}&s=$_season&e=$ep';
    } else {
       link = '${kSrcAnime}?id=${widget.item!.id}&e=$ep';
    }
    _web.loadRequest(Uri.parse(link));
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.item?.title ?? widget.title ?? 'Live Stream';
    final subtitle = widget.isLive ? 'LIVE' : (widget.item?.type == 'movie' ? 'Movie' : 'S$_season:E$_episode');

    return Scaffold(
      backgroundColor: cBg,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(height: 50, padding: const EdgeInsets.symmetric(horizontal: 10), color: cHighlight, child: Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: cTextDim), onPressed: () => Navigator.pop(context)),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(subtitle, style: TextStyle(fontSize: 10, color: appState.primary, fontWeight: FontWeight.bold))
              ]))
            ])),
            
            // Video Player
            AspectRatio(
              aspectRatio: 16/9,
              child: Stack(children: [
                WebViewWidget(controller: _web),
                if (_loading) Container(color: Colors.black, child: const Center(child: CircularProgressIndicator())),
              ]),
            ),

            // Sidebar / Content
            Expanded(
              child: widget.isLive || widget.item?.type == 'movie' 
                ? _buildMovieUI() 
                : _buildSeriesUI(), // Sidebar logic
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMovieUI() {
    if (widget.isLive) return const Center(child: Text("Live Stream", style: TextStyle(color: Colors.red)));
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width: 120, height: 180, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), image: DecorationImage(image: NetworkImage(widget.item!.image!), fit: BoxFit.cover))),
      const SizedBox(height: 20),
      const Text("Now Playing", style: TextStyle(color: cTextDim, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
      const SizedBox(height: 5),
      Padding(padding: const EdgeInsets.all(20), child: Text(widget.item!.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)))
    ]));
  }

  Widget _buildSeriesUI() {
    return Column(
      children: [
        // Tabs
        Container(
          height: 60,
          color: cBg,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(10),
            children: appState.mode == 'tmdb' 
              ? widget.item!.seasons.map((s) => _tab("Season ${s.number}", _season == s.number, () { setState(() => _season = s.number); _loadTmdbEps(); })).toList()
              : _buildAnimeTabs()
          ),
        ),
        const Divider(height: 1, color: Colors.white10),
        // Episode List
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(10),
            itemCount: appState.mode == 'tmdb' ? _episodes.length : (_rangeEnd - _rangeStart + 1),
            separatorBuilder: (_,__) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) {
               // Adjust index for Anime Ranges
               int idx = appState.mode == 'tmdb' ? i : (_rangeStart + i - 1);
               if (idx >= _episodes.length) return const SizedBox();
               final ep = _episodes[idx];
               final active = ep.number == _episode;
               
               return GestureDetector(
                 onTap: () => _play(ep.number),
                 child: Container(
                   padding: const EdgeInsets.all(8),
                   decoration: BoxDecoration(color: active ? appState.primary.withOpacity(0.1) : Colors.transparent, borderRadius: BorderRadius.circular(8), border: Border.all(color: active ? appState.primary : Colors.transparent)),
                   child: Row(children: [
                     SizedBox(width: 30, child: Text(ep.number.toString(), style: const TextStyle(color: cTextDim, fontWeight: FontWeight.bold))),
                     Container(width: 100, height: 56, decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: cHighlight, image: ep.image != null ? DecorationImage(image: NetworkImage(ep.image!), fit: BoxFit.cover) : null)),
                     const SizedBox(width: 10),
                     Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                       Text(ep.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.bold, color: active ? appState.primary : cText)),
                       Text(ep.desc, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: cTextDim))
                     ]))
                   ]),
                 ),
               );
            },
          ),
        ),
      ],
    );
  }

  List<Widget> _buildAnimeTabs() {
    int total = _episodes.length;
    int chunkSize = total > 150 ? 50 : 20;
    List<Widget> tabs = [];
    for (int i = 0; i < total; i += chunkSize) {
       int start = i + 1;
       int end = (i + chunkSize) > total ? total : (i + chunkSize);
       tabs.add(_tab("$start-$end", _rangeStart == start, () => setState(() { _rangeStart = start; _rangeEnd = end; })));
    }
    return tabs;
  }

  Widget _tab(String t, bool active, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(margin: const EdgeInsets.only(right: 10), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: active ? appState.primary : cHighlight, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white10)), child: Center(child: Text(t, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: active ? Colors.white : cTextDim)))),
  );
}

// --- SHARED WIDGETS ---
class HeroCarousel extends StatefulWidget {
  final List<MediaItem> items;
  const HeroCarousel({super.key, required this.items});
  @override
  State<HeroCarousel> createState() => _HeroCarouselState();
}
class _HeroCarouselState extends State<HeroCarousel> {
  final _c = PageController();
  int _i = 0;
  @override void initState() { super.initState(); Timer.periodic(const Duration(seconds:6), (t) { if(mounted) { _i=(_i+1)%widget.items.length; _c.animateToPage(_i, duration: const Duration(seconds:1), curve: Curves.easeInOut); }}); }
  @override Widget build(BuildContext context) => SizedBox(height: 420, child: Stack(children: [
    PageView.builder(controller: _c, onPageChanged: (i)=>setState(()=>_i=i), itemCount: widget.items.length, itemBuilder: (_,i) => CachedNetworkImage(imageUrl: widget.items[i].backdrop!, fit: BoxFit.cover)),
    Container(decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, cBg]))),
    Positioned(bottom: 20, left: 20, right: 20, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
       Text(widget.items[_i].title, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900, height: 1.1)),
       const SizedBox(height: 10), Text(widget.items[_i].overview, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cTextDim)),
       const SizedBox(height: 15), ElevatedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsPage(item: widget.items[_i]))), icon: const Icon(Icons.play_arrow, color: Colors.black), label: const Text("Watch Now", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)), style: ElevatedButton.styleFrom(backgroundColor: Colors.white))
    ])),
    Positioned(bottom: 20, right: 20, child: Row(children: List.generate(widget.items.length, (i)=>AnimatedContainer(duration: const Duration(milliseconds: 300), margin: const EdgeInsets.only(left: 5), width: _i==i?20:6, height: 6, decoration: BoxDecoration(color: _i==i?appState.primary:Colors.white54, borderRadius: BorderRadius.circular(3))))))
  ]));
}

class MediaCard extends StatelessWidget {
  final MediaItem item;
  final bool isGrid;
  const MediaCard({super.key, required this.item, this.isGrid=false});
  @override Widget build(BuildContext context) => GestureDetector(
    onTap: () => Navigator.push(context, PageRouteBuilder(pageBuilder: (_,__,___)=>DetailsPage(item: item), transitionsBuilder: (_,a,__,c)=>SlideTransition(position: Tween(begin: const Offset(1,0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutExpo)), child: c))),
    child: SizedBox(width: isGrid?null:140, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Container(decoration: BoxDecoration(color: cHighlight, borderRadius: BorderRadius.circular(12), image: DecorationImage(image: NetworkImage(item.image!), fit: BoxFit.cover)))),
      const SizedBox(height: 6), Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
      Text("${item.year} • ${item.type.toUpperCase()}", style: const TextStyle(fontSize: 10, color: cTextDim))
    ]))
  );
}

class LiveCard extends StatelessWidget {
  final dynamic data; final bool isLive;
  const LiveCard({super.key, required this.data, required this.isLive});
  @override Widget build(BuildContext context) {
    final i = data['eventInfo'];
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerPage(isLive: true, url: '${kSrcLive}?url=${data['slug']}', title: i['eventName']))),
      child: Container(width: 280, padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: cSurface, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white10)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Row(children: [if(i['eventLogo']!=null) Image.network(i['eventLogo'], width: 20), const SizedBox(width: 8), Text(i['eventType']??'EVENT', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: cTextDim))]), if(isLive) Container(padding: const EdgeInsets.symmetric(horizontal:6, vertical:2), decoration: BoxDecoration(color: Colors.red.withOpacity(0.2), borderRadius: BorderRadius.circular(4)), child: const Text("LIVE", style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.bold)))]),
        const Spacer(),
        Row(children: [Expanded(child: Column(children: [CircleAvatar(backgroundImage: NetworkImage(i['teamAFlag']??''), radius: 15), const SizedBox(height:4), Text(i['teamA'], maxLines:1, overflow:TextOverflow.ellipsis, style: const TextStyle(fontSize:12, fontWeight: FontWeight.bold))])), const Text("VS", style: TextStyle(color:Colors.white24, fontWeight: FontWeight.w900)), Expanded(child: Column(children: [CircleAvatar(backgroundImage: NetworkImage(i['teamBFlag']??''), radius: 15), const SizedBox(height:4), Text(i['teamB'], maxLines:1, overflow:TextOverflow.ellipsis, style: const TextStyle(fontSize:12, fontWeight: FontWeight.bold))]))]),
        const Spacer(), const Divider(height:1, color:Colors.white10), const SizedBox(height:5),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Expanded(child: Text(i['eventName'], maxLines:1, overflow:TextOverflow.ellipsis, style: const TextStyle(fontSize:11, color:cTextDim))), const Text("Watch", style: TextStyle(fontSize:11, fontWeight: FontWeight.bold))])
      ]))
    );
  }
}

class GridViewPage extends StatefulWidget { final String mode; const GridViewPage({super.key, required this.mode}); @override State<GridViewPage> createState() => _GState(); }
class _GState extends State<GridViewPage> {
  List<MediaItem> _l = []; int _p = 1; bool _loading = false; String _g = '', _y = '';
  @override void initState() { super.initState(); _fetch(); }
  Future<void> _fetch() async {
    if (_loading) return; setState(() => _loading = true);
    if (widget.mode == 'browse') {
       String f = ''; if(_g.isNotEmpty) f+=', genre: "$_g"'; if(_y.isNotEmpty) f+=', seasonYear: $_y';
       final d = await Api.postAni('query(\$p:Int){Page(page:\$p, perPage:18){media(type:ANIME, sort:POPULARITY_DESC $f){id title{english romaji} coverImage{extraLarge} averageScore startDate{year} format}}}', {'p': _p});
       if(d!=null) _l.addAll((d['Page']['media'] as List).map((e)=>Api.normAni(e)));
    } else {
       final d = await Api.getTmdb('/discover/${widget.mode}', '&page=$_p');
       if(d!=null) _l.addAll((d['results'] as List).map((e)=>Api.normTmdb(e)));
    }
    if(mounted) setState(() { _loading=false; _p++; });
  }
  @override Widget build(BuildContext context) => Column(children: [
    SizedBox(height: MediaQuery.of(context).padding.top + 70),
    if(widget.mode == 'browse') SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal:16), children: [_drop('Genre', ['Action','Adventure','Comedy','Drama','Fantasy'], _g, (v){setState(()=>_g=v); _l.clear(); _p=1; _fetch();}), const SizedBox(width:10), _drop('Year', List.generate(20, (i)=>(2024-i).toString()), _y, (v){setState(()=>_y=v); _l.clear(); _p=1; _fetch();})])),
    Expanded(child: GridView.builder(padding: const EdgeInsets.all(16), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.64, mainAxisSpacing: 10, crossAxisSpacing: 10), itemCount: _l.length, itemBuilder: (_,i) { if(i==_l.length-2) _fetch(); return MediaCard(item: _l[i], isGrid: true); }))
  ]);
  Widget _drop(String h, List<String> i, String v, Function(String) c) => Container(padding: const EdgeInsets.symmetric(horizontal:12), decoration: BoxDecoration(color: cHighlight, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white10)), child: DropdownButton<String>(value: v.isEmpty?null:v, hint: Text(h, style: const TextStyle(fontSize:12, color: cTextDim)), underline: const SizedBox(), dropdownColor: cSurface, items: i.map((e)=>DropdownMenuItem(value:e, child: Text(e, style: const TextStyle(fontSize:12)))).toList(), onChanged: (val)=>c(val!)));
}

class SearchView extends StatefulWidget { const SearchView({super.key}); @override State<SearchView> createState() => _SState(); }
class _SState extends State<SearchView> {
  final _c = TextEditingController(); List<MediaItem> _l = []; Timer? _t;
  void _s(String q) { if(_t?.isActive??false) _t!.cancel(); _t = Timer(const Duration(milliseconds:500), () async { if(q.isEmpty){setState(()=>_l.clear()); return;} if(appState.mode == 'tmdb') { final d = await Api.getTmdb('/search/multi', '&query=$q'); if(d!=null) setState(()=>_l = (d['results'] as List).where((e)=>e['media_type']!='person').map((e)=>Api.normTmdb(e)).toList()); } else { final d = await Api.postAni('query(\$s:String){Page(perPage:20){media(search:\$s, type:ANIME){id title{english romaji} coverImage{extraLarge} averageScore startDate{year} format}}}', {'s':q}); if(d!=null) setState(()=>_l = (d['Page']['media'] as List).map((e)=>Api.normAni(e)).toList()); }}); }
  @override Widget build(BuildContext context) => Column(children: [SizedBox(height: MediaQuery.of(context).padding.top + 80), Padding(padding: const EdgeInsets.symmetric(horizontal:20), child: TextField(controller: _c, onChanged: _s, decoration: InputDecoration(filled: true, fillColor: cHighlight, hintText: "Search titles...", prefixIcon: const Icon(Icons.search, color: cTextDim), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)))), Expanded(child: GridView.builder(padding: const EdgeInsets.all(20), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.64, mainAxisSpacing: 10, crossAxisSpacing: 10), itemCount: _l.length, itemBuilder: (_,i) => MediaCard(item: _l[i], isGrid: true)))]);
}

class SettingsPage extends StatelessWidget { const SettingsPage({super.key});
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(backgroundColor: Colors.transparent, title: const Text("Settings")), body: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text("CONTENT SOURCE", style: TextStyle(color: cTextDim, fontSize: 12, fontWeight: FontWeight.bold)), const SizedBox(height:10),
    _opt(context, 'tmdb', 'Movies & TV', Icons.movie, Colors.indigo), _opt(context, 'anime', 'Anime Mode', Icons.smart_toy, Colors.pink), _opt(context, 'live', 'Live Events', Icons.live_tv, Colors.red)
  ])));
  Widget _opt(BuildContext ctx, String k, String t, IconData i, Color c) { final a = appState.mode == k; return ListTile(onTap: (){appState.setMode(k); Navigator.pop(ctx);}, leading: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: c.withOpacity(0.2), shape: BoxShape.circle), child: Icon(i, color: c)), title: Text(t, style: TextStyle(fontWeight: FontWeight.bold, color: a?c:Colors.white)), trailing: a?Icon(Icons.check_circle, color:c):null, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: a?c:Colors.white10))); }
}
