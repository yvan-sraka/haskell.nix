{-# LANGUAGE NamedFieldPuns #-}

import qualified Cabal2Nix
import qualified Data.ByteString.Lazy as BSL
import Data.Foldable (for_)
import Distribution.Client.DistDirLayout (DistDirLayout (distDirectory, distProjectCacheFile, distProjectFile))
import Distribution.Client.GlobalFlags
import Distribution.Client.HashValue (HashValue, showHashValue)
import qualified Distribution.Client.InstallPlan as InstallPlan
import Distribution.Client.NixStyleOptions (NixStyleFlags (..), defaultNixStyleFlags, nixStyleOptions)
import Distribution.Client.ProjectConfig
import Distribution.Client.ProjectOrchestration
import Distribution.Client.ProjectPlanOutput (writePlanExternalRepresentation)
import Distribution.Client.ProjectPlanning (ElaboratedConfiguredPackage (..), rebuildInstallPlan)
import Distribution.Client.Setup
import Distribution.Client.Types.PackageLocation (PackageLocation (..))
import Distribution.Client.Types.Repo (LocalRepo (..), RemoteRepo (..), Repo (..))
import Distribution.Client.Types.SourceRepo (SourceRepositoryPackage (..))
import Distribution.Package (pkgName)
import Distribution.Pretty (prettyShow)
import Distribution.Simple.Command
import Distribution.Simple.Flag
import qualified Distribution.Simple.Utils as Cabal
import Distribution.Types.SourceRepo (KnownRepoType (Git), RepoType (..))
import Distribution.Verbosity (Verbosity)
import qualified Distribution.Verbosity as Verbosity
import Nix.Pretty (prettyNix)
import Prettyprinter (Doc)
import Prettyprinter.Render.Text (hPutDoc)
import System.Environment (getArgs)
import System.FilePath
import System.IO (IOMode (WriteMode), hClose, openFile)

main :: IO ()
main = do
  args <- getArgs
  case commandParseArgs cmdUI True args of
    CommandHelp help -> putStrLn (help "make-install-plan")
    CommandList opts -> putStrLn $ "commandList" ++ show opts
    CommandErrors errs -> putStrLn $ "commandErrors: " ++ show errs
    CommandReadyToGo (mkflags, _commandParse) ->
      let globalFlags = defaultGlobalFlags
          flags@NixStyleFlags {configFlags} = mkflags (commandDefaultFlags cmdUI)
          verbosity = fromFlagOrDefault Verbosity.normal (configVerbosity configFlags)
          cliConfig = commandLineFlagsToProjectConfig globalFlags flags mempty
       in installPlanAction verbosity cliConfig

cmdUI :: CommandUI (NixStyleFlags ())
cmdUI =
  CommandUI
    { commandName = "",
      commandSynopsis = "Makes an install-plan",
      commandUsage = ("Usage: " ++),
      commandDescription = Nothing,
      commandNotes = Nothing,
      commandDefaultFlags = defaultNixStyleFlags (),
      commandOptions = nixStyleOptions (const [])
    }

-- The following is adapted from cabal-install's Distribution.Client.CmdFreeze
installPlanAction :: Verbosity -> ProjectConfig -> IO ()
installPlanAction verbosity cliConfig = do
  ProjectBaseContext {distDirLayout, cabalDirLayout, projectConfig, localPackages} <-
    establishProjectBaseContext verbosity cliConfig OtherCommand

  (_improvedPlan, elaboratedPlan, elaboratedSharedConfig, _tis, _at) <-
    rebuildInstallPlan verbosity distDirLayout cabalDirLayout projectConfig localPackages

  -- Write plan.json
  Cabal.notice verbosity $ "Writing plan.json to " ++ distProjectCacheFile distDirLayout "plan.json"
  writePlanExternalRepresentation distDirLayout elaboratedPlan elaboratedSharedConfig

  -- Write cabal.freeze
  let cabalFreezeFile = distProjectFile distDirLayout "freeze"
  Cabal.notice verbosity $ "Wrote freeze file to " ++ cabalFreezeFile
  writeProjectConfigFile cabalFreezeFile projectConfig

  -- Write cabal files and their nix version
  let cabalFilesDir = distDirectory distDirLayout </> "cabal-files"
  Cabal.createDirectoryIfMissingVerbose verbosity True cabalFilesDir
  Cabal.notice verbosity $ "Writing cabal files to " ++ cabalFilesDir

  let ecps = [ecp | InstallPlan.Configured ecp <- InstallPlan.toList elaboratedPlan, not $ elabLocalToProject ecp]

  for_ ecps $
    \ElaboratedConfiguredPackage
       { elabPkgSourceId,
         elabPkgSourceLocation,
         elabPkgSourceHash,
         elabPkgDescriptionOverride
       } -> do
        let pkgFile = cabalFilesDir </> prettyShow (pkgName elabPkgSourceId) <.> "cabal"
        let nixFile = cabalFilesDir </> prettyShow (pkgName elabPkgSourceId) <.> "nix"
        for_ elabPkgDescriptionOverride $ \pkgTxt ->
          do
            -- raw
            Cabal.info verbosity $ "Writing cabal file for " ++ prettyShow elabPkgSourceId ++ " to " ++ pkgFile
            BSL.writeFile pkgFile pkgTxt
            -- nix
            let src = packageLocation2Src elabPkgSourceLocation elabPkgSourceHash
            Cabal2Nix.cabal2nix False Cabal2Nix.MinimalDetails (Just src) (Cabal2Nix.OnDisk pkgFile)
            >>= writeDoc nixFile . prettyNix

packageLocation2Src :: PackageLocation local -> Maybe HashValue -> Cabal2Nix.Src
packageLocation2Src pkgSrcLoc pkgSrcHash = case pkgSrcLoc of
  LocalUnpackedPackage path -> Cabal2Nix.Path path
  LocalTarballPackage path -> Cabal2Nix.Path path
  RemoteTarballPackage uri _local -> Cabal2Nix.Repo (show uri) mSrcHash
  RepoTarballPackage repo packageId _local -> case repo of
    (RepoLocalNoIndex lr _local) -> Cabal2Nix.Path (localRepoPath lr)
    (RepoRemote rr _local) -> Cabal2Nix.Repo (show (remoteRepoURI rr) </> "package" </> prettyShow packageId) mSrcHash
    (RepoSecure rr _local) -> Cabal2Nix.Repo (show (remoteRepoURI rr) </> "package" </> prettyShow packageId) mSrcHash
  RemoteSourceRepoPackage sourceRepoMaybe _local -> case sourceRepoMaybe of
    (SourceRepositoryPackage (KnownRepoType Git) location (Just tag) branch subdir []) ->
      Cabal2Nix.Git location tag branch subdir
    _otherCases -> error $ "Repository " <> show sourceRepoMaybe <> " not supported"
  where
    mSrcHash = showHashValue <$> pkgSrcHash

writeDoc :: FilePath -> Doc ann -> IO ()
writeDoc file doc = do
  handle <- openFile file WriteMode
  hPutDoc handle doc
  hClose handle
