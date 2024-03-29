{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StaticPointers #-}
{-# LANGUAGE TypeApplications #-}
module Obelisk.Command where

import Control.Monad
import Control.Monad.IO.Class (liftIO)
import qualified Data.Binary as Binary
import Data.Bool (bool)
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as LBS
import Data.List
import Data.Maybe (catMaybes)
import qualified Data.Text as T
import Data.Text.Encoding
import Data.Text.Encoding.Error (lenientDecode)
import GHC.StaticPtr
import Options.Applicative
import Options.Applicative.Help.Pretty (text, (<$$>))
import System.Directory
import System.Environment
import System.FilePath
import qualified System.Info
import System.IO (hIsTerminalDevice, stdout)
import System.Posix.Process (executeFile)

import Obelisk.App
import Obelisk.CliApp
import Obelisk.CliApp.Demo (cliDemo)
import Obelisk.Command.Deploy
import Obelisk.Command.Project
import Obelisk.Command.Run
import Obelisk.Command.Thunk
import Obelisk.Command.Utils
import qualified Obelisk.Command.VmBuilder as VmBuilder


data Args = Args
  { _args_noHandOffPassed :: Bool
  -- ^ This flag is actually handled outside of the optparse-applicative parser, but we detect whether
  -- it has gotten through in order to notify the user that it should only be passed once and as the very
  -- first argument
  , _args_verbose :: Bool
  , _args_command :: ObCommand
  }
  deriving Show

newtype ArgsConfig = ArgsConfig
  { _argsConfig_enableVmBuilderByDefault :: Bool
  }

args :: ArgsConfig -> Parser Args
args cfg = Args <$> noHandoff <*> verbose <*> obCommand cfg

noHandoff :: Parser Bool
noHandoff = flag False True $ mconcat
  [ long "no-handoff"
  , help "Do not hand off execution to project-specific implementation of this command"
  , hidden
  ]

verbose :: Parser Bool
verbose = flag False True $ mconcat
  [ long "verbose"
  , short 'v'
  , help "Be more verbose"
  ]

argsInfo :: ArgsConfig -> ParserInfo Args
argsInfo cfg = info (args cfg <**> helper) $ mconcat
  [ fullDesc
  , progDesc "Manage Obelisk projects"
  ]

initSource :: Parser InitSource
initSource = foldl1 (<|>)
  [ pure InitSource_Default
  , InitSource_Branch <$> strOption (long "branch" <> metavar "BRANCH")
  , InitSource_Symlink <$> strOption (long "symlink" <> action "directory" <> metavar "PATH")
  ]

initForce :: Parser Bool
initForce = switch (long "force" <> help "Allow ob init to overwrite files")

data ObCommand
   = ObCommand_Init InitSource Bool
   | ObCommand_Deploy DeployCommand
   | ObCommand_Run
   | ObCommand_Thunk ThunkCommand
   | ObCommand_Repl
   | ObCommand_Watch
   | ObCommand_Shell ShellOpts
   | ObCommand_Doc String [String] -- shell and list of packages
   | ObCommand_Internal ObInternal
   deriving Show

data ObInternal
   = ObInternal_RunStaticIO StaticKey
   | ObInternal_CLIDemo
   deriving Show

inNixShell' :: MonadObelisk m => StaticPtr (ObeliskT IO ()) -> m ()
inNixShell' p = withProjectRoot "." $ \root -> do
  cmd <- liftIO $ unwords <$> mkCmd  -- TODO: shell escape instead of unwords
  projectShell root True "ghc" (Just cmd)
  where
    mkCmd = do
      argsCfg <- getArgsConfig
      myArgs <- getArgs
      obArgs <- parseCLIArgs argsCfg myArgs
      progName <- getObeliskExe
      return $ progName : catMaybes
        [ Just "--no-handoff"
        , bool Nothing (Just "--verbose") $ _args_verbose obArgs
        , Just "internal"
        , Just "run-static-io"
        , Just $ encodeStaticKey $ staticKey p
        ]

obCommand :: ArgsConfig -> Parser ObCommand
obCommand cfg = hsubparser
    (mconcat
      [ command "init" $ info (ObCommand_Init <$> initSource <*> initForce) $ progDesc "Initialize an Obelisk project"
      , command "deploy" $ info (ObCommand_Deploy <$> deployCommand cfg) $ progDesc "Prepare a deployment for an Obelisk project"
      , command "run" $ info (pure ObCommand_Run) $ progDesc "Run current project in development mode"
      , command "thunk" $ info (ObCommand_Thunk <$> thunkCommand) $ progDesc "Manipulate thunk directories"
      , command "repl" $ info (pure ObCommand_Repl) $ progDesc "Open an interactive interpreter"
      , command "watch" $ info (pure ObCommand_Watch) $ progDesc "Watch current project for errors and warnings"
      , command "shell" $ info (ObCommand_Shell <$> shellOpts) $ progDesc "Enter a shell with project dependencies"
      , command "doc" $ info (ObCommand_Doc <$> shellFlags <*> packageNames) $
          progDesc "List paths to haddock documentation for specified packages"
          <> footerDoc (Just $
               text "Hint: To open the documentation you can pipe the output of this command like"
               <$$> text "ob doc reflex reflex-dom-core | xargs -n1 xdg-open")
      ])
  <|> subparser
    (mconcat
      [ internal
      , command "internal" (info (ObCommand_Internal <$> internalCommand) mempty)
      ])

packageNames :: Parser [String]
packageNames = some (strArgument (metavar "PACKAGE-NAME..."))

deployCommand :: ArgsConfig -> Parser DeployCommand
deployCommand cfg = hsubparser $ mconcat
  [ command "init" $ info (DeployCommand_Init <$> deployInitOpts) $ progDesc "Initialize a deployment configuration directory"
  , command "push" $ info (DeployCommand_Push <$> remoteBuilderParser) mempty
  , command "test" $ info (DeployCommand_Test <$> platformP) $ progDesc "Test your obelisk project from a mobile platform."
  , command "update" $ info (pure DeployCommand_Update) $ progDesc "Update the deployment's src thunk to latest"
  ]
  where
    platformP = hsubparser $ mconcat
      [ command "android" $ info (pure (Android, [])) mempty
      , command "ios"     $ info ((,) <$> pure IOS <*> (fmap pure $ strArgument (metavar "TEAMID" <> help "Your Team ID - found in the Apple developer portal"))) mempty
      ]

    remoteBuilderParser :: Parser (Maybe RemoteBuilder)
    remoteBuilderParser =
      flag (if enabledByDefault then enabled else Nothing) enabled (mconcat
        [ long $ "enable-" <> flagBase
        , help $ "Enable " <> flagDesc <> (if enabledByDefault then " (default)" else "")
        ])
      <|> flag enabled Nothing (mconcat
        [ long $ "disable-" <> flagBase
        , help $ "Disable a " <> flagDesc <> (if not enabledByDefault then " (default)" else "")
        ])
      where
        enabledByDefault = _argsConfig_enableVmBuilderByDefault cfg
        enabled = Just RemoteBuilder_ObeliskVM
        flagBase = "vm-builder"
        flagDesc = "managed Linux virtual machine as a Nix remote builder (requires Docker)"


deployInitOpts :: Parser DeployInitOpts
deployInitOpts = DeployInitOpts
  <$> strArgument (action "directory" <> metavar "DEPLOYDIR" <> help "Path to a directory that it will create")
  <*> strOption (long "ssh-key" <> action "file" <> metavar "SSHKEY" <> help "Path to an ssh key that it will symlink to")
  <*> some (strOption (long "hostname" <> metavar "HOSTNAME" <> help "hostname of the deployment target"))
  <*> strOption (long "route" <> metavar "PUBLICROUTE" <> help "Publicly accessible URL of your app")
  <*> strOption (long "admin-email" <> metavar "ADMINEMAIL" <> help "Email address where administrative alerts will be sent")
  <*> flag True False (long "disable-https" <> help "Disable automatic https configuration for the backend")

type TeamID = String
data RemoteBuilder = RemoteBuilder_ObeliskVM
  deriving (Eq, Show)

data DeployCommand
  = DeployCommand_Init DeployInitOpts
  | DeployCommand_Push (Maybe RemoteBuilder)
  | DeployCommand_Test (PlatformDeployment, [String])
  | DeployCommand_Update
  deriving Show

data DeployInitOpts = DeployInitOpts
  { _deployInitOpts_outputDir :: FilePath
  , _deployInitOpts_sshKey :: FilePath
  , _deployInitOpts_hostname :: [String]
  , _deployInitOpts_route :: String
  , _deployInitOpts_adminEmail :: String
  , _deployInitOpts_enableHttps :: Bool
  }
  deriving Show

internalCommand :: Parser ObInternal
internalCommand = subparser $ mconcat
  [ command "run-static-io" $ info (ObInternal_RunStaticIO <$> argument (eitherReader decodeStaticKey) (action "static-key")) mempty
  , command "clidemo" $ info (pure ObInternal_CLIDemo) mempty
  ]

--TODO: Result should provide normalised path and also original user input for error reporting.
thunkDirectoryParser :: Parser FilePath
thunkDirectoryParser = fmap (dropTrailingPathSeparator . normalise) . strArgument $ mconcat
  [ action "directory"
  , metavar "THUNKDIR"
  , help "Path to directory containing thunk data"
  ]

data ThunkCommand
   = ThunkCommand_Update [FilePath] (Maybe String)
   | ThunkCommand_Unpack [FilePath]
   | ThunkCommand_Pack   [FilePath] Bool
  deriving Show

forceFlag :: Parser Bool
forceFlag = switch $ long "force" <> short 'f' <> help "Force packing thunks even if there are branches not pushed upstream, uncommitted changes, stashes. This will cause changes that have not been pushed upstream to be lost; use with care."

thunkCommand :: Parser ThunkCommand
thunkCommand = hsubparser $ mconcat
  [ command "update" $ info (ThunkCommand_Update <$> some thunkDirectoryParser <*> optional (strOption (long "branch" <> metavar "BRANCH"))) $ progDesc "Update thunk to latest revision available"
  , command "unpack" $ info (ThunkCommand_Unpack <$> some thunkDirectoryParser) $ progDesc "Unpack thunk into git checkout of revision it points to"
  , command "pack" $ info (ThunkCommand_Pack <$> some thunkDirectoryParser <*> forceFlag) $ progDesc "Pack git checkout into thunk that points at the current branch's upstream"
  ]

data ShellOpts
  = ShellOpts
    { _shellOpts_shell :: String
    , _shellOpts_command :: Maybe String
    }
  deriving Show

shellFlags :: Parser String
shellFlags =
  flag' "ghc" (long "ghc" <> help "Enter a shell environment having ghc (default)")
  <|> flag "ghc" "ghcjs" (long "ghcjs" <> help "Enter a shell having ghcjs rather than ghc")
  <|> strOption (short 'A' <> long "argument" <> metavar "NIXARG" <> help "Use the environment specified by the given nix argument of `shells'")

shellOpts :: Parser ShellOpts
shellOpts = ShellOpts
  <$> shellFlags
  <*> optional (strArgument (metavar "COMMAND"))

parserPrefs :: ParserPrefs
parserPrefs = defaultPrefs
  { prefShowHelpOnEmpty = True
  }

parseCLIArgs :: ArgsConfig -> [String] -> IO Args
parseCLIArgs cfg as = pure as >>= handleParseResult . execParserPure parserPrefs (argsInfo cfg)

-- | Create an Obelisk config for the current process.
mkObeliskConfig :: IO Obelisk
mkObeliskConfig = do
  cliArgs <- getArgs
  -- This function should not use argument parser (full argument parsing happens post handoff)
  let logLevel = toLogLevel $ "-v" `elem` cliArgs
  notInteractive <- not <$> isInteractiveTerm
  cliConf <- newCliConfig logLevel notInteractive notInteractive $ \case
    ObeliskError_ProcessError (ProcessFailure p code) ann ->
      ( "Process exited with code " <> T.pack (show code) <> "; " <> reconstructCommand p
        <> maybe "" ("\n" <>) ann
      , 2
      )
    ObeliskError_Unstructured msg -> (msg, 2)

  return $ Obelisk cliConf
  where
    toLogLevel = bool Notice Debug
    isInteractiveTerm = do
      isTerm <- hIsTerminalDevice stdout
      -- Running in bash/fish/zsh completion
      inShellCompletion <- liftIO $ isInfixOf "completion" . unwords <$> getArgs

      -- Respect the user’s TERM environment variable. Dumb terminals
      -- like Eshell cannot handle lots of control sequences that the
      -- spinner uses.
      termEnv <- lookupEnv "TERM"
      let isDumb = termEnv == Just "dumb"

      return $ isTerm && not inShellCompletion && not isDumb

-- | For use from development obelisk repls
--
-- Example:
-- > runCommand $ someFuncInMonadObelisk ...
runCommand :: ObeliskT IO a -> IO a
runCommand f = flip runObelisk f =<< mkObeliskConfig

main :: IO ()
main = runCommand . main' =<< getArgsConfig

main' :: MonadObelisk m => ArgsConfig -> m ()
main' argsCfg = do
  obPath <- liftIO getExecutablePath
  myArgs <- liftIO getArgs
  logLevel <- getLogLevel
  putLog Debug $ T.pack $ unwords
    [ "Starting Obelisk <" <> obPath <> ">"
    , "args=" <> show myArgs
    , "logging-level=" <> show logLevel
    ]

  --TODO: We'd like to actually use the parser to determine whether to hand off,
  --but in the case where this implementation of 'ob' doesn't support all
  --arguments being passed along, this could fail.  For now, we don't bother
  --with optparse-applicative until we've done the handoff.
  let go as = do
        args' <- liftIO $ handleParseResult (execParserPure parserPrefs (argsInfo argsCfg) as)
        case _args_noHandOffPassed args' of
          False -> return ()
          True -> putLog Warning "--no-handoff should only be passed once and as the first argument; ignoring"
        ob $ _args_command args'
      handoffAndGo as = findProjectObeliskCommand "." >>= \case
        Nothing -> go as -- If not in a project, just run ourselves
        Just impl -> do
          -- Invoke the real implementation, using --no-handoff to prevent infinite recursion
          putLog Debug $ "Handing off to " <> T.pack impl
          liftIO $ executeFile impl False ("--no-handoff" : myArgs) Nothing
  case myArgs of
    "--no-handoff" : as -> go as -- If we've been told not to hand off, don't hand off
    a:as -- Otherwise bash completion would always hand-off even if the user isn't trying to
      | "--bash-completion" `isPrefixOf` a
      && "--no-handoff" `elem` as -> go (a:as)
      | otherwise -> handoffAndGo (a:as)
    as -> handoffAndGo as

ob :: MonadObelisk m => ObCommand -> m ()
ob = \case
  ObCommand_Init source force -> initProject source force
  ObCommand_Deploy dc -> case dc of
    DeployCommand_Init deployOpts -> withProjectRoot "." $ \root -> do
      let deployDir = _deployInitOpts_outputDir deployOpts
      r <- liftIO $ canonicalizePath root
      rootEqualsTarget <- liftIO $ equalFilePath r <$> canonicalizePath deployDir
      when rootEqualsTarget $
        failWith $ "Deploy directory " <> T.pack deployDir <> " should not be the same as project root."
      thunkPtr <- readThunk root >>= \case
        Left err -> failWith $ case err of
          ReadThunkError_AmbiguousFiles ->
            "Project root " <> T.pack r <> " is not a git repository or valid thunk"
          ReadThunkError_UnrecognizedFiles ->
            "Project root " <> T.pack r <> " is not a git repository or valid thunk"
          _ -> "thunk read: " <> T.pack (show err)
        Right (ThunkData_Packed ptr) -> return ptr
        Right (ThunkData_Checkout (Just ptr)) -> return ptr
        Right (ThunkData_Checkout Nothing) ->
          getThunkPtr False root
      let sshKeyPath = _deployInitOpts_sshKey deployOpts
          hostname = _deployInitOpts_hostname deployOpts
          route = _deployInitOpts_route deployOpts
          adminEmail = _deployInitOpts_adminEmail deployOpts
          enableHttps = _deployInitOpts_enableHttps deployOpts
      deployInit thunkPtr deployDir sshKeyPath hostname route adminEmail enableHttps
    DeployCommand_Push remoteBuilder -> do
      deployPath <- liftIO $ canonicalizePath "."
      deployPush deployPath $ case remoteBuilder of
        Nothing -> pure []
        Just RemoteBuilder_ObeliskVM -> (:[]) <$> VmBuilder.getNixBuildersArg
    DeployCommand_Update -> deployUpdate "."
    DeployCommand_Test (platform, extraArgs) -> deployMobile platform extraArgs
  ObCommand_Run -> inNixShell' $ static run
    -- inNixShell ($(mkClosure 'ghcidAction) ())
  ObCommand_Thunk tc -> case tc of
    ThunkCommand_Update thunks mBranch -> mapM_ ((flip updateThunkToLatest) mBranch) thunks
    ThunkCommand_Unpack thunks -> mapM_ unpackThunk thunks
    ThunkCommand_Pack thunks force -> forM_ thunks (packThunk force)
  ObCommand_Repl -> runRepl
  ObCommand_Watch -> inNixShell' $ static runWatch
  ObCommand_Shell so -> withProjectRoot "." $ \root ->
    projectShell root False (_shellOpts_shell so) (_shellOpts_command so)
  ObCommand_Doc shell pkgs -> withProjectRoot "." $ \root ->
    projectShell root False shell (Just $ haddockCommand pkgs)
  ObCommand_Internal icmd -> case icmd of
    ObInternal_RunStaticIO k -> liftIO (unsafeLookupStaticPtr @(ObeliskT IO ()) k) >>= \case
      Nothing -> failWith $ "ObInternal_RunStaticIO: no such StaticKey: " <> T.pack (show k)
      Just p -> do
        c <- getObelisk
        liftIO $ runObelisk c $ deRefStaticPtr p
    ObInternal_CLIDemo -> cliDemo

haddockCommand :: [String] -> String
haddockCommand pkgs = unwords
  [ "for p in"
  , unwords [getHaddockPath p ++ "/index.html" | p <- pkgs]
  , "; do echo $p; done"
  ]
  where getHaddockPath p = "$(ghc-pkg field " ++ p ++ " haddock-html --simple-output)"

--TODO: Clean up all the magic strings throughout this codebase

getArgsConfig :: IO ArgsConfig
getArgsConfig = pure $ ArgsConfig { _argsConfig_enableVmBuilderByDefault = System.Info.os == "darwin" }

encodeStaticKey :: StaticKey -> String
encodeStaticKey = T.unpack . decodeUtf8With lenientDecode . Base16.encode . LBS.toStrict . Binary.encode

-- TODO: Use failWith in place of fail to be consistent.
decodeStaticKey :: String -> Either String StaticKey
decodeStaticKey s = case Base16.decode $ encodeUtf8 $ T.pack s of
  (b, "") -> case Binary.decodeOrFail $ LBS.fromStrict b of
    Right ("", _, a) -> pure a
    Right _ -> fail "decodeStaticKey: Binary.decodeOrFail didn't consume all input"
    Left (_, _, e) -> fail $ "decodeStaticKey: Binary.decodeOrFail failed: " <> show e
  _ -> fail $ "decodeStaticKey: could not decode hex string: " <> show s
