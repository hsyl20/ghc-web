{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

import CmdLine (Options(..), getOptions)

import Control.Monad
import Text.Printf
import Network.Socket (withSocketsDo)
import Happstack.Server
import Data.List (isPrefixOf, isSuffixOf, sortOn, foldl',isInfixOf)
import Data.Maybe (fromJust, isJust, fromMaybe)
import Data.FileEmbed
import System.IO.Temp
import System.FilePath
import Data.IORef
import Control.Monad.IO.Class
import qualified Data.Map  as Map

import Text.Highlighting.Kate as Kate
import Text.Megaparsec.String (Parser)
import Text.Megaparsec
import Text.Blaze.Html5 ((!), toHtml, docTypeHtml, Html, toValue)
import qualified Text.Blaze.Html5.Attributes as A
import qualified Text.Blaze.Html5 as H
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as L

import GHC
import Outputable (SDoc,PprStyle,renderWithStyle,showSDoc)
import GHC.Paths ( libdir )
import FastString (unpackFS)
import DynFlags
import Control.Concurrent
import Control.Concurrent.STM
import System.Directory
import Data.Time.Clock
import Safe
import Extra
import Numeric


data Compilation = Compilation
   { compilFlags   :: DynFlags
   , compilSources :: [File]
   , compilLogs    :: [Log]
   , compilPhases  :: [PhaseInfo]
   }

data CompilationProfile = CompilationProfile
   { profileName  :: String
   , profileDesc  :: String
   , profileFlags :: DynFlags -> DynFlags
   }

data Log = Log
   { logDynFlags :: DynFlags
   , logReason   :: WarnReason
   , logSeverity :: Severity
   , logLocation :: Maybe Location
   , logStyle    :: PprStyle
   , logMessage  :: SDoc
   }

data Location = Location
   { locFile      :: String
   , locStartLine :: Int
   , locEndLine   :: Int
   , locStartCol  :: Int
   , locEndCol    :: Int
   }

-- TODO: add location for logs that concern the module but
-- that don't have location info
--    (e.g. "!!! Parser [A]: finished in...")
convertLocation :: SrcSpan -> Maybe Location
convertLocation = \case
   UnhelpfulSpan _ -> Nothing
   RealSrcSpan s   ->
      Just $ Location (prepareFile (unpackFS (srcSpanFile s)))
                      (srcSpanStartLine s) (srcSpanEndLine s)
                      (srcSpanStartCol  s) (srcSpanEndCol  s)
   where
      prepareFile s
         | "./" `isPrefixOf` s = drop 2 s
         | otherwise           = s

defaultProfiles :: [CompilationProfile]
defaultProfiles =
   [ CompilationProfile
      { profileName  = "Show passes (-O0)"
      , profileDesc  = "Use this pass to detect the most expensive phases with -O0"
      , profileFlags = \dflags -> enableWarningGroup "all" $ dflags
         { verbosity = 2 -- -dshow-passes is -v2 in fact
         }
      }
   , CompilationProfile
      { profileName  = "Show passes (-O1)"
      , profileDesc  = "Use this pass to detect the most expensive phases with -O1"
      , profileFlags = \dflags -> 
         enableWarningGroup "all" 
         $ updOptLevel 1
         $ dflags
            { verbosity = 2 -- -dshow-passes is -v2 in fact
            }
      }
   , CompilationProfile
      { profileName  = "Show passes (-O2)"
      , profileDesc  = "Use this pass to detect the most expensive phases with -O2"
      , profileFlags = \dflags -> 
         enableWarningGroup "all" 
         $ updOptLevel 2
         $ dflags
            { verbosity = 2 -- -dshow-passes is -v2 in fact
            }
      }
   , CompilationProfile
      { profileName  = "Maximal verbosity"
      , profileDesc  = "Use maximal verbosity (-v5) and -Wall: the intermediate representation after each compilation phase is dumped"
      , profileFlags = \dflags -> enableWarningGroup "all" $ dflags
         { verbosity = 5
         }
      }
   , CompilationProfile
      { profileName  = "Maximal verbosity and optimization"
      , profileDesc  = "Use maximal verbosity (-v5), -Wall and maximal optimization (-O2)"
      , profileFlags = \dflags ->
           updOptLevel 2
         $ enableWarningGroup "all" $ dflags
            { verbosity = 5
            }
      }
   , CompilationProfile
      { profileName  = "Debug TypeChecker"
      , profileDesc  = "Enable type-checker tracing"
      , profileFlags = \dflags -> dflags
         { verbosity = 1
         } `dopt_set` Opt_D_dump_tc
           `dopt_set` Opt_D_dump_tc_trace
      }
   ]

main :: IO ()
main = withSocketsDo $ do

   opts <- getOptions

   infiles <- forM (optfiles opts) $ \src ->
               File src <$> readFile src

   comps <- newTVarIO Map.empty
   profs <- newTVarIO defaultProfiles

   quit <- newEmptyMVar

   let conf = nullConf {port = optport opts}
   putStrLn (printf "Starting Web server at localhost:%d" (port conf))
   httpTID <- forkIO $ simpleHTTP conf $ msum
      [ dir "css" $ dir "style.css" $ ok css

      , dir "quit" $ nullDir >> do
         liftIO $ putMVar quit ()
         tempRedirect "/" (toResponse "")

      , nullDir >> do
         ps <- liftIO $ atomically $ readTVar profs
         ok $ toResponse $ appTemplate "Welcome" $ showWelcome infiles ps

      , dir "compilation" $ path $ \i -> do
         ps <- liftIO $ readTVarIO profs
         case ps `atMay` i of
            Nothing   -> mempty
            Just prof -> do
               cs <- liftIO $ readTVarIO comps
               when (Map.notMember i cs) $ do
                  comp <- liftIO $ compileFiles infiles prof
                  liftIO $ atomically $ modifyTVar comps (Map.insert i comp)

               cs' <- liftIO $ readTVarIO comps
               let title = profileName prof
               fileFilter <- optional $ look "file"
               case Map.lookup i cs' of
                  Nothing -> mempty
                  Just c  -> msum
                     [ nullDir >> (ok $ toResponse $ appTemplate title $
                        showCompilation i c)
                     , dir "phase" $ path $ \phaseIdx -> do
                        case compilPhases c `atMay` phaseIdx of
                           Nothing    -> mempty
                           Just phase -> ok $ toResponse $ appTemplate title $
                                          showPhase c phase
                     , dir "logs" $ ok $ toResponse $ appTemplate title $
                        showLogs fileFilter c
                     ]
      ]

   takeMVar quit
   killThread httpTID
   putStrLn "Quit."


data File = File
   { fileName     :: String
   , fileContents :: String
   } deriving (Show)


compileFiles :: [File] -> CompilationProfile -> IO Compilation
compileFiles files prof = do
   logs <- newIORef []

   dflgs <- withSystemTempDirectory "ghc-web" $ \tmpdir -> do
      -- write module files
      forM_ files $ \file -> do
         -- FIXME: check that fileName is not relative (e.g., ../../etc/passwd)
         createDirectoryIfMissing True (tmpdir </> takeDirectory (fileName file))
         writeFile (tmpdir </> fileName file) (fileContents file)

      withCurrentDirectory tmpdir $ do
         -- execute ghc
         runGhc (Just libdir) $ do
            dflags <- getSessionDynFlags

            -- we catch logs generated by GHC
            let logact dfl reason sev srcspan style msg = do
                  modifyIORef logs (Log dfl reason sev (convertLocation srcspan) style msg :)
                  --log_action dflags dfl reason sev srcspan style msg

            let dflags' = (profileFlags prof dflags)
                  { dumpDir    = Just tmpdir
                  , log_action = logact
                  }
            void $ setSessionDynFlags dflags'
            target <- guessTarget (fileName (head files)) Nothing
            setTargets [target]
            void $ load LoadAllTargets

            return dflags'

   logs' <- reverse <$> readIORef logs

   let phaseInfos = makePhaseInfos logs'

   return $ Compilation dflgs files logs' phaseInfos



css :: Response
css = toResponseBS (C.pack "text/css") (L.fromStrict $(embedFile "src/style.css"))

-- | Template of all pages
appTemplate :: String -> Html -> Html
appTemplate title bdy = docTypeHtml $ do
   H.head $ do
      H.title (toHtml "GHC Web")
      H.meta ! A.httpEquiv (toValue "Content-Type")
             ! A.content   (toValue "text/html;charset=utf-8")
      H.link ! A.rel       (toValue "stylesheet") 
             ! A.type_     (toValue "text/css")
             ! A.href      (toValue "/css/style.css")
      H.style ! A.type_ (toValue "text/css") $ toHtml $ styleToCss tango
   H.body $ do
      H.div (toHtml $ "GHC Web " ++ " / " ++ title)
         ! A.class_ (toValue "headtitle")
      H.div (do
         H.a (toHtml ("Home")) ! A.href (toValue "/")
         toHtml "  -  "
         H.a (toHtml ("Quit")) ! A.href (toValue "/quit")
         ) ! A.class_ (toValue "panel")
      bdy

-- | Welcoming screen
showWelcome :: [File] -> [CompilationProfile] -> Html
showWelcome files profs = do
   H.p (toHtml "This is a GHC Web frontend. It will help you debug your program and/or GHC.")
   H.p (toHtml "The following files are considered:")
   H.ul $ forM_ files $ \file -> do
      H.li (toHtml (fileName file))
      H.div $ toHtml
         $ formatHtmlBlock defaultFormatOpts
         $ highlightAs "haskell" (fileContents file)
   H.p (toHtml "Now you can compile your files with the profile you want:")
   H.table $ forM_ (profs `zip` [0..]) $ \(prof,(i::Int)) -> do
      H.tr $ do
         H.td $ H.a (toHtml (profileName prof)) ! A.href (toValue ("/compilation/"++show i))
         H.td $ toHtml (profileDesc prof)

showCompilation :: Int -> Compilation -> Html
showCompilation i comp = do
   H.h1 (toHtml "GHC configuration used for this build")
   showDynFlags (compilFlags comp)
   H.h1 (toHtml "Analyse")

   H.h2 (toHtml "Phases: summary")
   showPhasesSummary comp

   H.h2 (toHtml "Core Phases: summary")
   showCoreSizeEvolution i comp

   H.h2 (toHtml "Phases: details")
   showPhases i comp
   H.br

   H.div
      (H.a (toHtml "View full log")
            ! A.href (toValue ("/compilation/"++show i++"/logs"))
      ) ! A.style (toValue "margin:auto; text-align:center")

   H.h2 (toHtml "Sources with inline logs:")
   H.table (forM_ (compilSources comp) $ \f -> H.tr $ do
      H.td $ H.a (toHtml (toHtml (fileName f)))
         ! A.href (toValue ("/compilation/"++show i++"/logs?file="++fileName f))
      ) ! A.class_ (toValue "phaseTable")


showLogs :: Maybe String -> Compilation -> Html
showLogs fileFilter comp = do
   let
      logFilter clog = case (fileFilter,logLocation clog) of
         (Nothing,_)      -> True
         (Just f, Just s) -> locFile s == f
         _                -> False
      logs = filter logFilter (compilLogs comp)

   case fileFilter of
      Nothing -> showLogTable logs
      Just f  -> do
         let
            pos = locEndLine . fromJust . logLocation
            ers = sortOn fst
                     $ fmap (\x -> (locEndLine $ fromJust $ logLocation $ head x,x))
                     $ groupOn pos
                     $ sortOn pos
                     $ filter (isJust . logLocation) logs

            file   = head (filter ((== f) . fileName) (compilSources comp))
            source = highlightAs "haskell" (fileContents file)

            go _           []  []               = return ()
            go currentLine src []               = do
               let opts = defaultFormatOpts
                     { numberLines = True
                     , startNumber = currentLine+1
                     }
               formatHtmlBlock opts src
            go currentLine src ((n,errs):errors)
               | n == currentLine = showLogTable errs >> go (currentLine+1) src errors
               | otherwise        = do
                  let (src1,src2) = splitAt (n - currentLine) src
                  let opts = defaultFormatOpts
                        { numberLines = True
                        , startNumber = currentLine+1
                        }
                  formatHtmlBlock opts src1
                  showLogTable errs
                  go n src2 errors

         H.h2 (toHtml "Source inlined logs:")
         H.div $ toHtml $ go 0 source ers

showLogTable :: [Log] -> Html
showLogTable logs = do
   H.table (do
      H.tr $ do
         H.th (toHtml "Severity")
         H.th (toHtml "Reason")
         H.th (toHtml "Location")
         H.th (toHtml "Message")
      forM_ logs $ \clog -> do
         H.tr $ do
            H.td $ toHtml $ case logSeverity clog of
               SevOutput      -> "Output"
               SevFatal       -> "Fatal"
               SevInteractive -> "Interactive"
               SevDump        -> "Dump"
               SevInfo        -> "Info"
               SevWarning     -> "Warning"
               SevError       -> "Error"
            H.td (toHtml $ case logReason clog of
               NoReason    -> "None"
               Reason flag -> getWarningFlagName flag)
               ! A.style (toValue ("min-width: 12em"))
            H.td (toHtml $ case logLocation clog of
               Nothing -> "None"
               Just s  -> locFile s
                  ++ " (" ++ show (locStartLine s)
                  ++ "," ++ show (locStartCol  s)
                  ++ ") -> (" ++ show (locEndLine s)
                  ++ "," ++ show (locEndCol  s) ++ ")")
               ! A.style (toValue ("min-width: 12em"))
            H.td (H.pre $ toHtml $
               renderWithStyle (logDynFlags clog) (logMessage clog) (logStyle clog)
               ) ! A.class_ (toValue "logTableMessage")
         ) ! A.class_ (toValue "logtable")


getFlagName :: (Show a, Enum a) => Maybe [FlagSpec a] -> a -> String
getFlagName specs opt = case specs of
      Nothing -> show opt
      Just ss -> case filter ((== fromEnum opt) . fromEnum . flagSpecFlag) ss of
         []    -> show opt
         (x:_) -> flagSpecName x

getWarningFlagName :: WarningFlag -> String
getWarningFlagName = getFlagName (Just wWarningFlags)

showDynFlags :: DynFlags -> Html
showDynFlags dflags = do
   let showFlagEnum :: (Show a, Enum a) => String -> Maybe [FlagSpec a] -> (a -> Bool) -> Html
       showFlagEnum lbl specs test = do
         H.td $ do
            H.label (toHtml lbl)
            H.br
            H.select (forM_ (sortOn (getFlagName specs) (enumFrom (toEnum 0))) $ \opt -> do
               let name = getFlagName specs opt
               H.option (toHtml name)
                     ! (if not (test opt)
                           then A.style (toValue "color:red")
                           else mempty)
                     ! A.value (toValue (show (fromEnum opt)))
               ) ! (A.size (toValue "12"))


   
   H.div (H.table $ H.tr $ do
      showFlagEnum "General flags:" (Just fFlags) (`gopt` dflags)
      showFlagEnum "Dump flags:" Nothing (`dopt` dflags)
      showFlagEnum "Warning flags:" (Just wWarningFlags) (`wopt` dflags)
      showFlagEnum "Extensions:" (Just xFlags) (`xopt` dflags)

      H.tr $ H.td $ do
         H.table $ do
            H.tr $ do
               H.td $ H.label (toHtml "Verbosity level: ")
               H.td $ H.select (forM_ [0..5] $ \(v :: Int) -> 
                  H.option (toHtml (show v))
                     ! (if v == verbosity dflags
                        then A.selected (toValue "selected")
                        else mempty)
                  ) ! A.disabled (toValue "disabled")

            H.tr $ do
               H.td $ H.label (toHtml "Optimization level: ")
               H.td $ H.select (forM_ [0..2] $ \(v :: Int) -> 
                  H.option (toHtml (show v))
                     ! (if v == optLevel dflags
                        then A.selected (toValue "selected")
                        else mempty)
                  ) ! A.disabled (toValue "disabled")

            H.tr $ do
               H.td $ H.label (toHtml "Debug level: ")
               H.td $ H.select (forM_ [0..2] $ \(v :: Int) -> 
                  H.option (toHtml (show v))
                     ! (if v == debugLevel dflags
                        then A.selected (toValue "selected")
                        else mempty)
                  ) ! A.disabled (toValue "disabled")
      ) ! A.class_ (toValue "dynflags")


data PhaseBegin = PhaseBegin
   { phaseBeginName   :: String
   , phaseBeginModule :: Maybe String
   } deriving (Show)

data PhaseStat = PhaseStat
   { phaseStatDuration :: Float
   , phaseStatMemory   :: Float
   } deriving (Show)

data PhaseCoreSize = PhaseCoreSize
   { phaseCoreSizeName      :: String
   , phaseCoreSizeTerms     :: Word
   , phaseCoreSizeTypes     :: Word
   , phaseCoreSizeCoercions :: Word
   } deriving (Show)

data PhaseLog
   = PhaseRawLog [Log]
   | PhaseCoreSizeLog PhaseCoreSize
   | PhaseDumpLog [Block]

data PhaseInfo = PhaseInfo
   { phaseName        :: String
   , phaseModule      :: Maybe String
   , phaseDuration    :: Float
   , phaseMemory      :: Float
   , phaseLog         :: [PhaseLog]
   }

emptyPhaseInfo :: PhaseInfo
emptyPhaseInfo = PhaseInfo
   { phaseName     = ""
   , phaseModule   = Nothing
   , phaseDuration = 0
   , phaseMemory   = 0
   , phaseLog      = []
   }
   

showPhase :: Compilation -> PhaseInfo -> Html
showPhase _ phase = do
   H.h2 $ toHtml ("Phase: " ++ phaseName phase)
   forM_ (phaseLog phase) $ \case
      PhaseRawLog ls  -> showLogTable ls
      PhaseCoreSizeLog s  ->
         H.table (do
            H.tr $ do
               H.th (toHtml "Pass")
               H.th (toHtml "Terms")
               H.th (toHtml "Types")
               H.th (toHtml "Coercions")
            H.tr $ do
               H.td $ toHtml (phaseCoreSizeName s)
               H.td $ toHtml (show (phaseCoreSizeTerms s))
               H.td $ toHtml (show (phaseCoreSizeTypes s))
               H.td $ toHtml (show (phaseCoreSizeCoercions s))
            ) ! A.class_ (toValue "phaseTable")
      PhaseDumpLog bs -> forM_ bs showBlock


showPhases :: Int -> Compilation -> Html
showPhases compIdx comp = do
   let phases = compilPhases comp
   H.table (do
      H.tr $ do
         H.th (toHtml "Phase")
         H.th (toHtml "Module")
         H.th (toHtml "Duration (ms)")
         H.th (toHtml "Memory (MB)")
      forM_ (phases `zip` [0..]) $ \(s,(idx :: Int)) -> H.tr $ do
         case phaseLog s of
            [] -> H.td (toHtml (phaseName s))
            _  -> H.td $ H.a (toHtml (phaseName s))
               ! A.href (toValue ("/compilation/"++show compIdx ++"/phase/"++show idx))
         H.td $ toHtml (fromMaybe "-" (phaseModule s))
         H.td $ htmlFloat (phaseDuration s)
         H.td $ htmlFloat (phaseMemory s)
      H.tr (do
         H.th $ toHtml "Total"
         H.th $ toHtml "-"
         H.td $ htmlFloat (sum (phaseDuration <$> phases))
         H.td $ htmlFloat (sum (phaseMemory <$> phases))
         ) ! A.style (toValue "border-top: 1px gray solid")
      ) ! A.class_ (toValue "phaseTable")

htmlFloat :: Float -> Html
htmlFloat f = toHtml (showFFloat (Just 2) f "")

showCoreSizeEvolution :: Int -> Compilation -> Html
showCoreSizeEvolution compIdx comp = do
   let phases = compilPhases comp
   H.table (do
      H.tr $ do
         H.th (toHtml "Module")
         H.th (toHtml "Phase")
         H.th (toHtml "Pass")
         H.th (toHtml "Terms")
         H.th (toHtml "Types")
         H.th (toHtml "Coercions")
      forM_ (phases `zip` [0..]) $ \(phase,(pid :: Int)) -> do
         forM_ (phaseLog phase) $ \case
            PhaseCoreSizeLog s -> H.tr $ do 
               H.td $ toHtml (fromMaybe "-" (phaseModule phase))
               H.td $ H.a (toHtml (phaseName phase))
                  ! A.href (toValue ("/compilation/"++show compIdx++"/phase/"++show pid))
               H.td $ toHtml (phaseCoreSizeName s)
               H.td $ toHtml (show (phaseCoreSizeTerms s))
               H.td $ toHtml (show (phaseCoreSizeTypes s))
               H.td $ toHtml (show (phaseCoreSizeCoercions s))
            _ -> return ()
      ) ! A.class_ (toValue "phaseTable")

showPhasesSummary :: Compilation -> Html
showPhasesSummary comp = do
   let phases = compilPhases comp
       groups = groupOn phaseName (sortOn phaseName phases)
       totmem = sum (phaseMemory <$> phases)
       totdur = sum (phaseDuration <$> phases)
       gstat  = fmap (\group ->
         let dur  = sum (fmap phaseDuration group)
             mem  = sum (fmap phaseMemory group)
             durp = dur / totdur * 100
             memp = mem / totmem * 100
         in (phaseName (head group),dur,mem,durp,memp)) groups
       gstat' = reverse $ sortOn (\(_,_,_,durp,memp) -> durp+memp) gstat
   H.table (do
      H.tr $ do
         H.th (toHtml "Phase")
         H.th (toHtml "Duration (%)")
         H.th (toHtml "Memory (%)")
         H.th (toHtml "Duration (ms)")
         H.th (toHtml "Memory (MB)")
      forM_ gstat' $ \(nam,dur,mem,durp,memp) -> H.tr $ do
         H.td $ toHtml nam
         H.td $ htmlFloat durp
         H.td $ htmlFloat memp
         H.td $ htmlFloat dur
         H.td $ htmlFloat mem
      H.tr (do
         H.th $ toHtml "Total"
         H.td $ htmlFloat 100
         H.td $ htmlFloat 100
         H.td $ htmlFloat totdur
         H.td $ htmlFloat totmem
         ) ! A.style (toValue "border-top: 1px gray solid")
      ) ! A.class_ (toValue "phaseTable")

makePhaseInfos :: [Log] -> [PhaseInfo]
makePhaseInfos = go $ emptyPhaseInfo { phaseName = iname }
   where
      iname = "****"
      
      go :: PhaseInfo -> [Log] -> [PhaseInfo]
      go c []     = [reverseLog c]
      go c (x:ls) =
         let l = logMessage' x in
         case parseMaybe parsePhaseBegin l of
            Just b  -> let c' = emptyPhaseInfo
                                 { phaseName     = phaseBeginName b
                                 , phaseModule   = phaseBeginModule b
                                 }
                       in case (phaseName c, phaseLog c) of
                           -- ditch empty intermediate phase
                           (n,[]) | n == iname -> go c' ls
                           _                   -> reverseLog c:go c' ls
            Nothing -> do
               case parseMaybe parsePhaseCoreSize l of
                  Just ps -> go (appendLog (PhaseCoreSizeLog ps) c) ls
                  Nothing -> case parseMaybe parsePhaseStat l of
                     Just ps -> let c' = c
                                       { phaseDuration = phaseStatDuration ps
                                       , phaseMemory   = phaseStatMemory ps
                                       }
                                in c' : go (emptyPhaseInfo { phaseName = iname}) ls
                     Nothing -> case logSeverity x of
                        SevDump -> go (appendLog (PhaseDumpLog (parseBlock "" l)) c) ls
                        _       -> case phaseLog c of
                           -- concat consecutive raw logs
                           (PhaseRawLog rl:rs) ->
                              let c' = c
                                    { phaseLog = PhaseRawLog (rl++[x]) : rs
                                    }
                               in go c' ls

                           _                  -> go (appendLog (PhaseRawLog [x]) c) ls
                        

      reverseLog :: PhaseInfo -> PhaseInfo
      reverseLog phi = phi { phaseLog = reverse (phaseLog phi)}

      appendLog :: PhaseLog -> PhaseInfo -> PhaseInfo
      appendLog l phi = phi { phaseLog = l:phaseLog phi }

      logMessage' l = showSDoc (logDynFlags l) (logMessage l)

      parsePhaseName :: Parser (String,Maybe String)
      parsePhaseName = 
         (try $ do
            phase <- manyTill anyChar (string " [")
            md    <- manyTill anyChar (char ']')
            void (char ':')
            return (phase, Just md)
         ) <|> (do
            phase <- manyTill anyChar (char ':')
            return (phase, Nothing)
         )

      parsePhaseBegin :: Parser PhaseBegin
      parsePhaseBegin = do
         void (string "*** ")
         (phase,md) <- parsePhaseName
         return $ PhaseBegin phase md

      parsePhaseStat :: Parser PhaseStat
      parsePhaseStat = do
         void (string "!!! ")
         void $ parsePhaseName
         void (string " finished in ")
         dur   <- read <$> manyTill anyChar (char ' ')
         void (string "milliseconds, allocated ")
         mem   <- read <$> manyTill anyChar (char ' ')
         void (string "megabytes")
         return $ PhaseStat dur mem

      parsePhaseCoreSize :: Parser PhaseCoreSize
      parsePhaseCoreSize = do
         void (string "Result size of ")
         phase <- manyTill anyChar (string "= {")
         void (string "terms: ")
         terms <- read <$> manyTill anyChar (char ',')
         void (string " types: ")
         typs <- read <$> manyTill anyChar (char ',')
         void (string " coercions: ")
         coes <- read <$> manyTill anyChar (char '}')
         return $ PhaseCoreSize phase terms typs coes

showBlock :: Block -> Html
showBlock block = do
   H.h4 (toHtml (blockName block))
   let dateStr = case blockDate block of
         Nothing -> "No date"
         Just x  -> show x
   H.div (toHtml dateStr) ! A.class_ (toValue "date")
   H.div $ toHtml
      $ formatHtmlBlock defaultFormatOpts
      $ highlightAs (selectFormat (blockFile block) (blockName block)) (blockContents block)

-- | Select highlighting format
selectFormat :: FilePath -> String -> String
selectFormat pth name
   | "Asm code"             `isInfixOf` name   = "nasm"
   | "Synthetic instructions expanded" == name = "nasm"
   | "Registers allocated"             == name = "nasm"
   | "Liveness annotations added"      == name = "nasm"
   | "Native code"                     == name = "nasm"
   | "Sink assignments"                == name = "c"
   | "Layout Stack"                    == name = "c"
   | "Post switch plan"                == name = "c"
   | "Post common block elimination"   == name = "c"
   | "Post control-flow optimisations" == name = "c"
   | "after setInfoTableStackMap"      == name = "c"
   | "Cmm"                  `isInfixOf` name   = "c"
   | "Common sub-expression"           == name = "haskell"
   | "Occurrence analysis"             == name = "haskell"
   | "worker Wrapper binds"            == name = "haskell"
   | "Demand analysis"                 == name = "haskell"
   | "Called arity analysis"           == name = "haskell"
   | "Specialise"                      == name = "haskell"
   | "Desugar"              `isInfixOf` name   = "haskell"
   | "STG"                  `isInfixOf` name   = "haskell"
   | "Parser"                          == name = "haskell"
   | ".dump-asm"            `isPrefixOf` ext   = "nasm"
   | ".dump-cmm"            `isPrefixOf` ext   = "c"
   | ".dump-opt-cmm"        `isPrefixOf` ext   = "c"
   | ".dump-ds"             `isPrefixOf` ext   = "haskell"
   | ".dump-occur"          `isPrefixOf` ext   = "haskell"
   | ".dump-stranal"        `isPrefixOf` ext   = "haskell"
   | ".dump-spec"           `isPrefixOf` ext   = "haskell"
   | ".dump-cse"            `isPrefixOf` ext   = "haskell"
   | ".dump-call-arity"     `isPrefixOf` ext   = "haskell"
   | ".dump-worker-wrapper" `isPrefixOf` ext   = "haskell"
   | ".dump-parsed"         `isPrefixOf` ext   = "haskell"
   | ".dump-prep"           `isPrefixOf` ext   = "haskell"
   | ".dump-stg"            `isPrefixOf` ext   = "haskell"
   | ".dump-simpl"          `isPrefixOf` ext   = "haskell"
   | ".dump-foreign"        `isPrefixOf` ext   = if "header file" `isSuffixOf` name
                                                     then "c"
                                                     else "haskell"
   | otherwise                                 = ""
   where
      ext = takeExtension pth
   
   


data Block = Block
   { blockFile     :: String
   , blockName     :: String
   , blockDate     :: Maybe UTCTime
   , blockContents :: String
   }

parseBlock :: String -> String -> [Block]
parseBlock name contents = case runParser blocks name contents of
      Right x -> x
      Left e  -> [Block name "Whole file"
                  Nothing
                  (contents ++ "\n\n==== Parse error ====\n" ++ show e)]
   where
      blockMark = do
         void eol
         void $ count 20 (char '=')

      blockHead = do
         blockMark
         void $ char ' '
         bname <- init <$> manyTill anyChar (char '=')
         void $ count 19 (char '=')
         void eol
         dateStr <- lookAhead (manyTill anyChar (eol <|> (eof >> return "")))
         -- date isn't always present (e.g., typechecker dumps)
         date <- if "UTC" `isSuffixOf` dateStr
            then do
               void (manyTill anyChar eol)
               void eol
               return (Just (read dateStr))
            else return Nothing
         return (bname,date)

      block = do
         (bname,date) <- blockHead
         bcontents <- manyTill anyChar (try (lookAhead blockMark) <|> eof)
         return (Block name bname date bcontents)

      blocks :: Parser [Block]
      blocks = many block


enableWarningGroup :: String -> DynFlags -> DynFlags
enableWarningGroup groupName dflags = case Map.lookup groupName groups of
      Nothing   -> error $ "Invalid warning flag group: " ++ show groupName
                     ++ ". Expecting one of: " ++ show (Map.keys groups)
      Just flgs -> foldl' wopt_set dflags flgs
   where
      groups = Map.fromList warningGroups


----------------------------------------------
-- TODO: remove these once GHC exports them


warningGroups :: [(String, [WarningFlag])]
warningGroups =
    [ ("compat",       minusWcompatOpts)
    , ("unused-binds", unusedBindsFlags)
    , ("default",      standardWarnings)
    , ("extra",        minusWOpts)
    , ("all",          minusWallOpts)
    , ("everything",   minusWeverythingOpts)
    ]


-- | Warnings enabled unless specified otherwise
standardWarnings :: [WarningFlag]
standardWarnings -- see Note [Documenting warning flags]
    = [ Opt_WarnOverlappingPatterns,
        Opt_WarnWarningsDeprecations,
        Opt_WarnDeprecatedFlags,
        Opt_WarnDeferredTypeErrors,
        Opt_WarnTypedHoles,
        Opt_WarnPartialTypeSignatures,
        Opt_WarnUnrecognisedPragmas,
        Opt_WarnDuplicateExports,
        Opt_WarnOverflowedLiterals,
        Opt_WarnEmptyEnumerations,
        Opt_WarnMissingFields,
        Opt_WarnMissingMethods,
        Opt_WarnWrongDoBind,
        Opt_WarnUnsupportedCallingConventions,
        Opt_WarnDodgyForeignImports,
        Opt_WarnInlineRuleShadowing,
        Opt_WarnAlternativeLayoutRuleTransitional,
        Opt_WarnUnsupportedLlvmVersion,
        Opt_WarnTabs,
        Opt_WarnUnrecognisedWarningFlags
      ]

-- | Things you get with -W
minusWOpts :: [WarningFlag]
minusWOpts
    = standardWarnings ++
      [ Opt_WarnUnusedTopBinds,
        Opt_WarnUnusedLocalBinds,
        Opt_WarnUnusedPatternBinds,
        Opt_WarnUnusedMatches,
        Opt_WarnUnusedForalls,
        Opt_WarnUnusedImports,
        Opt_WarnIncompletePatterns,
        Opt_WarnDodgyExports,
        Opt_WarnDodgyImports
      ]

-- | Things you get with -Wall
minusWallOpts :: [WarningFlag]
minusWallOpts
    = minusWOpts ++
      [ Opt_WarnTypeDefaults,
        Opt_WarnNameShadowing,
        Opt_WarnMissingSignatures,
        Opt_WarnHiShadows,
        Opt_WarnOrphans,
        Opt_WarnUnusedDoBind,
        Opt_WarnTrustworthySafe,
        Opt_WarnUntickedPromotedConstructors,
        Opt_WarnMissingPatternSynonymSignatures
      ]

-- | Things you get with -Weverything, i.e. *all* known warnings flags
minusWeverythingOpts :: [WarningFlag]
minusWeverythingOpts = [ toEnum 0 .. ]

-- | Things you get with -Wcompat.
--
-- This is intended to group together warnings that will be enabled by default
-- at some point in the future, so that library authors eager to make their
-- code future compatible to fix issues before they even generate warnings.
minusWcompatOpts :: [WarningFlag]
minusWcompatOpts
    = [ Opt_WarnMissingMonadFailInstances
      , Opt_WarnSemigroup
      , Opt_WarnNonCanonicalMonoidInstances
      ]

-- Things you get with -Wunused-binds
unusedBindsFlags :: [WarningFlag]
unusedBindsFlags = [ Opt_WarnUnusedTopBinds
                   , Opt_WarnUnusedLocalBinds
                   , Opt_WarnUnusedPatternBinds
                   ]
