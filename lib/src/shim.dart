import 'dart:async';

import 'package:analysis_server_lib/analysis_server_lib.dart'
    hide Position, Location;
import 'package:json_rpc_2/json_rpc_2.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'apply_change.dart';
import 'args.dart';
import 'capabilities.dart';
import 'convert.dart';
import 'logging/logs.dart';
import 'subscriptions.dart';
import 'position_convert.dart';
import 'protocol/language_server/interface.dart';
import 'protocol/language_server/messages.dart';
import 'utils/command_cache.dart';
import 'utils/file_cache.dart';
import 'utils/guid.dart';
import 'utils/package_dir_detection.dart';
import 'utils/per_file_pool.dart';

Future<LanguageServer> startShimmedServer(StartupArgs args) async {
  var client = await AnalysisServer.create(
      onRead: (m) => analyzerSink.add('OUT: $m\n'),
      onWrite: (m) => analyzerSink.add('IN: $m\n'),
      serverArgs: args.analysisServerArgs);
  await client.server.onConnected.first;
  return new AnalysisServerAdapter(client, args);
}

/// Wraps an [AnalysisServer] and exposes it as a [LanguageServer].
class AnalysisServerAdapter extends LanguageServer {
  final AnalysisServer _server;
  final StartupArgs _args;

  final _files = new FileCache();
  final _pools = new PerFilePool();
  final _commands = new CommandCache();
  final _fileVersions = <String, int>{};
  final Subscriptions _subscriptions;

  final _log = new Logger('AnalysisServerAdapter');

  AnalysisServerAdapter._(this._server, this._subscriptions, this._args) {
    _listeners();
  }

  factory AnalysisServerAdapter(AnalysisServer server, StartupArgs args) {
    final subscriptions = new Subscriptions(server);
    return new AnalysisServerAdapter._(server, subscriptions, args);
  }

  final _openDirectories = new Set<String>();
  final _openFiles = new Set<String>();

  ClientCapabilities clientCapabilities;

  @override
  Future<ServerCapabilities> initialize(int clientPid, String rootUri,
      ClientCapabilities clientCapabilities, String trace) async {
    this.clientCapabilities = clientCapabilities;
    final directory = _filePath(rootUri);
    final clientName = '${p.basename(directory)}-$clientPid';
    startLogging(clientName, _args.forceTraceLevel ?? trace);
    return serverCapabilities;
  }

  /// If [directory] is not already present in or underneath [_openDirectories]
  /// look for a parent that might be a package and add it.
  Future<Null> _addAnalysisRoot(String directory) async {
    if (!_openDirectories.contains(directory) &&
        !_openDirectories.any((d) => p.isWithin(d, directory))) {
      var packageDir = findParentPackageDir(directory);
      if (packageDir != null) {
        _openDirectories.add(packageDir);
        await _server.analysis
            .setAnalysisRoots(_openDirectories.toList(), const []);
      } else {
        _openDirectories.add(directory);
        await _server.analysis
            .setAnalysisRoots(_openDirectories.toList(), const []);
      }
    }
  }

  @override
  Future<Null> get onDone => _onDone.future;
  final _onDone = new Completer<Null>();
  bool _hasShutdown = false;

  @override
  Future<Null> shutdown() async {
    _hasShutdown = true;
    await _subscriptions.close();
    await _server.dispose();
  }

  @override
  void exit() {
    if (_hasShutdown) {
      _onDone.complete();
    } else {
      _server.dispose();
      _onDone.completeError('Exit called before shutdown');
    }
  }

  @override
  Future<Null> textDocumentDidOpen(TextDocumentItem document) {
    final path = _filePath(document.uri);
    return _pools.lock(path, () async {
      _files[path] = findLineLengths(document.text);
      _fileVersions[path] = document.version;
      var directory = p.dirname(path);
      await _addAnalysisRoot(directory);
      _openFiles.add(path);
      await _server.analysis.setPriorityFiles(_openFiles.toList());
      await _server.analysis
          .updateContent({path: new AddContentOverlay(document.text)});
    }, withTimeout: false);
  }

