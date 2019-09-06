{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Applicative    ((<|>))
import Control.Monad          (forM, unless, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson             (FromJSON, (.:))
import Data.Aeson.Types       (parseMaybe)
import Data.Bifunctor         (first)
import Data.HashMap.Strict    (HashMap, lookupDefault, mapMaybe)
import Data.List              (nubBy)
import Data.Monoid            ((<>))
import Data.Text              (Text, pack)
import Data.Char              (isDigit)
import Network.Connection     (TLSSettings(..))
import Network.HTTP.Client    (defaultManagerSettings)
import Network.HTTP.Conduit   (Manager, newManager, mkManagerSettings)
import Network.HTTP.Simple    (HttpException(..), Request, Response,
                               defaultRequest, setRequestHeader, setRequestPort,
                               setRequestPath, setRequestHost, setRequestManager,
                               setRequestSecure, httpLBS, getResponseBody,
                               getResponseStatusCode)
import System.Environment     (getEnvironment)
import System.Posix.Process   (executeFile)
import Control.Monad.Except   (ExceptT (..), MonadError, runExceptT, mapExceptT, throwError, liftEither, withExceptT)

import qualified Control.Concurrent.Async   as Async
import qualified Control.Retry              as Retry
import qualified Data.Aeson                 as Aeson
import qualified Data.ByteString.Char8      as SBS
import qualified Data.ByteString.Lazy       as LBS hiding (unpack)
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Foldable              as Foldable
import qualified Data.Map                   as Map
import qualified System.Exit                as Exit

import Config (Options(..), parseOptionsFromEnvAndCli, unMilliSeconds,
               LogLevel(..), readConfigFromEnvFiles, 
               Specified(..), fromSpecifiedValue, isDefault, isSpecified, getOptionsValue)
import SecretsFile (Secret(..), SFError(..), readSecretList)

-- | Make a HTTP URL path from a secret. This is the path that Vault expects.
secretRequestPath :: MountInfo -> Secret -> String
secretRequestPath (MountInfo mountInfo) secret = "/v1/" <> sMount secret <> foo <> sPath secret
  where
    foo = case lookupDefault KV1 (pack $ sMount secret <> "/") mountInfo of
      KV1 -> "/"
      KV2 -> "/data/"

type EnvVar = (String, String)

data MountInfo = MountInfo (HashMap Text EngineType)
  deriving (Show)

data Context
  = Context
  { cLocalEnvVars :: [EnvVar]
  , cCliOptions :: Options
  , cHttpManager :: Manager
  }

-- | The different types of Engine that Vautlenv supports
data EngineType = KV1 | KV2
  deriving (Show)

data VaultData = VaultData (Map.Map String String)

-- Vault has two versions of the Key/Value backend. We try to parse both
-- response formats here and return the one which we can parse correctly.
--
-- This means there is some inference going on by vaultenv, but since
-- we can find out which format we're parsing unambiguously, we just go
-- with the inference instead of making the user specify this. The benefit
-- here is that users can upgrade the version of the KV secret engine
-- without having to change their config files.
--
-- KV version 1 looks like this:
--
-- @
-- {
--   "auth": null,
--   "data": {
--     "foo": "bar"
--   },
--   "lease_duration": 2764800,
--   "lease_id": "",
--   "renewable": false
-- }
-- @
--
-- And version 2 looks like this:
--
-- @
-- {
--   "data": {
--     "data": {
--       "foo": "bar"
--     },
--     "metadata": {
--       "created_time": "2018-03-22T02:24:06.945319214Z",
--       "deletion_time": "",
--       "destroyed": false,
--       "version": 1
--     }
--   },
-- }
-- @
instance FromJSON VaultData where
  parseJSON =
    let
      parseV1 obj = do
        keyValuePairs <- obj .: "data"
        VaultData <$> Aeson.parseJSON keyValuePairs
      parseV2 obj = do
        nested <- obj .: "data"
        flip (Aeson.withObject "nested") nested $ \obj' -> do
          keyValuePairs <- obj' .: "data"
          VaultData <$> Aeson.parseJSON keyValuePairs
    in Aeson.withObject "object" $ \obj -> parseV1 obj <|> parseV2 obj

-- Parses a very mixed type of response that Vault gives back when you
-- request /sys/mounts. It has a garbage format. We primarily care about
-- this information:
--
-- {
--   "secret/": {
--     "options": {
--       "version": "1"
--     },
--     "type": "kv"
--   },
-- }
--
-- But there is a whole load of other stuff in the top level object.
-- Integers, dates, strings, null values. Get the stuff we need
-- and get out.
instance FromJSON MountInfo where
  parseJSON =
    let
      getType = Aeson.withObject "MountSpec" $ \o -> do
        o .: "type" >>= (Aeson.withText "mount type" $ (\case
          "kv" -> do
            options <- o .: "options"
            Aeson.withObject "Options" (\opts -> do
              version <- opts .: "version"
              case version of
                Aeson.String "1" -> pure KV1
                Aeson.String "2" -> pure KV2
                _ -> fail "unknown version number") options
          _ -> fail "expected a KV type"))
    in
      Aeson.withObject "MountResp" $ \obj -> do
        pure $ MountInfo (mapMaybe (\v -> parseMaybe getType v) obj)

-- | Error modes of this program.
--
-- Every part of the program that can fail has an error type. These can bubble
-- up the call stack and end up as a value of this type. We then have a single
-- function which is responsible for printing an error message and exiting.
data VaultError
  = SecretNotFound        String
  | SecretFileError       SFError
  | KeyNotFound           Secret
  | BadRequest            LBS.ByteString
  | Forbidden
  | BadJSONResp           String
  | ServerError           LBS.ByteString
  | ServerUnavailable     LBS.ByteString
  | ServerUnreachable     HttpException
  | InvalidUrl            String
  | DuplicateVar          String
  | Unspecified           Int LBS.ByteString
  | AddrInvalidFormat     String
  | AddrPortHostMismatch  String Int String -- Host Port Addr

-- | Retry configuration to use for network requests to Vault.
-- We use a limited exponential backoff with the policy
-- fullJitterBackoff that comes with the Retry package.
vaultRetryPolicy :: (MonadIO m) => Options -> Retry.RetryPolicyM m
vaultRetryPolicy opts = Retry.fullJitterBackoff (unMilliSeconds (getOptionsValue "retry base delay" $ oRetryBaseDelay opts) * 1000)
                     <> Retry.limitRetries (getOptionsValue "Retry attempts" $ oRetryAttempts opts)

--
-- IO
--

main :: IO ()
main = do
  localEnvVars <- getEnvironment
  envFileSettings <- readConfigFromEnvFiles

  cliAndEnvAndEnvFileOptions <- parseOptionsFromEnvAndCli localEnvVars envFileSettings

  let envAndEnvFileConfig = nubBy (\(x, _) (y, _) -> x == y) (localEnvVars ++ concat (reverse envFileSettings))

  if True || getOptionsValue "Log level" (oLogLevel cliAndEnvAndEnvFileOptions) <= Info
    then print cliAndEnvAndEnvFileOptions
    else pure ()
  print cliAndEnvAndEnvFileOptions
  httpManager <- getHttpManager cliAndEnvAndEnvFileOptions

  let context = Context { cLocalEnvVars = envAndEnvFileConfig
                        , cCliOptions = cliAndEnvAndEnvFileOptions
                        , cHttpManager = httpManager
                        }

  runExceptT (vaultEnv context) >>= \case
    Left err -> Exit.die (vaultErrorLogMessage err)
    Right newEnv -> runCommand cliAndEnvAndEnvFileOptions newEnv

{-
--  | Verifies the options that the host and the port should match the address
--  If no address is specified, the options are not checked anymore (as there can be no difference)
--  If an address is specfified, that address is split on the last semicolon, after which the address port is 
--  verified to be an integer. If the address port is an integer, and the address host is compared to the host
--  if that is specified and the address port is compared to the port if that is specified.
verifyHostPortAddr :: Options -> IO Options
verifyHostPortAddr options 
    | isDefault (oVaultAddr options) = return options
    | otherwise = let
        -- | Split the string on the last colon
        splitOnLastColon :: String -> (String, String)
        splitOnLastColon = splitOnLastColonHelper "" ""
        -- | Helper that splits on the last colon, oneButLast contains everything before the last colon
        -- lastAfter contains everything after the last colon
        splitOnLastColonHelper :: String -> String -> String -> (String, String)
        splitOnLastColonHelper oneButLast lastAfter [] = (drop 1 (reverse oneButLast), reverse lastAfter)
        splitOnLastColonHelper oneButLast lastAfter (c:cs) 
            | c == ':' = splitOnLastColonHelper (lastAfter ++ ":" ++ oneButLast) "" cs
            | otherwise = splitOnLastColonHelper oneButLast (c : lastAfter) cs
        -- | Throws an vault error to the IO
        throwVerifyError :: VaultError -> IO ()
        throwVerifyError msg = Exit.die (vaultErrorLogMessage msg)
      in do 
        let 
          addrStr = fromSpecifiedValue (oVaultAddr options)
          (addrHost, addrStrPort) = splitOnLastColon addrStr
        unless (all isDigit addrStrPort && not (null addrStrPort)) (throwVerifyError $ AddrInvalidFormat addrStr)
        let host = fromSpecifiedValue (oVaultHost options)
            port = fromSpecifiedValue (oVaultPort options)
            addrPort = read addrStrPort
        when 
          (
            (isSpecified (oVaultHost options) && addrHost /= host) 
            || 
            (isSpecified (oVaultPort options) && addrPort /= port)
          )
          (throwVerifyError $ AddrPortHostMismatch host port addrStr)
        return options{
            oVaultHost = Specified addrHost,
            oVaultPort = Specified addrPort
          }
  
-}

-- | This function returns either a manager for plain HTTP or
-- for HTTPS connections. If TLS is wanted, we also check if the
-- user specified an option to disable the certificate check.
getHttpManager :: Options -> IO Manager
getHttpManager opts = newManager managerSettings
  where
    managerSettings = if getOptionsValue "Connect TLS" $ oConnectTls opts
                      then mkManagerSettings tlsSettings Nothing
                      else defaultManagerSettings
    tlsSettings = TLSSettingsSimple
                { settingDisableCertificateValidation = not $ getOptionsValue "Validate Certs" $ oValidateCerts opts
                , settingDisableSession = False
                , settingUseServerName = True
                }

-- | Main logic of our application. Reads a list of secrets, fetches
-- each of them from Vault, checks for duplicates, and then yields
-- the list of environment variables to make available to the process
-- we want to run eventually. It either scrubs the environment that
-- already existed or keeps it.
--
-- Signals failure through a value of type VaultError, but can also
-- throw HTTP exceptions.
vaultEnv :: Context -> ExceptT VaultError IO [EnvVar]
vaultEnv context = do
  mountInfo <- requestMountInfo context
  secrets <- mapExceptT (fmap $ first SecretFileError) $ readSecretList secretFile
  secretEnv <- requestSecrets context mountInfo secrets
  checkNoDuplicates (buildEnv secretEnv)
    where
      secretFile = getOptionsValue "Secret file" $ oSecretFile (cCliOptions context)
      checkNoDuplicates :: MonadError VaultError m => [EnvVar] -> m [EnvVar]
      checkNoDuplicates e =
        either (throwError . DuplicateVar) (return . const e) $ dups (map fst e)

      -- We need to check duplicates in the environment and fail if
      -- there are any. `dups` runs in O(n^2),
      -- but this shouldn't matter for our small lists.
      --
      -- Equality is determined on the first element of the env var
      -- tuples.
      dups :: Eq a => [a] -> Either a ()
      dups [] = Right ()
      dups (x:xs) | isDup x xs = Left x
                  | otherwise = dups xs

      isDup x = foldr (\y acc -> acc || x == y) False

      buildEnv :: [EnvVar] -> [EnvVar]
      buildEnv secretsEnv =
        if (getOptionsValue "CliOptions" . oInheritEnv . cCliOptions $ context)
        then secretsEnv ++ (cLocalEnvVars context)
        else secretsEnv


runCommand :: Options -> [EnvVar] -> IO a
runCommand options env =
  let
    command = getOptionsValue "CMD" $ oCmd options
    searchPath = getOptionsValue "Use path" $ oUsePath options
    args = getOptionsValue "Args" $ oArgs options
    env' = Just env
  in
    -- `executeFile` calls one of the syscalls in the execv* family, which
    -- replaces the current process with `command`. It does not return.
    executeFile command searchPath args env'

-- | Look up what mounts are available and what type they have.
requestMountInfo :: Context -> ExceptT VaultError IO MountInfo
requestMountInfo context =
  let
    cliOptions = cCliOptions context
    request = setRequestManager (cHttpManager context)
            $ setRequestHeader "x-vault-token" [SBS.pack (getOptionsValue "Vault token" $ oVaultToken cliOptions)]
            $ setRequestPath (SBS.pack "/v1/sys/mounts")
            $ setRequestPort (getOptionsValue "Vault port" $ oVaultPort cliOptions)
            $ setRequestHost (SBS.pack (getOptionsValue "Vault host" $ oVaultHost cliOptions))
            $ setRequestSecure (getOptionsValue "Connect TLS" $ oConnectTls cliOptions)
            $ defaultRequest
  in do
    resp <- withExceptT ServerUnreachable (httpLBS request)
    withExceptT BadJSONResp (liftEither $ Aeson.eitherDecode' (getResponseBody resp))

-- | Request all the data associated with a secret from the vault.
requestSecret :: Context -> String -> ExceptT VaultError IO VaultData
requestSecret context secretPath =
  let
    cliOptions = cCliOptions context
    request = setRequestManager (cHttpManager context)
            $ setRequestHeader "x-vault-token" [SBS.pack (getOptionsValue "Vault token" $ oVaultToken cliOptions)]
            $ setRequestPath (SBS.pack secretPath)
            $ setRequestPort (getOptionsValue "Port" $ oVaultPort cliOptions)
            $ setRequestHost (SBS.pack (getOptionsValue "Host" $ oVaultHost cliOptions))
            $ setRequestSecure (getOptionsValue "Connect TLs" $ oConnectTls cliOptions)
            $ defaultRequest

    -- Only retry on connection related failures
    shouldRetry :: Applicative f => Retry.RetryStatus -> VaultError -> f Bool
    --shouldRetry _retryStatus _ =I--
    shouldRetry _retryStatus res = pure $ case res of
      ServerError _ -> True
      ServerUnavailable _ -> True
      ServerUnreachable _ -> True
      Unspecified _ _ -> True
      BadJSONResp _ -> True

      -- Errors where we don't retry
      BadRequest _ -> False
      Forbidden -> False
      InvalidUrl _ -> False
      SecretNotFound _ -> False
      

      -- Errors that cannot occur at this point, but we list for
      -- exhaustiveness checking.
      KeyNotFound _ -> False
      DuplicateVar _ -> False
      SecretFileError _ -> False
      AddrPortHostMismatch{} -> False
      AddrInvalidFormat _ -> False

    retryAction :: Retry.RetryStatus -> ExceptT VaultError IO VaultData
    retryAction _retryStatus = doRequest secretPath request
  in
    retryingExceptT (vaultRetryPolicy cliOptions) shouldRetry retryAction

-- |
-- Like 'Retry.retrying', but using 'ExceptT' instead of return values. The
-- predicate also only gets the error, not the return value.
retryingExceptT
  :: MonadIO m
  => Retry.RetryPolicyM m
  -> (Retry.RetryStatus -> e -> m Bool)
  -> (Retry.RetryStatus -> ExceptT e m a)
  -> ExceptT e m a
retryingExceptT policy predicate action =
  ExceptT $ Retry.retrying policy predicate' action'
  where
    predicate' _ (Right _) = pure False
    predicate' s (Left e)  = predicate s e
    action' = runExceptT . action

-- | Request all the supplied secrets from the vault, but just once, even if
-- multiple keys are specified for a single secret. This is an optimization in
-- order to avoid unnecessary round trips and DNS requets.
requestSecrets :: Context -> MountInfo -> [Secret] -> ExceptT VaultError IO [EnvVar]
requestSecrets context mountInfo secrets = do
  let secretPaths = Foldable.foldMap (\x -> Map.singleton x x) $ fmap (secretRequestPath mountInfo) secrets
  secretData <- liftIO (Async.mapConcurrently (runExceptT . (requestSecret context)) secretPaths)
  either throwError return $ sequence secretData >>= lookupSecrets mountInfo secrets

-- | Look for the requested keys in the secret data that has been previously fetched.
lookupSecrets :: MountInfo -> [Secret] -> Map.Map String VaultData -> Either VaultError [EnvVar]
lookupSecrets mountInfo secrets vaultData = forM secrets $ \secret ->
  let secretData = Map.lookup (secretRequestPath mountInfo secret) vaultData
      secretValue = secretData >>= (\(VaultData vd) -> Map.lookup (sKey secret) vd)
      toEnvVar val = (sVarName secret, val)
  in maybe (Left $ KeyNotFound secret) (Right . toEnvVar) $ secretValue

-- | Send a request for secrets to the vault and parse the response.
doRequest :: String -> Request -> ExceptT VaultError IO VaultData
doRequest secretPath request = do
  resp <- withExceptT exToErr (httpLBS request)
  parseResponse secretPath resp
  where
    exToErr :: HttpException -> VaultError
    exToErr e@(HttpExceptionRequest _ _) = ServerUnreachable e
    exToErr (InvalidUrlException _ _) = InvalidUrl secretPath

--
-- HTTP response handling
--

parseResponse :: (Monad m) => String -> Response LBS.ByteString -> ExceptT VaultError m VaultData
parseResponse secretPath response =
  let
    responseBody = getResponseBody response
    statusCode = getResponseStatusCode response
  in case statusCode of
    200 -> liftEither (parseSuccessResponse responseBody)
    403 -> throwError Forbidden
    404 -> throwError $ SecretNotFound secretPath
    500 -> throwError $ ServerError responseBody
    503 -> throwError $ ServerUnavailable responseBody
    _   -> throwError $ Unspecified statusCode responseBody


parseSuccessResponse :: LBS.ByteString -> Either VaultError VaultData
parseSuccessResponse responseBody = first BadJSONResp $ Aeson.eitherDecode' responseBody

--
-- Utility functions
--

vaultErrorLogMessage :: VaultError -> String
vaultErrorLogMessage vaultError =
  let
    description = case vaultError of
      SecretNotFound secretPath ->
        "Secret not found: " <> secretPath
      SecretFileError sfe -> show sfe
      KeyNotFound secret ->
        "Key " <> (sKey secret) <> " not found for path " <> (sPath secret)
      DuplicateVar varName ->
        "Found duplicate environment variable \"" ++ varName ++ "\""
      BadRequest resp ->
        "Made a bad request: " <> (LBS.unpack resp)
      Forbidden ->
        "Invalid Vault token"
      InvalidUrl secretPath ->
        "Secret " <> secretPath <> " contains characters that are illegal in URLs"
      BadJSONResp msg ->
        "Received bad JSON from Vault: " <> msg
      ServerError resp ->
        "Internal Vault error: " <> (LBS.unpack resp)
      ServerUnavailable resp ->
        "Vault is unavailable for requests. It can be sealed, " <>
        "under maintenance or enduring heavy load: " <> (LBS.unpack resp)
      ServerUnreachable exception ->
        "ServerUnreachable error: " <> show exception
      Unspecified status resp ->
        "Received an error that I don't know about (" <> show status
        <> "): " <> (LBS.unpack resp)
      AddrPortHostMismatch host port addr -> concat [
        "The host and port combined are different from the address, I do not know which to choose. Host:  ",
        host, " Port: ", show port, " Address: ", addr]
      AddrInvalidFormat addr -> "The address is of an invalid format, expected something like localhost:port, but got " <> addr  
  in
    "[ERROR] " <> description
