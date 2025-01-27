## PostgreSQL migration driver.

import driver

import db_postgres
import std/sequtils
import std/sugar

from strutils import endsWith, parseInt
from logging import debug, error, addHandler, newConsoleLogger
from sets import incl, excl, HashSet, initHashSet, len, items, `$`, OrderedSet, initOrderedSet
from os import fileExists, `/`
from nre import re, replace

addHandler(newConsoleLogger())
const
  createMigrationsTableCommand = sql"""CREATE TABLE IF NOT EXISTS migrations(
    filename VARCHAR(255) NOT NULL,
    batch serial
  );"""
  getRanMigrationsCommand = sql"SELECT filename, batch FROM migrations ORDER BY batch DESC, filename DESC;"
  getNextBatchNumberCommand = sql"SELECT MAX(batch) FROM migrations;"
  insertRanMigrationCommand = sql"INSERT INTO migrations(filename, batch) VALUES (?, ?);"
  removeRanMigrationCommand = sql"DELETE FROM migrations WHERE filename = ? AND batch = ?;"
  getRanMigrationsForBatchCommand = sql"SELECT filename FROM migrations WHERE batch = ? ORDER BY filename DESC;"
  getTablesForDatabaseCommand = sql"SELECT TABLE_NAME FROM information_schema.tables WHERE TABLE_SCHEMA = ?;"
  getCreateForTableCommand = "SHOW CREATE TABLE `"

let
  autoIncrementRegex = re" AUTO_INCREMENT=\d+"

type
  PostgreSqlDriver* = ref object of Driver
    handle: DbConn

proc initPostgreSqlDriver*(settings: ConnectionSettings, migrationPath: string): PostgreSqlDriver =
  new result
  result.connectionSettings = settings
  result.migrationPath = migrationPath
  result.handle = open(settings.server, settings.username, settings.password, settings.db)

method ensureMigrationsTableExists*(d: PostgreSqlDriver) =
  ## Make sure that the `migrations` table exists in the database.
  d.handle.exec(createMigrationsTableCommand)

method closeDriver*(d: PostgreSqlDriver) =
  ## Close the driver and the underlying database connection.
  ## debug("Closing PostgreSQL connection")
  d.handle.close()

proc runUpMigration(d: PostgreSqlDriver, query, migration: string, batch: int): bool =
  ## Run and record an upwards migration.
  result = false
  try:
    let queries = strutils.split(query, ";").filter(q => len(q) > 0)
    for q in queries:
      d.handle.exec(SqlQuery(q))
    d.handle.exec(insertRanMigrationCommand, migration, batch)
    result = true
  except DbError:
    let exp = getCurrentException()
    echo exp.getStackTrace()
    error("Error running migration '", migration, "': ", exp.msg)

proc runDownMigration(d: PostgreSqlDriver, query, migration: string, batch: int): bool =
  ## Run and remove a downwards migration.
  result = false
  try:
    let queries = strutils.split(query, ";").filter(q => len(q) > 0)
    for q in queries:
      d.handle.exec(SqlQuery(q))
    d.handle.exec(removeRanMigrationCommand, migration, batch)
    result = true
  except DbError:
    error("Error reversing migration '", migration, "': ", getCurrentExceptionMsg())

proc getLastBatchNumber(d: PostgreSqlDriver): int =
  ## Get the last used batch number from the `migrations` table.
  result = 0
  let value = d.handle.getValue(getNextBatchNumberCommand)
  if value == "":
    result = 0
  else:
    result = parseInt(value)

proc getNextBatchNumber(d: PostgreSqlDriver): int =
  ## Get the next batch number.
  let lastNumber = d.getLastBatchNumber()
  result = lastNumber + 1

iterator getRanMigrations(d: PostgreSqlDriver): RanMigration =
  ## Get a list of all of the migrations that have already been ran.
  var ranMigration: RanMigration
  for row in d.handle.rows(getRanMigrationsCommand):
    ranMigration = (filename: row[0], batch: parseInt(row[1]))
    debug("ranMigration", ranMigration)
    yield ranMigration

proc getUpMigrationsToRun(d: PostgreSqlDriver, path: string): OrderedSet[string] =
  ## Get a set of pending upwards migrations from the given path.
  debug("Calculating up migrations to run")
  result = getFilenamesToCheck(path, ".up.sql")
  var ranMigrations = initOrderedSet[string]()

  for migration, batch in d.getRanMigrations():
    ranMigrations.incl(migration)
    result.excl(migration)

  debug("Found ", len(ranMigrations), " already ran migrations")

  

  debug("Got ", len(result), " files to run: ", $result)

method runUpMigrations*(d: PostgreSqlDriver): MigrationResult =
  ## Run all of the outstanding upwards migrations.
  result = (numRan: 0, batchNumber: d.getnextBatchNumber())

  var fileContent: TaintedString
  for file in d.getUpMigrationsToRun(d.migrationPath):
    debug("Running migration: ", file)
    fileContent = readFile(d.migrationPath / file)
    if len(fileContent) > 0:
      if d.runUpMigration(fileContent, file, result.batchNumber):
        inc result.numRan

iterator getMigrationsForBatch(d: PostgreSqlDriver, batch: int): string =
  ## Get all of the migrations that have been ran for a given batch.
  for row in d.handle.rows(getRanMigrationsForBatchCommand, batch):
    yield row[0]

method revertLastRanMigrations*(d: PostgreSqlDriver): MigrationResult =
  ## Wind back the most recent batch of migrations.
  result = (numRan: 0, batchNumber: d.getLastBatchNumber())

  debug("Calculating down migrations to run for batch number ", result.batchNumber)

  var downFileName: string
  var downFilePath: string
  var fileContent: TaintedString
  for file in d.getMigrationsForBatch(result.batchNumber):
    if file.endsWith(".up.sql"):
      debug("Found migration to revert: ", file)
      downFileName = file[0..^8] & ".down.sql"
      downFilePath = d.migrationPath / downFileName
      if fileExists(downFilePath):
        debug("Running down migration: ", downFilePath)
        fileContent = readFile(downFilePath)
        if d.runDownMigration(fileContent, file, result.batchNumber):
          inc result.numRan

method revertAllMigrations*(d: PostgreSqlDriver): MigrationResult =
  ## Wind back all of the ran migrations.
  result = (numRan: 0, batchNumber: 0)

  debug("Calculating down migrations to run")

  var downFileName: string
  var downFilePath: string
  var fileContent: TaintedString
  for file, batchNumber in d.getRanMigrations():
    if file.endsWith(".up.sql"):
      debug("Found migration to revert: ", file)
      downFileName = file[0..^8] & ".down.sql"
      downFilePath = d.migrationPath / downFileName
      if fileExists(downFilePath):
        debug("Running down migration: ", downFilePath)
        fileContent = readFile(downFilePath)
        if d.runDownMigration(fileContent, file, batchNumber):
          inc result.numRan

method getAllTablesForDatabase*(d: PostgreSqlDriver, database: string): (iterator: string) =
  ## Get the names of all of the tables within the given database.
  return iterator: string =
    for row in d.handle.rows(getTablesForDatabaseCommand, database):
      if row[0] != "migrations":
        yield row[0]

method getCreateForTable*(d: PostgreSqlDriver, table: string): string =
  ## Get the create syntax for the given table.
  let row = d.handle.getRow(SqlQuery(getCreateForTableCommand & table & "`"), table)
  result = row[1].replace(autoIncrementRegex, "")

method getDropForTable*(d: PostgreSqlDriver, table: string): string =
  ## Get the drop syntax for the given table.
  result = "DROP TABLE IF EXISTS `" & table & "`;"