  @override
  Future<Null> textDocumentDidChange(VersionedTextDocumentIdentifier documentId,
      List<TextDocumentContentChangeEvent> changes) {
    final path = _filePath(documentId.uri);
    _subscriptions.invalidate(path);
    return _pools.lock(path, () async {
      if (_fileVersions[path] > documentId.version) {
        _log.warning('Ignoring file change for $path at version '
            '${documentId.version} since last seen in ${_fileVersions[path]}');
        return;
      }
      _fileVersions[path] = documentId.version;
      if (changes.length == 1 && changes.first.range == null) {
        _files[path] = findLineLengths(changes.single.text);
        await _server.analysis
            .updateContent({path: new AddContentOverlay(changes.single.text)});
      } else {
        var overlay = new ChangeContentOverlay(changes.map((change) {
          var sourceEdit = _toSourceEdit(_files[path], change);
          try {
            _files[path] = applyChange(_files[path], change);
          } catch (e) {
            _log.severe('Failed to apply change to line lengths', e);
          }
          return sourceEdit;
        }).toList());
        await _server.analysis.updateContent({path: overlay});
      }
    }, withTimeout: false);
  }

  @override
  Future<Null> textDocumentDidClose(TextDocumentIdentifier documentId) {
    final path = _filePath(documentId.uri);
    _subscriptions.onFileClose(path);
    return _pools.lock(path, () async {
      await _server.analysis.updateContent({path: new RemoveContentOverlay()});
    }, withTimeout: false);
  }

  @override
  Future<CompletionList> textDocumentCompletion(
      TextDocumentIdentifier documentId, Position position) {
    final path = _filePath(documentId.uri);
    return _pools.lock(path, () async {
      var offset = offsetFromPosition(_files[path], position);
      var id = (await _server.completion.getSuggestions(path, offset)).id;
      if (id == null) return null;
      _completionPaths[id] = path;
      return (_completions[id] = new Completer<CompletionList>()).future;
    });
  }

  final _completions = <String, Completer<CompletionList>>{};
  final _completionPaths = <String, String>{};
  void _listeners() {
    _server.completion.onResults.listen((results) {
      var id = results.id;
      if (!_completions.containsKey(id)) throw 'Missing completion $id';
      var path = _completionPaths.remove(id);
      _completions
          .remove(id)
          .complete(_toCompletionList(_files[path], results));
    });
    _server.search.onResults.listen((results) {
      var id = results.id;
      if (_searchResults.containsKey(id)) {
        _searchResults.remove(id).complete(_toLocationList(results, _files));
        return;
      }
      if (_symbolSearchResults.containsKey(id)) {
        _symbolSearchResults
            .remove(id)
            .complete(_toSymbolInformation(results, _files));
        return;
      }
      _log.severe('Missing handler for search result $id');
    });
  }

  @override
  Future<Location> textDocumentDefinition(
      TextDocumentIdentifier documentId, Position position) {
    final path = _filePath(documentId.uri);
    return _pools.lock(path, () async {
      var offset = offsetFromPosition(_files[path], position);
      var result = await _server.analysis.getNavigation(path, offset, 1);
      if (result.targets.isEmpty) return null;
      return _navigationLocations(result).first;
    });
  }

  Iterable<Location> _navigationLocations(NavigationResult result) =>
      result.targets.map((t) {
        var file = result.files[t.fileIndex];
        return new Location((b) => b
          ..uri = toFileUri(file)
          ..range = rangeFromOffset(_files[file], t.offset, t.length));
      });

  @override
  Future<List<Location>> textDocumentReferences(
      TextDocumentIdentifier documentId,
      Position position,
      ReferenceContext context) {
    final path = _filePath(documentId.uri);
    return _pools.lock(path, () async {
      var offset = offsetFromPosition(_files[path], position);
      var id =
          (await _server.search.findElementReferences(path, offset, true)).id;
      if (id == null) return const [];
      var references =
          (_searchResults[id] = new Completer<List<Location>>()).future;
      if (context.includeDeclaration) {
        var definition = await _server.analysis.getNavigation(path, offset, 1);
        return (await references)..addAll(_navigationLocations(definition));
      }
      return references;
    });
  }

