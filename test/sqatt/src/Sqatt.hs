{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
-- | Integration test utilities.
module Sqatt
  ( TxsExample(..)
  , checkSMTSolvers
  , checkCompilers
  , testExamples
  , checkTxsInstall
  , ExampleResult (..)
  , javaCmd
  , testExampleSet
  , testExampleSets
  , TxsExampleSet (..)
  , SutExample (..)
  )
where

import           Control.Applicative
import           Control.Concurrent.Async
import           Control.Exception
import           Control.Foldl
import           Control.Monad.Except
import           Data.Either
import           Data.Foldable
import           Data.Maybe
import           Data.Monoid
import qualified Data.Text                 as T
import qualified Data.Text.IO              as TIO
import           Filesystem.Path
import           Filesystem.Path.CurrentOS
import           Prelude                   hiding (FilePath)
import           System.Info
import           System.Random
import           Test.Hspec
import           Turtle

-- * Data structures for specifying examples

-- | A description of a TorXakis example.
data TxsExample
  = TxsExample {
    -- | Name of the example.
    exampleName     :: String
    -- | Path to the TorXakis model file.
  , txsModelFile    :: FilePath
    -- | Path to the file containing the commands that will be passed to the
    --   TorXakis server.
  , txsCommandsFile :: FilePath
    -- | SUT example. This run together with TorXakis. If this field is
    --   `Nothing` then the example is assumed to be autonomous (only TorXakis
    --   will be run)
  , sutExample      :: Maybe SutExample
    -- | Example's expected result.
  , expectedResult  :: ExampleResult
  } deriving (Show)

data SutExample
  -- | A Java SUT that must be compiled and executed.
  = JavaExample {
    -- | Source file of the SUT.
    javaSourcePath :: FilePath
    -- | Arguments to be passed to the SUT.
  , javaSutArgs    :: [Text]
  }
  -- | A TorXakis simulated SUT.
  | TxsSimulator FilePath
  deriving (Show)

-- | A set of examples.
data TxsExampleSet
  = TxsExampleSet {
    -- | Description of the example set.
    exampleSetdesc :: ExampleSetDesc
    -- | Examples in the set.
  , txsExamples    :: [TxsExample]
  }

-- | Description of the example set.
newtype ExampleSetDesc
  = ExampleSetDesc {
    -- | Name of the example set.
    exampleSetName :: String
  }

instance IsString ExampleSetDesc where
  fromString = ExampleSetDesc

-- | Information about a compiled Java program.
data CompiledSut
  -- | `JavaCompiledSut mainClass mClassSP`:
  --
  --   - `mainClass`: name of the main Java class.
  --
  --   - `mClassSP`: Class search path. If omitted no `-cp` option will be
  --     passed to the `java` command.
  --
  = JavaCompiledSut Text (Maybe FilePath)
  -- | An SUT simulated by TorXakis.
  --
  --  `TxsSimulatedSut cmds`:
  --
  --   - `cmds`: Commands to be passed to the simulator.
  | TxsSimulatedSut FilePath

-- | A processed example, ready to be run.
--
-- Currently the only processing that takes place is the compilation of the
-- SUT, if any.
data RunnableExample = ExampleWithSut TxsExample CompiledSut [Text]
                     | StandaloneExample TxsExample

data ExampleResult = Pass | Fail deriving (Show, Eq)

-- * Path manipulation functions

addExeSuffix :: Text -> Text
addExeSuffix path = if os == "mingw32" then path <> ".exe" else path

javaCmd :: Text
javaCmd = addExeSuffix "java"

javacCmd :: Text
javacCmd = addExeSuffix "javac"

txsServerCmd :: Text
txsServerCmd = addExeSuffix "txsserver"

txsUICmd :: Text
txsUICmd = addExeSuffix "txsui"

txsUIPassMsg :: Text
txsUIPassMsg = "TXS >>  PASS"

txsUIFailMsg :: Text
txsUIFailMsg = "TXS >>  FAIL"

-- | Decode a file path into a human readable text string. The decoding is
-- dependent on the operating system. An error is thrown if the decoding is not
-- successful.
decodePath :: FilePath -> Test Text
decodePath filePath =
  case toText filePath of
    Right path ->
      return path
    Left apprPath ->
      throwError $ FilePathError $
        "Cannot decode " <> apprPath <> " properly"

-- * Environment checking

-- | Check that all the supported SMT solvers are installed.
--
-- Throws an exception on failure.
checkSMTSolvers :: IO ()
checkSMTSolvers = do
  putStrLn "WARNING: The presence of SMT solvers was not checked."
  putStrLn "         First issue #47 needs to be resolved."
  putStrLn "See: https://github.com/TorXakis/TorXakis/issues/47"


-- | Check that the given command exists in the search path of the host system.
checkCommand :: Text -> IO ()
checkCommand cmd = do
  path <- which (fromText cmd)
  case path of
    Nothing -> throwIO $ ProgramNotFound (T.pack (show cmd))
    _       -> return ()

-- | Check that all the compilers are installed.
--
-- Throws an exception on failure.
checkCompilers :: IO ()
checkCompilers = traverse_ checkCommand [javaCmd, javacCmd]

-- | Check that the TorXakis UI and server programs are installed.
checkTxsInstall :: IO ()
checkTxsInstall = traverse_ checkCommand [txsUICmd, txsServerCmd]

-- * Compilation and testing

-- | Sqatt test monad.
newtype Test a = Test { runTest :: ExceptT SqattError IO a }
  deriving (Functor, Monad, Applicative, MonadError SqattError, MonadIO)

-- | Test errors that can arise when running a TorXakis example.
data SqattError = CompileError Text
                | ProgramNotFound Text
                | UnsupportedLanguage Text
                | FilePathError Text
                | TestExpectationError Text
                | SutAborted
                | TxsServerAborted
                | TestTimedOut
  deriving (Show, Eq)

instance Exception SqattError

-- | Compile the system under test.
compileSut :: FilePath -> Test CompiledSut
compileSut sourcePath =
  case extension sourcePath of
    Just "java" ->
      compileJavaSut sourcePath
    _    -> do
      path <- decodePath sourcePath
      throwError $ UnsupportedLanguage $
        "Compiler not found for file " <> path

-- | Compile a SUT written in Java.
compileJavaSut :: FilePath -> Test CompiledSut
compileJavaSut sourcePath = do
  path <- decodePath sourcePath
  exitCode <- proc javacCmd [path] mempty
  case exitCode of
    ExitFailure code ->
      throwError $ CompileError $
        "Java compilation command failed with code: " <> (T.pack . show) code
    ExitSuccess -> do
      mClass <- decodePath $ basename sourcePath
      let sPath = directory sourcePath
      return $ JavaCompiledSut mClass (Just sPath)

-- | Add the class path option if a class-path is given.
getCPOpts :: Maybe FilePath -> Test [Text]
getCPOpts Nothing         = return []
getCPOpts (Just filePath) = (("-cp":) . pure) <$> decodePath filePath

-- | Timeout (in seconds) for running a test. For now the timeout is not
-- configurable.
sqattTimeout :: NominalDiffTime
sqattTimeout = 60.0

-- | Run TorXakis with the given example specification.
runTxsWithExample :: FilePath   -- ^ Path to the logging directory for the current example set.
                  -> TxsExample -- ^ Example to run.
                  -> Concurrently (Either SqattError ())
runTxsWithExample logDir ex = Concurrently $ do
  eInputModelF <- runExceptT $ runTest $ decodePath (txsModelFile ex)
  case eInputModelF of
    Left decodeErr -> return $ Left decodeErr
    Right inputModelF -> do
      port <- repr <$> getRandomPort
      runConcurrently $ timer
                    <|> txsServerProc logDir port
                    <|> txsUIProc logDir inputModelF port
  where
    timer = Concurrently $ do
      sleep sqattTimeout
      throwIO TestTimedOut
    txsUIProc uiLogDir imf port =
      Concurrently $ try $ do
        res <- Turtle.fold txsUIShell findExpectedMsg
        unless res (throw tErr)
      where
        txsUIShell :: Shell Line
        txsUIShell = do
          h <- appendonly $ uiLogDir </> "txsui.out.log"
          line <- either id id <$> inprocWithErr txsUICmd [port, imf] (input cmdsFile)
          liftIO $ TIO.hPutStrLn h (lineToText line)
          return line
        findExpectedMsg :: Fold Line Bool
        findExpectedMsg = Control.Foldl.any (T.isInfixOf searchStr . lineToText)
    cmdsFile = txsCommandsFile ex
    searchStr = expectedMsg . expectedResult $ ex
    tErr = TestExpectationError $
              format ("Did not get expected result "%s)
                     (repr . expectedResult $ ex)
    expectedMsg Fail = txsUIFailMsg
    expectedMsg Pass = txsUIPassMsg
    txsServerProc sLogDir port =
      runInprocNI (sLogDir </> "txsserver.out.log") txsServerCmd [port]

-- | Run a process.
runInproc :: FilePath   -- ^ Directory where the logs will be stored.
          -> Text       -- ^ Command to run.
          -> [Text]     -- ^ Command arguments.
          -> Shell Line -- ^ Lines to be input to the command.
          -> Concurrently (Either SqattError ())
runInproc logDir cmd cmdArgs procInput = Concurrently $
  try $ output logDir (either id id <$> inprocWithErr cmd cmdArgs procInput)

-- | Run a process without input. See `runInproc`.
--
runInprocNI :: FilePath
            -> Text
            -> [Text]
            -> Concurrently (Either SqattError ())
runInprocNI logDir cmd cmdArgs =
  runInproc logDir cmd cmdArgs Turtle.empty

-- | Run TorXakis as system under test.
runTxsAsSut :: FilePath   -- ^ Path to the logging directory for the current example set.
            -> TxsExample -- ^ Example to run.
            -> Concurrently (Either SqattError ())
runTxsAsSut logDir ex = Concurrently $ do
  eInputModelF <- runExceptT $ runTest $ decodePath (txsModelFile ex)
  case eInputModelF of
    Left decodeErr -> return $ Left decodeErr
    Right inputModelF -> do
      port <- repr <$> getRandomPort
      runConcurrently $
        txsServerProc port <|> txsUIProc inputModelF port
  where
    txsUIProc imf port =
      let cLogDir = logDir </> "txsui.SUT.out.log" in
      runInproc cLogDir txsUICmd [port, imf] (input cmdsFile)
    cmdsFile = txsCommandsFile ex
    txsServerProc port =
      let cLogDir = logDir </> "txsserver.SUT.out.log" in
      runInprocNI cLogDir txsServerCmd [port]

runSUT :: FilePath -> Text -> [Text] -> Concurrently (Either SqattError ())
runSUT logDir = runInprocNI (logDir </> "SUT.out.log")

mkTest :: FilePath -> RunnableExample -> Test ()
mkTest logDir (ExampleWithSut ex (JavaCompiledSut mClass cpSP) args) = do
  cpOpts <- getCPOpts cpSP
  let javaArgs = cpOpts ++ [mClass] ++ args
  res <- liftIO $
    runConcurrently $  runSUT logDir javaCmd javaArgs
                   <|> runTxsWithExample logDir ex
  case res of
    Left txsErr -> throwError txsErr
    Right ()    -> return ()
mkTest logDir (ExampleWithSut ex (TxsSimulatedSut cmds) _) = do
  let sim = ex {txsCommandsFile = cmds}
  res <- liftIO $
    runConcurrently $ runTxsWithExample logDir ex <|> runTxsAsSut logDir sim
  case res of
    Left txsErr -> throwError txsErr
    Right ()    -> return ()
mkTest logDir (StandaloneExample ex) = do
  res <- liftIO $ runConcurrently $ runTxsWithExample logDir ex
  case res of
    Left txsErr -> throwError txsErr
    Right  _    -> return ()

-- | Get a random port number.
getRandomPort :: IO Integer
getRandomPort = randomRIO (10000, 60000)

-- | Execute a test.
execTest :: FilePath -> TxsExample -> IO (Either SqattError ())
execTest topLogDir ex = runExceptT $ runTest $ do
  let logDir = topLogDir </> (fromString . exampleName) ex
  mktree logDir
  runnableExample <- getRunnableExample
  mkTest logDir runnableExample
  where
    getRunnableExample =
      case sutExample ex of
        Nothing ->
          return (StandaloneExample ex)
        Just (JavaExample sourcePath args) -> do
          cmpSut <- compileSut sourcePath
          return (ExampleWithSut ex cmpSut args)
        Just (TxsSimulator cmds) ->
          return (ExampleWithSut ex (TxsSimulatedSut cmds) [])

-- | Test a single example.
testExample :: FilePath -> TxsExample -> Spec
testExample logDir ex = it (exampleName ex) $ do
  res <- execTest logDir ex
  res `shouldBe` Right ()

-- | Test a list of examples.
testExamples :: FilePath -> [TxsExample] -> Spec
testExamples logDir = traverse_ (testExample logDir)

-- | Test an example set.
testExampleSet :: FilePath -> TxsExampleSet -> Spec
testExampleSet logDir (TxsExampleSet exSetDesc exs) = do
  let thisSetLogDir = logDir </> fromString (exampleSetName exSetDesc)
  runIO $ mktree thisSetLogDir
  describe (exampleSetName exSetDesc) (testExamples thisSetLogDir exs)

-- | Test a list of example sets.
testExampleSets :: FilePath -> [TxsExampleSet] -> Spec
testExampleSets logDir = traverse_ (testExampleSet logDir)