module Data.Argonaut.Decode
  ( DecodeJson
  , decodeJson
  , gDecodeJson
  , gDecodeJson'
  , decodeMaybe
  ) where

import Prelude

import Control.Alt ((<|>))
import Control.Bind ((=<<))
import Data.Argonaut.Core (Json(), isNull, foldJsonNull, foldJsonBoolean, foldJsonNumber, foldJsonString, toArray, toNumber, toObject, toString, toBoolean)
import Data.Argonaut.Internal
import Data.Array (zipWithA, length)
import Data.Either (either, Either(..))
import Data.Foldable (find)
import Data.Generic (Generic, GenericSpine(..), GenericSignature(..), DataConstructor(), fromSpine, toSignature)
import Data.Int (fromNumber)
import Data.List (List(..), toList)
import Data.Map as Map
import Data.Maybe (maybe, Maybe(..))
import Data.String (charAt, toChar)
import Data.StrMap as M
import Data.Traversable (traverse, for)
import Data.Tuple (Tuple(..))
import Type.Proxy (Proxy(..))

class DecodeJson a where
  decodeJson :: Json -> Either String a

-- | Decode `Json` representation of a value which has a `Generic` type.
gDecodeJson :: forall a. (Generic a) => Json -> Either String a
gDecodeJson json = maybe (Left "fromSpine failed") Right <<< fromSpine
                 =<< gDecodeJson' (toSignature (Proxy :: Proxy a)) json