  @override
  Future<List<Location>> textDocumentImplementation(
      TextDocumentIdentifier documentId, Position position) {
    final path = _filePath(documentId.uri);
    return _pools.lock(path, () async {
      var offset = offsetFromPosition(_files[path], position);
      var items = (await _server.search.getTypeHierarchy(path, offset))
          .hierarchyItems
          ?.where((i) => i.classElement.name != 'Object');
      if (items == null) return const [];
      var lookingForClass = items.every((i) => i.memberElement == null);
      return items
          .map((item) => lookingForClass
              ? item.classElement?.location
              : item.memberElement?.location)
          .where((location) => location != null)
          .map((location) => new Location((b) => b
            ..uri = toFileUri(location.file)
            ..range = rangeFromLocation(_files[location.file], location)))
          .toList();
    });
  }

  @override
  Future<List<DocumentHighlight>> textDocumentHighlights(
      TextDocumentIdentifier documentId, Position position) {
    final path = _filePath(documentId.uri);
    return _pools.lock(path, () async {
      var occurrences =
          (await _subscriptions.occurrences.requestFor(path)).occurrences;
      var offset = offsetFromPosition(_files[path], position);
      final matchingOccurrence = occurrences.firstWhere((occurrence) {
        for (final occurrenceOffset in occurrence.offsets) {
          if (offset >= occurrenceOffset &&
              offset <= occurrenceOffset + occurrence.length) {
            return true;
          }
        }
        return false;
      }, orElse: () => null);
      if (matchingOccurrence == null) return const [];
      return matchingOccurrence.offsets
          .map((o) => new DocumentHighlight((b) => b
            ..range =
                rangeFromOffset(_files[path], o, matchingOccurrence.length)))
          .toList();
    });
  }

  @override
  Future<Hover> textDocumentHover(
      TextDocumentIdentifier documentId, Position position) {
    final path = _filePath(documentId.uri);
    return _pools.lock(path, () async {
      var offset = offsetFromPosition(_files[path], position);
      var hovers = (await _server.analysis.getHover(path, offset)).hovers;
      if (hovers.isEmpty) return null;
      var hover = hovers.first;
      var range = rangeFromOffset(_files[path], hover.offset, hover.length);
      return new Hover((b) => b
        ..contents = _hoverMessage(hover)
        ..range = range);
    });
  }

  @override
  Future<List<Command>> textDocumentCodeAction(
      TextDocumentIdentifier documentId,
      Range range,
      CodeActionContext context) {
    // The only actions supported go through workspace/applyEdit
    if (!(clientCapabilities?.workspace?.applyEdit ?? false)) {
      return new Future.value(const []);
    }

    final path = _filePath(documentId.uri);
    return _pools.lock(path, () async {
      final results = <Command>[];
      List<int> lineLengths = _files[path];
      var offsetLength = offsetLengthFromRange(lineLengths, range);
      var assists = (await _server.edit
              .getAssists(path, offsetLength.offset, offsetLength.length))
          .assists
          .where(
              (a) => a.message != 'Convert into block documentation comment');
      results.addAll(assists
          .map((a) => _commands.add(_toCommand(a), () => _applyEdit(a))));

      final fixes =
          (await _server.edit.getFixes(path, offsetLength.offset)).fixes;
      results.addAll(fixes.expand((fix) {
        final prefix = 'Fix [${fix.error.code}]: ';
        return fix.fixes.map(
            (f) => _commands.add(_toCommand(f, prefix), () => _applyEdit(f)));
      }));

      results.add(_commands.add(
          new Command((b) => b
            ..title = 'Organize imports'
            ..command = makeGuid()),
          () => _organizeDirectives(_files[path], path)));
      results.add(_commands.add(
          new Command((b) => b
            ..title = 'Sort Members'
            ..command = makeGuid()),
          () => _sortMembers(_files[path], path)));

      return results;
    });
  }

