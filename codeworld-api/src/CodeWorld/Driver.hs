{-# LANGUAGE CPP                      #-}
{-# LANGUAGE DefaultSignatures        #-}
{-# LANGUAGE DeriveGeneric            #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE JavaScriptFFI            #-}
{-# LANGUAGE KindSignatures           #-}
{-# LANGUAGE LambdaCase               #-}
{-# LANGUAGE MultiWayIf               #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE PatternGuards            #-}
{-# LANGUAGE RecordWildCards          #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE StandaloneDeriving       #-}
{-# LANGUAGE DataKinds                #-}

{-
  Copyright 2016 The CodeWorld Authors. All rights reserved.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
-}

module CodeWorld.Driver (
    drawingOf,
    animationOf,
    simulationOf,
    interactionOf,
    collaborationOf,
    unsafeCollaborationOf,
    trace
    ) where

import           CodeWorld.Color
import           CodeWorld.Event
import           CodeWorld.Picture
import           CodeWorld.Prediction
import           CodeWorld.Message
import           CodeWorld.CollaborationUI (SetupPhase(..), Step(..), UIState)
import qualified CodeWorld.CollaborationUI as CUI
import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Concurrent.Chan
import           Control.Exception
import           Control.Monad
import           Control.Monad.Trans (liftIO)
import           Data.Char (chr)
import           Data.List (zip4)
import           Data.Maybe (fromMaybe, mapMaybe)
import           Data.Monoid
import           Data.Serialize
import           Data.Serialize.Text
import qualified Data.Text as T
import           Data.Text (Text, singleton, pack)
import           GHC.Fingerprint.Type
import           GHC.Generics
import           GHC.StaticPtr
import           Numeric
import           System.Environment
import           System.Mem.StableName
import           Text.Read
import           System.Random

#ifdef ghcjs_HOST_OS

import           Data.Hashable
import           Data.IORef
import           Data.JSString.Text
import qualified Data.JSString
import           Data.Time.Clock
import           Data.Word
import           GHCJS.DOM
import           GHCJS.DOM.Window as Window
import           GHCJS.DOM.Document
import qualified GHCJS.DOM.ClientRect as ClientRect
import           GHCJS.DOM.Element
import           GHCJS.DOM.EventM
import           GHCJS.DOM.MouseEvent
import           GHCJS.DOM.Types (Element, unElement)
import           GHCJS.Foreign
import           GHCJS.Marshal
import           GHCJS.Marshal.Pure
import           GHCJS.Types
import           JavaScript.Web.AnimationFrame
import qualified JavaScript.Web.Canvas as Canvas
import qualified JavaScript.Web.Canvas.Internal as Canvas
import qualified JavaScript.Web.Location as Loc
import qualified JavaScript.Web.MessageEvent as WS
import qualified JavaScript.Web.WebSocket as WS
import           System.IO.Unsafe

#else

import           Data.Time.Clock
import qualified Debug.Trace
import qualified Graphics.Blank as Canvas
import           Graphics.Blank (Canvas)
import           System.IO
import           Text.Printf

#endif

--------------------------------------------------------------------------------
-- The common interface, provided by both implementations below.

-- | Draws a 'Picture'.  This is the simplest CodeWorld entry point.
drawingOf :: Picture -> IO ()

-- | Shows an animation, with a picture for each time given by the parameter.
animationOf :: (Double -> Picture) -> IO ()

-- | Shows a simulation, which is essentially a continuous-time dynamical
-- system described by an initial value and step function.
simulationOf :: world -> (Double -> world -> world) -> (world -> Picture) -> IO ()

-- | Runs an interactive event-driven CodeWorld program.  This is a
-- generalization of simulations that can respond to events like key presses
-- and mouse movement.
interactionOf :: world
              -> (Double -> world -> world)
              -> (Event -> world -> world)
              -> (world -> Picture)
              -> IO ()

-- | Runs an interactive multi-user CodeWorld program, involving multiple
-- participants over the internet.
collaborationOf :: Int
                -> StaticPtr (StdGen -> world)
                -> StaticPtr (Double -> world -> world)
                -> StaticPtr (Int -> Event -> world -> world)
                -> StaticPtr (Int -> world -> Picture)
                -> IO ()

-- | A version of 'collaborationOf' that avoids static pointers, and does not
-- check for consistent parameters.
unsafeCollaborationOf :: Int
                      -> (StdGen -> world)
                      -> (Double -> world -> world)
                      -> (Int -> Event -> world -> world)
                      -> (Int -> world -> Picture)
                      -> IO ()

-- | Prints a debug message to the CodeWorld console when a value is forced.
-- This is equivalent to the similarly named function in `Debug.Trace`, except
-- that it uses the CodeWorld console instead of standard output.
trace :: Text -> a -> a

--------------------------------------------------------------------------------
-- Draw state.  An affine transformation matrix, plus a Bool indicating whether
-- a color has been chosen yet.

type DrawState = (Double, Double, Double, Double, Double, Double, Maybe Color)

initialDS :: DrawState
initialDS = (1, 0, 0, 1, 0, 0, Nothing)

translateDS :: Double -> Double -> DrawState -> DrawState
translateDS x y (a,b,c,d,e,f,hc) =
    (a, b, c, d, a*25*x + c*25*y + e, b*25*x + d*25*y + f, hc)

scaleDS :: Double -> Double -> DrawState -> DrawState
scaleDS x y (a,b,c,d,e,f,hc) =
    (x*a, x*b, y*c, y*d, e, f, hc)

rotateDS :: Double -> DrawState -> DrawState
rotateDS r (a,b,c,d,e,f,hc) =
    (a * cos r + c * sin r,
     b * cos r + d * sin r,
     c * cos r - a * sin r,
     d * cos r - b * sin r,
     e, f, hc)

setColorDS :: Color -> DrawState -> DrawState
setColorDS col (a,b,c,d,e,f,Nothing) = (a,b,c,d,e,f,Just col)
setColorDS _ (a,b,c,d,e,f,Just col) = (a,b,c,d,e,f,Just col)

getColorDS :: DrawState -> Maybe Color
getColorDS (a,b,c,d,e,f,col) = col

--------------------------------------------------------------------------------
-- GHCJS implementation of drawing

#ifdef ghcjs_HOST_OS

foreign import javascript unsafe "$1.drawImage($2, $3, $4, $5, $6);"
    js_canvasDrawImage :: Canvas.Context -> Element -> Int -> Int -> Int -> Int -> IO ()

foreign import javascript unsafe "$1.getContext('2d', { alpha: false })"
    js_getCodeWorldContext :: Canvas.Canvas -> IO Canvas.Context

foreign import javascript unsafe "performance.now()"
    js_getHighResTimestamp :: IO Double

canvasFromElement :: Element -> Canvas.Canvas
canvasFromElement = Canvas.Canvas . unElement

elementFromCanvas :: Canvas.Canvas -> Element
elementFromCanvas = pFromJSVal . jsval

getTime :: IO Double
getTime = (/ 1000) <$> js_getHighResTimestamp

nextFrame :: IO Double
nextFrame = waitForAnimationFrame >> getTime

withDS :: Canvas.Context -> DrawState -> IO () -> IO ()
withDS ctx (ta,tb,tc,td,te,tf,col) action = do
    Canvas.save ctx
    Canvas.transform ta tb tc td te tf ctx
    Canvas.beginPath ctx
    action
    Canvas.restore ctx

applyColor :: Canvas.Context -> DrawState -> IO ()
applyColor ctx ds = case getColorDS ds of
    Nothing -> do
      Canvas.strokeStyle 0 0 0 1 ctx
      Canvas.fillStyle 0 0 0 1 ctx
    Just (RGBA r g b a) -> do
      Canvas.strokeStyle (round $ r * 255)
                         (round $ g * 255)
                         (round $ b * 255)
                         a ctx
      Canvas.fillStyle (round $ r * 255)
                       (round $ g * 255)
                       (round $ b * 255)
                       a ctx

foreign import javascript unsafe "$1.globalCompositeOperation = $2"
    js_setGlobalCompositeOperation :: Canvas.Context -> JSString -> IO ()

drawCodeWorldLogo :: Canvas.Context -> DrawState -> Int -> Int -> Int -> Int -> IO ()
drawCodeWorldLogo ctx ds x y w h = do
    Just doc <- currentDocument
    Just canvas <- getElementById doc ("cwlogo" :: JSString)
    case getColorDS ds of
        Nothing -> js_canvasDrawImage ctx canvas x y w h
        Just (RGBA r g b a) -> do
            -- This is a tough case.  The best we can do is to allocate an
            -- offscreen buffer as a temporary.
            buf <- Canvas.create w h
            bufctx <- js_getCodeWorldContext buf
            applyColor bufctx ds
            Canvas.fillRect 0 0 (fromIntegral w) (fromIntegral h) bufctx
            js_setGlobalCompositeOperation bufctx "destination-in"
            js_canvasDrawImage bufctx canvas 0 0 w h
            js_canvasDrawImage ctx (elementFromCanvas buf) x y w h

followPath :: Canvas.Context -> [Point] -> Bool -> Bool -> IO ()
followPath ctx [] closed _ = return ()
followPath ctx [p1] closed _ = return ()
followPath ctx ((sx,sy):ps) closed False = do
    Canvas.moveTo (25 * sx) (25 * sy) ctx
    forM_ ps $ \(x,y) -> Canvas.lineTo (25 * x) (25 * y) ctx
    when closed $ Canvas.closePath ctx
followPath ctx [p1, p2] False True = followPath ctx [p1, p2] False False
followPath ctx ps False True = do
    let [(x1,y1), (x2,y2), (x3,y3)] = take 3 ps
        dprev = sqrt ((x2 - x1)^2 + (y2 - y1)^2)
        dnext = sqrt ((x3 - x2)^2 + (y3 - y2)^2)
        p     = dprev / (dprev + dnext)
        cx    = x2 + p * (x1 - x3) / 2
        cy    = y2 + p * (y1 - y3) / 2
     in do Canvas.moveTo (25 * x1) (25 * y1) ctx
           Canvas.quadraticCurveTo (25 * cx) (25 * cy) (25 * x2) (25 * y2) ctx
    forM_ (zip4 ps (tail ps) (tail $ tail ps) (tail $ tail $ tail ps)) $
        \((x1,y1),(x2,y2),(x3,y3),(x4,y4)) ->
            let dp  = sqrt ((x2 - x1)^2 + (y2 - y1)^2)
                d1  = sqrt ((x3 - x2)^2 + (y3 - y2)^2)
                d2  = sqrt ((x4 - x3)^2 + (y4 - y3)^2)
                p   = d1 / (d1 + d2)
                r   = d1 / (dp + d1)
                cx1 = x2 + r * (x3 - x1) / 2
                cy1 = y2 + r * (y3 - y1) / 2
                cx2 = x3 + p * (x2 - x4) / 2
                cy2 = y3 + p * (y2 - y4) / 2
            in  Canvas.bezierCurveTo (25 * cx1) (25 * cy1) (25 * cx2) (25 * cy2)
                                     (25 * x3) (25 * y3) ctx
    let [(x1,y1), (x2,y2), (x3,y3)] = reverse $ take 3 $ reverse ps
        dp = sqrt ((x2 - x1)^2 + (y2 - y1)^2)
        d1 = sqrt ((x3 - x2)^2 + (y3 - y2)^2)
        r  = d1 / (dp + d1)
        cx = x2 + r * (x3 - x1) / 2
        cy = y2 + r * (y3 - y1) / 2
     in Canvas.quadraticCurveTo (25 * cx) (25 * cy) (25 * x3) (25 * y3) ctx
followPath ctx ps@(_:(sx,sy):_) True True = do
    Canvas.moveTo (25 * sx) (25 * sy) ctx
    let rep = cycle ps
    forM_ (zip4 ps (tail rep) (tail $ tail rep) (tail $ tail $ tail rep)) $
        \((x1,y1),(x2,y2),(x3,y3),(x4,y4)) ->
            let dp  = sqrt ((x2 - x1)^2 + (y2 - y1)^2)
                d1  = sqrt ((x3 - x2)^2 + (y3 - y2)^2)
                d2  = sqrt ((x4 - x3)^2 + (y4 - y3)^2)
                p   = d1 / (d1 + d2)
                r   = d1 / (dp + d1)
                cx1 = x2 + r * (x3 - x1) / 2
                cy1 = y2 + r * (y3 - y1) / 2
                cx2 = x3 + p * (x2 - x4) / 2
                cy2 = y3 + p * (y2 - y4) / 2
            in  Canvas.bezierCurveTo (25 * cx1) (25 * cy1) (25 * cx2) (25 * cy2)
                                     (25 * x3) (25 * y3) ctx
    Canvas.closePath ctx

drawFigure :: Canvas.Context -> DrawState -> Double -> IO () -> IO ()
drawFigure ctx ds w figure = do
    withDS ctx ds $ do
        figure
        when (w /= 0) $ do
            Canvas.lineWidth (25 * w) ctx
            applyColor ctx ds
            Canvas.stroke ctx
    when (w == 0) $ do
        Canvas.lineWidth 1 ctx
        applyColor ctx ds
        Canvas.stroke ctx

fontString :: TextStyle -> Font -> JSString
fontString style font = stylePrefix style <> "25px " <> fontName font
  where stylePrefix Plain        = ""
        stylePrefix Bold         = "bold "
        stylePrefix Italic       = "italic "
        fontName SansSerif       = "sans-serif"
        fontName Serif           = "serif"
        fontName Monospace       = "monospace"
        fontName Handwriting     = "cursive"
        fontName Fancy           = "fantasy"
        fontName (NamedFont txt) = "\"" <> textToJSString (T.filter (/= '"') txt) <> "\""

drawPicture :: Canvas.Context -> DrawState -> Picture -> IO ()
drawPicture ctx ds (Polygon ps smooth) = do
    withDS ctx ds $ followPath ctx ps True smooth
    applyColor ctx ds
    Canvas.fill ctx
drawPicture ctx ds (Path ps w closed smooth) = do
    drawFigure ctx ds w $ followPath ctx ps closed smooth
drawPicture ctx ds (Sector b e r) = withDS ctx ds $ do
    Canvas.arc 0 0 (25 * abs r) b e (b > e) ctx
    Canvas.lineTo 0 0 ctx
    applyColor ctx ds
    Canvas.fill ctx
drawPicture ctx ds (Arc b e r w) = do
    drawFigure ctx ds w $ do
        Canvas.arc 0 0 (25 * abs r) b e (b > e) ctx
drawPicture ctx ds (Text sty fnt txt) = withDS ctx ds $ do
    Canvas.scale 1 (-1) ctx
    applyColor ctx ds
    Canvas.font (fontString sty fnt) ctx
    Canvas.fillText (textToJSString txt) 0 0 ctx
drawPicture ctx ds Logo = withDS ctx ds $ do
    Canvas.scale 1 (-1) ctx
    drawCodeWorldLogo ctx ds (-225) (-50) 450 100
drawPicture ctx ds (Color col p)     = drawPicture ctx (setColorDS col ds) p
drawPicture ctx ds (Translate x y p) = drawPicture ctx (translateDS x y ds) p
drawPicture ctx ds (Scale x y p)     = drawPicture ctx (scaleDS x y ds) p
drawPicture ctx ds (Rotate r p)      = drawPicture ctx (rotateDS r ds) p
drawPicture ctx ds (Pictures ps)     = mapM_ (drawPicture ctx ds) (reverse ps)

drawFrame :: Canvas.Context -> Picture -> IO ()
drawFrame ctx pic = do
    Canvas.fillStyle 255 255 255 1 ctx
    Canvas.fillRect (-250) (-250) 500 500 ctx
    drawPicture ctx initialDS pic

setupScreenContext :: Element -> ClientRect.ClientRect -> IO Canvas.Context
setupScreenContext canvas rect = do
    cw <- ClientRect.getWidth rect
    ch <- ClientRect.getHeight rect
    ctx <- js_getCodeWorldContext (canvasFromElement canvas)
    Canvas.save ctx
    Canvas.translate (realToFrac cw / 2) (realToFrac ch / 2) ctx
    Canvas.scale (realToFrac cw / 500) (- realToFrac ch / 500) ctx
    Canvas.lineWidth 0 ctx
    Canvas.textAlign Canvas.Center ctx
    Canvas.textBaseline Canvas.Middle ctx
    return ctx

setCanvasSize :: Element -> Element -> IO ()
setCanvasSize target canvas = do
    Just rect <- getBoundingClientRect canvas
    cx <- ClientRect.getWidth rect
    cy <- ClientRect.getHeight rect
    setAttribute target ("width" :: JSString) (show (round cx))
    setAttribute target ("height" :: JSString) (show (round cy))

display :: Picture -> IO ()
display pic = do
    Just window <- currentWindow
    Just doc <- currentDocument
    Just canvas <- getElementById doc ("screen" :: JSString)
    on window Window.resize $ liftIO (draw canvas)
    draw canvas
  where
    draw canvas = do
        setCanvasSize canvas canvas
        Just rect <- getBoundingClientRect canvas
        ctx <- setupScreenContext canvas rect
        drawFrame ctx pic
        Canvas.restore ctx

drawingOf pic = display pic `catch` reportError


--------------------------------------------------------------------------------
-- Stand-alone implementation of drawing

#else

withDS :: DrawState -> Canvas () -> Canvas ()
withDS (ta,tb,tc,td,te,tf,col) action =
    Canvas.saveRestore $ do
        Canvas.transform (ta, tb, tc, td, te, tf)
        Canvas.beginPath ()
        action

applyColor :: DrawState -> Canvas ()
applyColor ds = case getColorDS ds of
    Nothing -> do
      Canvas.strokeStyle "black"
      Canvas.fillStyle   "black"
    Just (RGBA r g b a) -> do
      let style = pack $ printf "rgba(%.0f,%.0f,%.0f,%f)" (r*255) (g*255) (b*255) a
      Canvas.strokeStyle style
      Canvas.fillStyle   style


drawFigure :: DrawState -> Double -> Canvas () -> Canvas ()
drawFigure ds w figure = do
    withDS ds $ do
        figure
        when (w /= 0) $ do
            Canvas.lineWidth (25 * w)
            applyColor ds
            Canvas.stroke ()
    when (w == 0) $ do
        Canvas.lineWidth 1
        applyColor ds
        Canvas.stroke ()

followPath :: [Point] -> Bool -> Bool -> Canvas ()
followPath [] closed _ = return ()
followPath [p1] closed _ = return ()
followPath ((sx,sy):ps) closed False = do
    Canvas.moveTo (25 * sx, 25 * sy)
    forM_ ps $ \(x,y) -> Canvas.lineTo (25 * x, 25 * y)
    when closed $ Canvas.closePath ()
followPath [p1, p2] False True = followPath [p1, p2] False False
followPath ps False True = do
    let [(x1,y1), (x2,y2), (x3,y3)] = take 3 ps
        dprev = sqrt ((x2 - x1)^2 + (y2 - y1)^2)
        dnext = sqrt ((x3 - x2)^2 + (y3 - y2)^2)
        p     = dprev / (dprev + dnext)
        cx    = x2 + p * (x1 - x3) / 2
        cy    = y2 + p * (y1 - y3) / 2
     in do Canvas.moveTo (25 * x1, 25 * y1)
           Canvas.quadraticCurveTo (25 * cx, 25 * cy, 25 * x2, 25 * y2)
    forM_ (zip4 ps (tail ps) (tail $ tail ps) (tail $ tail $ tail ps)) $
        \((x1,y1),(x2,y2),(x3,y3),(x4,y4)) ->
            let dp  = sqrt ((x2 - x1)^2 + (y2 - y1)^2)
                d1  = sqrt ((x3 - x2)^2 + (y3 - y2)^2)
                d2  = sqrt ((x4 - x3)^2 + (y4 - y3)^2)
                p   = d1 / (d1 + d2)
                r   = d1 / (dp + d1)
                cx1 = x2 + r * (x3 - x1) / 2
                cy1 = y2 + r * (y3 - y1) / 2
                cx2 = x3 + p * (x2 - x4) / 2
                cy2 = y3 + p * (y2 - y4) / 2
            in  Canvas.bezierCurveTo ( 25 * cx1, 25 * cy1, 25 * cx2, 25 * cy2
                                     , 25 * x3,  25 * y3)
    let [(x1,y1), (x2,y2), (x3,y3)] = reverse $ take 3 $ reverse ps
        dp = sqrt ((x2 - x1)^2 + (y2 - y1)^2)
        d1 = sqrt ((x3 - x2)^2 + (y3 - y2)^2)
        r  = d1 / (dp + d1)
        cx = x2 + r * (x3 - x1) / 2
        cy = y2 + r * (y3 - y1) / 2
     in Canvas.quadraticCurveTo (25 * cx, 25 * cy, 25 * x3, 25 * y3)
followPath ps@(_:(sx,sy):_) True True = do
    Canvas.moveTo (25 * sx, 25 * sy)
    let rep = cycle ps
    forM_ (zip4 ps (tail rep) (tail $ tail rep) (tail $ tail $ tail rep)) $
        \((x1,y1),(x2,y2),(x3,y3),(x4,y4)) ->
            let dp  = sqrt ((x2 - x1)^2 + (y2 - y1)^2)
                d1  = sqrt ((x3 - x2)^2 + (y3 - y2)^2)
                d2  = sqrt ((x4 - x3)^2 + (y4 - y3)^2)
                p   = d1 / (d1 + d2)
                r   = d1 / (dp + d1)
                cx1 = x2 + r * (x3 - x1) / 2
                cy1 = y2 + r * (y3 - y1) / 2
                cx2 = x3 + p * (x2 - x4) / 2
                cy2 = y3 + p * (y2 - y4) / 2
            in  Canvas.bezierCurveTo ( 25 * cx1, 25 * cy1, 25 * cx2, 25 * cy2
                                     , 25 * x3, 25 * y3)
    Canvas.closePath ()


fontString :: TextStyle -> Font -> Text
fontString style font = stylePrefix style <> "25px " <> fontName font
  where stylePrefix Plain        = ""
        stylePrefix Bold         = "bold "
        stylePrefix Italic       = "italic "
        fontName SansSerif       = "sans-serif"
        fontName Serif           = "serif"
        fontName Monospace       = "monospace"
        fontName Handwriting     = "cursive"
        fontName Fancy           = "fantasy"
        fontName (NamedFont txt) = "\"" <> T.filter (/= '"') txt <> "\""

drawPicture :: DrawState -> Picture -> Canvas ()
drawPicture ds (Polygon ps smooth) = do
    withDS ds $ followPath ps True smooth
    applyColor ds
    Canvas.fill ()
drawPicture ds (Path ps w closed smooth) = do
    drawFigure ds w $ followPath ps closed smooth
drawPicture ds (Sector b e r) = withDS ds $ do
    Canvas.arc (0, 0, 25 * abs r, b, e,  b > e)
    Canvas.lineTo (0, 0)
    applyColor ds
    Canvas.fill ()
drawPicture ds (Arc b e r w) = do
    drawFigure ds w $ do
        Canvas.arc (0, 0, 25 * abs r, b, e, b > e)
drawPicture ds (Text sty fnt txt) = withDS ds $ do
    Canvas.scale (1, -1)
    applyColor ds
    Canvas.font (fontString sty fnt)
    Canvas.fillText (txt, 0, 0)
drawPicture ds Logo              = return () -- Unimplemented
drawPicture ds (Color col p)     = drawPicture (setColorDS col ds) p
drawPicture ds (Translate x y p) = drawPicture (translateDS x y ds) p
drawPicture ds (Scale x y p)     = drawPicture (scaleDS x y ds) p
drawPicture ds (Rotate r p)      = drawPicture (rotateDS r ds) p
drawPicture ds (Pictures ps)     = mapM_ (drawPicture ds) (reverse ps)

setupScreenContext :: (Int, Int) -> Canvas ()
setupScreenContext (cw, ch) = do
    -- blank before transformation (canvas might be non-sqare)
    Canvas.fillStyle "white"
    Canvas.fillRect (0,0,fromIntegral cw,fromIntegral ch)

    Canvas.translate (realToFrac cw / 2, realToFrac ch / 2)
    let s = min (realToFrac cw / 500) (realToFrac ch / 500)
    Canvas.scale (s, -s)
    Canvas.lineWidth 0
    Canvas.textAlign Canvas.CenterAnchor
    Canvas.textBaseline Canvas.MiddleBaseline

type Port = Int

readPortFromEnv :: String -> Port -> IO Port
readPortFromEnv envName defaultPort = do
    ms <- lookupEnv envName
    return (fromMaybe defaultPort (ms >>= readMaybe))

runBlankCanvas :: (Canvas.DeviceContext -> IO ()) -> IO ()
runBlankCanvas act = do
    port <- readPortFromEnv "CODEWORLD_API_PORT" 3000
    let options = (fromIntegral port) { Canvas.events =
            [ "mousedown", "mouseup", "mousemove", "keydown", "keyup"]
        }
    putStrLn $ printf "Open me on http://127.0.0.1:%d/" (Canvas.port options)
    Canvas.blankCanvas options $ \context -> do
        putStrLn "Program is starting..."
        act context

display :: Picture -> IO ()
display pic = runBlankCanvas $ \context ->
    Canvas.send context $ Canvas.saveRestore $ do
        let rect = (Canvas.width context, Canvas.height context)
        setupScreenContext rect
        drawPicture initialDS pic

drawingOf pic = display pic `catch` reportError
#endif


--------------------------------------------------------------------------------
-- Common event handling and core interaction code

keyCodeToText :: Int -> Text
keyCodeToText n = case n of
    _ | n >= 47  && n <= 90  -> fromAscii n
    _ | n >= 96  && n <= 105 -> fromNum (n - 96)
    _ | n >= 112 && n <= 135 -> "F" <> fromNum (n - 111)
    3                        -> "Cancel"
    6                        -> "Help"
    8                        -> "Backspace"
    9                        -> "Tab"
    12                       -> "5"
    13                       -> "Enter"
    16                       -> "Shift"
    17                       -> "Ctrl"
    18                       -> "Alt"
    19                       -> "Break"
    20                       -> "CapsLock"
    27                       -> "Esc"
    32                       -> " "
    33                       -> "PageUp"
    34                       -> "PageDown"
    35                       -> "End"
    36                       -> "Home"
    37                       -> "Left"
    38                       -> "Up"
    39                       -> "Right"
    40                       -> "Down"
    42                       -> "*"
    43                       -> "+"
    44                       -> "PrintScreen"
    45                       -> "Insert"
    46                       -> "Delete"
    106                      -> "*"
    107                      -> "+"
    108                      -> "Separator"
    109                      -> "-"
    110                      -> "."
    111                      -> "/"
    144                      -> "NumLock"
    145                      -> "ScrollLock"
    186                      -> ";"
    187                      -> "="
    188                      -> ","
    189                      -> "-"
    190                      -> "."
    191                      -> "/"
    192                      -> "`"
    219                      -> "["
    220                      -> "\\"
    221                      -> "]"
    222                      -> "'"
    _                        -> "Unknown:" <> fromNum n
  where fromAscii n = singleton (chr n)
        fromNum   n = pack (show (fromIntegral n))

isUniversallyConstant :: (a -> s -> s) -> s -> IO Bool
isUniversallyConstant f old = falseOr $ do
    oldName <- makeStableName old
    genName <- makeStableName $! (f undefined old)
    return (genName == oldName)
  where falseOr x = x `catch` \(e :: SomeException) -> return False

applyIfModifying :: (s -> IO s) -> s -> IO (Maybe s)
applyIfModifying f s0 = do
    oldName <- makeStableName $! s0
    s1      <- f s0
    newName <- makeStableName $! s1
    if newName /= oldName then return (Just s1)
                          else return Nothing

modifyMVarIfNeeded :: MVar s -> (s -> IO s) -> IO Bool
modifyMVarIfNeeded var f = modifyMVar var $ \s0 -> do
    ms1 <- applyIfModifying f s0
    case ms1 of Nothing -> return (s0, False)
                Just s1 -> return (s1, True)

data GameToken
    = FullToken {
          tokenDeployHash :: Text,
          tokenNumPlayers :: Int,
          tokenInitial :: StaticKey,
          tokenStep :: StaticKey,
          tokenEvent :: StaticKey,
          tokenDraw :: StaticKey
      }
    | PartialToken {
          tokenDeployHash :: Text
      }
    | NoToken
    deriving Generic

deriving instance Generic Fingerprint
instance Serialize Fingerprint
instance Serialize GameToken

--------------------------------------------------------------------------------
-- GHCJS event handling and core interaction code

#ifdef ghcjs_HOST_OS

getMousePos :: IsMouseEvent e => Element -> EventM w e Point
getMousePos canvas = do
    (ix, iy) <- mouseClientXY
    liftIO $ do
        Just rect <- getBoundingClientRect canvas
        cx <- ClientRect.getLeft rect
        cy <- ClientRect.getTop rect
        cw <- ClientRect.getWidth rect
        ch <- ClientRect.getHeight rect
        return (20 * fromIntegral (ix - round cx) / realToFrac cw - 10,
                20 * fromIntegral (round cy - iy) / realToFrac cw + 10)

fromButtonNum :: Word -> Maybe MouseButton
fromButtonNum 0 = Just LeftButton
fromButtonNum 1 = Just MiddleButton
fromButtonNum 2 = Just RightButton
fromButtonNum _ = Nothing

onEvents :: Element -> (Event -> IO ()) -> IO ()
onEvents canvas handler = do
    Just window <- currentWindow
    on window Window.keyDown $ do
        code <- uiKeyCode
        let keyName = keyCodeToText code
        when (keyName /= "") $ do
            liftIO $ handler (KeyPress keyName)
            preventDefault
            stopPropagation
    on window Window.keyUp $ do
        code <- uiKeyCode
        let keyName = keyCodeToText code
        when (keyName /= "") $ do
            liftIO $ handler (KeyRelease keyName)
            preventDefault
            stopPropagation
    on window Window.mouseDown $ do
        button <- mouseButton
        case fromButtonNum button of
            Nothing  -> return ()
            Just btn -> do
                pos <- getMousePos canvas
                liftIO $ handler (MousePress btn pos)
    on window Window.mouseUp $ do
        button <- mouseButton
        case fromButtonNum button of
            Nothing  -> return ()
            Just btn -> do
                pos <- getMousePos canvas
                liftIO $ handler (MouseRelease btn pos)
    on window Window.mouseMove $ do
        pos <- getMousePos canvas
        liftIO $ handler (MouseMovement pos)
    return ()

encodeEvent :: (Timestamp, Maybe Event) -> String
encodeEvent = show

decodeEvent :: String -> Maybe (Timestamp, Maybe Event)
decodeEvent = readMaybe

data GameState s
    = Main       (UIState SMain)
    | Connecting WS.WebSocket (UIState SConnect)
    | Waiting    WS.WebSocket GameId PlayerId (UIState SWait)
    | Running    WS.WebSocket GameId Timestamp PlayerId (Future s)

isRunning :: GameState s -> Bool
isRunning Running{} = True
isRunning _         = False

gameTime :: GameState s -> Timestamp -> Double
gameTime (Running _ _ tstart _ _) t = t - tstart
gameTime _ _                        = 0

-- It's worth trying to keep the canonical animation rate exactly representable
-- as a float, to minimize the chance of divergence due to rounding error.
gameRate :: Double
gameRate = 1/16

gameStep :: (Double -> s -> s) -> Double -> GameState s -> GameState s
gameStep _    t (Main s)
    = Main (CUI.step t s)
gameStep _    t (Connecting ws s)
    = Connecting ws (CUI.step t s)
gameStep _    t (Waiting ws gid pid s)
    = Waiting ws gid pid (CUI.step t s)
gameStep step t (Running ws gid tstart pid s)
    = Running ws gid tstart pid (currentTimePasses step gameRate (t - tstart) s)

gameDraw :: (Double -> s -> s)
         -> (PlayerId -> s -> Picture)
         -> GameState s
         -> Timestamp
         -> Picture
gameDraw _    _    (Main s)                   _ = CUI.picture s
gameDraw _    _    (Connecting _ s)           _ = CUI.picture s
gameDraw _    _    (Waiting _ _ _ s)          _ = CUI.picture s
gameDraw step draw (Running _ _ tstart pid s) t = draw pid (currentState step gameRate (t - tstart) s)

handleServerMessage :: Int
                    -> (StdGen -> s)
                    -> (Double -> s -> s)
                    -> (PlayerId -> Event -> s -> s)
                    -> MVar (GameState s)
                    -> ServerMessage
                    -> IO ()
handleServerMessage numPlayers initial stepHandler eventHandler gsm sm = do
    modifyMVar_ gsm $ \gs -> do
        t <- getTime
        case (sm, gs) of
            (GameAborted,         _) ->
                return initialGameState
            (JoinedAs pid gid,    Connecting ws s) ->
                return (Waiting ws gid pid (CUI.startWaiting gid s))
            (PlayersWaiting m n,  Waiting ws gid pid s) ->
                return (Waiting ws gid pid (CUI.updatePlayers n m s))
            (Started,             Waiting ws gid pid _) ->
                return (Running ws gid t pid (initFuture (initial (mkStdGen (hash gid))) numPlayers))
            (OutEvent pid eo,     Running ws gid tstart mypid s) ->
                case decodeEvent eo of
                    Just (t',event) ->
                        let ours   = pid == mypid
                            func   = eventHandler pid <$> event -- might be a ping (Nothing)
                            result | ours      = s -- we already took care of our events
                                   | otherwise = addEvent stepHandler gameRate mypid t' func s
                        in  return (Running ws gid tstart mypid result)
                    Nothing -> return (Running ws gid tstart mypid s)
            _ -> return gs
    return ()

gameHandle :: Int
            -> (StdGen -> s)
            -> (Double -> s -> s)
            -> (PlayerId -> Event -> s -> s)
            -> GameToken
            -> MVar (GameState s)
            -> Event
            -> IO ()
gameHandle numPlayers initial stepHandler eventHandler token gsm event = do
    gs <- takeMVar gsm
    case gs of
        Main s -> case CUI.event event s of
            ContinueMain s' -> do
                putMVar gsm (Main s')
            Create s' -> do
                ws <- connectToGameServer (handleServerMessage numPlayers initial stepHandler eventHandler gsm)
                sendClientMessage ws (NewGame numPlayers (encode token))
                putMVar gsm (Connecting ws s')
            Join gid s' -> do
                ws <- connectToGameServer (handleServerMessage numPlayers initial stepHandler eventHandler gsm)
                sendClientMessage ws (JoinGame gid (encode token))
                putMVar gsm (Connecting ws s')
        Connecting ws s -> case CUI.event event s of
            ContinueConnect s' -> do
                putMVar gsm (Connecting ws s')
            CancelConnect s' -> do
                WS.close Nothing Nothing ws
                putMVar gsm (Main s')
        Waiting ws gid pid s -> case CUI.event event s of
            ContinueWait s' -> do
                putMVar gsm (Waiting ws gid pid s')
            CancelWait s' -> do
                WS.close Nothing Nothing ws
                putMVar gsm (Main s')

        Running ws gid tstart pid f -> do
            t   <- getTime
            let gameState0 = currentState stepHandler gameRate (t - tstart) f
            let eventFun = eventHandler pid event
            ms1 <- (return . eventFun) `applyIfModifying` gameState0
            case ms1 of
                Nothing -> do
                    putMVar gsm gs
                Just s1 -> do
                    sendClientMessage ws (InEvent (encodeEvent (gameTime gs t, Just event)))
                    let f1 = addEvent stepHandler gameRate pid (t - tstart) (Just eventFun) f
                    putMVar gsm (Running ws gid tstart pid f1)

getWebSocketURL :: IO JSString
getWebSocketURL = do
    loc      <- Loc.getWindowLocation
    proto    <- Loc.getProtocol loc
    hostname <- Loc.getHostname loc

    let url = case proto of
            "http:"  -> "ws://" <> hostname <> ":9160/gameserver"
            "https:" -> "wss://" <> hostname <> "/gameserver"

    return url

connectToGameServer :: (ServerMessage -> IO ()) -> IO WS.WebSocket
connectToGameServer handleServerMessage = do
    let handleWSRequest m = do
        maybeSM <- decodeServerMessage m
        case maybeSM of
            Nothing -> return ()
            Just sm -> handleServerMessage sm

    wsURL <- getWebSocketURL
    let req = WS.WebSocketRequest
            { url = wsURL
            , protocols = []
            , onClose = Just $ \_ -> handleServerMessage GameAborted
            , onMessage = Just handleWSRequest
            }
    WS.connect req
  where
    decodeServerMessage :: WS.MessageEvent -> IO (Maybe ServerMessage)
    decodeServerMessage m = case WS.getData m of
        WS.StringData str -> do
            return $ readMaybe (Data.JSString.unpack str)
        _ -> return Nothing

    encodeClientMessage :: ClientMessage -> JSString
    encodeClientMessage m = Data.JSString.pack (show m)

sendClientMessage :: WS.WebSocket -> ClientMessage -> IO ()
sendClientMessage ws msg = WS.send (encodeClientMessage msg) ws
  where
    encodeClientMessage :: ClientMessage -> JSString
    encodeClientMessage m = Data.JSString.pack (show m)

initialGameState :: GameState s
initialGameState = Main CUI.initial

runGame :: GameToken
        -> Int
        -> (StdGen -> s)
        -> (Double -> s -> s)
        -> (Int -> Event -> s -> s)
        -> (Int -> s -> Picture)
        -> IO ()
runGame token numPlayers initial stepHandler eventHandler drawHandler = do
    Just window <- currentWindow
    Just doc <- currentDocument
    Just canvas <- getElementById doc ("screen" :: JSString)
    offscreenCanvas <- Canvas.create 500 500

    setCanvasSize canvas canvas
    setCanvasSize (elementFromCanvas offscreenCanvas) canvas
    on window Window.resize $ do
        liftIO $ setCanvasSize canvas canvas
        liftIO $ setCanvasSize (elementFromCanvas offscreenCanvas) canvas

    currentGameState <- newMVar initialGameState

    onEvents canvas $ gameHandle numPlayers initial stepHandler eventHandler token currentGameState

    screen <- js_getCodeWorldContext (canvasFromElement canvas)

    let go t0 lastFrame = do
            gs  <- readMVar currentGameState
            let pic = gameDraw stepHandler drawHandler gs t0
            picFrame <- makeStableName $! pic
            when (picFrame /= lastFrame) $ do
                Just rect <- getBoundingClientRect canvas
                buffer <- setupScreenContext (elementFromCanvas offscreenCanvas)
                                             rect
                drawFrame buffer pic
                Canvas.restore buffer

                Just rect <- getBoundingClientRect canvas
                cw <- ClientRect.getWidth rect
                ch <- ClientRect.getHeight rect
                js_canvasDrawImage screen (elementFromCanvas offscreenCanvas)
                                   0 0 (round cw) (round ch)

            t1 <- nextFrame
            modifyMVar_ currentGameState $ return . gameStep stepHandler t1
            go t1 picFrame

    t0 <- getTime
    nullFrame <- makeStableName undefined
    initialStateName <- makeStableName $! initialGameState
    go t0 nullFrame

run :: s -> (Double -> s -> s) -> (Event -> s -> s) -> (s -> Picture) -> IO ()
run initial stepHandler eventHandler drawHandler = do
    Just window <- currentWindow
    Just doc <- currentDocument
    Just canvas <- getElementById doc ("screen" :: JSString)
    offscreenCanvas <- Canvas.create 500 500

    setCanvasSize canvas canvas
    setCanvasSize (elementFromCanvas offscreenCanvas) canvas
    on window Window.resize $ do
        liftIO $ setCanvasSize canvas canvas
        liftIO $ setCanvasSize (elementFromCanvas offscreenCanvas) canvas

    currentState <- newMVar initial
    eventHappened <- newMVar ()

    onEvents canvas $ \event -> do
        changed <- modifyMVarIfNeeded currentState (return . eventHandler event)
        when changed $ void $ tryPutMVar eventHappened ()

    screen <- js_getCodeWorldContext (canvasFromElement canvas)

    let go t0 lastFrame lastStateName needsTime = do
            pic <- drawHandler <$> readMVar currentState
            picFrame <- makeStableName $! pic
            when (picFrame /= lastFrame) $ do
                Just rect <- getBoundingClientRect canvas
                buffer <- setupScreenContext (elementFromCanvas offscreenCanvas)
                                             rect
                drawFrame buffer pic
                Canvas.restore buffer

                Just rect <- getBoundingClientRect canvas
                cw <- ClientRect.getWidth rect
                ch <- ClientRect.getHeight rect
                js_canvasDrawImage screen (elementFromCanvas offscreenCanvas)
                                   0 0 (round cw) (round ch)

            t1 <- if
              | needsTime -> do
                  t1 <- nextFrame
                  let dt = min (t1 - t0) 0.25
                  modifyMVar_ currentState (return . stepHandler dt)
                  return t1
              | otherwise -> do
                  takeMVar eventHappened
                  getTime

            nextState <- readMVar currentState
            nextStateName <- makeStableName $! nextState
            nextNeedsTime <- if
                | nextStateName /= lastStateName -> return True
                | not needsTime -> return False
                | otherwise     -> not <$> isUniversallyConstant stepHandler nextState

            go t1 picFrame nextStateName nextNeedsTime

    t0 <- getTime
    nullFrame <- makeStableName undefined
    initialStateName <- makeStableName $! initial
    go t0 nullFrame initialStateName True

--------------------------------------------------------------------------------
-- Stand-Alone event handling and core interaction code

#else

fromButtonNum :: Int -> Maybe MouseButton
fromButtonNum 1 = Just LeftButton
fromButtonNum 2 = Just MiddleButton
fromButtonNum 3 = Just RightButton
fromButtonNum _ = Nothing

getMousePos :: (Int, Int) -> (Double, Double) -> (Double, Double)
getMousePos (w,h) (x,y) = ((x - fromIntegral w / 2)/s, -(y - fromIntegral h / 2)/s)
  where
   s = min (realToFrac w / 20) (realToFrac h / 20)

toEvent :: (Int, Int) -> Canvas.Event -> Maybe Event
toEvent rect Canvas.Event {..}
    | eType == "keydown"
    , Just code <- eWhich
    = Just $ KeyPress (keyCodeToText code)
    | eType == "keyup"
    , Just code <- eWhich
    = Just $ KeyRelease (keyCodeToText code)
    | eType == "mousedown"
    , Just button <- eWhich >>= fromButtonNum
    , Just pos <- getMousePos rect <$> ePageXY
    = Just $ MousePress button pos
    | eType == "mouseup"
    , Just button <- eWhich >>= fromButtonNum
    , Just pos <- getMousePos rect <$> ePageXY
    = Just $ MouseRelease button pos
    | eType == "mousemove"
    , Just pos <- getMousePos rect <$> ePageXY
    = Just $ MouseMovement pos
    | otherwise
    = Nothing

onEvents :: Canvas.DeviceContext -> (Int, Int) -> (Event -> IO ()) -> IO ()
onEvents context rect handler = void $ forkIO $ forever $ do
    maybeEvent <- toEvent rect <$> Canvas.wait context
    case maybeEvent of
        Nothing -> return ()
        Just event -> handler event

run :: s -> (Double -> s -> s) -> (Event -> s -> s) -> (s -> Picture) -> IO ()
run initial stepHandler eventHandler drawHandler = runBlankCanvas $ \context -> do
    let rect = (Canvas.width context, Canvas.height context)
    offscreenCanvas <- Canvas.send context $ Canvas.newCanvas rect

    currentState <- newMVar initial
    eventHappened <- newMVar ()

    onEvents context rect $ \event -> do
        modifyMVar_ currentState (return . eventHandler event)
        tryPutMVar eventHappened ()
        return ()

    let go t0 lastFrame lastStateName needsTime = do
            pic <- drawHandler <$> readMVar currentState
            picFrame <- makeStableName $! pic
            when (picFrame /= lastFrame) $ do
                Canvas.send context $ do
                    Canvas.with offscreenCanvas $
                        Canvas.saveRestore $ do
                            setupScreenContext rect
                            drawPicture initialDS pic
                    Canvas.drawImageAt (offscreenCanvas, 0, 0)

            t1 <- if
              | needsTime -> do
                  tn <- getCurrentTime
                  threadDelay $ max 0 (50000 - (round ((tn `diffUTCTime` t0) * 1000000)))
                  t1 <- getCurrentTime
                  let dt = realToFrac (t1 `diffUTCTime` t0)
                  modifyMVar_ currentState (return . stepHandler dt)
                  return t1
              | otherwise -> do
                  takeMVar eventHappened
                  getCurrentTime

            nextState <- readMVar currentState
            nextStateName <- makeStableName $! nextState
            nextNeedsTime <- if nextStateName == lastStateName
                then not <$> isUniversallyConstant stepHandler nextState
                else return True

            go t1 picFrame nextStateName nextNeedsTime

    t0 <- getCurrentTime
    nullFrame <- makeStableName undefined
    initialStateName <- makeStableName $! initial
    go t0 nullFrame initialStateName True

getDeployHash :: IO Text
getDeployHash = error "game API unimplemented in stand-alone interface mode"

runGame :: GameToken
        -> Int
        -> (StdGen -> s)
        -> (Double -> s -> s)
        -> (Int -> Event -> s -> s)
        -> (Int -> s -> Picture)
        -> IO ()
runGame = error "game API unimplemented in stand-alone interface mode"
#endif


--------------------------------------------------------------------------------
-- Common code for game interface

unsafeCollaborationOf numPlayers initial step event draw = do
    dhash <- getDeployHash
    let token = PartialToken dhash
    runGame token numPlayers initial step event draw `catch` reportError
  where token = NoToken

collaborationOf numPlayers initial step event draw = do
    dhash <- getDeployHash
    let token = FullToken {
                    tokenDeployHash = dhash,
                    tokenNumPlayers = numPlayers,
                    tokenInitial = staticKey initial,
                    tokenStep = staticKey step,
                    tokenEvent = staticKey event,
                    tokenDraw = staticKey draw
                }
    runGame token numPlayers (deRefStaticPtr initial) (deRefStaticPtr step)
            (deRefStaticPtr event) (deRefStaticPtr draw)

--------------------------------------------------------------------------------
-- Common code for interaction, animation and simulation interfaces

interactionOf initial step event draw =
    run initial step event draw `catch` reportError

data Wrapped a = Wrapped {
    state          :: a,
    paused         :: Bool,
    mouseMovedTime :: Double
    } deriving Show

data Control :: * -> * where
  PlayButton    :: Control a
  PauseButton   :: Control a
  StepButton    :: Control a
  RestartButton :: Control Double
  BackButton    :: Control Double
  TimeLabel     :: Control Double

wrappedStep :: (Double -> a -> a) -> Double -> Wrapped a -> Wrapped a
wrappedStep f dt w = w {
    state          = if paused w then state w else f dt (state w),
    mouseMovedTime = mouseMovedTime w + dt
    }

wrappedEvent :: (Wrapped a -> [Control a])
      -> (Double -> a -> a)
      -> Event -> Wrapped a -> Wrapped a
wrappedEvent _     _ (MouseMovement _)         w
    = w { mouseMovedTime = 0 }
wrappedEvent ctrls f (MousePress LeftButton p) w
    = (foldr (handleControl f p) w (ctrls w)) { mouseMovedTime = 0 }
wrappedEvent _     _ _                         w = w

handleControl :: (Double -> a -> a)
              -> Point
              -> Control a
              -> Wrapped a
              -> Wrapped a
handleControl _ (x,y) RestartButton w
  | -9.4 < x && x < -8.6 && -9.4 < y && y < -8.6
      = w { state = 0 }
handleControl _ (x,y) PlayButton    w
  | -8.4 < x && x < -7.6 && -9.4 < y && y < -8.6
      = w { paused = False }
handleControl _ (x,y) PauseButton   w
  | -8.4 < x && x < -7.6 && -9.4 < y && y < -8.6
      = w { paused = True }
handleControl _ (x,y) BackButton    w
  | -7.4 < x && x < -6.6 && -9.4 < y && y < -8.6
      = w { state = max 0 (state w - 0.1) }
handleControl f (x,y) StepButton    w
  | -6.4 < x && x < -5.6 && -9.4 < y && y < -8.6
      = w { state = f 0.1 (state w) }
handleControl _ _     _             w = w

wrappedDraw :: (Wrapped a -> [Control a])
     -> (a -> Picture)
     -> Wrapped a -> Picture
wrappedDraw ctrls f w = drawControlPanel ctrls w <> f (state w)

drawControlPanel :: (Wrapped a -> [Control a]) -> Wrapped a -> Picture
drawControlPanel ctrls w
  | alpha > 0 = pictures [ drawControl w alpha c | c <- ctrls w ]
  | otherwise = blank
  where alpha | mouseMovedTime w < 4.5  = 1
              | mouseMovedTime w < 5.0  = 10 - 2 * mouseMovedTime w
              | otherwise               = 0

drawControl :: Wrapped a -> Double -> Control a -> Picture
drawControl _ alpha RestartButton = translated (-9) (-9) p
  where p = colored (RGBA 0   0   0   alpha)
                    (thickArc 0.1 (pi / 6) (11 * pi / 6) 0.2 <>
                     translated 0.173 (-0.1) (solidRectangle 0.17 0.17))
         <> colored (RGBA 0.2 0.2 0.2 alpha) (rectangle      0.8 0.8)
         <> colored (RGBA 0.8 0.8 0.8 alpha) (solidRectangle 0.8 0.8)

drawControl _ alpha PlayButton = translated (-8) (-9) p
  where p = colored (RGBA 0   0   0   alpha)
                    (solidPolygon [ (-0.2, 0.25), (-0.2, -0.25), (0.2, 0) ])
         <> colored (RGBA 0.2 0.2 0.2 alpha) (rectangle      0.8 0.8)
         <> colored (RGBA 0.8 0.8 0.8 alpha) (solidRectangle 0.8 0.8)

drawControl _ alpha PauseButton = translated (-8) (-9) p
  where p = colored (RGBA 0   0   0   alpha)
                    (translated (-0.15) 0 (solidRectangle 0.2 0.6) <>
                     translated ( 0.15) 0 (solidRectangle 0.2 0.6))
         <> colored (RGBA 0.2 0.2 0.2 alpha) (rectangle      0.8 0.8)
         <> colored (RGBA 0.8 0.8 0.8 alpha) (solidRectangle 0.8 0.8)

drawControl _ alpha BackButton = translated (-7) (-9) p
  where p = colored (RGBA 0   0   0   alpha)
                    (translated 0.15 0 (solidRectangle 0.2 0.5) <>
                     solidPolygon [ (-0.05, 0.25), (-0.05, -0.25), (-0.3, 0) ])
         <> colored (RGBA 0.2 0.2 0.2 alpha) (rectangle      0.8 0.8)
         <> colored (RGBA 0.8 0.8 0.8 alpha) (solidRectangle 0.8 0.8)

drawControl _ alpha StepButton = translated (-6) (-9) p
  where p = colored (RGBA 0   0   0   alpha)
                    (translated (-0.15) 0 (solidRectangle 0.2 0.5) <>
                     solidPolygon [ (0.05, 0.25), (0.05, -0.25), (0.3, 0) ])
         <> colored (RGBA 0.2 0.2 0.2 alpha) (rectangle      0.8 0.8)
         <> colored (RGBA 0.8 0.8 0.8 alpha) (solidRectangle 0.8 0.8)

drawControl w alpha TimeLabel = translated (8) (-9) p
  where p = colored (RGBA 0   0   0   alpha)
                    (scaled 0.5 0.5 $
                        text (pack (showFFloatAlt (Just 4) (state w) "s")))
         <> colored (RGBA 0.2 0.2 0.2 alpha) (rectangle      3.0 0.8)
         <> colored (RGBA 0.8 0.8 0.8 alpha) (solidRectangle 3.0 0.8)

animationControls :: Wrapped Double -> [Control Double]
animationControls w
  | mouseMovedTime w > 5    = []
  | paused w && state w > 0 = [ RestartButton, PlayButton, StepButton,
                                BackButton, TimeLabel ]
  | paused w                = [ RestartButton, PlayButton, StepButton,
                                TimeLabel ]
  | otherwise               = [ RestartButton, PauseButton, TimeLabel ]

animationOf f =
    interactionOf initial
                  (wrappedStep (+))
                  (wrappedEvent animationControls (+))
                  (wrappedDraw animationControls f)
  where initial = Wrapped {
            state          = 0,
            paused         = False,
            mouseMovedTime = 1000
        }

simulationControls :: Wrapped w -> [Control w]
simulationControls w
  | mouseMovedTime w > 5 = []
  | paused w             = [ PlayButton, StepButton ]
  | otherwise            = [ PauseButton ]

simulationOf simInitial simStep simDraw =
    interactionOf initial
                  (wrappedStep simStep)
                  (wrappedEvent simulationControls simStep)
                  (wrappedDraw simulationControls simDraw)
  where initial = Wrapped {
            state          = simInitial,
            paused         = False,
            mouseMovedTime = 1000
        }


#ifdef ghcjs_HOST_OS
--------------------------------------------------------------------------------
--- GHCJS implementation of tracing and error handling

foreign import javascript unsafe "window.reportRuntimeError($1, $2);"
    js_reportRuntimeError :: Bool -> JSString -> IO ()

trace msg x = unsafePerformIO $ do
    js_reportRuntimeError False (textToJSString msg)
    return x

reportError :: SomeException -> IO ()
reportError e = js_reportRuntimeError True (textToJSString (pack (show e)))

foreign import javascript "/[&?]dhash=(.{22})/.exec(window.location.search)[1]"
    js_deployHash :: IO JSVal

getDeployHash :: IO Text
getDeployHash = pFromJSVal <$> js_deployHash

--------------------------------------------------------------------------------
--- Stand-alone implementation of tracing and error handling
#else

trace = Debug.Trace.trace . T.unpack

reportError :: SomeException -> IO ()
reportError e = hPrint stderr e

#endif
