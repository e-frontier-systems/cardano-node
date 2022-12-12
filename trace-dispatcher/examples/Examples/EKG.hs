{-# OPTIONS_GHC -Wno-orphans  #-}

module Examples.EKG (
  testEKG
) where

import           Cardano.Logging
import           Control.Concurrent

import qualified Data.Aeson as AE
import           Data.Text (pack)
import           System.Remote.Monitoring (forkServer)


newtype Measure = Measure Int

instance LogFormatting Measure where
  forMachine _dtal (Measure count) =
      mconcat
        [ "count" AE..= AE.String (pack $ show count)
        ]
  asMetrics (Measure count) =
    [ DoubleM "measure" (fromIntegral count)]

instance MetaTrace Measure where
  namespaceFor (Measure _count) = NamespaceInner ["Count"]
  severityFor (NamespaceInner ["Count"]) = Info
  privacyFor  (NamespaceInner ["Count"]) = Public
  documentFor (NamespaceInner ["Count"]) = "A counter"
  metricsDocFor (NamespaceInner ["Count"]) =
    [("count", "an integer")]
  allNamespaces = [NamespaceInner ["Count"]]


testEKG :: IO ()
testEKG = do
    server <- forkServer "localhost" 8000
    tracer <- ekgTracer (Right server)
    let formattedTracer = metricsFormatter "cardano" tracer
    configureTracers emptyTraceConfig [formattedTracer]
    loop (appendName "ekg1" formattedTracer) 1
  where
    loop :: Trace IO Measure -> Int -> IO ()
    loop tr count = do
      if count == 1000
        then pure ()
        else do
          traceWith tr (Measure count)
          threadDelay 100000
          loop tr (count + 1)
