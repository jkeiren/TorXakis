{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleContexts #-}
module TorXakis.Compiler.MapsToSpec where

import Prelude hiding (lookup)
import           Data.Map   (Map)
import qualified Data.Map   as Map
import           Test.Hspec (Spec, it, pending, shouldBe)
import Data.Proxy (Proxy (Proxy))

import TorXakis.Compiler.Error

import TorXakis.Compiler.MapsTo

data Fruit = Orange | Pear | Apple | Banana deriving (Show, Eq)
data Vegetable = Cucumber | Carrot | Spinach deriving (Show, Eq)
data Legume = Lentils | Chickpeas | BlackEyedPeas deriving (Show, Eq)

fruitNames :: Map String Fruit
fruitNames = [("Orange", Orange), ("Pear", Pear), ("Apple", Apple)]

vegetableNames :: Map String Vegetable
vegetableNames = [("Cucumber", Cucumber), ("Carrot", Carrot), ("Spinach", Spinach)]

fruitNumbers :: Map Int Fruit
fruitNumbers = [(0, Orange), (1, Pear), (2, Apple)]

fruitWithName :: MapsTo String Fruit m => String -> m -> Either Error Fruit
fruitWithName n m =
    lookup n m

vegetableWithName :: MapsTo String Vegetable m => String -> m -> Either Error Vegetable
vegetableWithName n m =
    lookup n m    

somethingWithName :: ( MapsTo String Fruit m
                     , MapsTo String Vegetable m )
                  => String -> m -> Either Error (Either Fruit Vegetable)
somethingWithName n m = 
    case fruitWithName n m of
        Right f -> Right (Left f)
        Left _  -> Right <$> vegetableWithName n m

fooBi :: ( --MapsTo Text SortId mm
    MapsTo String Bool mm
--         , In (Loc VarDeclE, VarId) (Contents mm) ~ 'False
         -- , In (Text, ChanId) (Contents mm) ~ 'False
         -- , In (Loc ChanDeclE, ChanId) (Contents mm) ~ 'False
         -- , In (Loc ChanRefE, Loc ChanDeclE) (Contents mm) ~ 'False
         -- , In (ProcId, ()) (Contents mm) ~ 'False
--         , In (Loc VarDeclE, SortId) (Contents mm) ~ 'False
         )
      => mm -> ()
fooBi _ = ()

qq :: Map Double Int
qq = Map.empty
zz :: Map Bool Int
zz = Map.empty
tt :: Map Char Int
tt = Map.empty
dd :: Map Int Double
dd = Map.empty
gg :: Map Bool Double
gg = Map.empty
hh :: Map Char Double
hh = Map.empty
myma :: Map String Bool
myma = Map.empty
        
boom :: ()
boom =
    fooBi ( (myma
            :&
            qq)
            :& (dd -- TODO: find out why removing the parentheses won't compile.
            :& tt  -- Removing one of the elements here (e.g. 'tt' will work as well)
            :& zz
            :& gg)
            :& hh
          )

spec :: Spec
spec = do
    it "It gets the right fruit in a map" $
       let Right res = fruitWithName "Orange" fruitNames in
           res `shouldBe` Orange
    it "It gets the right fruit in a composite map" $
       let Right res = fruitWithName "Orange" (fruitNames :& fruitNumbers) in
           res `shouldBe` Orange           
    it "It gets the right fruit in a composite map (second variant)" $
       let Right res = fruitWithName "Orange" (fruitNumbers :& fruitNames) in
           res `shouldBe` Orange
    it "It gets the right vegetable in a composite map" $
       let Right res = vegetableWithName "Spinach" (fruitNames :& vegetableNames :& fruitNumbers) in
           res `shouldBe` Spinach
    it "It gets the right thing in a composite map" $
       let Right (Right res) = somethingWithName "Spinach" (z :& x :& fruitNames :& vegetableNames :& fruitNumbers)
           x :: Map Double Int
           x = undefined
           z :: Map Double Bool
           z = undefined
       in
           res `shouldBe` Spinach           
    it "It gets all the vegetables names in a composite map" $
        keys @String @Vegetable
            (fruitNames :& vegetableNames :& fruitNumbers)
        `shouldBe`
        ["Carrot", "Cucumber", "Spinach"]
    it "It gets all the vegetables in a composite map" $
        values @String
            (fruitNames :& vegetableNames :& fruitNumbers)
        `shouldBe`
        [Carrot, Cucumber, Spinach]
    it  "Adds a map" $
        values @String ([("Whatever", Banana)] <.+> fruitNames)
        `shouldBe`
        [Apple, Orange, Pear, Banana]
    it  "Adds a map in a nested context" $
        values @String ([("Whatever", Banana)] <.+> (fruitNames :& fruitNumbers))
        `shouldBe`
        [Apple, Orange, Pear, Banana]                
    it "Replaces a map" $
        values @String (replaceInnerMap fruitNames [("Whatever", Banana)] )
        `shouldBe`
        [Banana]
    it "Replaces a map in a nested context" $
        values @String (replaceInnerMap (fruitNames :& vegetableNames) [("Whatever", Banana)] )
        `shouldBe`
        [Banana]
        
    -- Uncomment these to test for the type errors of the compiler:
    --
    -- it "Fails when no map is found)" $
    --    let Right res = fruitWithName "Orange" (fruitNumbers :& "Not here either") in
    --        res `shouldBe` Orange                      
    -- it "It gets the right fruit in a composite map (third variant)" $
    --    let Right res = fruitWithName "Orange" (fruitNumbers :& fruitNames :& fruitNumbers :& fruitNames) in
    --        res `shouldBe` Orange
    --
    -- We could test this by calling the ghc compiler, and checking the error message.

           
       