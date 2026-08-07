import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

/// Duenne HTTP-Basis fuer die Backend-REST-API. Bewusst generisch
/// (GET/POST-Multipart/DELETE, Fehler-Parsing des `detail`-Felds wie in app.js)
/// statt pro Endpunkt hartkodiert: wenn spaetere Backend-Phasen (Sync/Scoring/
/// Feedback) neue Endpunkte bringen, kommen dafuer weitere *Api-Klassen dazu,
/// ohne dass diese Basis-Klasse angefasst werden muss.
class ApiClient {
  final String baseUrl;
  final http.Client _http;

  ApiClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
        _http = httpClient ?? http.Client();

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.parse('$baseUrl$path').replace(queryParameters: query);
  }

  Map<String, dynamic> _decode(http.Response response) {
    final body = response.body.isEmpty ? '{}' : response.body;
    final decoded = jsonDecode(body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded as Map<String, dynamic>;
    }
    final detail = (decoded is Map && decoded['detail'] != null)
        ? decoded['detail'].toString()
        : 'Unbekannter Fehler (${response.statusCode}).';
    throw ApiException(response.statusCode, detail);
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async {
    final response = await _http.get(_uri(path, query));
    return _decode(response);
  }

  Future<Uint8List> getBytes(String path, {Map<String, String>? query}) async {
    final response = await _http.get(_uri(path, query));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response.bodyBytes;
    }
    String detail = 'Unbekannter Fehler (${response.statusCode}).';
    try {
      final decoded = jsonDecode(response.body.isEmpty ? '{}' : response.body);
      if (decoded is Map && decoded['detail'] != null) {
        detail = decoded['detail'].toString();
      }
    } catch (_) {
      // Fehlerantwort war kein JSON - Standardnachricht behalten.
    }
    throw ApiException(response.statusCode, detail);
  }

  Future<void> delete(String path) async {
    final response = await _http.delete(_uri(path));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _decode(response);
    }
  }

  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required String fieldName,
    required Uint8List bytes,
    required String filename,
    Map<String, String>? fields,
    String? secondFieldName,
    Uint8List? secondBytes,
    String? secondFilename,
  }) async {
    final request = http.MultipartRequest('POST', _uri(path));
    request.files.add(http.MultipartFile.fromBytes(fieldName, bytes, filename: filename));
    if (fields != null) {
      request.fields.addAll(fields);
    }
    if (secondFieldName != null && secondBytes != null) {
      request.files.add(http.MultipartFile.fromBytes(
        secondFieldName,
        secondBytes,
        filename: secondFilename ?? 'file',
      ));
    }
    final streamedResponse = await _http.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    return _decode(response);
  }

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    final response = await _http.post(
      _uri(path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decode(response);
  }
}
