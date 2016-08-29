{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PolyKinds                  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
module Web.Internal.FormUrlEncoded where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative
#endif

import           Control.Monad              ((<=<))
import qualified Data.ByteString.Lazy       as BSL
import qualified Data.ByteString.Lazy.Char8 as BSL8
import qualified Data.Map                   as M
import           Data.Monoid
import qualified Data.Text                  as T
import           Data.Text.Encoding         (decodeUtf8With, encodeUtf8)
import           Data.Text.Encoding.Error   (lenientDecode)
import           GHC.Exts                   (IsList (..))
import           GHC.Generics
import           Network.URI                (escapeURIString, isUnreserved,
                                             unEscapeString)

import Web.Internal.HttpApiData

-- $setup
-- >>> :set -XDeriveGeneric
-- >>> :set -XOverloadedLists
-- >>> :set -XOverloadedStrings
-- >>> :set -XFlexibleContexts
-- >>> :set -XScopedTypeVariables
-- >>> :set -XTypeFamilies
-- >>> import Data.Either (isLeft)
-- >>> import Data.List (sort)
-- >>> data Person = Person { name :: String, age :: Int } deriving (Show, Generic)
-- >>> instance ToForm Person
-- >>> instance FromForm Person

-- | The contents of a form, not yet URL-encoded.
--
-- 'Form' can be URL-encoded with 'encodeForm' and URL-decoded with 'decodeForm'.
newtype Form = Form { unForm :: M.Map T.Text T.Text }
  deriving (Eq, Read, Generic, Monoid)

instance Show Form where
  showsPrec d form = showParen (d > 10) $
    showString "fromList " . shows (toList form)

instance IsList Form where
  type Item Form = (T.Text, T.Text)
  fromList = Form . M.fromList
  toList = M.toList . unForm

-- | Convert a value into 'Form'.
--
-- An example type and instance:
--
-- @
-- {-\# LANGUAGE OverloadedLists \#-}
--
-- data Person = Person
--   { name :: String
--   , age  :: Int }
--
-- instance 'ToForm' Person where
--   'toForm' person =
--     [ (\"name\", 'toQueryParam' (name person))
--     , (\"age\", 'toQueryParam' (age person)) ]
-- @
--
-- Instead of manually writing @'ToForm'@ instances you can
-- use a default generic implementation of @'toForm'@.
--
-- To do that, simply add @deriving 'Generic'@ clause to your datatype
-- and declare a 'ToForm' instance for your datatype without
-- giving definition for 'toForm'.
--
-- For instance, the previous example can be simplified into this:
--
-- @
-- data Person = Person
--   { name :: String
--   , age  :: Int
--   } deriving ('Generic')
--
-- instance 'ToForm' Person
-- @
--
-- The default implementation will use 'toQueryParam' for each field's value.
class ToForm a where
  -- | Convert a value into 'Form'.
  toForm :: a -> Form
  default toForm :: (Generic a, GToForm (Rep a)) => a -> Form
  toForm = genericToForm

instance ToForm [(T.Text, T.Text)] where toForm = fromList
instance ToForm (M.Map T.Text T.Text) where toForm = Form
instance ToForm Form where toForm = id

-- | A 'Generic'-based implementation of 'toForm'.
-- This is used as a default implementation in 'ToForm'.
genericToForm :: (Generic a, GToForm (Rep a)) => a -> Form
genericToForm = gToForm . from

class GToForm (f :: * -> *) where
  gToForm :: f x -> Form

instance (GToForm f, GToForm g) => GToForm (f :*: g) where
  gToForm (a :*: b) = gToForm a <> gToForm b

instance (GToForm f, GToForm g) => GToForm (f :+: g) where
  gToForm (L1 a) = gToForm a
  gToForm (R1 a) = gToForm a

instance (GToForm f) => GToForm (M1 D x f) where
  gToForm (M1 a) = gToForm a

instance (GToForm f) => GToForm (M1 C x f) where
  gToForm (M1 a) = gToForm a

instance (Selector s, ToHttpApiData c) => GToForm (M1 S s (K1 i c)) where
  gToForm (M1 (K1 c)) = fromList [(key, toQueryParam c)]
    where
      key = T.pack $ selName (Proxy3 :: Proxy3 s g p)

-- | Parse 'Form' into a value.
--
-- An example type and instance:
--
-- @
-- data Person = Person
--   { name :: String
--   , age  :: Int }
--
-- instance 'FromForm' Person where
--   'fromForm' (Form m) = Person
--     '\<$\>' maybe (Left "key \"name\" not found") 'parseQueryParam' (lookup "name" m)
--     '\<*\>' maybe (Left "key \"age\" not found")  'parseQueryParam' (lookup "name" m)
-- @
--
-- Instead of manually writing @'FromForm'@ instances you can
-- use a default generic implementation of @'fromForm'@.
--
-- To do that, simply add @deriving 'Generic'@ clause to your datatype
-- and declare a 'FromForm' instance for your datatype without
-- giving definition for 'fromForm'.
--
-- For instance, the previous example can be simplified into this:
--
-- @
-- data Person = Person
--   { name :: String
--   , age  :: Int
--   } deriving ('Generic')
--
-- instance 'FromForm' Person
-- @
--
-- The default implementation will use 'parseQueryParam' for each field's value.
class FromForm a where
  -- | Parse 'Form' into a value.
  fromForm :: Form -> Either T.Text a
  default fromForm :: (Generic a, GFromForm (Rep a))
     => Form -> Either T.Text a
  fromForm = genericFromForm

instance FromForm Form where fromForm = return
instance FromForm [(T.Text, T.Text)] where fromForm = return . toList
instance FromForm (M.Map T.Text T.Text) where fromForm = return . unForm

-- | A 'Generic'-based implementation of 'fromForm'.
-- This is used as a default implementation in 'FromForm'.
genericFromForm :: (Generic a, GFromForm (Rep a))
    => Form -> Either T.Text a
genericFromForm f = to <$> gFromForm f

class GFromForm (f :: * -> *) where
  gFromForm :: Form -> Either T.Text (f x)

instance (GFromForm f, GFromForm g) => GFromForm (f :*: g) where
  gFromForm f = (:*:) <$> gFromForm f <*> gFromForm f

instance (GFromForm f, GFromForm g) => GFromForm (f :+: g) where
  gFromForm f
      = fmap L1 (gFromForm f)
    <!> fmap R1 (gFromForm f)
    where
      Left _  <!> y = y
      x       <!> _ = x

instance (Selector s, FromHttpApiData f) => GFromForm (M1 S s (K1 i f)) where
  gFromForm f =
    case M.lookup key (unForm f) of
      Nothing -> Left $ "Could not find key " <> T.pack (show key)
      Just v  -> M1 . K1 <$> parseQueryParam v
    where
      key = T.pack $ selName (Proxy3 :: Proxy3 s g p)

instance (GFromForm f) => GFromForm (M1 D x f) where
  gFromForm f = M1 <$> gFromForm f

instance (GFromForm f) => GFromForm (M1 C x f) where
  gFromForm f = M1 <$> gFromForm f

-- | Encode a 'Form' to an @application/x-www-form-urlencoded@ 'BSL.ByteString'.
--
-- Key-value pairs get encoded to @key=value@ and separated by @&@:
--
-- >>> encodeForm [("name", "Julian"), ("lastname", "Arni")]
-- "lastname=Arni&name=Julian"
--
-- Keys with empty values get encoded to just @key@ (without the @=@ sign):
--
-- >>> encodeForm [("is_test", "")]
-- "is_test"
--
-- Empty keys are allowed too:
--
-- >>> encodeForm [("", "foobar")]
-- "=foobar"
--
-- However, if not key and value are empty, the key-value pair is ignored.
-- (This prevents @'decodeForm' . 'encodeForm'@ from being a true isomorphism).
--
-- >>> encodeForm [("", "")]
-- ""
--
-- Everything is escaped with @'escapeURIString' 'isUnreserved'@:
--
-- >>> encodeForm [("fullname", "Andres Löh")]
-- "fullname=Andres%20L%C3%B6h"
encodeForm :: Form -> BSL.ByteString
encodeForm xs = BSL.intercalate "&" $ map (BSL.fromStrict . encodePair) $ toList xs
  where
    escape = encodeUtf8 . T.pack . escapeURIString isUnreserved . T.unpack

    encodePair (k, "") = escape k
    encodePair (k, v) = escape k <> "=" <> escape v


-- | Decode an @application/x-www-form-urlencoded@ 'BSL.ByteString' to a 'Form'.
--
-- Key-value pairs get decoded normally:
--
-- >>> decodeForm "name=Greg&lastname=Weber"
-- Right (fromList [("lastname","Weber"),("name","Greg")])
--
-- Keys with no values get decoded to pairs with empty values.
--
-- >>> decodeForm "is_test"
-- Right (fromList [("is_test","")])
--
-- Empty keys are allowed:
--
-- >>> decodeForm "=foobar"
-- Right (fromList [("","foobar")])
--
-- The empty string gets decoded into an empty 'Form':
--
-- >>> decodeForm ""
-- Right (fromList [])
--
-- Everything is un-escaped with 'unEscapeString':
--
-- >>> decodeForm "fullname=Andres%20L%C3%B6h"
-- Right (fromList [("fullname","Andres L\246h")])
--
-- Improperly formed strings result in an error:
--
-- >>> decodeForm "this=has=too=many=equals"
-- Left "not a valid pair: this=has=too=many=equals"
decodeForm :: BSL.ByteString -> Either T.Text Form
decodeForm bs = toForm <$> traverse parsePair pairs
  where
    pairs = map (decodeUtf8With lenientDecode . BSL.toStrict) (BSL8.split '&' bs)

    unescape = T.pack . unEscapeString . T.unpack . T.replace "+" "%20"

    parsePair :: T.Text -> Either T.Text (T.Text, T.Text)
    parsePair p =
      case T.splitOn "=" p of
        [k, v] -> return (unescape k, unescape v)
        [k]    -> return (unescape k, "" )
        _ -> Left $ "not a valid pair: " <> p

data Proxy3 a b c = Proxy3

-- | This is a convenience function for decoding a
-- @application/x-www-form-urlencoded@ 'BSL.ByteString' directly to a datatype
-- that has an instance of 'FromForm'.
--
-- This is effectively @'fromForm' '<=<' 'decodeForm'@.
--
-- >>> decodeAsForm "name=Dennis&age=22" :: Either T.Text Person
-- Right (Person {name = "Dennis", age = 22})
decodeAsForm :: FromForm a => BSL.ByteString -> Either T.Text a
decodeAsForm = fromForm <=< decodeForm

-- | This is a convenience function for encoding a datatype that has instance
-- of 'ToForm' directly to a @application/x-www-form-urlencoded@
-- 'BSL.ByteString'.
--
-- This is effectively @'encodeForm' . 'toForm'@.
--
-- >>> encodeAsForm Person {name = "Dennis", age = 22}
-- "age=22&name=Dennis"
encodeAsForm :: ToForm a => a -> BSL.ByteString
encodeAsForm = encodeForm . toForm
