import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../bindings.dart';
import '../image.dart';

/// Result of an optimization pass.
final class PdfOptimizationReport {
  const PdfOptimizationReport({
    required this.bytes,
    required this.originalSize,
    required this.optimizedSize,
    required this.pageCount,
    required this.streamsRecompressed,
    required this.imagesReduced,
    required this.changed,
  });

  /// The optimized document, or the original bytes when nothing safe was
  /// possible.
  final Uint8List bytes;

  final int originalSize;
  final int optimizedSize;
  final int pageCount;
  final int streamsRecompressed;
  final int imagesReduced;

  /// Whether [bytes] differs from the input.
  final bool changed;

  double get savedRatio =>
      originalSize == 0 ? 0 : (originalSize - optimizedSize) / originalSize;
}

/// A conservative, in-house PDF optimizer.
///
/// It understands classic cross-reference tables (not xref streams or hybrid
/// files), recompresses Flate content at maximum effort, drops unreachable
/// objects and optionally downsamples JPEG images. Anything it cannot parse
/// safely is returned unchanged — it never hands back a document it cannot
/// re-parse itself.
abstract final class NativePdfOptimizer {
  /// Optimizes [input].
  ///
  /// [maxImageDimension] caps the longest edge of embedded JPEG images;
  /// set [reduceImages] to false for strict lossless output.
  static PdfOptimizationReport optimize(
    Uint8List input, {
    bool reduceImages = true,
    double maxImageDimension = 2480,
    int jpegQuality = 85,
  }) {
    final original = PdfOptimizationReport(
      bytes: input,
      originalSize: input.length,
      optimizedSize: input.length,
      pageCount: 0,
      streamsRecompressed: 0,
      imagesReduced: 0,
      changed: false,
    );

    try {
      final document = _Parser(input).parse();
      final beforePages = document.pageCount;
      if (beforePages <= 0) return original;

      final writer = _Writer(
        document,
        reduceImages: reduceImages,
        maxImageDimension: maxImageDimension,
        jpegQuality: jpegQuality,
      );
      final output = writer.write();
      if (output.length >= input.length) return original;

      final check = _Parser(output).parse();
      if (check.pageCount != beforePages) return original;

      return PdfOptimizationReport(
        bytes: output,
        originalSize: input.length,
        optimizedSize: output.length,
        pageCount: beforePages,
        streamsRecompressed: writer.streamsRecompressed,
        imagesReduced: writer.imagesReduced,
        changed: true,
      );
    } catch (_) {
      // Unsupported structure, encryption, malformed xref, decoder failure:
      // the original is always a valid answer.
      return original;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Object model
// ─────────────────────────────────────────────────────────────────────────────

sealed class _PdfObject {
  const _PdfObject();
}

final class _PdfNull extends _PdfObject {
  const _PdfNull();
}

final class _PdfBool extends _PdfObject {
  const _PdfBool(this.value);
  final bool value;
}

final class _PdfNumber extends _PdfObject {
  const _PdfNumber(this.value);
  final num value;
}

final class _PdfName extends _PdfObject {
  const _PdfName(this.raw);
  final String raw;
}

final class _PdfString extends _PdfObject {
  const _PdfString(this.raw);
  final Uint8List raw;
}

final class _PdfArray extends _PdfObject {
  const _PdfArray(this.items);
  final List<_PdfObject> items;
}

final class _PdfDict extends _PdfObject {
  const _PdfDict(this.entries);
  final Map<String, _PdfObject> entries;
}

final class _PdfRef extends _PdfObject {
  const _PdfRef(this.number, this.generation);
  final int number;
  final int generation;
}

final class _PdfStream extends _PdfObject {
  const _PdfStream(this.dict, this.data);
  final _PdfDict dict;
  final Uint8List data;
}

/// An entry in an xref stream that points into an `/ObjStm` object stream.
final class _CompressedRef {
  const _CompressedRef(this.stream, this.index);

  final int stream;
  final int index;
}

final class _PdfDocument {
  _PdfDocument(this.objects, this.generations, this.trailer);
  final Map<int, _PdfObject> objects;
  final Map<int, int> generations;
  final _PdfDict trailer;

  int get pageCount => pageNumbers.length;

  /// Object numbers of the pages, in document order.
  List<int> get pageNumbers {
    final root = trailer.entries['Root'];
    if (root is! _PdfRef) return const [];
    final catalog = _deref(root);
    if (catalog is! _PdfDict) return const [];
    final pages = catalog.entries['Pages'];
    final seen = <int>{};
    final numbers = <int>[];

    // Walk with references so the page's object number is preserved.
    void collect(_PdfObject? node) {
      if (node is _PdfRef) {
        if (!seen.add(node.number)) return;
        final target = objects[node.number];
        if (target is _PdfDict) {
          final type = target.entries['Type'];
          if (type is _PdfName && type.raw == 'Page') {
            numbers.add(node.number);
            return;
          }
          final kids = target.entries['Kids'];
          if (kids is _PdfArray) {
            for (final kid in kids.items) {
              collect(kid);
            }
          }
        }
        return;
      }
      if (node is _PdfDict) {
        final type = node.entries['Type'];
        if (type is _PdfName && type.raw == 'Page') return;
        final kids = node.entries['Kids'];
        if (kids is _PdfArray) {
          for (final kid in kids.items) {
            collect(kid);
          }
        }
      }
    }

    collect(pages);
    return numbers;
  }

  _PdfObject? _deref(_PdfObject object) =>
      object is _PdfRef ? objects[object.number] : object;
}

class _Unsupported implements Exception {
  const _Unsupported(this.message);
  final String message;

  @override
  String toString() => 'Unsupported PDF: $message';
}

// ─────────────────────────────────────────────────────────────────────────────
// Lexer
// ─────────────────────────────────────────────────────────────────────────────

class _Lexer {
  _Lexer(this.bytes, this.position);

  final Uint8List bytes;
  int position;

  bool get atEnd => position >= bytes.length;

  static bool _isWhitespace(int c) =>
      c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;

  static bool _isDelimiter(int c) =>
      c == 0x28 ||
      c == 0x29 ||
      c == 0x3C ||
      c == 0x3E ||
      c == 0x5B ||
      c == 0x5D ||
      c == 0x7B ||
      c == 0x7D ||
      c == 0x2F ||
      c == 0x25;

  static bool _isTokenEnd(int c) => _isWhitespace(c) || _isDelimiter(c);

  void skipWhitespace() {
    while (!atEnd) {
      final c = bytes[position];
      if (_isWhitespace(c)) {
        position++;
      } else if (c == 0x25) {
        // Comment to end of line.
        while (!atEnd && bytes[position] != 10 && bytes[position] != 13) {
          position++;
        }
      } else {
        break;
      }
    }
  }

  bool matchKeyword(String keyword) {
    if (!_startsWith(keyword)) return false;
    final end = position + keyword.length;
    if (end < bytes.length && !_isTokenEnd(bytes[end])) return false;
    position = end;
    return true;
  }

  void expectKeyword(String keyword) {
    skipWhitespace();
    if (!matchKeyword(keyword)) {
      throw _Unsupported('expected "$keyword" at $position');
    }
  }

  bool _startsWith(String value) {
    if (position + value.length > bytes.length) return false;
    for (var i = 0; i < value.length; i++) {
      if (bytes[position + i] != value.codeUnitAt(i)) return false;
    }
    return true;
  }

  _PdfObject parseObject() {
    skipWhitespace();
    if (atEnd) throw const _Unsupported('unexpected end of file');

    final c = bytes[position];
    switch (c) {
      case 0x2F: // '/'
        return _parseName();
      case 0x28: // '('
        return _parseLiteralString();
      case 0x5B: // '['
        return _parseArray();
      case 0x3C: // '<'
        if (position + 1 < bytes.length && bytes[position + 1] == 0x3C) {
          return _parseDictionary();
        }
        return _parseHexString();
      case 0x74: // t
        if (matchKeyword('true')) return const _PdfBool(true);
        throw _Unsupported('unexpected token at $position');
      case 0x66: // f
        if (matchKeyword('false')) return const _PdfBool(false);
        throw _Unsupported('unexpected token at $position');
      case 0x6E: // n
        if (matchKeyword('null')) return const _PdfNull();
        throw _Unsupported('unexpected token at $position');
      default:
        return _parseNumberOrReference();
    }
  }

  _PdfName _parseName() {
    position++; // '/'
    final start = position;
    while (!atEnd && !_isTokenEnd(bytes[position])) {
      position++;
    }
    return _PdfName(latin1.decode(bytes.sublist(start, position)));
  }

  _PdfString _parseLiteralString() {
    final start = position;
    position++; // '('
    var depth = 1;
    while (!atEnd) {
      final c = bytes[position];
      if (c == 0x5C) {
        position += position + 1 < bytes.length ? 2 : 1;
        continue;
      }
      position++;
      if (c == 0x28) {
        depth++;
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) break;
      }
    }
    if (depth != 0) throw const _Unsupported('unterminated string');
    return _PdfString(Uint8List.sublistView(bytes, start, position));
  }

  _PdfString _parseHexString() {
    final start = position;
    position++; // '<'
    while (!atEnd && bytes[position] != 0x3E) {
      position++;
    }
    if (atEnd) throw const _Unsupported('unterminated hex string');
    position++; // '>'
    return _PdfString(Uint8List.sublistView(bytes, start, position));
  }

  _PdfArray _parseArray() {
    position++; // '['
    final items = <_PdfObject>[];
    while (true) {
      skipWhitespace();
      if (atEnd) throw const _Unsupported('unterminated array');
      if (bytes[position] == 0x5D) {
        position++;
        return _PdfArray(items);
      }
      items.add(parseObject());
    }
  }

  _PdfDict _parseDictionary() {
    position += 2; // '<<'
    final entries = <String, _PdfObject>{};
    while (true) {
      skipWhitespace();
      if (atEnd) throw const _Unsupported('unterminated dictionary');
      if (bytes[position] == 0x3E &&
          position + 1 < bytes.length &&
          bytes[position + 1] == 0x3E) {
        position += 2;
        return _PdfDict(entries);
      }
      final key = parseObject();
      if (key is! _PdfName) {
        throw const _Unsupported('dictionary key is not a name');
      }
      entries[key.raw] = parseObject();
    }
  }

  _PdfObject _parseNumberOrReference() {
    final start = position;
    while (!atEnd && !_isTokenEnd(bytes[position])) {
      position++;
    }
    final token = latin1.decode(bytes.sublist(start, position));
    final value = num.tryParse(token);
    if (value == null) {
      throw _Unsupported('unexpected token "$token"');
    }

    if (value is int && value >= 0) {
      final saved = position;
      skipWhitespace();
      final genStart = position;
      while (!atEnd && bytes[position] >= 0x30 && bytes[position] <= 0x39) {
        position++;
      }
      if (position > genStart) {
        final generation = int.parse(
          latin1.decode(bytes.sublist(genStart, position)),
        );
        skipWhitespace();
        if (!atEnd && bytes[position] == 0x52 /* R */ ) {
          final after = position + 1;
          if (after >= bytes.length || _isTokenEnd(bytes[after])) {
            position = after;
            return _PdfRef(value, generation);
          }
        }
      }
      position = saved;
    }

    return _PdfNumber(value);
  }

  int readInteger() {
    skipWhitespace();
    final start = position;
    if (!atEnd && bytes[position] == 0x2D) position++;
    while (!atEnd && bytes[position] >= 0x30 && bytes[position] <= 0x39) {
      position++;
    }
    if (position == start) throw const _Unsupported('expected an integer');
    return int.parse(latin1.decode(bytes.sublist(start, position)));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Parser
// ─────────────────────────────────────────────────────────────────────────────

class _Parser {
  _Parser(this.bytes);

  final Uint8List bytes;
  final Map<int, int> _offsets = {};
  final Map<int, int> _generations = {};
  final Map<int, _PdfObject> _objects = {};
  final Set<int> _loading = {};
  final Map<int, _CompressedRef> _compressed = {};
  final Set<int> _loadedObjectStreams = {};
  _PdfDict? _trailer;

  _PdfDocument parse() {
    final startXref = _findStartXref();
    _readXref(startXref);
    final trailer = _trailer;
    if (trailer == null) throw const _Unsupported('missing trailer');
    if (trailer.entries.containsKey('Encrypt')) {
      throw const _Unsupported('encrypted documents');
    }

    final document = _PdfDocument(_objects, _generations, trailer);
    _loadReachable(document);
    return document;
  }

  int _findStartXref() {
    const needle = 'startxref';
    final codes = needle.codeUnits;
    var index = -1;
    outer:
    for (var i = bytes.length - codes.length; i >= 0; i--) {
      for (var j = 0; j < codes.length; j++) {
        if (bytes[i + j] != codes[j]) continue outer;
      }
      index = i;
      break;
    }
    if (index < 0) throw const _Unsupported('missing startxref');
    final lexer = _Lexer(bytes, index + 'startxref'.length);
    final offset = lexer.readInteger();
    if (offset <= 0 || offset >= bytes.length) {
      throw const _Unsupported('invalid startxref offset');
    }
    return offset;
  }

  void _readXref(int offset) {
    final seen = <int>{};
    var next = offset;

    while (next > 0 && seen.add(next)) {
      final lexer = _Lexer(bytes, next)..skipWhitespace();
      if (lexer.matchKeyword('xref')) {
        final current = <int, int>{};
        final currentGenerations = <int, int>{};
        while (true) {
          lexer.skipWhitespace();
          if (lexer.matchKeyword('trailer')) break;
          final first = lexer.readInteger();
          final count = lexer.readInteger();
          for (var i = 0; i < count; i++) {
            final entryOffset = lexer.readInteger();
            final generation = lexer.readInteger();
            lexer.skipWhitespace();
            if (lexer.atEnd) throw const _Unsupported('truncated xref');
            final marker = latin1.decode([bytes[lexer.position]]);
            lexer.position++;
            current[first + i] = marker == 'n' ? entryOffset : -1;
            if (marker == 'n') {
              currentGenerations[first + i] = generation;
            }
          }
        }

        final trailerObject = lexer.parseObject();
        if (trailerObject is! _PdfDict) {
          throw const _Unsupported('invalid trailer');
        }

        // In a hybrid file the xref stream is authoritative for the entries it
        // contains, so read it before inserting the classic table.
        final xrefStream = trailerObject.entries['XRefStm'];
        if (xrefStream is _PdfNumber) {
          _readXrefStreamAt(xrefStream.value.toInt());
        }

        _rejectEncrypted(trailerObject);
        _mergeTrailer(trailerObject);

        // Newest entries win; older sections only fill gaps.
        for (final entry in current.entries) {
          _offsets.putIfAbsent(entry.key, () => entry.value);
          if (entry.value >= 0) {
            _generations.putIfAbsent(
              entry.key,
              () => currentGenerations[entry.key] ?? 0,
            );
          }
        }

        final prev = trailerObject.entries['Prev'];
        next = prev is _PdfNumber ? prev.value.toInt() : 0;
      } else {
        final trailer = _readXrefStreamAt(next);
        if (trailer == null) {
          throw const _Unsupported('invalid xref stream');
        }
        _rejectEncrypted(trailer);
        _mergeTrailer(trailer);
        final prev = trailer.entries['Prev'];
        next = prev is _PdfNumber ? prev.value.toInt() : 0;
      }
    }

    if (_offsets.isEmpty && _compressed.isEmpty) {
      throw const _Unsupported('empty xref');
    }
  }

  void _rejectEncrypted(_PdfDict trailer) {
    if (trailer.entries.containsKey('Encrypt')) {
      throw const _Unsupported('encrypted documents');
    }
  }

  void _mergeTrailer(_PdfDict trailer) {
    final existing = _trailer;
    if (existing == null) {
      _trailer = trailer;
      return;
    }
    final merged = Map<String, _PdfObject>.of(existing.entries);
    for (final entry in trailer.entries.entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
    _trailer = _PdfDict(merged);
  }

  /// Reads a PDF 1.5 cross-reference stream and installs its entries.
  _PdfDict? _readXrefStreamAt(int offset) {
    int? streamNumber;
    final object = _parseIndirectAt(
      offset,
      onHeader: (number, generation) => streamNumber = number,
    );
    if (object is! _PdfStream) return null;
    final dictionary = object.dict;
    final type = dictionary.entries['Type'];
    if (type is! _PdfName || type.raw != 'XRef') return null;

    final size = _intValue(dictionary.entries['Size']);
    final widths = _intList(dictionary.entries['W']);
    if (size == null || widths == null || widths.length < 3) return null;

    final data = _decodedStreamData(object);
    if (data == null) return null;

    final index = _intList(dictionary.entries['Index']) ?? <int>[0, size];
    var position = 0;
    for (var pair = 0; pair + 1 < index.length; pair += 2) {
      final first = index[pair];
      final count = index[pair + 1];
      if (count < 0) return null;
      for (var i = 0; i < count; i++) {
        final values = <int>[];
        for (var field = 0; field < 3; field++) {
          var value = 0;
          for (var byte = 0; byte < widths[field]; byte++) {
            if (position >= data.length) return dictionary;
            value = (value << 8) | data[position++];
          }
          values.add(value);
        }
        final number = first + i;
        final entryType = widths[0] == 0 ? 1 : values[0];
        switch (entryType) {
          case 0:
            _offsets.putIfAbsent(number, () => -1);
            break;
          case 1:
            _offsets.putIfAbsent(number, () => values[1]);
            _generations.putIfAbsent(number, () => values[2]);
            break;
          case 2:
            _compressed.putIfAbsent(
              number,
              () => _CompressedRef(values[1], values[2]),
            );
            _offsets.putIfAbsent(number, () => -1);
            break;
          default:
            // Unknown entry types are reserved; ignore them.
            break;
        }
      }
    }

    if (streamNumber != null) {
      _offsets.putIfAbsent(streamNumber!, () => offset);
    }
    return dictionary;
  }

  _PdfObject _object(int number) {
    final cached = _objects[number];
    if (cached != null) return cached;

    if (_compressed.containsKey(number)) {
      _loadCompressed(number);
      final loaded = _objects[number];
      if (loaded != null) return loaded;
      throw _Unsupported('missing compressed object $number');
    }

    final offset = _offsets[number];
    if (offset == null || offset < 0) {
      throw _Unsupported('missing object $number');
    }
    if (!_loading.add(number)) {
      throw _Unsupported('cyclic object reference $number');
    }

    try {
      final object = _parseIndirectAt(offset, expectedNumber: number);
      _objects[number] = object;
      return object;
    } finally {
      _loading.remove(number);
    }
  }

  /// Loads one object from an `/ObjStm` object stream.
  void _loadCompressed(int number) {
    final reference = _compressed[number];
    if (reference == null) {
      throw _Unsupported('missing compressed object $number');
    }
    _loadObjectStream(reference.stream);
    if (!_objects.containsKey(number)) {
      throw _Unsupported('object $number is missing from its object stream');
    }
  }

  void _loadObjectStream(int streamNumber) {
    if (!_loadedObjectStreams.add(streamNumber)) return;
    final object = _object(streamNumber);
    if (object is! _PdfStream) {
      throw _Unsupported('object stream $streamNumber is not a stream');
    }
    final count = _intValue(object.dict.entries['N']);
    final first = _intValue(object.dict.entries['First']);
    if (count == null || first == null || count < 0 || first < 0) {
      throw _Unsupported('invalid object stream $streamNumber');
    }
    final data = _decodedStreamData(object);
    if (data == null) throw const _Unsupported('undecodable object stream');

    final header = _Lexer(data, 0);
    final numbers = <int>[];
    final offsets = <int>[];
    for (var i = 0; i < count; i++) {
      numbers.add(header.readInteger());
      offsets.add(header.readInteger());
    }
    for (var i = 0; i < count; i++) {
      final number = numbers[i];
      final offset = offsets[i];
      _objects.putIfAbsent(number, () {
        if (first + offset >= data.length) {
          throw const _Unsupported('object stream entry out of range');
        }
        return _Lexer(data, first + offset).parseObject();
      });
    }
  }

  _PdfObject _parseIndirectAt(
    int offset, {
    void Function(int number, int generation)? onHeader,
    int? expectedNumber,
  }) {
    final lexer = _Lexer(bytes, offset)..skipWhitespace();
    final number = lexer.readInteger();
    final generation = lexer.readInteger();
    lexer.expectKeyword('obj');
    onHeader?.call(number, generation);
    if (expectedNumber != null && number != expectedNumber) {
      throw _Unsupported(
        'object $expectedNumber expected at $offset, found $number',
      );
    }

    final object = lexer.parseObject();
    lexer.skipWhitespace();

    if (object is _PdfDict && lexer.matchKeyword('stream')) {
      // The stream keyword is followed by CRLF or LF, not part of the data.
      if (!lexer.atEnd && bytes[lexer.position] == 13) lexer.position++;
      if (!lexer.atEnd && bytes[lexer.position] == 10) lexer.position++;

      var length = _resolveLength(object.entries['Length']);
      if (length == null) {
        // Some writers get /Length wrong; find the end of the stream instead.
        final end = _findEndStream(lexer.position);
        if (end < 0) throw const _Unsupported('unterminated stream');
        length = end - lexer.position;
      }
      final end = lexer.position + length;
      if (end < 0 || end > bytes.length) {
        throw const _Unsupported('stream length exceeds the file');
      }

      final data = Uint8List.sublistView(bytes, lexer.position, end);
      lexer.position = end;
      lexer.skipWhitespace();
      lexer.matchKeyword('endstream');
      return _PdfStream(object, data);
    }

    return object;
  }

  int? _resolveLength(_PdfObject? length) {
    if (length is _PdfNumber && length.value >= 0) {
      return length.value.toInt();
    }
    if (length is _PdfRef) {
      try {
        final resolved = _object(length.number);
        if (resolved is _PdfNumber && resolved.value >= 0) {
          return resolved.value.toInt();
        }
      } catch (_) {
        // The length may live in an object stream that is not available yet;
        // fall back to scanning for endstream.
        return null;
      }
    }
    return null;
  }

  int _findEndStream(int start) {
    final needle = latin1.encode('endstream');
    outer:
    for (var i = start; i < bytes.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (bytes[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  void _loadReachable(_PdfDocument document) {
    final seen = <int>{};

    void visit(_PdfObject? object) {
      if (object == null || object is _PdfNull) return;
      if (object is _PdfRef) {
        if (!seen.add(object.number)) return;
        visit(_object(object.number));
        return;
      }
      if (object is _PdfArray) {
        for (final item in object.items) {
          visit(item);
        }
        return;
      }
      if (object is _PdfDict) {
        for (final value in object.entries.values) {
          visit(value);
        }
        return;
      }
      if (object is _PdfStream) {
        visit(object.dict);
      }
    }

    final trailer = document.trailer;
    for (final key in const ['Root', 'Info']) {
      visit(trailer.entries[key]);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Writer
// ─────────────────────────────────────────────────────────────────────────────

class _Writer {
  _Writer(
    this.document, {
    required this.reduceImages,
    required this.maxImageDimension,
    required this.jpegQuality,
  });

  final _PdfDocument document;
  final bool reduceImages;
  final double maxImageDimension;
  final int jpegQuality;

  int streamsRecompressed = 0;
  int imagesReduced = 0;

  final Map<int, int> _offsets = {};
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  Uint8List write() {
    _buffer.add(latin1.encode('%PDF-1.7\n'));
    _buffer.add(const [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    final numbers = document.objects.keys.toList()..sort();
    var maxNumber = 0;
    for (final number in numbers) {
      if (number > maxNumber) maxNumber = number;
    }

    for (final number in numbers) {
      _offsets[number] = _buffer.length;
      _writeIndirect(number, document.objects[number]!);
    }

    final xrefOffset = _buffer.length;
    final size = maxNumber + 1;
    _buffer.add(latin1.encode('xref\n0 $size\n'));
    _buffer.add(latin1.encode('0000000000 65535 f \n'));
    for (var number = 1; number < size; number++) {
      final offset = _offsets[number];
      if (offset == null) {
        _buffer.add(latin1.encode('0000000000 00000 f \n'));
      } else {
        final generation = document.generations[number] ?? 0;
        _buffer.add(
          latin1.encode(
            '${offset.toString().padLeft(10, '0')} '
            '${generation.toString().padLeft(5, '0')} n \n',
          ),
        );
      }
    }

    final trailer = StringBuffer('<< /Size $size');
    final root = document.trailer.entries['Root'];
    if (root is _PdfRef) {
      trailer.write(' /Root ${root.number} ${root.generation} R');
    }
    final info = document.trailer.entries['Info'];
    if (info is _PdfRef && _offsets.containsKey(info.number)) {
      trailer.write(' /Info ${info.number} ${info.generation} R');
    }
    trailer.write(' >>');
    _buffer.add(
      latin1.encode('trailer\n$trailer\nstartxref\n$xrefOffset\n%%EOF\n'),
    );

    return _buffer.takeBytes();
  }

  void _writeIndirect(int number, _PdfObject object) {
    final generation = document.generations[number] ?? 0;
    _buffer.add(latin1.encode('$number $generation obj\n'));
    if (object is _PdfStream) {
      _writeStream(object);
    } else {
      _writeObject(object);
      _buffer.add(latin1.encode('\n'));
    }
    _buffer.add(latin1.encode('endobj\n'));
  }

  void _writeStream(_PdfStream stream) {
    var data = stream.data;
    final dictionary = Map<String, _PdfObject>.of(stream.dict.entries);
    dictionary.remove('Length');

    final filter = _singleFilter(dictionary);
    if (filter == null || filter == 'FlateDecode') {
      final decoded = _decodedStreamData(stream);
      if (decoded != null) {
        if (reduceImages) {
          final reduced = _maybeReduceFlateImage(
            dictionary,
            decoded,
            stream.data.length,
          );
          if (reduced != null) {
            data = reduced;
            dictionary['Filter'] = const _PdfName('DCTDecode');
            dictionary.remove('DecodeParms');
            imagesReduced++;
          }
        }
        if (identical(data, stream.data)) {
          try {
            final compressed = Uint8List.fromList(
              ZLibEncoder(level: 9).convert(decoded),
            );
            if (filter == null || compressed.length < stream.data.length) {
              data = compressed;
              dictionary['Filter'] = const _PdfName('FlateDecode');
              dictionary.remove('DecodeParms');
              streamsRecompressed++;
            }
          } catch (_) {
            // Keep the stream as stored.
          }
        }
      }
    } else if (filter == 'DCTDecode' && reduceImages) {
      data = _maybeReduceImage(dictionary, stream.data);
    }

    dictionary['Length'] = _PdfNumber(data.length);
    _writeObject(_PdfDict(dictionary));
    _buffer.add(latin1.encode('\nstream\n'));
    _buffer.add(data);
    _buffer.add(latin1.encode('\nendstream\n'));
  }

  /// Converts an 8-bit DeviceRGB/DeviceGray Flate image to JPEG.
  ///
  /// Scanned PDFs frequently store full-resolution raster pages as Flate. A
  /// lossy JPEG at a capped dimension is far smaller and keeps the document
  /// readable. Everything with masks, palettes, CMYK or unusual bit depths is
  /// left untouched.
  Uint8List? _maybeReduceFlateImage(
    Map<String, _PdfObject> dictionary,
    Uint8List decoded,
    int originalLength,
  ) {
    final subtype = dictionary['Subtype'];
    if (subtype is! _PdfName || subtype.raw != 'Image') return null;
    for (final key in const ['SMask', 'Mask', 'ImageMask', 'Decode']) {
      if (dictionary.containsKey(key)) return null;
    }

    final bits = dictionary['BitsPerComponent'];
    if (bits is _PdfNumber && bits.value != 8) return null;

    final colorSpace = dictionary['ColorSpace'];
    if (colorSpace is! _PdfName) return null;
    final components = switch (colorSpace.raw) {
      'DeviceRGB' => 3,
      'DeviceGray' => 1,
      _ => 0,
    };
    if (components == 0) return null;

    final width = _intValue(dictionary['Width']);
    final height = _intValue(dictionary['Height']);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    final longest = width > height ? width : height;
    if (longest <= maxImageDimension) return null;

    final expected = width * height * components;
    if (decoded.length < expected) return null;
    final pixels = decoded.length == expected
        ? decoded
        : Uint8List.sublistView(decoded, 0, expected);

    try {
      final png = _encodePng(width, height, components, pixels);
      final result = NativeImageCompressor.compress(
        png,
        maxDimension: maxImageDimension,
        quality: jpegQuality,
        format: NativeImageFormat.jpeg,
      );
      if (result.byteLength >= originalLength) return null;
      if (result.width >= width && result.height >= height) return null;
      dictionary['Width'] = _PdfNumber(result.width);
      dictionary['Height'] = _PdfNumber(result.height);
      return result.bytes;
    } catch (_) {
      return null;
    }
  }

  Uint8List _maybeReduceImage(
    Map<String, _PdfObject> dictionary,
    Uint8List data,
  ) {
    final subtype = dictionary['Subtype'];
    if (subtype is! _PdfName || subtype.raw != 'Image') return data;
    for (final key in const ['SMask', 'Mask', 'ImageMask', 'Decode']) {
      if (dictionary.containsKey(key)) return data;
    }
    final colorSpace = dictionary['ColorSpace'];
    if (colorSpace is _PdfName &&
        colorSpace.raw != 'DeviceRGB' &&
        colorSpace.raw != 'DeviceGray') {
      return data;
    }
    if (colorSpace is! _PdfName) return data;

    final width = dictionary['Width'];
    final height = dictionary['Height'];
    if (width is! _PdfNumber || height is! _PdfNumber) return data;
    final longest = width.value > height.value ? width.value : height.value;
    if (longest <= maxImageDimension) return data;

    try {
      final result = NativeImageCompressor.compress(
        data,
        maxDimension: maxImageDimension,
        quality: jpegQuality,
        format: NativeImageFormat.jpeg,
      );
      if (result.byteLength >= data.length) return data;
      if (result.width >= width.value && result.height >= height.value) {
        return data;
      }
      dictionary['Width'] = _PdfNumber(result.width);
      dictionary['Height'] = _PdfNumber(result.height);
      dictionary['Filter'] = const _PdfName('DCTDecode');
      dictionary.remove('DecodeParms');
      imagesReduced++;
      return result.bytes;
    } catch (_) {
      return data;
    }
  }

  String? _singleFilter(Map<String, _PdfObject> dictionary) {
    final filter = dictionary['Filter'];
    if (filter is _PdfName) return filter.raw;
    if (filter is _PdfArray && filter.items.length == 1) {
      final only = filter.items.first;
      if (only is _PdfName) return only.raw;
    }
    return filter == null ? null : '\u0000unsupported';
  }

  void _writeObject(_PdfObject object) {
    switch (object) {
      case _PdfNull():
        _buffer.add(latin1.encode('null'));
      case _PdfBool(:final value):
        _buffer.add(latin1.encode(value ? 'true' : 'false'));
      case _PdfNumber(:final value):
        _buffer.add(latin1.encode(_formatNumber(value)));
      case _PdfName(:final raw):
        _buffer.add(latin1.encode('/$raw'));
      case _PdfString(:final raw):
        _buffer.add(raw);
      case _PdfRef(:final number, :final generation):
        _buffer.add(latin1.encode('$number $generation R'));
      case _PdfArray(:final items):
        _buffer.add(latin1.encode('['));
        for (var i = 0; i < items.length; i++) {
          if (i > 0) _buffer.add(latin1.encode(' '));
          _writeObject(items[i]);
        }
        _buffer.add(latin1.encode(']'));
      case _PdfDict(:final entries):
        _buffer.add(latin1.encode('<<'));
        for (final entry in entries.entries) {
          _buffer.add(latin1.encode(' /${entry.key} '));
          _writeObject(entry.value);
        }
        _buffer.add(latin1.encode(' >>'));
      case _PdfStream():
        // Streams are only written through _writeStream.
        throw const _Unsupported('nested stream');
    }
  }

  String _formatNumber(num value) {
    if (value is int) return '$value';
    final text = value.toString();
    return text.contains('.') ? text : '$text.0';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Text extraction (best effort)
// ─────────────────────────────────────────────────────────────────────────────

/// The text layer of one page.
final class PdfPageText {
  const PdfPageText({required this.index, required this.text});

  /// Zero-based page index.
  final int index;

  /// Extracted text, possibly empty for a scanned page.
  final String text;

  /// Number of non-whitespace characters.
  int get characterCount => text.replaceAll(RegExp(r'\s'), '').length;

  /// Whether this page carries a usable text layer.
  bool get hasText => characterCount > 0;
}

/// Extracts the text layer of a PDF.
///
/// This is a conservative extractor: it reads `Tj`, `TJ`, `'` and `"` operators
/// from Flate or uncompressed content streams and ignores font CMaps and
/// custom encodings. Simple, standard-font documents extract well; complex
/// typography may not. Scanned pages have no text layer — use OCR for those.
///
/// On Apple platforms [native_pdf_kit_ocr] uses PDFKit for a higher-fidelity
/// text layer and falls back to this extractor elsewhere.
abstract final class PdfTextExtractor {
  /// Returns the text of [page] (zero-based) or the whole document when null.
  static String extract(Uint8List input, {int? page}) {
    try {
      final document = _Parser(input).parse();
      final pages = document.pageNumbers;
      final buffer = StringBuffer();

      for (var index = 0; index < pages.length; index++) {
        if (page != null && page != index) continue;
        final text = _pageText(document, pages[index]);
        if (text.isEmpty) continue;
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(text);
      }

      return buffer.toString();
    } catch (_) {
      return '';
    }
  }

  /// Extracts several pages in one parse.
  ///
  /// [pages] are zero-based indexes; when null every page is returned in
  /// document order. Unsupported input yields an empty list.
  static List<PdfPageText> extractPages(
    Uint8List input, {
    Set<int>? pages,
  }) {
    try {
      final document = _Parser(input).parse();
      final numbers = document.pageNumbers;
      final result = <PdfPageText>[];
      for (var index = 0; index < numbers.length; index++) {
        if (pages != null && !pages.contains(index)) continue;
        result.add(
          PdfPageText(
            index: index,
            text: _pageText(document, numbers[index]),
          ),
        );
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static String _pageText(_PdfDocument document, int pageNumber) {
    final page = document.objects[pageNumber];
    if (page is! _PdfDict) return '';

    final contents = _resolve(document, page.entries['Contents']);
    final streams = <_PdfStream>[];
    if (contents is _PdfStream) {
      streams.add(contents);
    } else if (contents is _PdfArray) {
      for (final item in contents.items) {
        final resolved = _resolve(document, item);
        if (resolved is _PdfStream) streams.add(resolved);
      }
    }

    final buffer = StringBuffer();
    for (final stream in streams) {
      final data = _decodedStream(stream);
      if (data == null) continue;
      buffer.write(_ContentTextScanner(data).scan());
    }
    return buffer.toString();
  }

  static _PdfObject? _resolve(_PdfDocument document, _PdfObject? object) {
    var current = object;
    final seen = <int>{};
    while (current is _PdfRef) {
      if (!seen.add(current.number)) return null;
      current = document.objects[current.number];
    }
    return current;
  }

  static Uint8List? _decodedStream(_PdfStream stream) =>
      _decodedStreamData(stream);
}

String? _streamFilter(_PdfDict dictionary) {
  final filter = dictionary.entries['Filter'];
  if (filter is _PdfName) return filter.raw;
  if (filter is _PdfArray && filter.items.length == 1) {
    final only = filter.items.first;
    if (only is _PdfName) return only.raw;
  }
  return filter == null ? null : '\u0000unsupported';
}

_PdfDict? _firstDecodeParams(_PdfDict dictionary) {
  final params = dictionary.entries['DecodeParms'];
  if (params is _PdfDict) return params;
  if (params is _PdfArray) {
    for (final item in params.items) {
      if (item is _PdfDict) return item;
      if (item is _PdfNull) return null;
    }
  }
  return null;
}

/// Decodes one Flate or uncompressed stream, applying PNG/TIFF predictors.
Uint8List? _decodedStreamData(_PdfStream stream) {
  final filter = _streamFilter(stream.dict);
  if (filter == null) return stream.data;
  if (filter != 'FlateDecode') return null;
  try {
    final decoded = Uint8List.fromList(ZLibDecoder().convert(stream.data));
    final params = _firstDecodeParams(stream.dict);
    if (params == null) return decoded;
    return _applyPredictor(decoded, params);
  } catch (_) {
    return null;
  }
}

int? _intValue(_PdfObject? object) {
  if (object is _PdfNumber) return object.value.toInt();
  return null;
}

List<int>? _intList(_PdfObject? object) {
  if (object is! _PdfArray) return null;
  final values = <int>[];
  for (final item in object.items) {
    if (item is _PdfNumber) {
      values.add(item.value.toInt());
    } else {
      return null;
    }
  }
  return values;
}

/// Reverses the PNG (10..15) and TIFF (2) predictors used by PDF streams.
Uint8List? _applyPredictor(Uint8List data, _PdfDict params) {
  final predictor = _intValue(params.entries['Predictor']) ?? 1;
  if (predictor <= 1) return data;

  final colors = _intValue(params.entries['Colors']) ?? 1;
  final bits = _intValue(params.entries['BitsPerComponent']) ?? 8;
  final columns = _intValue(params.entries['Columns']) ?? 1;
  if (colors <= 0 || bits <= 0 || columns <= 0) return null;

  final rowBytes = (colors * columns * bits + 7) ~/ 8;
  if (rowBytes <= 0) return null;
  final bytesPerPixel = ((colors * bits) + 7) ~/ 8;

  if (predictor == 2) {
    if (bits != 8 || data.length % rowBytes != 0) return null;
    final out = Uint8List.fromList(data);
    for (var row = 0; row < out.length; row += rowBytes) {
      for (var i = bytesPerPixel; i < rowBytes; i++) {
        out[row + i] = (out[row + i] + out[row + i - bytesPerPixel]) & 0xFF;
      }
    }
    return out;
  }

  if (predictor < 10) return null;
  final stride = rowBytes + 1;
  final rows = data.length ~/ stride;
  if (rows == 0) return null;

  final out = Uint8List(rows * rowBytes);
  final previous = Uint8List(rowBytes);
  for (var row = 0; row < rows; row++) {
    final filter = data[row * stride];
    final source = row * stride + 1;
    final target = row * rowBytes;

    if (filter == 0) {
      out.setRange(target, target + rowBytes, data, source);
    } else if (filter == 1) {
      for (var i = 0; i < rowBytes; i++) {
        final left = i >= bytesPerPixel ? out[target + i - bytesPerPixel] : 0;
        out[target + i] = (data[source + i] + left) & 0xFF;
      }
    } else if (filter == 2) {
      for (var i = 0; i < rowBytes; i++) {
        out[target + i] = (data[source + i] + previous[i]) & 0xFF;
      }
    } else if (filter == 3) {
      for (var i = 0; i < rowBytes; i++) {
        final left = i >= bytesPerPixel ? out[target + i - bytesPerPixel] : 0;
        final up = previous[i];
        out[target + i] = (data[source + i] + ((left + up) >> 1)) & 0xFF;
      }
    } else if (filter == 4) {
      for (var i = 0; i < rowBytes; i++) {
        final left = i >= bytesPerPixel ? out[target + i - bytesPerPixel] : 0;
        final up = previous[i];
        final upLeft = i >= bytesPerPixel
            ? previous[i - bytesPerPixel]
            : 0;
        out[target + i] = (data[source + i] + _paeth(left, up, upLeft)) & 0xFF;
      }
    } else {
      return null;
    }
    previous.setRange(0, rowBytes, out, target);
  }
  return out;
}

int _paeth(int left, int up, int upLeft) {
  final estimate = left + up - upLeft;
  final leftDistance = (estimate - left).abs();
  final upDistance = (estimate - up).abs();
  final upLeftDistance = (estimate - upLeft).abs();
  if (leftDistance <= upDistance && leftDistance <= upLeftDistance) {
    return left;
  }
  if (upDistance <= upLeftDistance) return up;
  return upLeft;
}

/// Wraps raw 8-bit RGB/gray samples in a minimal PNG for the native encoder.
Uint8List _encodePng(
  int width,
  int height,
  int components,
  Uint8List pixels,
) {
  final stride = width * components;
  final raw = BytesBuilder(copy: false);
  for (var row = 0; row < height; row++) {
    raw.addByte(0); // PNG filter: none
    raw.add(Uint8List.sublistView(pixels, row * stride, (row + 1) * stride));
  }
  final compressed = ZLibEncoder(level: 9).convert(raw.takeBytes());

  final out = BytesBuilder(copy: false);
  out.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  final header = BytesBuilder(copy: false)
    ..add(_u32(width))
    ..add(_u32(height))
    ..add([8, components == 1 ? 0 : 2, 0, 0, 0]);
  _pngChunk(out, 'IHDR', header.takeBytes());
  _pngChunk(out, 'IDAT', Uint8List.fromList(compressed));
  _pngChunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _pngChunk(BytesBuilder out, String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  out.add(_u32(data.length));
  out.add(typeBytes);
  out.add(data);
  final crcInput = Uint8List(typeBytes.length + data.length)
    ..setAll(0, typeBytes)
    ..setAll(typeBytes.length, data);
  out.add(_u32(_crc32(crcInput)));
}

Uint8List _u32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

int _crc32(Uint8List data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

class _ContentTextScanner {
  _ContentTextScanner(this.bytes);

  final Uint8List bytes;
  int position = 0;
  final StringBuffer output = StringBuffer();

  static bool _isWhitespace(int c) =>
      c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32;

  static bool _isDelimiter(int c) =>
      c == 0x28 ||
      c == 0x29 ||
      c == 0x3C ||
      c == 0x3E ||
      c == 0x5B ||
      c == 0x5D ||
      c == 0x7B ||
      c == 0x7D ||
      c == 0x2F ||
      c == 0x25;

  String scan() {
    final operands = <Object?>[];
    while (true) {
      _skipWhitespace();
      if (position >= bytes.length) break;

      final c = bytes[position];
      if (c == 0x28) {
        operands.add(_literalString());
        continue;
      }
      if (c == 0x3C) {
        if (position + 1 < bytes.length && bytes[position + 1] == 0x3C) {
          _skipDictionary();
        } else {
          operands.add(_hexString());
        }
        continue;
      }
      if (c == 0x5B) {
        operands.add(_array());
        continue;
      }
      if (c == 0x5D || c == 0x3E || c == 0x29) {
        position++;
        continue;
      }

      final token = _token();
      if (token == null) continue;

      switch (token) {
        case 'Tj':
        case "'":
        case '"':
          _emitString(operands.isEmpty ? null : operands.last);
          operands.clear();
        case 'TJ':
          _emitArray(operands.isEmpty ? null : operands.last);
          operands.clear();
        case 'Td':
        case 'TD':
        case 'T*':
        case 'ET':
          output.write(' ');
          operands.clear();
        case 'Tf':
        case 'Tm':
        case 'TL':
        case 'Tc':
        case 'Tw':
        case 'Tz':
        case 'Ts':
        case 'Tr':
          operands.clear();
        default:
          if (num.tryParse(token) != null || token.startsWith('/')) {
            operands.add(token);
          } else {
            operands.clear();
          }
      }
    }
    return output.toString().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  }

  void _emitString(Object? operand) {
    if (operand is! String) return;
    if (output.isNotEmpty && !output.toString().endsWith(' ')) {
      output.write(' ');
    }
    output.write(operand);
  }

  void _emitArray(Object? operand) {
    if (operand is! List<Object?>) return;
    for (final item in operand) {
      if (item is String) {
        if (output.isNotEmpty && !output.toString().endsWith(' ')) {
          output.write(' ');
        }
        output.write(item);
      } else if (item is num && item <= -100) {
        output.write(' ');
      }
    }
  }

  void _skipWhitespace() {
    while (position < bytes.length) {
      final c = bytes[position];
      if (_isWhitespace(c)) {
        position++;
      } else if (c == 0x25) {
        while (position < bytes.length &&
            bytes[position] != 10 &&
            bytes[position] != 13) {
          position++;
        }
      } else {
        break;
      }
    }
  }

  String? _token() {
    final start = position;
    while (position < bytes.length &&
        !_isWhitespace(bytes[position]) &&
        !_isDelimiter(bytes[position])) {
      position++;
    }
    if (position == start) {
      position++;
      return null;
    }
    return latin1.decode(bytes.sublist(start, position));
  }

  String _literalString() {
    position++; // '('
    final bytesOut = <int>[];
    var depth = 1;
    while (position < bytes.length) {
      final c = bytes[position++];
      if (c == 0x5C) {
        if (position >= bytes.length) break;
        final escaped = bytes[position++];
        switch (escaped) {
          case 0x6E:
            bytesOut.add(10);
          case 0x72:
            bytesOut.add(13);
          case 0x74:
            bytesOut.add(9);
          case 0x62:
            bytesOut.add(8);
          case 0x66:
            bytesOut.add(12);
          case 0x28:
          case 0x29:
          case 0x5C:
            bytesOut.add(escaped);
          case 0x0A:
          case 0x0D:
            if (escaped == 0x0D &&
                position < bytes.length &&
                bytes[position] == 0x0A) {
              position++;
            }
          default:
            if (escaped >= 0x30 && escaped <= 0x37) {
              var value = escaped - 0x30;
              for (var i = 0; i < 2 && position < bytes.length; i++) {
                final digit = bytes[position];
                if (digit < 0x30 || digit > 0x37) break;
                value = value * 8 + (digit - 0x30);
                position++;
              }
              bytesOut.add(value & 0xFF);
            } else {
              bytesOut.add(escaped);
            }
        }
        continue;
      }
      if (c == 0x28) depth++;
      if (c == 0x29) {
        depth--;
        if (depth == 0) break;
      }
      bytesOut.add(c);
    }
    return _decodeTextBytes(Uint8List.fromList(bytesOut));
  }

  String _hexString() {
    position++; // '<'
    final digits = <int>[];
    while (position < bytes.length && bytes[position] != 0x3E) {
      final c = bytes[position++];
      final value = c >= 0x30 && c <= 0x39
          ? c - 0x30
          : c >= 0x41 && c <= 0x46
          ? c - 0x41 + 10
          : c >= 0x61 && c <= 0x66
          ? c - 0x61 + 10
          : -1;
      if (value >= 0) digits.add(value);
    }
    if (position < bytes.length) position++;
    final output = <int>[];
    for (var i = 0; i < digits.length; i += 2) {
      final high = digits[i];
      final low = i + 1 < digits.length ? digits[i + 1] : 0;
      output.add((high << 4) | low);
    }
    return _decodeTextBytes(Uint8List.fromList(output));
  }

  List<Object?> _array() {
    position++; // '['
    final items = <Object?>[];
    while (true) {
      _skipWhitespace();
      if (position >= bytes.length) break;
      final c = bytes[position];
      if (c == 0x5D) {
        position++;
        break;
      }
      if (c == 0x28) {
        items.add(_literalString());
      } else if (c == 0x3C) {
        items.add(_hexString());
      } else {
        final token = _token();
        if (token == null) continue;
        final number = num.tryParse(token);
        if (number != null) items.add(number);
      }
    }
    return items;
  }

  void _skipDictionary() {
    var depth = 0;
    while (position < bytes.length) {
      final c = bytes[position++];
      if (c == 0x3C && position < bytes.length && bytes[position] == 0x3C) {
        position++;
        depth++;
      } else if (c == 0x3E &&
          position < bytes.length &&
          bytes[position] == 0x3E) {
        position++;
        depth--;
        if (depth <= 0) return;
      }
    }
  }

  String _decodeTextBytes(Uint8List data) {
    if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
      final units = <int>[];
      for (var i = 2; i + 1 < data.length; i += 2) {
        units.add((data[i] << 8) | data[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
      final units = <int>[];
      for (var i = 2; i + 1 < data.length; i += 2) {
        units.add((data[i + 1] << 8) | data[i]);
      }
      return String.fromCharCodes(units);
    }
    return latin1.decode(data, allowInvalid: true);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page editing
// ─────────────────────────────────────────────────────────────────────────────

/// Result of a page edit.
final class PdfEditResult {
  const PdfEditResult({
    required this.bytes,
    required this.changed,
    required this.pageCount,
  });

  final Uint8List bytes;
  final bool changed;
  final int pageCount;
}

/// Page-level edits.
abstract final class PdfPageEditor {
  /// Rotates [pages] (zero-based; all pages when null) by [degrees].
  ///
  /// Only the page dictionary's `/Rotate` entry changes. Unsupported files are
  /// returned unchanged.
  static PdfEditResult rotate(
    Uint8List input, {
    int degrees = 90,
    Set<int>? pages,
  }) {
    final unchanged = PdfEditResult(bytes: input, changed: false, pageCount: 0);

    try {
      final document = _Parser(input).parse();
      final references = document.pageNumbers;
      if (references.isEmpty) return unchanged;

      final targets = pages ?? {for (var i = 0; i < references.length; i++) i};
      for (final index in targets) {
        if (index < 0 || index >= references.length) continue;
        final page = document.objects[references[index]];
        if (page is! _PdfDict) continue;
        final current = page.entries['Rotate'];
        final existing = current is _PdfNumber ? current.value.toInt() : 0;
        var next = (existing + degrees) % 360;
        if (next < 0) next += 360;
        page.entries['Rotate'] = _PdfNumber(next);
      }

      final writer = _Writer(
        document,
        reduceImages: false,
        maxImageDimension: 0,
        jpegQuality: 85,
      );
      final output = writer.write();
      final check = _Parser(output).parse();
      if (check.pageCount != references.length) return unchanged;

      return PdfEditResult(
        bytes: output,
        changed: true,
        pageCount: references.length,
      );
    } catch (_) {
      return unchanged;
    }
  }
}

/// Reorders, keeps or removes pages in a single document.
///
/// [order] holds zero-based page indices in the new order. Pass a subset to
/// split or remove pages. The page tree is flattened, so bookmarks/outlines
/// are dropped; annotations on removed pages go with them. Anything the
/// parser cannot represent safely is returned unchanged.
PdfEditResult reorderPdfPages(Uint8List input, List<int> order) {
  final unchanged = PdfEditResult(bytes: input, changed: false, pageCount: 0);
  try {
    final document = _Parser(input).parse();
    final pages = _flattenPages(document);
    if (pages.isEmpty) return unchanged;
    if (order.isEmpty) return unchanged;
    if (order.toSet().length != order.length) return unchanged;
    for (final index in order) {
      if (index < 0 || index >= pages.length) return unchanged;
    }

    final rootRef = document.trailer.entries['Root'];
    if (rootRef is! _PdfRef) return unchanged;
    final catalog = document.objects[rootRef.number];
    if (catalog is! _PdfDict) return unchanged;
    final pagesRef = catalog.entries['Pages'];
    if (pagesRef is! _PdfRef) return unchanged;
    final rootPages = document.objects[pagesRef.number];
    if (rootPages is! _PdfDict) return unchanged;

    final selected = <_PdfRef>[];
    for (final index in order) {
      final page = pages[index];
      page.dict.entries['Parent'] = pagesRef;
      selected.add(
        _PdfRef(page.number, document.generations[page.number] ?? 0),
      );
    }

    rootPages.entries['Kids'] = _PdfArray(selected);
    rootPages.entries['Count'] = _PdfNumber(selected.length);
    // Outlines point at the old page tree; dropping them keeps the output
    // self-consistent after a flatten.
    catalog.entries.remove('Outlines');

    final writer = _Writer(
      document,
      reduceImages: false,
      maxImageDimension: 0,
      jpegQuality: 85,
    );
    final output = writer.write();
    final check = _Parser(output).parse();
    if (check.pageCount != selected.length) return unchanged;

    return PdfEditResult(
      bytes: output,
      changed: true,
      pageCount: selected.length,
    );
  } catch (_) {
    return unchanged;
  }
}

List<({int number, _PdfDict dict})> _flattenPages(_PdfDocument document) {
  final root = document.trailer.entries['Root'];
  if (root is! _PdfRef) return const [];
  final catalog = document.objects[root.number];
  if (catalog is! _PdfDict) return const [];

  final pages = <({int number, _PdfDict dict})>[];
  final seen = <int>{};

  void walk(_PdfObject? node, Map<String, _PdfObject> inherited) {
    var target = node;
    int? number;
    if (target is _PdfRef) {
      if (!seen.add(target.number)) return;
      number = target.number;
      target = document.objects[target.number];
    }
    if (target is! _PdfDict) return;

    final merged = <String, _PdfObject>{...inherited};
    for (final key in const ['MediaBox', 'CropBox', 'Rotate', 'Resources']) {
      final value = target.entries[key];
      if (value != null) merged[key] = value;
    }

    final type = target.entries['Type'];
    if (type is _PdfName && type.raw == 'Page') {
      for (final key in const ['MediaBox', 'CropBox', 'Rotate', 'Resources']) {
        final value = merged[key];
        if (value != null) target.entries.putIfAbsent(key, () => value);
      }
      pages.add((number: number ?? -1, dict: target));
      return;
    }

    final kids = target.entries['Kids'];
    if (kids is _PdfArray) {
      for (final kid in kids.items) {
        walk(kid, merged);
      }
    }
  }

  walk(catalog.entries['Pages'], const {});
  return pages;
}

// ─────────────────────────────────────────────────────────────────────────────
// Merge
// ─────────────────────────────────────────────────────────────────────────────

/// Merges PDFs by appending the pages of each input to the first.
///
/// Page dictionaries, resources and content are deep-copied with new object
/// numbers. Outlines from the appended documents are not carried over.
/// Unsupported inputs return the first document unchanged.
PdfEditResult mergePdfs(List<Uint8List> inputs) {
  if (inputs.length < 2) {
    return PdfEditResult(
      bytes: inputs.isEmpty ? Uint8List(0) : inputs.first,
      changed: false,
      pageCount: 0,
    );
  }

  try {
    final target = _Parser(inputs.first).parse();
    final rootRef = target.trailer.entries['Root'];
    if (rootRef is! _PdfRef) throw const _Unsupported('missing catalog');
    final catalog = target.objects[rootRef.number];
    if (catalog is! _PdfDict) throw const _Unsupported('invalid catalog');
    final pagesRef = catalog.entries['Pages'];
    if (pagesRef is! _PdfRef) throw const _Unsupported('missing page tree');
    final rootPages = target.objects[pagesRef.number];
    if (rootPages is! _PdfDict) throw const _Unsupported('invalid page tree');

    var maxNumber = target.objects.keys.fold(0, (a, b) => a > b ? a : b);
    int nextNumber() => ++maxNumber;

    final targetPages = _flattenPages(target);
    if (targetPages.isEmpty) throw const _Unsupported('target has no pages');
    final mergedPages = <_PdfRef>[];
    for (final page in targetPages) {
      page.dict.entries['Parent'] = pagesRef;
      mergedPages.add(
        _PdfRef(page.number, target.generations[page.number] ?? 0),
      );
    }

    for (var index = 1; index < inputs.length; index++) {
      final source = _Parser(inputs[index]).parse();
      final sourcePages = _flattenPages(source);
      if (sourcePages.isEmpty) throw const _Unsupported('source has no pages');
      final remap = <int, int>{};

      for (final page in sourcePages) {
        final shallow = _PdfDict(
          Map<String, _PdfObject>.of(page.dict.entries)..remove('Parent'),
        );
        final copy = _copyObject(shallow, source, target, remap, nextNumber);
        if (copy is! _PdfDict) throw const _Unsupported('invalid page copy');
        copy.entries['Parent'] = pagesRef;
        final number = nextNumber();
        target.objects[number] = copy;
        target.generations[number] = 0;
        mergedPages.add(_PdfRef(number, 0));
      }
    }

    rootPages.entries['Kids'] = _PdfArray(mergedPages);
    rootPages.entries['Count'] = _PdfNumber(mergedPages.length);

    final writer = _Writer(
      target,
      reduceImages: false,
      maxImageDimension: 0,
      jpegQuality: 85,
    );
    final output = writer.write();
    final check = _Parser(output).parse();
    if (check.pageCount != mergedPages.length) {
      throw const _Unsupported('merge validation failed');
    }

    return PdfEditResult(
      bytes: output,
      changed: true,
      pageCount: mergedPages.length,
    );
  } catch (_) {
    return PdfEditResult(bytes: inputs.first, changed: false, pageCount: 0);
  }
}

_PdfObject _copyObject(
  _PdfObject object,
  _PdfDocument source,
  _PdfDocument target,
  Map<int, int> remap,
  int Function() nextNumber,
) {
  switch (object) {
    case _PdfRef():
      return _PdfRef(
        _copyReference(object, source, target, remap, nextNumber),
        0,
      );
    case _PdfArray():
      return _PdfArray([
        for (final item in object.items)
          _copyObject(item, source, target, remap, nextNumber),
      ]);
    case _PdfDict():
      return _PdfDict({
        for (final entry in object.entries.entries)
          entry.key: _copyObject(
            entry.value,
            source,
            target,
            remap,
            nextNumber,
          ),
      });
    case _PdfStream():
      final dict = _copyObject(object.dict, source, target, remap, nextNumber);
      if (dict is! _PdfDict) throw const _Unsupported('invalid stream');
      return _PdfStream(dict, Uint8List.fromList(object.data));
    case _PdfString():
      return _PdfString(Uint8List.fromList(object.raw));
    default:
      return object;
  }
}

int _copyReference(
  _PdfRef reference,
  _PdfDocument source,
  _PdfDocument target,
  Map<int, int> remap,
  int Function() nextNumber,
) {
  final existing = remap[reference.number];
  if (existing != null) return existing;

  final object = source.objects[reference.number];
  if (object == null) throw _Unsupported('missing object ${reference.number}');

  final number = nextNumber();
  remap[reference.number] = number;
  target.objects[number] = _copyObject(
    object,
    source,
    target,
    remap,
    nextNumber,
  );
  target.generations[number] = 0;
  return number;
}

// ─────────────────────────────────────────────────────────────────────────────
// Metadata
// ─────────────────────────────────────────────────────────────────────────────

/// The document information dictionary.
final class PdfMetadata {
  const PdfMetadata({
    this.title,
    this.author,
    this.subject,
    this.keywords,
    this.creator,
    this.producer,
  });

  final String? title;
  final String? author;
  final String? subject;
  final String? keywords;
  final String? creator;
  final String? producer;

  static const empty = PdfMetadata();
}

/// Reads and writes the document information dictionary.
abstract final class PdfMetadataEditor {
  /// Reads metadata, or [PdfMetadata.empty] when unavailable.
  static PdfMetadata read(Uint8List input) {
    try {
      final document = _Parser(input).parse();
      final info = _resolveInfo(document);
      if (info == null) return PdfMetadata.empty;
      String? value(String key) {
        final entry = info.entries[key];
        return entry is _PdfString ? _decodePdfString(entry) : null;
      }

      return PdfMetadata(
        title: value('Title'),
        author: value('Author'),
        subject: value('Subject'),
        keywords: value('Keywords'),
        creator: value('Creator'),
        producer: value('Producer'),
      );
    } catch (_) {
      return PdfMetadata.empty;
    }
  }

  /// Writes [metadata]. A null field is removed from the info dictionary.
  static PdfEditResult write(Uint8List input, PdfMetadata metadata) {
    final unchanged = PdfEditResult(bytes: input, changed: false, pageCount: 0);
    try {
      final document = _Parser(input).parse();
      final pages = document.pageCount;
      if (pages <= 0) return unchanged;

      var info = _resolveInfo(document);
      if (info == null) {
        final number =
            document.objects.keys.fold(0, (a, b) => a > b ? a : b) + 1;
        info = _PdfDict({});
        document.objects[number] = info;
        document.generations[number] = 0;
        document.trailer.entries['Info'] = _PdfRef(number, 0);
      }

      void set(String key, String? value) {
        if (value == null || value.isEmpty) {
          info!.entries.remove(key);
        } else {
          info!.entries[key] = _encodePdfString(value);
        }
      }

      set('Title', metadata.title);
      set('Author', metadata.author);
      set('Subject', metadata.subject);
      set('Keywords', metadata.keywords);
      set('Creator', metadata.creator);
      set('Producer', metadata.producer);

      final writer = _Writer(
        document,
        reduceImages: false,
        maxImageDimension: 0,
        jpegQuality: 85,
      );
      final output = writer.write();
      final check = _Parser(output).parse();
      if (check.pageCount != pages) return unchanged;

      return PdfEditResult(bytes: output, changed: true, pageCount: pages);
    } catch (_) {
      return unchanged;
    }
  }

  static _PdfDict? _resolveInfo(_PdfDocument document) {
    var info = document.trailer.entries['Info'];
    final seen = <int>{};
    while (info is _PdfRef) {
      if (!seen.add(info.number)) return null;
      info = document.objects[info.number];
    }
    return info is _PdfDict ? info : null;
  }
}

_PdfString _encodePdfString(String value) {
  final units = value.codeUnits;
  final hex = StringBuffer('<FEFF');
  for (final unit in units) {
    hex.write(unit.toRadixString(16).padLeft(4, '0'));
  }
  hex.write('>');
  return _PdfString(Uint8List.fromList(latin1.encode(hex.toString())));
}

String? _decodePdfString(_PdfString string) {
  final raw = string.raw;
  if (raw.length < 2) return null;
  if (raw[0] == 0x3C) {
    final hex = <int>[];
    for (var i = 1; i < raw.length && raw[i] != 0x3E; i++) {
      final c = raw[i];
      final value = c >= 0x30 && c <= 0x39
          ? c - 0x30
          : c >= 0x41 && c <= 0x46
          ? c - 0x41 + 10
          : c >= 0x61 && c <= 0x66
          ? c - 0x61 + 10
          : -1;
      if (value >= 0) hex.add(value);
    }
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add((hex[i] << 4) | (i + 1 < hex.length ? hex[i + 1] : 0));
    }
    return _decodeTextBytes(Uint8List.fromList(bytes));
  }
  if (raw[0] == 0x28) {
    final bytes = <int>[];
    var depth = 1;
    for (var i = 1; i < raw.length; i++) {
      final c = raw[i];
      if (c == 0x5C && i + 1 < raw.length) {
        bytes.add(raw[++i]);
        continue;
      }
      if (c == 0x28) depth++;
      if (c == 0x29) {
        depth--;
        if (depth == 0) break;
      }
      bytes.add(c);
    }
    return _decodeTextBytes(Uint8List.fromList(bytes));
  }
  return null;
}

String _decodeTextBytes(Uint8List data) {
  if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
    final units = <int>[];
    for (var i = 2; i + 1 < data.length; i += 2) {
      units.add((data[i] << 8) | data[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
    final units = <int>[];
    for (var i = 2; i + 1 < data.length; i += 2) {
      units.add((data[i + 1] << 8) | data[i]);
    }
    return String.fromCharCodes(units);
  }
  return latin1.decode(data, allowInvalid: true);
}
