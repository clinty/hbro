{-# LANGUAGE DoRec #-}
module Main where

-- {{{ Imports
import Hbro.Core
import qualified Hbro.Extra.Bookmarks as Bookmarks
import qualified Hbro.Extra.BookmarksQueue as Queue
import Hbro.Extra.Clipboard
import qualified Hbro.Extra.History as History
import Hbro.Extra.Misc
import Hbro.Extra.Session
import Hbro.Extra.StatusBar
import Hbro.Gui
import Hbro.Keys
import Hbro.Socket
import Hbro.Types
import Hbro.Util

import Graphics.UI.Gtk.Abstract.Widget
import Graphics.UI.Gtk.Builder
import Graphics.UI.Gtk.Display.Label
import Graphics.UI.Gtk.Entry.Entry
import Graphics.UI.Gtk.Gdk.EventM
import Graphics.UI.Gtk.Gdk.GC
import Graphics.UI.Gtk.General.General
import Graphics.UI.Gtk.WebKit.Download
import Graphics.UI.Gtk.WebKit.NetworkRequest
import Graphics.UI.Gtk.WebKit.WebNavigationAction
import Graphics.UI.Gtk.WebKit.WebPolicyDecision
import Graphics.UI.Gtk.WebKit.WebSettings
import Graphics.UI.Gtk.WebKit.WebView
import Graphics.UI.Gtk.Windows.Window

import System.Directory
import System.Environment
import System.Environment.XDG.BaseDir
import System.Glib.Attributes
import System.Glib.Signals
-- import System.Posix.Process
import System.Process 
-- }}}

-- Main function, expected to call launchHbro.
-- You can add custom tasks before & after calling it.
main :: IO ()
main = launchHbro myConfig

-- A structure containing your configuration settings, overriding
-- fields in the default config. Any you don't override, will     
-- use the defaults defined in Hbro.Types.Parameters.
myConfig :: CommonDirectories -> Config
myConfig directories = (defaultConfig directories) {
    mSocketDir        = mySocketDirectory directories,
    mUIFile           = myUIFile directories,
    mKeyEventHandler  = myKeyEventHandler,
    mKeyEventCallback = myKeyEventCallback,
    mHomePage         = myHomePage,
    mWebSettings      = myWebSettings,
    mSetup            = mySetup
}

-- Various constant parameters
myHomePage = "https://duckduckgo.com"

mySocketDirectory :: CommonDirectories -> FilePath
mySocketDirectory directories = mTemporary directories

myUIFile :: CommonDirectories -> FilePath
myUIFile directories = (mConfiguration directories) ++ "/ui.xml"

myHistoryFile :: CommonDirectories -> FilePath
myHistoryFile directories = (mData directories) ++ "/history"

myBookmarksFile :: CommonDirectories -> FilePath
myBookmarksFile directories = (mData directories) ++ "/bookmarks"

-- How to download files
myDownload :: CommonDirectories -> String -> String -> IO ()
myDownload directories uri name = spawn "aria2c" [uri, "-d", (mHome directories) ++ "/", "-o", name]
--myDownload directories uri name = spawn "wget" [uri, "-O", (mHome directories) ++ "/" ++ name]
--myDownload directories uri name = spawn "axel" [uri, "-o", (mHome directories) ++ "/" ++ name]
    
myKeyEventHandler :: KeyEventCallback -> ConnectId WebView -> WebView -> EventM EKey Bool
myKeyEventHandler = advancedKeyEventHandler

myKeyEventCallback :: Environment -> KeyEventCallback
myKeyEventCallback environment@Environment{ mGUI = gui } modifiers keys = do
    keysLabel <- builderGetObject builder castToLabel "keys"
    withFeedback keysLabel (simpleKeyEventCallback $ keysListToMap (myKeys environment)) modifiers keys
  where
    builder = mBuilder gui


-- {{{ Keys
-- Note that this example is suited for an azerty keyboard.
myKeys :: Environment -> KeysList
myKeys environment@Environment{ mGUI = gui, mConfig = config, mContext = context } = let
    window         = mWindow       gui
    webView        = mWebView      gui
    scrolledWindow = mScrollWindow gui
    statusBox      = mStatusBox    gui
    promptBar      = mPromptBar    gui
    promptEntry    = mEntry promptBar
    bookmarksFile  = myBookmarksFile (mCommonDirectories config)
    historyFile    = myHistoryFile   (mCommonDirectories config)
    socketDir      = mSocketDir config
  in  
    [
--  ((modifiers,        key),           callback)
-- Browse
    (([Control],        "<Left>"),      webViewGoBack    webView),
    (([Control],        "<Right>"),     webViewGoForward webView),
    (([Alt],            "<Left>"),      (goBackList    webView ["-l", "10"]) >>= maybe (return ()) (loadURI webView)),
    (([Alt],            "<Right>"),     (goForwardList webView ["-l", "10"]) >>= maybe (return ()) (loadURI webView)),
    (([Control],        "s"),           webViewStopLoading       webView),
    (([],               "<F5>"),        webViewReload            webView),
    (([Control],        "<F5>"),        webViewReloadBypassCache webView),
    (([Control],        "^"),           goLeft   scrolledWindow),
    (([Control],        "$"),           goRight  scrolledWindow),
    (([Control],        "<Home>"),      goTop    scrolledWindow),
    (([Control],        "<End>"),       goBottom scrolledWindow),
    (([Alt],            "<Home>"),      goHome webView config),
    (([Control],        "g"),           prompt "Google search" "" (\words -> loadURI webView ("https://www.google.com/search?q=" ++ words)) gui),

-- Display
    (([Control, Shift], "+"),           webViewZoomIn    webView),
    (([Control],        "-"),           webViewZoomOut   webView),
    (([],               "<F11>"),       windowFullscreen   window),
    (([],               "<Escape>"),    windowUnfullscreen window),
    (([Control],        "b"),           toggleVisibility statusBox),
    (([Control],        "u"),           toggleSourceMode webView),

-- Prompt
    (([Control],        "o"),           prompt "Open URL " "" (loadURI webView) gui),
    (([Control, Shift], "O"),           webViewGetUri webView >>= maybe (return ()) (\uri -> prompt "Open URL " uri (loadURI webView) gui)),

-- Search
    (([Shift],          "/"),           promptIncremental "Search " "" (\word -> webViewSearchText webView word False True True >> return ()) gui),
    (([Control],        "f"),           promptIncremental "Search " "" (\word -> webViewSearchText webView word False True True >> return ()) gui),
    (([Shift],          "?"),           promptIncremental "Search " "" (\word -> webViewSearchText webView word False False True >> return ()) gui),
    (([Control],        "n"),           entryGetText promptEntry >>= \word -> webViewSearchText webView word False True True >> return ()),
    (([Control, Shift], "N"),           entryGetText promptEntry >>= \word -> webViewSearchText webView word False False True >> return ()),

-- Copy/paste
    (([Control],        "y"),           webViewGetUri   webView >>= maybe (return ()) toClipboard),
    (([Control, Shift], "Y"),           webViewGetTitle webView >>= maybe (return ()) toClipboard),
    (([Control],        "p"),           withClipboard $ maybe (return ()) (loadURI webView)),
    (([Control, Shift], "P"),           withClipboard $ maybe (return ()) (\uri -> spawn "hbro" ["-u", uri])),

-- Misc
    (([],               "<Escape>"),    widgetHide $ mBox promptBar),
    (([Control],        "i"),           showWebInspector webView),
    (([Alt],            "p"),           printPage        webView),
    (([Control],        "t"),           spawn "hbro" []),
    (([Control],        "w"),           mainQuit),

-- Bookmarks
    (([Control],        "d"),           webViewGetUri webView >>= maybe (return ()) (\uri -> prompt "Bookmark with tags:" "" (\tags -> Bookmarks.add bookmarksFile uri (words tags)) gui)),
    (([Control, Shift], "D"),           prompt "Bookmark all instances with tag:" "" (\tags -> sendCommandToAll context socketDir "GET_URI" >>= mapM (\uri -> Bookmarks.add bookmarksFile uri $ words tags) >> (webViewGetUri webView) >>= maybe (return ()) (\uri -> Bookmarks.add bookmarksFile uri $ words tags) >> return ()) gui),
    (([Alt],            "d"),           Bookmarks.deleteWithTag bookmarksFile ["-l", "10"]),
    (([Control],        "l"),           Bookmarks.select        bookmarksFile ["-l", "10"] >>= maybe (return ()) (loadURI webView)),
    (([Control, Shift], "L"),           Bookmarks.selectTag     bookmarksFile ["-l", "10"] >>= maybe (return ()) (\uris -> mapM (\uri -> spawn "hbro" ["-u", uri]) uris >> return ())),
--    (([Control],        "q"),           webViewGetUri webView >>= maybe (return ()) (Queue.append),
--    (([Alt],            "q"),           \b -> do
--        uri <- Queue.popFront
--        loadURI uri b),

-- History
    (([Control],        "h"),           History.select historyFile ["-l", "10"] >>= maybe (return ()) (loadURI webView))
    
-- Session
    --(([Alt],            "l"),           loadFromSession ["-l", "10"])
    ]
-- }}}

-- {{{ Web settings
-- Commented out lines correspond to default values.
myWebSettings :: [AttrOp WebSettings]
myWebSettings = [
--  SETTING                                        VALUE 
    --webSettingsCursiveFontFamily              := "serif",
    --webSettingsDefaultFontFamily              := "sans-serif",
    --webSettingsFantasyFontFamily              := ,
    --webSettingsMonospaceFontFamily            := "monospace",
    --webSettingsSansFontFamily                 := "sans-serif",
    --webSettingsSerifFontFamily                := "serif",
    --webSettingsDefaultFontSize                := ,
    --webSettingsDefaultMonospaceFontSize       := 10,
    --webSettingsMinimumFontSize                := 5,
    --webSettingsMinimumLogicalFontSize         := 5,
    --webSettingsAutoLoadImages                 := True,
    --webSettingsAutoShrinkImages               := True,
    --webSettingsDefaultEncoding                := "iso-8859-1",
    --webSettingsEditingBehavior                := EditingBehaviorWindows,
    --webSettingsEnableCaretBrowsing              := False,
    webSettingsEnableDeveloperExtras            := True,
    --webSettingsEnableHtml5Database              := True,
    --webSettingsEnableHtml5LocalStorage          := True,
    --webSettingsEnableOfflineWebApplicationCache := True,
    webSettingsEnablePlugins                    := True,
    webSettingsEnablePrivateBrowsing            := False, -- Experimental
    webSettingsEnableScripts                    := False,
    --webSettingsEnableSpellChecking              := False,
    webSettingsEnableUniversalAccessFromFileUris := True,
    webSettingsEnableXssAuditor                 := True,
    --webSettingsEnableSiteSpecificQuirks       := False,
    --webSettingsEnableDomPaste                 := False,
    --webSettingsEnableDefaultContextMenu       := True,
    webSettingsEnablePageCache                  := True,
    --webSettingsEnableSpatialNavigation        := False,
    --webSettingsEnforce96Dpi                   := ,
    webSettingsJSCanOpenWindowAuto              := True,
    --webSettingsPrintBackgrounds               := True,
    --webSettingsResizableTextAreas             := True,
    webSettingsSpellCheckingLang                := Just "en_US",
    --webSettingsTabKeyCyclesThroughElements    := True,
    webSettingsUserAgent                        := "Mozilla/5.0 (X11; Linux x86_64; rv:2.0.1) Gecko/20100101 Firefox/4.0.1"
    --webSettingsUserStylesheetUri              := Nothing,
    --webSettingsZoomStep                       := 0.1
    ]
-- }}}

-- {{{ Setup
mySetup :: Environment -> IO ()
mySetup environment@Environment{ mGUI = gui, mConfig = config } = 
    let
        builder         = mBuilder      gui 
        webView         = mWebView      gui
        scrolledWindow  = mScrollWindow gui
        window          = mWindow       gui
        directories     = mCommonDirectories config
        historyFile     = myHistoryFile directories
        getLabel        = builderGetObject builder castToLabel
    in do
    -- Scroll position in status bar
        scrollLabel <- getLabel "scroll"
        setupScrollWidget scrollLabel scrolledWindow
    
    -- Zoom level in status bar
        zoomLabel <- getLabel "zoom"
        statusBarZoomLevel zoomLabel webView
                
    -- Load progress in status bar
        progressLabel <- getLabel "progress"
        statusBarLoadProgress progressLabel webView
        
    -- Current URI in status bar
        uriLabel <- getLabel "uri"
        statusBarURI uriLabel webView
        
    -- Session manager
        --setupSession browser

    -- 
        _ <- on webView titleChanged $ \_ title ->
            set window [ windowTitle := ("hbro | " ++ title)]

    -- Download requests
        feedbackLabel <- getLabel "feedback"
        _ <- on webView downloadRequested $ \download -> do
            uri  <- downloadGetUri download
            name <- downloadGetSuggestedFilename download
            size <- downloadGetTotalSize download

            case (uri, name) of
                (Just uri', Just name') -> do
                    myDownload directories uri' name' 
                    labelSetMarkupTemporary feedbackLabel "<span foreground=\"green\">Download started</span>" 5000
                _ -> labelSetMarkupTemporary feedbackLabel "<span foreground=\"red\">Unable to download</span>" 5000
            return False

    -- Per MIME actions
        _ <- on webView mimeTypePolicyDecisionRequested $ \_ request mimetype policyDecision -> do
            show <- webViewCanShowMimeType webView mimetype

            case (show, mimetype) of
                (True, _) -> webPolicyDecisionUse policyDecision >> return True
                _         -> webPolicyDecisionDownload policyDecision >> return True

    -- History handler
        _ <- on webView loadFinished $ \_ -> do
            uri   <- webViewGetUri   webView
            title <- webViewGetTitle webView
            case (uri, title) of
                (Just uri', Just title') -> History.add historyFile uri' title'
                _ -> return ()

    -- On navigating to a new URI
    -- Return True to forbid navigation, False to allow
        _ <- on webView navigationPolicyDecisionRequested $ \_ request action policyDecision -> do
            getUri      <- networkRequestGetUri request
            reason      <- webNavigationActionGetReason action
            mouseButton <- webNavigationActionGetButton action

            case getUri of
                Just ('m':'a':'i':'l':'t':'o':':':address) -> do
                    putStrLn $ "Mailing to: " ++ address
                    return True
                Just uri -> 
                    case mouseButton of
                        1 -> return False -- Left button 
                        2 -> spawn "hbro" ["-u", uri] >> putStrLn uri >> return True -- Middle button
                        3 -> return False -- Right button
                        _ -> return False -- No mouse button pressed
                _        -> return False
            
    -- On requesting new window
        _ <- on webView newWindowPolicyDecisionRequested $ \_ request action policyDecision -> do
            getUri <- networkRequestGetUri request
            case getUri of
                Just uri -> (spawn "hbro" ["-u", uri]) >> putStrLn uri
                _        -> putStrLn "ERROR: wrong URI given, unable to open window."

            return True

    -- Favicon
        --_ <- on webView iconLoaded $ \uri -> do something

        return ()
-- }}}