  Future<Null> _organizeDirectives(List<int> fileLengths, String path) async {
    final sourceFileEdit = (await _server.edit.organizeDirectives(path)).edit;
    final workspaceEdit = new WorkspaceEdit((b) => b
      ..changes = {
        toFileUri(sourceFileEdit.file): sourceFileEdit.edits
            .map((e) => _toTextEdit(fileLengths, e))
            .toList()
      });
    _workspaceEdits.add(new ApplyWorkspaceEditParams((b) => b
      ..label = 'Organize Imports'
      ..edit = workspaceEdit));
  }

  Future<Null> _sortMembers(List<int> lineLengths, String path) async {
    final sourceFileEdit = (await _server.edit.sortMembers(path)).edit;
    final workspaceEdit = new WorkspaceEdit((b) => b
      ..changes = {
        toFileUri(sourceFileEdit.file): sourceFileEdit.edits
            .map((e) => _toTextEdit(lineLengths, e))
            .toList()
      });
    _workspaceEdits.add(new ApplyWorkspaceEditParams((b) => b
      ..label = 'Sort Members'
      ..edit = workspaceEdit));
  }

  @override
  Future<Null> workspaceExecuteCommand(String command) {
    _commands[command]();
    return new Future.value();
  }

  void _applyEdit(SourceChange change) {
    final params = new ApplyWorkspaceEditParams((b) => b
      ..label = change.message
      ..edit = _toWorkspaceEdit(_files, change));
    _workspaceEdits.add(params);
  }

  final _searchResults = <String, Completer<List<Location>>>{};

  final _filesWithDiagnostics = new Set<String>();
  @override
  Stream<Diagnostics> get diagnostics => _server.analysis.onErrors
      .map((errors) {
        var lines = _files[errors.file];
        return _toDiagnostics(lines, errors);
      })
      .distinct()
      .where((diagnostics) {
        if (diagnostics.diagnostics.isEmpty) {
          if (!_filesWithDiagnostics.contains(diagnostics.uri)) {
            return false;
          } else {
            _filesWithDiagnostics.remove(diagnostics.uri);
          }
        } else {
          _filesWithDiagnostics.add(diagnostics.uri);
        }
        return true;
      });

  @override
  Stream<ApplyWorkspaceEditParams> get workspaceEdits => _workspaceEdits.stream;
  final _workspaceEdits = new StreamController<ApplyWorkspaceEditParams>();

  @override
  Future<WorkspaceEdit> textDocumentRename(
      TextDocumentIdentifier documentId, Position position, String newName) {
    final path = _filePath(documentId.uri);
    final offset = offsetFromPosition(_files[path], position);
    return _server.edit
        .getRefactoring('RENAME', path, offset, 0, false,
            options: new RenameRefactoringOptions(newName: newName))
        .then((result) => _toWorkspaceEdit(_files, result.change));
  }

  @override
  void setupExtraMethods(Peer peer) {
    peer
      ..registerMethod('dart/getServerPort',
          () => _server.diagnostic.getServerPort().then((r) => r.port));
  }

  @override
  Future<List<SymbolInformation>> textDocumentSymbols(
      TextDocumentIdentifier documentId) {
    final path = _filePath(documentId.uri);
    return _pools.lock(
        path,
        () => _subscriptions.outlines
            .requestFor(path)
            ?.then((o) => toSymbolInformation(_files, o)));
  }

  @override
  Future<List<SymbolInformation>> workspaceSymbol(String query) async {
    return (await Future.wait([_memberSearch(query), _topLevelSearch(query)]))
        .expand((r) => r)
        .toList();
  }

  final _symbolSearchResults = <String, Completer<List<SymbolInformation>>>{};
  Future<List<SymbolInformation>> _topLevelSearch(String query) async {
    final id = (await _server.search.findTopLevelDeclarations(query)).id;
    return (_symbolSearchResults[id] = new Completer<List<SymbolInformation>>())
        .future;
  }

  Future<List<SymbolInformation>> _memberSearch(String query) async {
    final id = (await _server.search.findMemberDeclarations(query)).id;
    return (_symbolSearchResults[id] = new Completer<List<SymbolInformation>>())
        .future;
  }
}

