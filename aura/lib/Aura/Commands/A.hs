{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE MonoLocalBinds    #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}
{-# LANGUAGE ViewPatterns      #-}

-- |
-- Module    : Aura.Commands.A
-- Copyright : (c) Colin Woodbury, 2012 - 2020
-- License   : GPL3
-- Maintainer: Colin Woodbury <colin@fosskers.ca>
--
-- Handle all @-A@ flags - those which involve viewing and building packages
-- from the AUR.

module Aura.Commands.A
  ( I.install
  , upgradeAURPkgs
  , aurPkgInfo
  , aurPkgSearch
  , I.displayPkgDeps
  , displayPkgbuild
  , aurJson
  ) where

import           Aura.Colour
import           Aura.Core
import qualified Aura.Install as I
import           Aura.Languages
import           Aura.Packages.AUR
import           Aura.Pkgbuild.Fetch
import           Aura.Settings
import           Aura.State (saveState)
import           Aura.Types
import           Aura.Utils
import           Control.Error.Util (hush)
import           Data.Aeson.Encode.Pretty (encodePretty)
import           Data.Generics.Product (field)
import qualified Data.List.NonEmpty as NEL
import           Data.Set.NonEmpty (NESet)
import qualified Data.Set.NonEmpty as NES
import           Data.Text.Prettyprint.Doc
import           Data.Text.Prettyprint.Doc.Render.Terminal
import           Data.Versions (Versioning, prettyV, versioning)
import           Lens.Micro (each, (^..))
import           Linux.Arch.Aur
import           Network.HTTP.Client (Manager)
import           RIO
import qualified RIO.ByteString as B
import qualified RIO.ByteString.Lazy as BL
import           RIO.List (intersperse)
import           RIO.List.Partial (maximum)
import qualified RIO.Set as S
import qualified RIO.Text as T
import           RIO.Text.Partial (splitOn)
import           Text.Printf (printf)

---

-- | The result of @-Au@.
upgradeAURPkgs :: Set PkgName -> RIO Env ()
upgradeAURPkgs pkgs = do
  ss <- asks settings
  liftIO . notify ss . upgradeAURPkgs_1 $ langOf ss
  liftIO (foreigns ss) >>= traverse_ (upgrade pkgs) . NES.nonEmptySet

-- | Foreign packages to consider for upgrading, after "ignored packages" have
-- been taken into consideration.
foreigns :: Settings -> IO (Set SimplePkg)
foreigns ss = S.filter (notIgnored . view (field @"name")) <$> foreignPackages
  where notIgnored p = not . S.member p $ ignoresOf ss

upgrade :: Set PkgName -> NESet SimplePkg -> RIO Env ()
upgrade pkgs fs = do
  ss        <- asks settings
  toUpgrade <- possibleUpdates fs
  let !names = map (PkgName . aurNameOf . fst) toUpgrade
  auraFirst <- auraCheck names
  case auraFirst of
    Just a  -> auraUpgrade a
    Nothing -> do
      devel <- develPkgCheck
      liftIO . notify ss . upgradeAURPkgs_2 $ langOf ss
      if | null toUpgrade && null devel -> liftIO . warn ss . upgradeAURPkgs_3 $ langOf ss
         | otherwise -> do
             reportPkgsToUpgrade toUpgrade (toList devel)
             liftIO . unless (switch ss DryRun) $ saveState ss
             traverse_ I.install . NES.nonEmptySet $ S.fromList names <> pkgs <> devel

possibleUpdates :: NESet SimplePkg -> RIO Env [(AurInfo, Versioning)]
possibleUpdates (NES.toList -> pkgs) = do
  aurInfos <- aurInfo $ fmap (^. field @"name") pkgs
  let !names  = map aurNameOf aurInfos
      aurPkgs = NEL.filter (\(SimplePkg (PkgName n) _) -> n `elem` names) pkgs
  pure . filter isntMostRecent . zip aurInfos $ aurPkgs ^.. each . field @"version"

-- | Is there an update for Aura that we could apply first?
auraCheck :: [PkgName] -> RIO Env (Maybe PkgName)
auraCheck ps = join <$> traverse f auraPkg
  where f a = do
          ss <- asks settings
          bool Nothing (Just a) <$> liftIO (optionalPrompt ss auraCheck_1)
        auraPkg | "aura" `elem` ps     = Just "aura"
                | "aura-bin" `elem` ps = Just "aura-bin"
                | otherwise            = Nothing

auraUpgrade :: PkgName -> RIO Env ()
auraUpgrade = I.install . NES.singleton

develPkgCheck :: RIO Env (Set PkgName)
develPkgCheck = asks settings >>= \ss ->
  if switch ss RebuildDevel then liftIO develPkgs else pure S.empty

-- | The result of @-Ai@.
aurPkgInfo :: NESet PkgName -> RIO Env ()
aurPkgInfo = aurInfo . NES.toList >=> traverse_ displayAurPkgInfo

displayAurPkgInfo :: AurInfo -> RIO Env ()
displayAurPkgInfo ai = asks settings >>= \ss -> liftIO . putTextLn $ renderAurPkgInfo ss ai <> "\n"

renderAurPkgInfo :: Settings -> AurInfo -> Text
renderAurPkgInfo ss ai = dtot . colourCheck ss $ entrify ss fields entries
    where fields   = infoFields . langOf $ ss
          entries = [ magenta "aur"
                    , annotate bold . pretty $ aurNameOf ai
                    , pretty $ aurVersionOf ai
                    , outOfDateMsg (dateObsoleteOf ai) $ langOf ss
                    , orphanedMsg (aurMaintainerOf ai) $ langOf ss
                    , cyan . maybe "(null)" pretty $ urlOf ai
                    , pretty . pkgUrl . PkgName $ aurNameOf ai
                    , pretty . T.unwords $ licenseOf ai
                    , pretty . T.unwords $ dependsOf ai
                    , pretty . T.unwords $ makeDepsOf ai
                    , yellow . pretty $ aurVotesOf ai
                    , yellow . pretty . T.pack . printf "%0.2f" $ popularityOf ai
                    , maybe "(null)" pretty $ aurDescriptionOf ai ]

-- | The result of @-As@.
aurPkgSearch :: Text -> RIO Env ()
aurPkgSearch regex = do
  ss <- asks settings
  db <- S.map (^. field @"name" . field @"name") <$> liftIO foreignPackages
  let t = case truncationOf $ buildConfigOf ss of  -- Can't this go anywhere else?
            None   -> id
            Head n -> take $ fromIntegral n
            Tail n -> reverse . take (fromIntegral n) . reverse
  results <- fmap (\x -> (x, aurNameOf x `S.member` db)) . t
            <$> aurSearch regex
  liftIO $ traverse_ (putTextLn . renderSearch ss regex) results

renderSearch :: Settings -> Text -> (AurInfo, Bool) -> Text
renderSearch ss r (i, e) = searchResult
    where searchResult = if switch ss LowVerbosity then sparseInfo else dtot $ colourCheck ss verboseInfo
          sparseInfo   = aurNameOf i
          verboseInfo  = repo <> n <+> v <+> "(" <> l <+> "|" <+> p <>
                         ")" <> (if e then annotate bold " [installed]" else "") <> "\n    " <> d
          repo = magenta "aur/"
          n = fold . intersperse (bCyan $ pretty r) . map (annotate bold . pretty) . splitOn r $ aurNameOf i
          d = maybe "(null)" pretty $ aurDescriptionOf i
          l = yellow . pretty $ aurVotesOf i  -- `l` for likes?
          p = yellow . pretty . T.pack . printf "%0.2f" $ popularityOf i
          v = case dateObsoleteOf i of
            Just _  -> red . pretty $ aurVersionOf i
            Nothing -> green . pretty $ aurVersionOf i

-- | The result of @-Ap@.
displayPkgbuild :: NESet PkgName -> RIO Env ()
displayPkgbuild ps = do
  man <- asks (managerOf . settings)
  pbs <- catMaybes <$> traverse (liftIO . getPkgbuild man) (toList ps)
  liftIO . traverse_ (\p -> B.putStr @IO p >> B.putStr "\n") $ pbs ^.. each . field @"pkgbuild"

isntMostRecent :: (AurInfo, Versioning) -> Bool
isntMostRecent (ai, v) = trueVer > Just v
  where trueVer = hush . versioning $ aurVersionOf ai

-- | Similar to @-Ai@, but yields the raw data as JSON instead.
aurJson :: NESet PkgName -> RIO Env ()
aurJson ps = do
  m <- asks (managerOf . settings)
  infos <- liftMaybeM (Failure connectionFailure_1) . fmap hush . liftIO $ f m ps
  liftIO $ traverse_ (BL.putStrLn @IO . encodePretty) infos
  where
    f :: Manager -> NESet PkgName -> IO (Either ClientError [AurInfo])
    f m = info m . (^.. each . field @"name") . toList

------------
-- REPORTING
------------
reportPkgsToUpgrade :: [(AurInfo, Versioning)] -> [PkgName] -> RIO Env ()
reportPkgsToUpgrade ups pns = do
  ss <- asks settings
  liftIO . notify ss . reportPkgsToUpgrade_1 $ langOf ss
  liftIO $ putDoc (colourCheck ss . vcat $ map f ups' <> map g devels) >> putTextLn "\n"
  where devels   = pns ^.. each . field @"name"
        ups'     = map (second prettyV) ups
        nLen     = maximum $ map (T.length . aurNameOf . fst) ups <> map T.length devels
        vLen     = maximum $ map (T.length . snd) ups'
        g        = annotate (color Cyan) . pretty
        f (p, v) = hsep [ cyan . fill nLen . pretty $ aurNameOf p
                        , "::"
                        , yellow . fill vLen $ pretty v
                        , "->"
                        , green . pretty $ aurVersionOf p ]
