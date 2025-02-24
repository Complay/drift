import 'package:collection/collection.dart';
import 'package:drift/drift.dart' show DriftSqlType;
import 'package:sqlparser/sqlparser.dart' as sql;
import 'package:sqlparser/utils/node_to_text.dart';

import '../analysis/results/results.dart';
import '../utils/string_escaper.dart';
import 'database_writer.dart';
import 'tables/table_writer.dart';
import 'writer.dart';

class SchemaVersion {
  final int version;
  final List<DriftSchemaElement> schema;
  final Map<String, Object?> options;

  SchemaVersion(this.version, this.schema, this.options);
}

enum _ResultSetKind {
  table,
  virtualTable,
  view,
}

final class _TableShape {
  final _ResultSetKind kind;

  // Map from Dart getter names to column names in SQL and the SQL type.
  final Map<String, (String, DriftSqlType)> columnTypes;

  _TableShape(this.kind, this.columnTypes);

  @override
  int get hashCode => Object.hash(kind, _equality.hash(columnTypes));

  @override
  bool operator ==(Object other) {
    return other is _TableShape &&
        other.kind == kind &&
        _equality.equals(other.columnTypes, columnTypes);
  }

  static const _equality = MapEquality<String, (String, DriftSqlType)>();

  static Map<String, (String, DriftSqlType)> columnsFrom(
      DriftElementWithResultSet e) {
    return {
      for (final column in e.columns)
        column.nameInDart: (column.nameInSql, column.sqlType.builtin),
    };
  }
}

/// A writer that writes schema code for all schema versions known to us.
///
/// While other tools to generate code for a specific schema version exists
/// (we use it to generate test code), the generated code is very large since
/// it can contain data classes and all information known to drift.
/// Code generated by this writer is optimized to be compact by hiding table
/// metadata not strictly necessary for migrations and by re-using column
/// definitions where possible.
class SchemaVersionWriter {
  static final Uri _schemaLibrary =
      Uri.parse('package:drift/internal/versioned_schema.dart');

  /// All schema versions, sorted by [SchemaVersion.version].
  final List<SchemaVersion> versions;
  final Scope libraryScope;

  final Map<String, String> _columnCodeToFactory = {};
  final Map<_TableShape, String> _shapes = {};

  SchemaVersionWriter(this.versions, this.libraryScope) {
    assert(versions.isSortedBy<num>((element) => element.version));
  }

  /// Since not every column changes in every schema version, we prefer to re-use
  /// columns with an identical definition across tables and schema versions.
  ///
  /// We do this by generating a method constructing the column which can be
  /// called in different places. This method looks up or creates a method for
  /// the given [column], returning it if doesn't exist.
  String _referenceColumn(DriftColumn column) {
    final text = libraryScope.leaf();
    final (type, code) = TableOrViewWriter.instantiateColumn(column, text);

    return _columnCodeToFactory.putIfAbsent(code, () {
      final methodName = '_column_${_columnCodeToFactory.length}';
      text.writeln('$type $methodName(String aliasedName) => $code;');
      return methodName;
    });
  }

  void _writeColumnsArgument(List<DriftColumn> columns, TextEmitter writer) {
    writer.write('columns: [');

    for (final column in columns) {
      writer
        ..write(_referenceColumn(column))
        ..write(',');
    }

    writer.write('],');
  }

  /// Finds a class to use for [resultSet].
  ///
  /// When only minor details like column or table constraints change, we don't
  /// want to introduce a new class. The interface of a class is only determined
  /// by its kind (since we need to subclass from VersionedTable,
  /// VersionedVirtualTable or VersionedView) and its public getters used to
  /// access columns.
  ///
  /// This looks up a suitable class for the existing [resultSet] or creates a
  /// new one, returning its name.
  String _shapeClass(DriftElementWithResultSet resultSet) {
    final (kind, superclass) = switch (resultSet) {
      DriftTable(virtualTableData: null) => (
          _ResultSetKind.table,
          'VersionedTable'
        ),
      DriftTable() => (_ResultSetKind.virtualTable, 'VersionedVirtualTable'),
      DriftView() => (_ResultSetKind.view, 'VersionedView'),
      _ => throw ArgumentError.value(resultSet, 'resultSet', 'Unknown type'),
    };

    final shape = _TableShape(kind, _TableShape.columnsFrom(resultSet));
    return _shapes.putIfAbsent(shape, () {
      final className = 'Shape${_shapes.length}';
      final classWriter = libraryScope.leaf();

      classWriter
        ..write('class $className extends ')
        ..writeUriRef(_schemaLibrary, superclass)
        ..writeln('{')
        ..writeln(
            '$className({required super.source, required super.alias}) : super.aliased();');

      for (final MapEntry(key: getterName, value: (sqlName, type))
          in shape.columnTypes.entries) {
        final columnType = AnnotatedDartCode([dartTypeNames[type]!]);

        classWriter
          ..writeDriftRef('GeneratedColumn<')
          ..writeDart(columnType)
          ..write('> get ')
          ..write(getterName)
          ..write(' => columnsByName[${asDartLiteral(sqlName)}]! as ')
          ..writeDriftRef('GeneratedColumn<')
          ..writeDart(columnType)
          ..writeln('>;');
      }

      classWriter.writeln('}');

      return className;
    });
  }

