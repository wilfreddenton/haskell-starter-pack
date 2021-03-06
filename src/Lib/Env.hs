{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Lib.Env where

import Control.Lens (makeClassy)
import Crypto.Gpgme (Ctx, Protocol (OpenPGP), newCtx)
import Data.Aeson.Extended
  ( (.=),
    ToJSON,
    encode,
    genericToJSON,
    object,
    snakeNoPrefix,
    toJSON,
  )
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Text.Lazy.Builder (fromText, toLazyText)
import Data.Text.Lazy.Encoding (decodeUtf8)
import Database.SQLite.Simple
  ( Connection,
    Query (Query),
    execute_,
    open,
  )
import Katip
  ( ColorStrategy (ColorIfTerminal),
    Item (..),
    ItemFormatter,
    LogContexts,
    LogEnv,
    LogItem,
    Namespace,
    Severity (DebugS),
    Verbosity (V3),
    defaultScribeSettings,
    initLogEnv,
    mkHandleScribeWithFormatter,
    permitItem,
    registerScribe,
    renderSeverity,
    toObject,
    unLogStr,
  )
import Katip.Format.Time (formatAsLogTime)
import Lucid.Extended (ToHtml, pre_, toHtml, toHtmlRaw)
import Protolude hiding (decodeUtf8)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (exitFailure)

data ServerEnv
  = ServerEnv
      { _sPort :: Int,
        _sSqliteDatabase :: FilePath,
        _sInitSql :: FilePath,
        _sGnuPgHomedir :: FilePath,
        _sPgpPublicKey :: FilePath
      }
  deriving (Generic)

makeClassy ''ServerEnv

instance ToJSON ServerEnv where
  toJSON = genericToJSON snakeNoPrefix

data LoggerEnv
  = LoggerEnv
      { _lLogEnv :: LogEnv,
        _lContext :: LogContexts,
        _lNamespace :: Namespace
      }

makeClassy ''LoggerEnv

data DbEnv
  = DbEnv
      { _dConn :: Connection
      }

makeClassy ''DbEnv

newtype PgpKey = PgpKey {pkPgpKey :: Text} deriving (Generic)

instance ToJSON PgpKey where
  toJSON = genericToJSON snakeNoPrefix

instance ToHtml PgpKey where

  toHtmlRaw = toHtml

  toHtml PgpKey {..} = pre_ $ toHtml pkPgpKey

data AuthEnv
  = AuthEnv
      { _aCtx :: Ctx,
        _aPgpKey :: PgpKey
      }

makeClassy ''AuthEnv

customJsonFormatter :: LogItem a => ItemFormatter a
customJsonFormatter _color _verb Item {..} = fromText . toStrict . decodeUtf8 $ encode value
  where
    value =
      object
        [ "at" .= formatAsLogTime _itemTime,
          "sev" .= renderSeverity _itemSeverity,
          "data" .= toObject _itemPayload,
          "msg" .= toLazyText (unLogStr _itemMessage),
          "ns" .= _itemNamespace
        ]

validateFilePath :: MonadIO m => FilePath -> (FilePath -> IO Bool) -> (FilePath -> IO a) -> m ()
validateFilePath path validate failure =
  liftIO $ bool (failure path >> exitFailure) (pure ()) =<< validate path

newAuthEnv :: MonadIO m => FilePath -> FilePath -> m AuthEnv
newAuthEnv homedir pgpKeyFile = do
  validateFilePath homedir doesDirectoryExist (failure "GnuPG homedir")
  validateFilePath pgpKeyFile doesFileExist (failure "PGP public key file")
  ctx <- liftIO $ newCtx homedir "C" OpenPGP
  pgpKey <- liftIO $ T.readFile pgpKeyFile
  pure . AuthEnv ctx $ PgpKey pgpKey
  where
    failure resource path = putStrLn $ "no " <> resource <> " found at filepath: " <> path

newDbEnv :: MonadIO m => FilePath -> FilePath -> m DbEnv
newDbEnv dbPath sqlPath = do
  validateFilePath sqlPath doesFileExist failure
  statements <- filter (/= "") . T.splitOn ";" . T.strip <$> liftIO (T.readFile sqlPath)
  dbExists <- liftIO $ doesFileExist dbPath
  conn <- liftIO $ open dbPath
  if not dbExists then liftIO (traverse_ (runStatement conn) statements) else pure ()
  pure $ DbEnv conn
  where
    runStatement conn = execute_ conn . Query
    failure = putStrLn . mappend "no SQL file found at filepath: "

newLoggerEnv :: MonadIO m => m LoggerEnv
newLoggerEnv = do
  handleScribe <- liftIO $ mkHandleScribeWithFormatter customJsonFormatter ColorIfTerminal stdout (permitItem DebugS) V3
  logEnv <- liftIO $ registerScribe "stdout" handleScribe defaultScribeSettings =<< initLogEnv "IO" "development"
  pure $ LoggerEnv logEnv mempty mempty

data AppEnv
  = AppEnv
      { _appServerEnv :: ServerEnv,
        _appLoggerEnv :: LoggerEnv,
        _appDbEnv :: DbEnv,
        _appAuthEnv :: AuthEnv
      }

makeClassy ''AppEnv

instance HasServerEnv AppEnv where
  serverEnv = appServerEnv . serverEnv

instance HasLoggerEnv AppEnv where
  loggerEnv = appLoggerEnv . loggerEnv

instance HasDbEnv AppEnv where
  dbEnv = appDbEnv . dbEnv

instance HasAuthEnv AppEnv where
  authEnv = appAuthEnv . authEnv

type CanServerEnv a m = (MonadReader a m, HasServerEnv a)

type CanDbEnv a m = (MonadReader a m, HasDbEnv a)

type CanAuthEnv a m = (MonadReader a m, HasAuthEnv a)