-- | Decode `Json` representation of a `GenericSpine`.
gDecodeJson' :: GenericSignature -> Json -> Either String GenericSpine
gDecodeJson' signature json = case signature of
  SigNumber -> SNumber <$> mFail "Expected a number" (toNumber json)
  SigInt -> SInt <$> mFail "Expected an integer number" (fromNumber =<< toNumber json)
  SigString -> SString <$> mFail "Expected a string" (toString json)
  SigChar -> SChar <$> mFail "Expected a char" (toChar =<< toString json)
  SigBoolean -> SBoolean <$> mFail "Expected a boolean" (toBoolean json)
  SigArray thunk -> do
    jArr <- mFail "Expected an array" $ toArray json
    SArray <$> traverse (map const <<< gDecodeJson' (thunk unit)) jArr
  SigRecord props -> do
    jObj <- mFail "Expected an object" $ toObject json
    SRecord <$> for props \({recLabel: lbl, recValue: val}) -> do
      pf <- mFail ("'" <> lbl <> "' property missing") (M.lookup lbl jObj)
      sp <- gDecodeJson' (val unit) pf
      pure { recLabel: lbl, recValue: const sp }
  SigProd typeConstr alts -> do
    let decodingErr msg = "When decoding a " ++ typeConstr ++ ": " ++ msg
    jObj <- mFail (decodingErr "expected an object") (toObject json)
    tagJson  <- mFail (decodingErr "'tag' property is missing") (M.lookup "tag" jObj)
    tag <- mFail (decodingErr "'tag' property is not a string") (toString tagJson)
    case find ((tag ==) <<< _.sigConstructor) alts of
      Nothing -> Left (decodingErr ("'" <> tag <> "' isn't a valid constructor"))
      Just { sigValues: sigValues } -> do
        vals <- mFail (decodingErr "'values' array is missing") (toArray =<< M.lookup "values" jObj)
        sps  <- zipWithA (\k -> gDecodeJson' (k unit)) sigValues vals
        pure (SProd tag (const <$> sps))
  where
  mFail :: forall a. String -> Maybe a -> Either String a
  mFail msg = maybe (Left msg) Right

-- | Decode `Json` representation of a value which has a `Generic` type.
gAesonDecodeJson :: forall a. (Generic a) => Json -> Either String a
gAesonDecodeJson json = maybe (Left "fromSpine failed") Right <<< fromSpine
                =<< gAesonDecodeJson' (toSignature (Proxy :: Proxy a)) json

-- | Decode `Json` representation of a `GenericSpine`.
gAesonDecodeJson' :: GenericSignature -> Json -> Either String GenericSpine
gAesonDecodeJson' signature json = case signature of
 SigNumber -> SNumber <$> mFail "Expected a number" (toNumber json)
 SigInt -> SInt <$> mFail "Expected an integer number" (fromNumber =<< toNumber json)
 SigString -> SString <$> mFail "Expected a string" (toString json)
 SigChar -> SChar <$> mFail "Expected a char" (toChar =<< toString json)
 SigBoolean -> SBoolean <$> mFail "Expected a boolean" (toBoolean json)
 SigArray thunk -> do
   jArr <- mFail "Expected an array" $ toArray json
   SArray <$> traverse (map const <<< gDecodeJson' (thunk unit)) jArr
 SigRecord props -> do
   jObj <- mFail "Expected an object" $ toObject json
   SRecord <$> for props \({recLabel: lbl, recValue: val}) -> do
     pf <- mFail ("'" <> lbl <> "' property missing") (M.lookup lbl jObj)
     sp <- gDecodeJson' (val unit) pf
     pure { recLabel: lbl, recValue: const sp }
 SigProd typeConstr constrSigns -> gAesonDecodeProdJson' typeConstr constrSigns json

mFail :: forall a. String -> Maybe a -> Either String a
mFail msg = maybe (Left msg) Right


gAesonDecodeProdJson' :: String -> Array DataConstructor -> Json -> Either String GenericSpine
gAesonDecodeProdJson' tname constrSigns json = if allConstrNullary constrSigns
                                               then decodeFromString
                                               else decodeTagged
  where
    decodeFromString = do
      tag <- mFail (decodingErr "Constructor name as string expected") (toString json)
      pure (SProd tag [])
    decodeTagged = do
      jObj <- mFail (decodingErr "expected an object") (toObject json)
      tagJson  <- mFail (decodingErr "'tag' property is missing") (M.lookup "tag" jObj)
      tag <- mFail (decodingErr "'tag' property is not a string") (toString tagJson)
      case find ((tag ==) <<< fixConstr <<< _.sigConstructor) constrSigns of
        Nothing -> Left (decodingErr ("'" <> tag <> "' isn't a valid constructor"))
        Just { sigValues: sigValues } -> do
          jVals <- mFail (decodingErr "'contents' property is missing") (M.lookup "contents" jObj)
          vals <- case length sigValues of
                    1 -> pure [jVals]
                    _  -> mFail (decodingErr "Expected array") (toArray jVals)
          sps  <- zipWithA (\k -> gAesonDecodeJson' (k unit)) sigValues vals
          pure (SProd tag (const <$> sps))
    decodingErr msg = "When decoding a " ++ tname ++ ": " ++ msg

instance decodeJsonMaybe :: (DecodeJson a) => DecodeJson (Maybe a) where
  decodeJson j
    | isNull j = pure Nothing
    | otherwise = (Just <$> decodeJson j) <|> (pure Nothing)

instance decodeJsonTuple :: (DecodeJson a, DecodeJson b) => DecodeJson (Tuple a b) where
  decodeJson j = decodeJson j >>= f
    where
    f (Cons a (Cons b Nil)) = Tuple <$> decodeJson a <*> decodeJson b
    f _ = Left "Couldn't decode Tuple"

instance decodeJsonEither :: (DecodeJson a, DecodeJson b) => DecodeJson (Either a b) where
  decodeJson j =
    case toObject j of
      Just obj -> do
        tag <- just (M.lookup "tag" obj)
        val <- just (M.lookup "value" obj)
        case toString tag of
          Just "Right" ->
            Right <$> decodeJson val
          Just "Left" ->
            Left <$> decodeJson val
          _ ->
            Left "Couldn't decode Either"
      _ ->
        Left "Couldn't decode Either"
    where
    just (Just x) = Right x
    just Nothing  = Left "Couldn't decode Either"

instance decodeJsonNull :: DecodeJson Unit where
  decodeJson = foldJsonNull (Left "Not null") (const $ Right unit)

instance decodeJsonBoolean :: DecodeJson Boolean where
  decodeJson = foldJsonBoolean (Left "Not a Boolean") Right

instance decodeJsonNumber :: DecodeJson Number where
  decodeJson = foldJsonNumber (Left "Not a Number") Right

instance decodeJsonInt :: DecodeJson Int where
  decodeJson num = foldJsonNumber (Left "Not a Number") go num
    where go num = maybe (Left "Not an Int") Right $ fromNumber num

instance decodeJsonString :: DecodeJson String where
  decodeJson = foldJsonString (Left "Not a String") Right

instance decodeJsonJson :: DecodeJson Json where
  decodeJson = Right

instance decodeJsonChar :: DecodeJson Char where
  decodeJson j = (charAt 0 <$> decodeJson j) >>= go where
    go Nothing  = Left $ "Expected character but found: " ++ show j
    go (Just c) = Right c

instance decodeStrMap :: (DecodeJson a) => DecodeJson (M.StrMap a) where
  decodeJson json = maybe (Left "Couldn't decode StrMap") Right $ do
    obj <- toObject json
    traverse decodeMaybe obj

instance decodeArray :: (DecodeJson a) => DecodeJson (Array a) where
  decodeJson json = maybe (Left "Couldn't decode Array") Right $ do
    obj <- toArray json
    traverse decodeMaybe obj

instance decodeList :: (DecodeJson a) => DecodeJson (List a) where
  decodeJson json = maybe (Left "Couldn't decode List") Right $ do
    lst <- toList <$> toArray json
    traverse decodeMaybe lst

instance decodeMap :: (Ord a, DecodeJson a, DecodeJson b) => DecodeJson (Map.Map a b) where
  decodeJson j = Map.fromList <$> decodeJson j

decodeMaybe :: forall a. (DecodeJson a) => Json -> Maybe a
decodeMaybe json = either (const Nothing) pure $ decodeJson json
