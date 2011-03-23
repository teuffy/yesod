{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
-- | Widgets combine HTML with JS and CSS dependencies with a unique identifier
-- generator, allowing you to create truly modular HTML components.
module Yesod.Widget
    ( -- * Datatype
      GWidget
    , GGWidget (..)
    , PageContent (..)
      -- * Creating
      -- ** Head of page
    , setTitle
    , addHamletHead
    , addHtmlHead
      -- ** Body
    , addHamlet
    , addHtml
    , addWidget
    , addSubWidget
      -- ** CSS
    , addCassius
    , addStylesheet
    , addStylesheetRemote
    , addStylesheetEither
      -- ** Javascript
    , addJulius
    , addScript
    , addScriptRemote
    , addScriptEither
      -- * Utilities
    , extractBody
    ) where

import Data.Monoid
import Control.Monad.Trans.RWS
import Text.Hamlet
import Text.Cassius
import Text.Julius
import Yesod.Handler
    (Route, GHandler, YesodSubRoute(..), toMasterHandlerMaybe, getYesod)
import Control.Applicative (Applicative)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans.Class (MonadTrans (lift))
import Yesod.Internal
import Control.Monad (liftM)

import Control.Monad.IO.Peel (MonadPeelIO)

-- | A generic widget, allowing specification of both the subsite and master
-- site datatypes. This is basically a large 'WriterT' stack keeping track of
-- dependencies along with a 'StateT' to track unique identifiers.
newtype GGWidget s m monad a = GWidget { unGWidget :: GWInner m monad a } -- FIXME remove s
    deriving (Functor, Applicative, Monad, MonadIO, MonadPeelIO)

instance MonadTrans (GGWidget s m) where
    lift = GWidget . lift

type GWidget s m = GGWidget s m (GHandler s m)
type GWInner master = RWST () (GWData (Route master)) Int

instance (Monad monad, a ~ ()) => Monoid (GGWidget sub master monad a) where
    mempty = return ()
    mappend x y = x >> y

instance (Monad monad, a ~ ()) => HamletValue (GGWidget s m monad a) where
    newtype HamletMonad (GGWidget s m monad a) b =
        GWidget' { runGWidget' :: GGWidget s m monad b }
    type HamletUrl (GGWidget s m monad a) = Route m
    toHamletValue = runGWidget'
    htmlToHamletMonad = GWidget' . addHtml
    urlToHamletMonad url params = GWidget' $
        addHamlet $ \r -> preEscapedString (r url params)
    fromHamletValue = GWidget'
instance (Monad monad, a ~ ()) => Monad (HamletMonad (GGWidget s m monad a)) where
    return = GWidget' . return
    x >>= y = GWidget' $ runGWidget' x >>= runGWidget' . y

addSubWidget :: (YesodSubRoute sub master) => sub -> GWidget sub master a -> GWidget sub' master a
addSubWidget sub (GWidget w) = do
    master <- lift getYesod
    let sr = fromSubRoute sub master
    s <- GWidget get
    (a, s', w') <- lift $ toMasterHandlerMaybe sr (const sub) Nothing $ runRWST w () s
    GWidget $ put s'
    GWidget $ tell w'
    return a

-- | Set the page title. Calling 'setTitle' multiple times overrides previously
-- set values.
setTitle :: Monad m => Html -> GGWidget sub master m ()
setTitle x = GWidget $ tell $ GWData mempty (Last $ Just $ Title x) mempty mempty mempty mempty mempty

-- | Add a 'Hamlet' to the head tag.
addHamletHead :: Monad m => Hamlet (Route master) -> GGWidget sub master m ()
addHamletHead = GWidget . tell . GWData mempty mempty mempty mempty mempty mempty . Head

-- | Add a 'Html' to the head tag.
addHtmlHead :: Monad m => Html -> GGWidget sub master m ()
addHtmlHead = addHamletHead . const

-- | Add a 'Hamlet' to the body tag.
addHamlet :: Monad m => Hamlet (Route master) -> GGWidget sub master m ()
addHamlet x = GWidget $ tell $ GWData (Body x) mempty mempty mempty mempty mempty mempty

-- | Add a 'Html' to the body tag.
addHtml :: Monad m => Html -> GGWidget sub master m ()
addHtml = addHamlet . const

-- | Add another widget. This is defined as 'id', by can help with types, and
-- makes widget blocks look more consistent.
addWidget :: Monad mo => GGWidget s m mo () -> GGWidget s m mo ()
addWidget = id

-- | Add some raw CSS to the style tag.
addCassius :: Monad m => Cassius (Route master) -> GGWidget sub master m ()
addCassius x = GWidget $ tell $ GWData mempty mempty mempty mempty (Just x) mempty mempty

-- | Link to the specified local stylesheet.
addStylesheet :: Monad m => Route master -> GGWidget sub master m ()
addStylesheet x = GWidget $ tell $ GWData mempty mempty mempty (toUnique $ Stylesheet $ Local x) mempty mempty mempty

-- | Link to the specified remote stylesheet.
addStylesheetRemote :: Monad m => String -> GGWidget sub master m ()
addStylesheetRemote x = GWidget $ tell $ GWData mempty mempty mempty (toUnique $ Stylesheet $ Remote x) mempty mempty mempty

addStylesheetEither :: Monad m => Either (Route master) String -> GGWidget sub master m ()
addStylesheetEither = either addStylesheet addStylesheetRemote

addScriptEither :: Monad m => Either (Route master) String -> GGWidget sub master m ()
addScriptEither = either addScript addScriptRemote

-- | Link to the specified local script.
addScript :: Monad m => Route master -> GGWidget sub master m ()
addScript x = GWidget $ tell $ GWData mempty mempty (toUnique $ Script $ Local x) mempty mempty mempty mempty

-- | Link to the specified remote script.
addScriptRemote :: Monad m => String -> GGWidget sub master m ()
addScriptRemote x = GWidget $ tell $ GWData mempty mempty (toUnique $ Script $ Remote x) mempty mempty mempty mempty

-- | Include raw Javascript in the page's script tag.
addJulius :: Monad m => Julius (Route master) -> GGWidget sub master m ()
addJulius x = GWidget $ tell $ GWData mempty mempty mempty mempty mempty (Just x) mempty

-- | Pull out the HTML tag contents and return it. Useful for performing some
-- manipulations. It can be easier to use this sometimes than 'wrapWidget'.
extractBody :: Monad mo => GGWidget s m mo () -> GGWidget s m mo (Hamlet (Route m))
extractBody (GWidget w) =
    GWidget $ mapRWST (liftM go) w
  where
    go ((), s, GWData (Body h) b c d e f g) = (h, s, GWData (Body mempty) b c d e f g)

-- | Content for a web page. By providing this datatype, we can easily create
-- generic site templates, which would have the type signature:
--
-- > PageContent url -> Hamlet url
data PageContent url = PageContent
    { pageTitle :: Html
    , pageHead :: Hamlet url
    , pageBody :: Hamlet url
    }