String _hoverMessage(HoverInformation hover) {
  var message = new StringBuffer();
  if (hover.elementDescription != null) {
    message.writeln(hover.elementDescription);
  }
  if (hover.isDeprecated) message.writeln('(deprecated)');
  if (hover.dartdoc != null) {
    if (message.isNotEmpty) message.writeln();
    message.writeln(hover.dartdoc);
  }
  return '$message';
}

String _filePath(String fileUri) =>
    Uri.decodeComponent(Uri.parse(fileUri).path);

List<Location> _toLocationList(SearchResults results, FileCache files) =>
    results.results
        .map((result) => result.location)
        .toSet()
        .map((location) => new Location((b) => b
          ..uri = toFileUri(location.file)
          ..range = rangeFromLocation(files[location.file], location)))
        .toList();

List<SymbolInformation> _toSymbolInformation(
        SearchResults results, FileCache files) =>
    results.results
        .map((result) => new SymbolInformation((b) => b
          ..containerName = result.path.length > 1 ? result.path[1].name : ''
          ..name = result.path.first.name
          ..kind = _toSymbolKind(result.path.first)
          ..location = new Location((b) => b
            ..uri = toFileUri(result.location.file)
            ..range = rangeFromLocation(
                files[result.location.file], result.location))))
        .toList();

SymbolKind _toSymbolKind(Element element) {
  switch (element.kind) {
    case "CLASS":
    case "CLASS_TYPE_ALIAS":
      return SymbolKind.classSymbol;
    case "COMPILATION_UNIT":
      return SymbolKind.module;
    case "CONSTRUCTOR":
    case "CONSTRUCTOR_INVOCATION":
      return SymbolKind.constructor;
    case "ENUM":
      return SymbolKind.enumSymbol;
    case "ENUM_CONSTANT":
      return SymbolKind.enumMember;
    case "FIELD":
      return SymbolKind.field;
    case "FILE":
      return SymbolKind.file;
    case "FUNCTION":
    case "FUNCTION_INVOCATION":
    case "FUNCTION_TYPE_ALIAS":
      return SymbolKind.function;
    case "GETTER":
      return SymbolKind.field;
    case "LABEL":
      return null; //???
    case "LIBRARY":
      return SymbolKind.module;
    case "LOCAL_VARIABLE":
      return SymbolKind.variable;
    case "METHOD":
      return SymbolKind.method;
    case "PARAMETER":
    case "PREFIX":
      return null; //???
    case "SETTER":
      return SymbolKind.field;
    case "TOP_LEVEL_VARIABLE":
      return SymbolKind.variable;
    case "TYPE_PARAMETER":
      return SymbolKind.typeParameter;
    case "UNIT_TEST_GROUP":
    case "UNIT_TEST_TEST":
    case "UNKNOWN":
    default:
      return null; //???
  }
}

Diagnostics _toDiagnostics(List<int> lineLengths, AnalysisErrors errors) =>
    new Diagnostics((b) => b
      ..uri = toFileUri(errors.file)
      ..diagnostics = errors.errors
          .map((error) => _toDiagnostic(lineLengths, error))
          .toList());

CompletionList _toCompletionList(
        List<int> lineLengths, CompletionResults results) =>
    new CompletionList((b) => b
      ..isIncomplete = !results.isLast
      ..items = results.results
          .map((r) => _toCompletionItem(lineLengths, r, results))
          .toList());

CompletionItem _toCompletionItem(List<int> lineLengths,
    CompletionSuggestion suggestion, CompletionResults results) {
  final symbol = _completionSymbol(suggestion);
  return new CompletionItem((b) => b
    ..label = symbol
    ..kind = _completionKind(suggestion)
    ..textEdit = new TextEdit((b) => b
      ..newText = symbol
      ..range = rangeFromOffset(
          lineLengths, results.replacementOffset, results.replacementLength))
    ..detail = _completionItemDetail(suggestion)
    ..documentation = suggestion.docComplete);
}

/// Normalize completions since snippets aren't supported.
///
/// Analysis Server expects to be able to send `selectionOffset` and
/// `selectionLength` to move the cursor and give a better UX. Normalize the
/// cases that depend on this that are particularly annoying.
String _completionSymbol(CompletionSuggestion suggestion) {
  if (suggestion.completion.endsWith(',')) {
    return suggestion.completion.substring(0, suggestion.completion.length - 1);
  }
  return suggestion.completion;
}