  String _suffixForElement(DriftSchemaElement element) => switch (element) {
        DriftTable() => 'Table',
        DriftView() => 'View',
        DriftIndex() => 'Index',
        DriftTrigger() => 'Trigger',
        _ => throw ArgumentError('Unhandled element type $element'),
      };

  String _writeWithResultSet(
    String getterName,
    DriftElementWithResultSet entity,
    TextEmitter writer,
  ) {
    final shape = _shapeClass(entity);
    writer
      ..write('late final $shape $getterName = ')
      ..write('$shape(source: ');

    switch (entity) {
      case DriftTable():
        if (entity.isVirtual) {
          final info = entity.virtualTableData!;

          writer
            ..writeUriRef(_schemaLibrary, 'VersionedVirtualTable(')
            ..write('entityName: ${asDartLiteral(entity.schemaName)},')
            ..write('moduleAndArgs: ${asDartLiteral(info.moduleAndArgs)},');
        } else {
          final tableConstraints = <String>[];

          if (entity.writeDefaultConstraints) {
            // We don't override primaryKey and uniqueKey in generated table
            // classes to keep the code shorter. The migrator would use those
            // getters to generate SQL at runtime, which means that this burden
            // now falls onto the generator.
            for (final constraint in entity.tableConstraints) {
              final astNode = switch (constraint) {
                PrimaryKeyColumns(primaryKey: var columns) => sql.KeyClause(
                    null,
                    isPrimaryKey: true,
                    columns: [
                      for (final column in columns)
                        sql.IndexedColumn(
                            sql.Reference(columnName: column.nameInSql))
                    ],
                  ),
                UniqueColumns(uniqueSet: var columns) => sql.KeyClause(
                    null,
                    isPrimaryKey: false,
                    columns: [
                      for (final column in columns)
                        sql.IndexedColumn(
                            sql.Reference(columnName: column.nameInSql))
                    ],
                  ),
                ForeignKeyTable() => sql.ForeignKeyTableConstraint(
                    null,
                    columns: [
                      for (final column in constraint.localColumns)
                        sql.Reference(columnName: column.nameInSql)
                    ],
                    clause: sql.ForeignKeyClause(
                      foreignTable:
                          sql.TableReference(constraint.otherTable.schemaName),
                      columnNames: [
                        for (final column in constraint.otherColumns)
                          sql.Reference(columnName: column.nameInSql)
                      ],
                      onUpdate: constraint.onUpdate,
                      onDelete: constraint.onDelete,
                    ),
                  ),
              };

              tableConstraints.add(astNode.toSql());
            }
          }
          tableConstraints.addAll(entity.overrideTableConstraints.toList());

          writer
            ..writeUriRef(_schemaLibrary, 'VersionedTable(')
            ..write('entityName: ${asDartLiteral(entity.schemaName)},')
            ..write('withoutRowId: ${entity.withoutRowId},')
            ..write('isStrict: ${entity.strict},')
            ..write('tableConstraints: [');

          for (final constraint in tableConstraints) {
            writer
              ..write(asDartLiteral(constraint))
              ..write(',');
          }

          writer.write('],');
        }
        break;
      case DriftView():
        final source = entity.source as SqlViewSource;

        writer
          ..writeUriRef(_schemaLibrary, 'VersionedView(')
          ..write('entityName: ${asDartLiteral(entity.schemaName)},')
          ..write(
              'createViewStmt: ${asDartLiteral(source.sqlCreateViewStmt)},');

        break;
    }

    _writeColumnsArgument(entity.columns, writer);
    writer.write('attachedDatabase: database,');
    writer.write('), alias: null)');

    return getterName;
  }

