{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
{-# LANGUAGE TupleSections #-}

-- | Migrations support for SQLite databases
module Database.Beam.Sqlite.Migrate
  ( migrationBackend, SqliteCommandSyntax

    -- * @beam-migrate@ utility functions
  , migrateScript, writeMigrationScript
  , sqlitePredConverter, sqliteTypeToHs
  , getDbConstraints

    -- * SQLite-specific data types
  , sqliteText, sqliteBlob, sqliteBigInt
  ) where

import qualified Database.Beam.Migrate as Db
import qualified Database.Beam.Migrate.Backend as Tool
import qualified Database.Beam.Migrate.Serialization as Db
import           Database.Beam.Migrate.Types (QualifiedName(..))
import qualified Database.Beam.Query.DataTypes as Db

import           Database.Beam.Backend.SQL
import           Database.Beam.Haskell.Syntax
import           Database.Beam.Sqlite.Connection
import           Database.Beam.Sqlite.Syntax

import           Control.Applicative
import           Control.Exception
import           Control.Monad
import           Control.Monad.Reader

import           Database.SQLite.Simple (open, close, query_, execute_, connectionHandle)
import           Database.SQLite3 (exec)

import           Data.Aeson
import           Data.Attoparsec.Text (asciiCI, skipSpace)
import qualified Data.Attoparsec.Text as A
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BL
import           Data.Char (isSpace)
import           Data.Int (Int64)
import           Data.List (sortBy)
import           Data.Maybe (mapMaybe, isJust)
import           Data.Monoid (Endo(..))
import           Data.Ord (comparing)
import           Data.String (fromString)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- | Top-level 'Tool.BeamMigrationBackend'
migrationBackend :: Tool.BeamMigrationBackend Sqlite SqliteM
migrationBackend = Tool.BeamMigrationBackend
                   { Tool.backendName = "sqlite"
                   , Tool.backendConnStringExplanation = "For beam-sqlite, this is the path to a sqlite3 file"
                   , Tool.backendGetDbConstraints = getDbConstraints
                   , Tool.backendPredicateParsers = Db.sql92Deserializers <> sqliteDataTypeDeserializers <>
                                                    Db.beamCheckDeserializers
                   , Tool.backendRenderSyntax = (BL.unpack . (<> ";") . sqliteRenderSyntaxScript . fromSqliteCommand)
                   , Tool.backendFileExtension = "sqlite.sql"
                   , Tool.backendConvertToHaskell = sqlitePredConverter
                   , Tool.backendActionProvider = Db.defaultActionProvider
                   , Tool.backendRunSqlScript = runSqlScript
                   , Tool.backendWithTransaction =
                       \(SqliteM go) ->
                         SqliteM . ReaderT $ \ctx@(pt, conn) ->
                           mask $ \unmask -> do
                             let ex q = pt (show q) >> execute_ conn q
                             ex "BEGIN TRANSACTION"
                             unmask (runReaderT go ctx <* ex "COMMIT TRANSACTION") `catch`
                               \(SomeException e) -> ex "ROLLBACK TRANSACTION" >> throwIO e
                     , Tool.backendConnect = \fp -> do
                       conn <- open fp
                       pure Tool.BeamMigrateConnection
                            { Tool.backendRun = \action ->
                                catch (Right <$> runReaderT (runSqliteM action)
                                                            (\_ -> pure (), conn))
                                      (\e -> pure (Left (show (e :: SomeException))))
                            , Tool.backendClose = close conn } }

-- | 'Db.BeamDeserializers' or SQLite specific types. Specifically,
-- 'sqliteBlob', 'sqliteText', and 'sqliteBigInt'. These are compatible with the
-- "typical" serialized versions of the standard 'Db.binaryLargeObject',
-- 'Db.characterLargeObject', and 'Db.bigint' types.
sqliteDataTypeDeserializers :: Db.BeamDeserializers Sqlite
sqliteDataTypeDeserializers =
  Db.beamDeserializer $ \_ v ->
  fmap (id @SqliteDataTypeSyntax) $
  case v of
    "blob" -> pure sqliteBlobType
    "clob" -> pure sqliteTextType
    "bigint" -> pure sqliteBigIntType
    Object o ->
       (fmap (\(_ :: Maybe Word) -> sqliteBlobType) (o .: "binary")) <|>
       (fmap (\(_ :: Maybe Word) -> sqliteBlobType) (o .: "varbinary")) <|>
       Db.beamDeserializeJSON "sqlite" customDtParser v
    _ -> fail "Could not parse sqlite-specific data type"
  where
    customDtParser = withObject "custom data type" $ \v -> do
                       txt <- v .: "custom"
                       pure (parseSqliteDataType txt)

-- | Render a series of 'Db.MigrationSteps' in the 'SqliteCommandSyntax' into a
-- line-by-line list of lazy 'BL'ByteString's. The output is suitable for
-- inclusion in a migration script. Comments are generated giving a description
-- of each migration step.
migrateScript :: Db.MigrationSteps Sqlite () a -> [BL.ByteString]
migrateScript steps =
  "-- Generated by beam-sqlite beam-migrate backend\n" :
  "\n" :
  appEndo (Db.migrateScript renderHeader renderCommand steps) []
  where
    renderHeader nm =
      Endo (("-- " <> BL.fromStrict (TE.encodeUtf8 nm) <> "\n"):)
    renderCommand cmd =
      Endo ((sqliteRenderSyntaxScript (fromSqliteCommand cmd) <> ";\n"):)

-- | Write the output of 'migrateScript' to a file
writeMigrationScript :: FilePath -> Db.MigrationSteps Sqlite () a -> IO ()
writeMigrationScript fp steps =
  let stepBs = migrateScript steps
  in BL.writeFile fp (BL.concat stepBs)

-- | 'Tool.HaskellPredicateConverter' that can convert all constraints generated
-- by 'getDbConstaints' into their equivalent in the @beam-migrate@ haskell
-- syntax. Suitable for auto-generation of a haskell migration.
sqlitePredConverter :: Tool.HaskellPredicateConverter
sqlitePredConverter = Tool.sql92HsPredicateConverters @Sqlite sqliteTypeToHs <>
                      Tool.hsPredicateConverter sqliteHasColumnConstraint
  where
    sqliteHasColumnConstraint (Db.TableColumnHasConstraint tblNm colNm c ::
                                  Db.TableColumnHasConstraint Sqlite)
      | c == Db.constraintDefinitionSyntax Nothing Db.notNullConstraintSyntax Nothing =
        Just (Db.SomeDatabasePredicate (Db.TableColumnHasConstraint tblNm colNm (Db.constraintDefinitionSyntax Nothing Db.notNullConstraintSyntax Nothing) ::
                                           Db.TableColumnHasConstraint HsMigrateBackend))
      | otherwise = Nothing

-- | Convert a SQLite data type to the corresponding Haskell one
sqliteTypeToHs :: SqliteDataTypeSyntax
               -> Maybe HsDataType
sqliteTypeToHs = Just . sqliteDataTypeToHs

customSqliteDataType :: T.Text -> SqliteDataTypeSyntax
customSqliteDataType txt =
    SqliteDataTypeSyntax (emit (TE.encodeUtf8 txt))
                         (hsErrorType ("Unknown SQLite datatype '" ++ T.unpack txt ++ "'"))
                         (Db.BeamSerializedDataType $
                            Db.beamSerializeJSON "sqlite"
                                  (object [ "custom" .= txt ]))
                         False

parseSqliteDataType :: T.Text -> SqliteDataTypeSyntax
parseSqliteDataType txt =
  case A.parseOnly dtParser txt of
    Left {} -> customSqliteDataType txt
    Right x -> x
  where
    dtParser = charP <|> varcharP <|>
               ncharP <|> nvarcharP <|>
               bitP <|> varbitP <|> numericP <|> decimalP <|>
               doubleP <|> integerP <|>
               smallIntP <|> bigIntP <|> floatP <|>
               doubleP <|> realP <|> dateP <|>
               timestampP <|> timeP <|> textP <|>
               blobP <|> booleanP

    ws = A.many1 A.space

    characterP = asciiCI "CHARACTER" <|> asciiCI "CHAR"
    characterVaryingP = characterP >> ws >> asciiCI "VARYING"
    charP = do
      characterP
      charType <$> precP <*> charSetP
    varcharP = do
      asciiCI "VARCHAR" <|> characterVaryingP
      varCharType <$> precP <*> charSetP
    ncharP = do
      asciiCI "NATIONAL"
      ws
      characterP
      nationalCharType <$> precP
    nvarcharP = do
      asciiCI "NVARCHAR" <|> (asciiCI "NATIONAL" >> ws >> characterVaryingP)
      nationalVarCharType <$> precP
    bitP = do
      asciiCI "BIT"
      bitType <$> precP
    varbitP = do
      asciiCI "VARBIT" <|> (asciiCI "BIT" >> ws >> asciiCI "VARYING")
      varBitType <$> precP

    numericP = do
      asciiCI "NUMERIC"
      numericType <$> numericPrecP
    decimalP = do
      asciiCI "DECIMAL"
      decimalType <$> numericPrecP
    floatP = do
      asciiCI "FLOAT"
      floatType <$> precP
    doubleP = do
      asciiCI "DOUBLE"
      optional $ skipSpace >> asciiCI "PRECISION"
      pure doubleType
    realP = realType <$ asciiCI "REAL"

    intTypeP =
      asciiCI "INT" <|> asciiCI "INTEGER"
    integerP = do
      intTypeP
      pure intType
    smallIntP = do
      asciiCI "INT2" <|> (asciiCI "SMALL" >> optional ws >> intTypeP)
      pure smallIntType
    bigIntP = do
      asciiCI "INT8" <|> (asciiCI "BIG" >> optional ws >> intTypeP)
      pure sqliteBigIntType
    dateP = dateType <$ asciiCI "DATE"
    timeP = do
      asciiCI "TIME"
      timeType <$> precP <*> timezoneP
    timestampP = do
      asciiCI "TIMESTAMP"
      timestampType <$> precP <*> timezoneP
    textP = sqliteTextType <$ asciiCI "TEXT"
    blobP = sqliteBlobType <$ asciiCI "BLOB"

    booleanP = booleanType <$ (asciiCI "BOOL" <|> asciiCI "BOOLEAN")

    timezoneP = (skipSpace *>
                 asciiCI "WITH" *> ws *>
                 (asciiCI "TIMEZONE" <|>
                  (asciiCI "TIME" >> ws >>
                   asciiCI "ZONE")) *>
                 pure True) <|>
                pure False

    precP = optional (skipSpace *> A.char '(' *>
                      A.decimal <* A.char ')')
    numericPrecP = optional ((,) <$> (skipSpace *> A.char '(' *>
                                      A.decimal)
                                 <*> (skipSpace *>
                                      optional (A.char ',' *> skipSpace *>
                                                 A.decimal) <*
                                      skipSpace <* A.char ')'))

    charSetP = optional (skipSpace *>
                         asciiCI "CHARACTER" *> ws *>
                         asciiCI "SET" *> ws *>
                         A.takeWhile (not . isSpace))

runSqlScript :: T.Text -> SqliteM ()
runSqlScript t =
    SqliteM . ReaderT $ \(_, conn) ->
        let hdl = connectionHandle conn
        in exec hdl t

-- TODO constraints and foreign keys

-- | Get a list of database predicates for the current database. This is beam's
-- best guess at providing a schema for the current database. Note that SQLite
-- type names are not standardized, and the so-called column "affinities" are
-- too broad to be of use. This function attemps to guess a good enough type
-- based on the exact type supplied in the @CREATE TABLE@ commands. It will
-- correctly parse any type generated by beam and most SQL compliant types, but
-- it may falter on databases created or managed by tools that do not follow
-- these standards.
getDbConstraints :: SqliteM [Db.SomeDatabasePredicate]
getDbConstraints =
  SqliteM . ReaderT $ \(_, conn) -> do
    tblNames <- query_ conn "SELECT name, sql from sqlite_master where type='table'"
    tblPreds <-
      fmap mconcat . forM tblNames $ \(tblNameStr, sql) -> do
        let tblName = QualifiedName Nothing tblNameStr
        columns <- fmap (sortBy (comparing (\(cid, _, _, _, _, _) -> cid :: Int))) $
                   query_ conn (fromString ("PRAGMA table_info('" <> T.unpack tblNameStr <> "')"))

        let columnPreds =
              foldMap
                (\(_ ::Int, nm, typStr, notNull, _, _) ->
                     let dtType = if isAutoincrement then sqliteSerialType else parseSqliteDataType typStr
                         isAutoincrement = isJust (A.maybeResult (A.parse autoincrementParser sql))

                         autoincrementParser = do
                           A.manyTill A.anyChar $ do
                             hadQuote <- optional (A.char '"')
                             A.string nm
                             maybe (pure ()) (\_ -> void $ A.char '"') hadQuote
                             A.many1 A.space
                             asciiCI "INTEGER"
                             A.many1 A.space
                             asciiCI "PRIMARY"
                             A.many1 A.space
                             asciiCI "KEY"
                             A.many1 A.space
                             asciiCI "AUTOINCREMENT"

                         notNullPred =
                           if notNull
                           then [ Db.SomeDatabasePredicate
                                    (Db.TableColumnHasConstraint tblName nm
                                       (Db.constraintDefinitionSyntax Nothing Db.notNullConstraintSyntax Nothing)
                                         :: Db.TableColumnHasConstraint Sqlite) ]
                           else []

                     in [ Db.SomeDatabasePredicate
                            (Db.TableHasColumn tblName nm dtType ::
                               Db.TableHasColumn Sqlite) ] ++
                        notNullPred
                )
                columns

            pkColumns = map fst $ sortBy (comparing snd) $
                        mapMaybe (\(_, nm, _, _, _ :: Maybe T.Text, pk) ->
                                      (nm,) <$> (pk <$ guard (pk > (0 :: Int)))) columns
            pkPred = case pkColumns of
                       [] -> []
                       _  -> [ Db.SomeDatabasePredicate (Db.TableHasPrimaryKey tblName pkColumns) ]
        pure ( [ Db.SomeDatabasePredicate (Db.TableExistsPredicate tblName) ]
             ++ pkPred ++ columnPreds )

    pure tblPreds

sqliteText :: Db.DataType Sqlite T.Text
sqliteText = Db.DataType sqliteTextType

sqliteBlob :: Db.DataType Sqlite ByteString
sqliteBlob = Db.DataType sqliteBlobType

sqliteBigInt :: Db.DataType Sqlite Int64
sqliteBigInt = Db.DataType sqliteBigIntType

