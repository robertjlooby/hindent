module HIndent.CabalFile
  ( getCabalExtensionsForSourcePath
  ) where

import Data.List
import Data.Maybe
import Data.Traversable
import Distribution.ModuleName
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration
import Distribution.PackageDescription.Parse
import Language.Haskell.Extension
import qualified Language.Haskell.Exts.Extension as HSE
import System.Directory
import System.FilePath
import Text.Read

data Stanza = MkStanza
  { _stanzaBuildInfo :: BuildInfo
  , stanzaIsSourceFilePath :: FilePath -> Bool
  }

-- | Find the relative path of a child path in a parent, if it is a child
toRelative :: FilePath -> FilePath -> Maybe FilePath
toRelative parent child = let
  rel = makeRelative parent child
  in if rel == child
       then Nothing
       else Just rel

-- | Create a Stanza from `BuildInfo` and names of modules and paths
mkStanza :: BuildInfo -> [ModuleName] -> [FilePath] -> Stanza
mkStanza bi mnames fpaths =
  MkStanza bi $ \path -> let
    modpaths = fmap toFilePath $ otherModules bi ++ mnames
    inDir dir =
      case toRelative dir path of
        Nothing -> False
        Just relpath ->
          any (equalFilePath $ dropExtension relpath) modpaths ||
          any (equalFilePath relpath) fpaths
    in any inDir $ hsSourceDirs bi

-- | Extract `Stanza`s from a package
packageStanzas :: PackageDescription -> [Stanza]
packageStanzas pd = let
  libStanza :: Library -> Stanza
  libStanza lib = mkStanza (libBuildInfo lib) (exposedModules lib) []
  exeStanza :: Executable -> Stanza
  exeStanza exe = mkStanza (buildInfo exe) [] [modulePath exe]
  testStanza :: TestSuite -> Stanza
  testStanza ts =
    mkStanza
      (testBuildInfo ts)
      (case testInterface ts of
         TestSuiteLibV09 _ mname -> [mname]
         _ -> [])
      (case testInterface ts of
         TestSuiteExeV10 _ path -> [path]
         _ -> [])
  benchStanza :: Benchmark -> Stanza
  benchStanza bn =
    mkStanza (benchmarkBuildInfo bn) [] $
    case benchmarkInterface bn of
      BenchmarkExeV10 _ path -> [path]
      _ -> []
  in mconcat
       [ maybeToList $ fmap libStanza $ library pd
       , fmap exeStanza $ executables pd
       , fmap testStanza $ testSuites pd
       , fmap benchStanza $ benchmarks pd
       ]

-- | Find cabal files that are "above" the source path
findCabalFiles :: FilePath -> FilePath -> IO (Maybe ([FilePath], FilePath))
findCabalFiles dir rel = do
  names <- getDirectoryContents dir
  let cabalnames = filter (isSuffixOf ".cabal") names
  case cabalnames of
    []
      | dir == "/" -> return Nothing
    [] -> findCabalFiles (takeDirectory dir) (takeFileName dir </> rel)
    _ -> return $ Just (fmap (\n -> dir </> n) cabalnames, rel)

-- | Find the `Stanza` that refers to this source path
getCabalStanza :: FilePath -> IO (Maybe Stanza)
getCabalStanza srcpath = do
  abssrcpath <- canonicalizePath srcpath
  mcp <- findCabalFiles (takeDirectory abssrcpath) (takeFileName abssrcpath)
  case mcp of
    Just (cabalpaths, relpath) -> do
      stanzass <-
        for cabalpaths $ \cabalpath -> do
          cabaltext <- readFile cabalpath
          case parsePackageDescription cabaltext of
            ParseFailed _ -> return []
            ParseOk _ gpd -> do
              return $ packageStanzas $ flattenPackageDescription gpd
      return $
        case filter (\stanza -> stanzaIsSourceFilePath stanza relpath) $
             mconcat stanzass of
          [] -> Nothing
          (stanza:_) -> Just stanza -- just pick the first one
    Nothing -> return Nothing

-- | Get (Cabal package) language and extensions from the cabal file for this source path
getCabalExtensions :: FilePath -> IO (Language, [Extension])
getCabalExtensions srcpath = do
  mstanza <- getCabalStanza srcpath
  return $
    case mstanza of
      Nothing -> (Haskell98, [])
      Just (MkStanza bi _) -> do
        (fromMaybe Haskell98 $ defaultLanguage bi, defaultExtensions bi)

convertLanguage :: Language -> HSE.Language
convertLanguage lang = read $ show lang

convertKnownExtension :: KnownExtension -> Maybe HSE.KnownExtension
convertKnownExtension ext =
  case readEither $ show ext of
    Left _ -> Nothing
    Right hext -> Just hext

convertExtension :: Extension -> Maybe HSE.Extension
convertExtension (EnableExtension ke) =
  fmap HSE.EnableExtension $ convertKnownExtension ke
convertExtension (DisableExtension ke) =
  fmap HSE.DisableExtension $ convertKnownExtension ke
convertExtension (UnknownExtension s) = Just $ HSE.UnknownExtension s

-- | Get extensions from the cabal file for this source path
getCabalExtensionsForSourcePath :: FilePath -> IO [HSE.Extension]
getCabalExtensionsForSourcePath srcpath = do
  (lang, exts) <- getCabalExtensions srcpath
  return $
    fmap HSE.EnableExtension $
    HSE.toExtensionList (convertLanguage lang) $ mapMaybe convertExtension exts