String _completionItemDetail(CompletionSuggestion suggestion) {
  if (suggestion.returnType != null && suggestion.docSummary != null) {
    return '${suggestion.returnType} : ${suggestion.docSummary}';
  }
  if (suggestion.docSummary != null) return suggestion.docSummary;
  if (suggestion.returnType != null) return suggestion.returnType;
  if (suggestion.parameterName != null) {
    if (suggestion.parameterType != null) {
      return '${suggestion.parameterName} : ${suggestion.parameterType}';
    }
    return '${suggestion.parameterName}';
  }
  return null;
}

Diagnostic _toDiagnostic(List<int> lineLengths, AnalysisError error) =>
    new Diagnostic((b) => b
      ..range = rangeFromLocation(lineLengths, error.location)
      ..severity = _diagnosticSeverity(error.severity, error.type)
      ..code = error.code
      ..source = 'Dart analysis server'
      ..message = error.message);

int _diagnosticSeverity(String severity, String type) {
  if (severity == 'ERROR') return 1;
  if (severity == 'WARNING') return 2;
  return (type == 'INFO') ? 4 : 3;
}

CompletionItemKind _completionKind(CompletionSuggestion suggestion) {
  if (suggestion.element != null) {
    switch (suggestion.element.kind) {
      case 'GETTER':
      case 'SETTER':
      case 'FIELD':
        return CompletionItemKind.field;
      case 'FUNCTION':
        return CompletionItemKind.function;
      case 'METHOD':
        return CompletionItemKind.method;
      case 'LOCAL_VARIABLE':
      case 'TOP_LEVEL_VARIABLE':
        return CompletionItemKind.variable;
      case 'CLASS_ELEMENT':
      case 'CLASS_TYPE_ALIAS':
        return CompletionItemKind.classKind;
      case 'CONSTRUCTOR':
        return CompletionItemKind.constructor;
      case 'ENUM_CONSTANT':
      case 'ENUM_ELEMENT':
        return CompletionItemKind.enumKind;
      case 'FILE':
        return CompletionItemKind.file;
      case 'LIBRARY':
      case 'COMPILATION_UNIT':
        return CompletionItemKind.module;
    }
  }
  switch (suggestion.kind) {
    case 'ARGUMENT_LIST':
      return CompletionItemKind.snippet; // ?
    case 'IMPORT':
      return CompletionItemKind.module; // ?
    case 'IDENTIFIER':
      return CompletionItemKind.reference;
    case 'INVOCATION':
      return CompletionItemKind.method;
    case 'KEYWORD':
      return CompletionItemKind.keyword;
    case 'NAMED_ARGUMENT':
    case 'OPTIONAL_ARGUMENT':
      return CompletionItemKind.snippet; // ?
    case 'PARAMETER':
      return CompletionItemKind.value; //?
    default:
      return null;
  }
}

SourceEdit _toSourceEdit(
        Iterable<int> lineLengths, TextDocumentContentChangeEvent change) =>
    new SourceEdit(offsetFromPosition(lineLengths, change.range.start),
        change.rangeLength, change.text);

Command _toCommand(SourceChange change, [String messagePrefix]) =>
    new Command((b) => b
      ..title = messagePrefix != null
          ? '$messagePrefix${change.message}'
          : change.message
      ..arguments = const []
      ..command = makeGuid());

WorkspaceEdit _toWorkspaceEdit(FileCache fileCache, SourceChange change) =>
    new WorkspaceEdit((b) => b
      ..changes = new Map<String, List<TextEdit>>.fromIterable(change.edits,
          key: (edit) => toFileUri(edit.file),
          value: (edit) => edit.edits
              .map((e) => _toTextEdit(fileCache[edit.file], e))
              .toList()));

TextEdit _toTextEdit(Iterable<int> lineLengths, SourceEdit edit) =>
    new TextEdit((b) => b
      ..newText = edit.replacement
      ..range = rangeFromOffset(lineLengths, edit.offset, edit.length));