  String _writeEntity({
    required DriftSchemaElement element,
    required TextEmitter definition,
  }) {
    final name = definition.parent!.getNonConflictingName(
      element.dbGetterName!,
      (name) => name + _suffixForElement(element),
    );

    if (element is DriftElementWithResultSet) {
      _writeWithResultSet(name, element, definition);
    } else if (element is DriftIndex) {
      final index = definition.drift('Index');

      definition
        ..write('final $index $name = ')
        ..writeln(DatabaseWriter.createIndex(definition.parent!, element));
    } else if (element is DriftTrigger) {
      final trigger = definition.drift('Trigger');

      definition
        ..write('final $trigger $name = ')
        ..writeln(DatabaseWriter.createTrigger(definition.parent!, element));
    } else {
      throw ArgumentError('Unhandled element type $element');
    }

    definition.write(';');
    return name;
  }

  void _writeCallbackArgsForStep(TextEmitter text) {
    for (final (current, next) in versions.withNext) {
      text
        ..write('required Future<void> Function(')
        ..writeDriftRef('Migrator')
        ..write(' m, _S${next.version} schema)')
        ..writeln('from${current.version}To${next.version},');
    }
  }

  void write() {
    libraryScope.leaf()
      ..writeln('// ignore_for_file: type=lint,unused_import')
      ..writeln('// GENERATED BY drift_dev, DO NOT MODIFY.');

    // There is no need to generate schema classes for the first version, we
    // only need them for versions targeted by migrations.
    for (final version in versions.skip(1)) {
      final versionNo = version.version;
      final versionClass = '_S$versionNo';
      final versionScope = libraryScope.child();

      // Reserve all the names already in use in [VersionedSchema] and its
      // superclasses. Without this certain table names would cause us to
      // generate invalid code.
      versionScope.reserveNames([
        'database',
        'entities',
        'version',
        'stepByStepHelper',
        'runMigrationSteps',
      ]);

      // Write an _S<x> class for each schema version x.
      versionScope.leaf()
        ..write('final class $versionClass extends ')
        ..writeUriRef(_schemaLibrary, 'VersionedSchema')
        ..writeln('{')
        ..writeln('$versionClass({required super.database}): '
            'super(version: $versionNo);');

      // Override the allEntities getters by VersionedSchema
      final allEntitiesWriter = versionScope.leaf()
        ..write('@override late final ')
        ..writeUriRef(AnnotatedDartCode.dartCore, 'List')
        ..write('<')
        ..writeDriftRef('DatabaseSchemaEntity')
        ..write('> entities = [');

      for (final entity in version.schema) {
        // Creata field for the entity and include it in the list
        final fieldName =
            _writeEntity(element: entity, definition: versionScope.leaf());

        allEntitiesWriter.write('$fieldName,');
      }

      allEntitiesWriter.write('];');
      versionScope.leaf().writeln('}');
    }

    // Write a MigrationStepWithVersion factory that takes a callback doing a
    // step for each schema to to the next. We supply a special migrator that
    // only considers entities from that version, as well as a typed reference
    // to the _S<x> class used to lookup elements.
    final steps = libraryScope.leaf()
      ..writeUriRef(_schemaLibrary, 'MigrationStepWithVersion')
      ..write(' migrationSteps({');
    _writeCallbackArgsForStep(steps);
    steps
      ..writeln('}) {')
      ..writeln('return (currentVersion, database) async {')
      ..writeln('switch (currentVersion) {');

    for (final (current, next) in versions.withNext) {
      steps
        ..writeln('case ${current.version}:')
        ..write('final schema = _S${next.version}(database: database);')
        ..write('final migrator = ')
        ..writeDriftRef('Migrator')
        ..writeln('(database, schema);')
        ..writeln(
            'await from${current.version}To${next.version}(migrator, schema);')
        ..writeln('return ${next.version};');
    }

    steps
      ..writeln(
          r"default: throw ArgumentError.value('Unknown migration from $currentVersion');")
      ..writeln('}') // End of switch
      ..writeln('};') // End of function literal
      ..writeln('}'); // End of migrationSteps method

    final stepByStep = libraryScope.leaf()
      ..writeDriftRef('OnUpgrade')
      ..write(' stepByStep({');
    _writeCallbackArgsForStep(stepByStep);
    stepByStep
      ..writeln('}) => ')
      ..writeUriRef(_schemaLibrary, 'VersionedSchema')
      ..write('.stepByStepHelper(step: migrationSteps(');

    for (final (current, next) in versions.withNext) {
      final name = 'from${current.version}To${next.version}';

      stepByStep.writeln('$name: $name,');
    }

    stepByStep.writeln('));');
  }
}

extension<T> on Iterable<T> {
  Iterable<(T, T)> get withNext sync* {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return;

    var a = iterator.current;
    while (iterator.moveNext()) {
      var b = iterator.current;
      yield (a, b);

      a = b;
    }
  }
}
