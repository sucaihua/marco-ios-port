import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 豆瓣「热播 / 榜单」条目，字段与影视仓首页「豆瓣热播」列表一致。
class DoubanFeedItem {
  const DoubanFeedItem({
    required this.title,
    required this.subjectId,
    required this.cover,
    required this.rate,
  });

  final String title;
  final String subjectId;
  final String cover;
  final double rate;
}

/// 豆瓣热播数据源。
///
/// 与影视仓同源：使用豆瓣 `new_search_subjects` 接口按分类标签拉取榜单，
/// 并携带浏览器 UA 与 movie.douban.com 的 Referer，否则豆瓣会返回空列表。
class DoubanFeed {
  DoubanFeed._();

  static const String _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const Map<String, String> _headers = <String, String>{
    'User-Agent': _ua,
    'Referer': 'https://movie.douban.com/',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'zh-CN,zh;q=0.9',
  };

  /// 首页「豆瓣热播」分类栏，顺序与影视仓保持一致。
  static const List<String> categories = <String>[
    '热门',
    '电影',
    '电视剧',
    '综艺',
    '动漫',
    '纪录片',
  ];

  /// 分类标签 → 豆瓣 tags 参数。
  static String _tagFor(String category) {
    switch (category) {
      case '电影':
        return '电影';
      case '电视剧':
        return '电视剧';
      case '综艺':
        return '综艺';
      case '动漫':
        return '动漫';
      case '纪录片':
        return '纪录片';
      default:
        return '';
    }
  }

  static String _sortFor(String category) => category == '热门' ? 'S' : 'U';

  static final Map<String, List<DoubanFeedItem>> _cache =
      <String, List<DoubanFeedItem>>{};

  static final Map<String, DateTime> _cacheAt = <String, DateTime>{};

  /// 内存缓存有效期，避免首页每次重建都打豆瓣。
  static const Duration cacheTtl = Duration(minutes: 20);

  static List<DoubanFeedItem>? cached(String category) {
    final hit = _cache[category];
    if (hit == null || hit.isEmpty) return null;
    final at = _cacheAt[category];
    if (at == null) return hit;
    if (DateTime.now().difference(at) > cacheTtl) return null;
    return hit;
  }

  static Future<List<DoubanFeedItem>> fetch(
    String category, {
    int start = 0,
    int count = 20,
    bool force = false,
  }) async {
    if (!force && start == 0) {
      final hit = cached(category);
      if (hit != null) return hit;
    }
    final tag = _tagFor(category);
    final uri = Uri.parse(
      'https://movie.douban.com/j/new_search_subjects'
      '?sort=${_sortFor(category)}&range=0,10'
      '&tags=${Uri.encodeComponent(tag)}&playable=1'
      '&start=$start&year_range=',
    );
    final items = await _request(uri, count);
    if (start == 0 && items.isNotEmpty) {
      _cache[category] = items;
      _cacheAt[category] = DateTime.now();
    }
    return items;
  }

  static Future<List<DoubanFeedItem>> _request(Uri uri, int count) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 9));
      _headers.forEach(req.headers.set);
      final resp =
          await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        throw HttpException('豆瓣接口返回 ${resp.statusCode}', uri: uri);
      }
      final body = await resp
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 12));
      return _parse(body, count);
    } finally {
      client.close(force: true);
    }
  }

  static List<DoubanFeedItem> _parse(String body, int count) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return const <DoubanFeedItem>[];
    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return const <DoubanFeedItem>[];
    }
    if (decoded is! Map) return const <DoubanFeedItem>[];
    final raw = decoded['subjects'];
    if (raw is! List) return const <DoubanFeedItem>[];
    final out = <DoubanFeedItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final title = (entry['title'] ?? '').toString().trim();
      if (title.isEmpty) continue;
      final cover = (entry['cover'] ?? '').toString().trim();
      final id = (entry['id'] ?? '').toString().trim();
      final rateRaw = entry['rate'];
      final rate = rateRaw is num
          ? rateRaw.toDouble()
          : double.tryParse('${rateRaw ?? ''}') ?? 0;
      out.add(
        DoubanFeedItem(
          title: title,
          subjectId: id,
          cover: cover,
          rate: rate,
        ),
      );
      if (out.length >= count) break;
    }
    return out;
  }
}
