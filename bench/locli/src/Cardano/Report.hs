{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wno-orphans #-}
module Cardano.Report
  ( module Cardano.Report
  )
where

import Cardano.Prelude

import Data.Aeson.Encode.Pretty qualified as AEP
import Data.ByteString      qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict      qualified as Map
import Data.Text            qualified as T
import Data.Text.Lazy       qualified as LT
import Data.Time.Clock
import System.Posix.User
import System.Environment (lookupEnv)

import Text.EDE hiding (Id)

import Data.CDF
import Data.Tuple.Extra (fst3)
import Cardano.Render
import Cardano.Util
import Cardano.Analysis.API
import Cardano.Analysis.Summary

newtype Author   = Author   { unAuthor   :: Text } deriving newtype (FromJSON, ToJSON)
newtype ShortId  = ShortId  { unShortId  :: Text } deriving newtype (FromJSON, ToJSON)
newtype Tag      = Tag      { unTag      :: Text } deriving newtype (FromJSON, ToJSON)

data ReportMeta
  = ReportMeta
    { rmAuthor       :: !Author
    , rmDate         :: !Text
    , rmLocliVersion :: !LocliVersion
    , rmTarget       :: !Version
    , rmTag          :: !Tag
    }
instance ToJSON ReportMeta where
  toJSON ReportMeta{..} = object
    [ "author"     .= rmAuthor
    , "date"       .= rmDate
    , "locli"      .= rmLocliVersion
    , "target"     .= rmTarget
    , "tag"        .= rmTag
    ]

getReport :: [Metadata] -> Version -> IO ReportMeta
getReport metas _ver = do
  rmAuthor <- getGecosFullUsername
              `catch`
              \(_ :: SomeException) ->
                 getFallbackUserId
  rmDate <- getCurrentTime <&> T.take 16 . show
  let rmLocliVersion = getLocliVersion
      rmTarget = Version $ ident $ last metas
      rmTag = Tag $ multiRunTag Nothing metas
  pure ReportMeta{..}
 where
   getGecosFullUsername, getFallbackUserId :: IO Author
   getGecosFullUsername =
     (getUserEntryForID =<< getRealUserID)
     <&> Author . T.pack . takeWhile (/= ',') . userGecos

   getFallbackUserId =
     (\user host->
        Author . T.pack $
        fromMaybe "user" user <> "@" <> fromMaybe "localhost" host)
     <$> lookupEnv "USER"
     <*> lookupEnv "HOSTNAME"

data Workload
  = WValue
  | WPlutusLoopCountdown
  | WPlutusLoopSECP
  | WPlutusUnknown

instance ToJSON Workload where
  toJSON = \case
    WValue               -> "value-only"
    WPlutusLoopCountdown -> "Plutus countdown loop"
    WPlutusLoopSECP      -> "Plutus SECP loop"
    WPlutusUnknown       -> "Plutus (other)"

filenameInfix :: Workload -> Text
filenameInfix = \case
  WPlutusLoopCountdown  -> "plutus"
  WPlutusLoopSECP       -> "plutus-secp"
  WValue                -> "value-only"
  _                     -> "unknown"

data Section where
  STable ::
    { sData      :: !(a p)
    , sFields    :: !FSelect
    , sNameCol   :: !Text
    , sValueCol  :: !Text
    , sDataRef   :: !Text
    , sOrgFile   :: !Text
    , sTitle     :: !Text
    } -> Section

formatSuffix :: RenderFormat -> Text
formatSuffix AsOrg = "org"
formatSuffix AsLaTeX = "latex"
formatSuffix _ = "txt"

summaryReportSection :: RenderFormat -> Summary f -> Section
summaryReportSection rf summ =
  STable summ (ISel @SummaryOne $ iFields sumFieldsReport) "Parameter" "Value"   "summary"
    ("summary." <> formatSuffix rf)
    "Overall run parameters"

analysesReportSections :: RenderFormat -> MachPerf (CDF I) -> BlockProp f -> [Section]
analysesReportSections rf mp bp =
  [ STable mp (DSel @MachPerf  $ dFields mtFieldsReport)   "metric"  "average"    "perf" ("clusterperf.report." <> ext)
    "Resource Usage"

  , STable bp (DSel @BlockProp $ dFields bpFieldsControl)  "metric"  "average" "control" ("blockprop.control." <> ext)
    "Anomaly control"

  , STable bp (DSel @BlockProp $ dFields bpFieldsForger)   "metric"  "average"   "forge" ("blockprop.forger." <> ext)
    "Forging"

  , STable bp (DSel @BlockProp $ dFields bpFieldsPeers)    "metric"  "average"   "peers" ("blockprop.peers." <> ext)
    "Individual peer propagation"

  , STable bp (DSel @BlockProp $ dFields bpFieldsEndToEnd) "metric"  "average" "end2end" ("blockprop.endtoend." <> ext)
    "End-to-end propagation"
  ]
  where
    ext = formatSuffix rf

--
-- Representation of a run, structured for template generator's needs.
--

liftTmplRun :: Summary a -> TmplRun
liftTmplRun Summary{sumWorkload=generatorProfile
                   ,sumMeta=meta@Metadata{..}} =
  TmplRun
  { trMeta      = meta
  , trManifest  = manifest & unsafeShortenManifest 5
  , trWorkload  =
    case plutusLoopScript generatorProfile of
      Nothing                               -> WValue
      Just script
        | script == "Loop"                  -> WPlutusLoopCountdown
        | script == "EcdsaSecp256k1Loop"    -> WPlutusLoopSECP
        | script == "SchnorrSecp256k1Loop"  -> WPlutusLoopSECP
        | otherwise                         -> WPlutusUnknown
  }

data TmplRun
  = TmplRun
    { trMeta         :: !Metadata
    , trWorkload     :: !Workload
    , trManifest     :: !Manifest
    }

instance ToJSON TmplRun where
  toJSON TmplRun{..} =
    object
      [ "meta"       .= trMeta
      , "workload"   .= trWorkload
      , "branch"     .= componentBranch (getComponent "cardano-node" trManifest)
      , "ver"        .= ident trMeta
      , "rev"        .= unManifest trManifest
      , "fileInfix"  .= filenameInfix trWorkload
      ]

data LaTeXSection =
  LaTeXSection {
      latexSectionTitle   :: Text
    , latexSectionColumns :: [Text]
    , latexSectionRows    :: [Text]
    , latexSectionData    :: [[Text]]
  } deriving (Eq, Read, Show)

-- liftTmplLaTeX :: KnownCDF a => Section (CDF a) Double -> LaTeXSection
liftTmplLaTeX :: Section -> LaTeXSection
liftTmplLaTeX STable {..} =
  LaTeXSection {
      latexSectionTitle   = sTitle
    -- *** XXX MAJOR BOGON XXX ***
    -- The column labels need to be associated with groups of columns.
    , latexSectionColumns = case sFields of
                                  ISel sel -> map fShortDesc (filter sel timelineFields)
                                  DSel sel -> map fShortDesc (filter sel      cdfFields)
    , latexSectionRows    = rows
    -- *** XXX MAJOR BOGON XXX ***
    -- Rows need to be properly extracted from the CDF/MachPerf/etc.
    -- , latexSectionData    = [concat [let range = cdfRange stats in map (formatDouble width) [cdfMedian stats, cdfAverageVal stats, cdfStddev stats, low range, high range] | width <- widths] | stats <- [sData]]
    , latexSectionData = []
    }
    where
          -- *** XXX MAJOR BOGON XXX ***
          -- Row labels need to get prepended to the table's rows.
          rows = repeat ""
          _widths = case sFields of
                           ISel sel -> [fWidth | Field {..} <- filter sel timelineFields]
                           DSel sel -> [fWidth | Field {..} <- filter sel      cdfFields]

liftTmplSection :: Section -> TmplSection
liftTmplSection =
  \case
    STable{..} ->
      TmplTable
      { tsTitle       = sTitle
      , tsNameCol     = sNameCol
      , tsValueCol    = sValueCol
      , tsDataRef     = sDataRef
      , tsOrgFile     = sOrgFile
      , tsRowPrecs    = fs <&> fromEnum
      , tsVars        = [ ("nSamples", "Sample count")
                        ]
      }
     where fs = case sFields of
                  ISel sel -> filter sel timelineFields <&> fPrecision
                  DSel sel -> filter sel      cdfFields <&> fPrecision

data TmplSection
  = TmplTable
    { tsTitle        :: !Text
    , tsNameCol      :: !Text
    , tsValueCol     :: !Text
    , tsDataRef      :: !Text
    , tsOrgFile      :: !Text
    , tsRowPrecs     :: ![Int]
    , tsVars         :: ![(Text, Text)] -- map from Org constant name to description
    }

instance ToJSON TmplSection where
  toJSON TmplTable{..} = object
    [ "title"     .= tsTitle
    , "nameCol"   .= tsNameCol
    , "valueCol"  .= tsValueCol
    , "dataRef"   .= tsDataRef
    , "orgFile"   .= tsOrgFile
    -- Yes, strange as it is, this is the encoding to ease iteration in ED-E.
    , "rowPrecs"  .= tsRowPrecs
    , "vars"      .= Map.fromList (zip tsVars ([0..] <&> flip T.replicate ">" . (length tsVars -))
                                   <&> \((k, name), angles) ->
                                         (k, Map.fromList @Text
                                             [("name", name),
                                              ("angles", angles)]))
    ]

generate' :: (SomeSummary, ClusterPerf, SomeBlockProp)
          -> [(SomeSummary, ClusterPerf, SomeBlockProp)]
          -- summary, resource, anomaly, forging, peers
          -> IO (Text, Text, Text, Text, Text, Text)
generate' (SomeSummary (summ :: Summary f), cp :: MachPerf cpt, SomeBlockProp (_bp :: BlockProp bpt)) rest = do
  ctx <- getReport metas (last restTmpls & trManifest & getComponent "cardano-node" & ciVersion)
  time <- getCurrentTime

  let summaryRendering :: [Text]
      summaryRendering  = renderSummary renderConfig anchor (iFields sumFieldsReport) summ
      anomalyRendering, forgingRendering, peersRendering, resourceRendering :: [(Text, [Text])]
      -- anomalyRendering  = renderAnalysisCDFs anchor (dFields bpFieldsControl :: (Field DSelect bpt BlockProp) -> Bool) OfInterCDF Nothing renderConfig bp
      -- forgingRendering  = renderAnalysisCDFs anchor (dFields bpFieldsForger :: (Field DSelect bpt BlockProp) -> Bool) OfInterCDF Nothing renderConfig bp
      -- peersRendering    = renderAnalysisCDFs anchor (dFields bpFieldsPeers :: (Field DSelect bpt BlockProp) -> Bool) OfInterCDF Nothing renderConfig bp
      anomalyRendering = []
      forgingRendering = []
      peersRendering = []
      resourceRendering = renderAnalysisCDFs anchor (dFields mtFieldsReport :: (Field DSelect cpt MachPerf) -> Bool) OfInterCDF Nothing renderConfig cp

      anchor :: Anchor
      anchor =
          Anchor {
              aRuns = getName summ : map (\(SomeSummary ss, _, _) -> getName ss) rest
             -- *** XXX MAJOR BOGON XXX ***
             -- Filters, slots and blocks should actually come from somewhere.
            , aFilters = ([], [])
            , aSlots = Nothing
            , aBlocks = Nothing
            , aVersion = getLocliVersion
            , aWhen = time
          } where getName = tag . sumMeta
  pure    $ ( titlingText ctx
            , T.intercalate " & " summaryRendering <> " \\\\\n"
            , fixup resourceRendering
            , fixup anomalyRendering
            , fixup forgingRendering
            , fixup peersRendering
            )
  where
   metas :: [Metadata]
   metas = sumMeta summ : fmap (\(SomeSummary ss, _, _) -> sumMeta ss) rest
   restTmpls = fmap ((\(SomeSummary ss) -> liftTmplRun ss) . fst3) rest
   fixup = unlines . map ((<>" \\\\") . T.intercalate " & ") . transpose . map (uncurry (:))
   renderConfig =
     RenderConfig {
       rcFormat = AsLaTeX
     , rcDateVerMetadata = False
     , rcRunMetadata = False
     }
   -- Authors should have "\\and" interspersed between them in LaTeX.
   -- Write this out to titling.latex
   titlingText ctx = unlines
     $ [ "\\def\\@locliauthor{" <> unAuthor (rmAuthor ctx) <> "}"
       , "\\def\\@loclititle{Value Workload for " <> unTag (rmTag ctx) <> "}"
       , "\\def\\@loclidate{" <> rmDate ctx <> "}"
       ]

generate :: InputDir -> Maybe TextInputFile
         -> (SomeSummary, ClusterPerf, SomeBlockProp) -> [(SomeSummary, ClusterPerf, SomeBlockProp)]
         -> IO (ByteString, ByteString, Text)
generate (InputDir ede) mReport (SomeSummary summ, cp, SomeBlockProp bp) rest = do
  ctx  <- getReport metas (last restTmpls & trManifest & getComponent "cardano-node" & ciVersion)
  tmplRaw <- BS.readFile (maybe defaultReportPath unTextInputFile mReport)
  tmpl <- parseWith defaultSyntax (includeFile ede) "report" tmplRaw
  let tmplEnv           = mkTmplEnv ctx baseTmpl restTmpls
      tmplEnvSerialised = AEP.encodePretty tmplEnv
  Text.EDE.result
    (error . show)
    (pure . (tmplRaw, LBS.toStrict tmplEnvSerialised,) . LT.toStrict) $ tmpl >>=
    \x ->
      renderWith mempty x tmplEnv
 where
   metas = sumMeta summ : fmap (\(SomeSummary ss, _, _) -> sumMeta ss) rest

   defaultReportPath = ede <> "/report.ede"

   baseTmpl  = liftTmplRun summ
   restTmpls = fmap ((\(SomeSummary ss) -> liftTmplRun ss). fst3) rest

   mkTmplEnv rc b rs = fromPairs
     [ "report"     .= rc
     , "base"       .= b
     , "runs"       .= rs
     , "summary"    .= liftTmplSection (summaryReportSection AsOrg summ)
     , "analyses"   .= (liftTmplSection <$> analysesReportSections AsOrg cp bp)
     , "dictionary" .= metricDictionary
     , "charts"     .=
       ((dClusterPerf metricDictionary & onlyKeys clusterPerfKeys)
        <>
        (dBlockProp   metricDictionary & onlyKeys blockPropKeys))
     ]

onlyKeys :: [Text] -> Map.Map Text DictEntry -> [DictEntry]
onlyKeys ks m =
  ks <&>
     \case
       (Nothing, k) -> error $ "Report.generate:  missing metric: " <> show k
       (Just x, _) -> x
     . (flip Map.lookup m &&& identity)

blockPropKeys, clusterPerfKeys :: [Text]
clusterPerfKeys =
          [ "CentiCpu"
          , "CentiGC"
          , "CentiMut"
          , "Alloc"
          , "GcsMajor"
          , "GcsMinor"
          , "Heap"
          , "Live"
          , "RSS"

          , "cdfStarted"
          , "cdfBlkCtx"
          , "cdfLgrState"
          , "cdfLgrView"
          , "cdfLeading"

          , "cdfDensity"
          , "cdfBlockGap"
          , "cdfSpanLensCpu"
          , "cdfSpanLensCpuEpoch"
          ]

blockPropKeys =
          [ "cdfForgerLead"
          , "cdfForgerTicked"
          , "cdfForgerMemSnap"
          , "cdfForgerForge"
          , "cdfForgerAnnounce"
          , "cdfForgerSend"
          , "cdfPeerNoticeFirst"
          , "cdfPeerAdoption"
          , "cdf0.50"
          , "cdf0.80"
          , "cdf0.90"
          , "cdf0.96"
          ]
