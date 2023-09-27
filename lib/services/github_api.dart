import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:injectable/injectable.dart';
import 'package:revanced_manager/app/app.locator.dart';
import 'package:revanced_manager/models/patch.dart';
import 'package:revanced_manager/services/manager_api.dart';

@lazySingleton
class GithubAPI {
  late Dio _dio = Dio();
  late final ManagerAPI _managerAPI = locator<ManagerAPI>();

  final _cacheOptions = CacheOptions(
    store: MemCacheStore(),
    maxStale: const Duration(days: 1),
    priority: CachePriority.high,
  );

  final Map<String, String> repoAppPath = {
    'com.google.android.youtube': 'youtube',
    'com.google.android.apps.youtube.music': 'music',
    'com.twitter.android': 'twitter',
    'com.reddit.frontpage': 'reddit',
    'com.zhiliaoapp.musically': 'tiktok',
    'de.dwd.warnapp': 'warnwetter',
    'com.garzotto.pflotsh.ecmwf_a': 'ecmwf',
    'com.spotify.music': 'spotify',
  };

  Future<void> initialize(String repoUrl) async {
    try {
      _dio = Dio(
        BaseOptions(
          baseUrl: repoUrl,
        ),
      );

      _dio.interceptors.add(DioCacheInterceptor(options: _cacheOptions));
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }
  }

  Future<void> clearAllCache() async {
    try {
      await _cacheOptions.store!.clean();
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }
  }

  Future<Map<String, dynamic>?> getLatestRelease(
    String repoName,
  ) async {
    try {
      final response = await _dio.get(
        '/repos/$repoName/releases',
      );
      return response.data[0];
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
      return null;
    }
  }

  Future<Map<String, dynamic>?> getPatchesRelease(
    String repoName,
    String version,
  ) async {
    try {
      final response = await _dio.get(
        '/repos/$repoName/releases/tags/$version',
      );
      return response.data;
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
      return null;
    }
  }

  Future<Map<String, dynamic>?> getLatestPatchesRelease(
    String repoName,
  ) async {
    try {
      final response = await _dio.get(
        '/repos/$repoName/releases/latest',
      );
      return response.data;
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
      return null;
    }
  }

  Future<Map<String, dynamic>?> getLatestManagerRelease(
    String repoName,
  ) async {
    try {
      final response = await _dio.get(
        '/repos/$repoName/releases',
      );
      final Map<String, dynamic> releases = response.data[0];
      int updates = 0;
      final String currentVersion =
          await ManagerAPI().getCurrentManagerVersion();
      while (response.data[updates]['tag_name'] != 'v$currentVersion') {
        updates++;
      }
      for (int i = 1; i < updates; i++) {
        releases.update(
          'body',
          (value) =>
              value +
              '\n' +
              '# ' +
              response.data[i]['tag_name'] +
              '\n' +
              response.data[i]['body'],
        );
      }
      return releases;
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
      return null;
    }
  }

  Future<List<String>> getCommits(
    String packageName,
    String repoName,
    DateTime since,
  ) async {
    final String path =
        'src/main/kotlin/app/revanced/patches/${repoAppPath[packageName]}';
    try {
      final response = await _dio.get(
        '/repos/$repoName/commits',
        queryParameters: {
          'path': path,
          'since': since.toIso8601String(),
        },
      );
      final List<dynamic> commits = response.data;
      return commits
          .map(
            (commit) => commit['commit']['message'].split('\n')[0] +
                ' - ' +
                commit['commit']['author']['name'] +
                '\n' as String,
          )
          .toList();
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }
    return [];
  }

  Future<File?> getLatestReleaseFile(
    String extension,
    String repoName,
  ) async {
    try {
      final Map<String, dynamic>? release = await getLatestRelease(repoName);
      if (release != null) {
        final Map<String, dynamic>? asset =
            (release['assets'] as List<dynamic>).firstWhereOrNull(
          (asset) => (asset['name'] as String).endsWith(extension),
        );
        if (asset != null) {
          return await DefaultCacheManager().getSingleFile(
            asset['browser_download_url'],
          );
        }
      }
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }
    return null;
  }

  Future<File?> getPatchesReleaseFile(
    String extension,
    String repoName,
    String version,
    String url,
  ) async {
    try {
      if (url.isNotEmpty) {
        return await DefaultCacheManager().getSingleFile(
          url,
        );
      }
      final Map<String, dynamic>? release =
          await getPatchesRelease(repoName, version);
      if (release != null) {
        final Map<String, dynamic>? asset =
            (release['assets'] as List<dynamic>).firstWhereOrNull(
          (asset) => (asset['name'] as String).endsWith(extension),
        );
        if (asset != null) {
          final String downloadUrl = asset['browser_download_url'];
          if (extension == '.apk') {
            _managerAPI.setIntegrationsDownloadURL(downloadUrl);
          } else {
            _managerAPI.setPatchesDownloadURL(downloadUrl);
          }
          return await DefaultCacheManager().getSingleFile(
            downloadUrl,
          );
        }
      }
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }
    return null;
  }

  Future<List<Patch>> getPatches(
    String repoName,
    String version,
    String url,
  ) async {
    List<Patch> patches = [];
    try {
      final File? f = await getPatchesReleaseFile(
        '.json',
        repoName,
        version,
        url,
      );
      if (f != null) {
        final List<dynamic> list = jsonDecode(f.readAsStringSync());
        patches = list.map((patch) => Patch.fromJson(patch)).toList();
      }
    } on Exception catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }

    return patches;
  }
}
