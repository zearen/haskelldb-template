{- 
 - Zachary Weaver (C) 2012
 - Template.hs
 -
 - Provides a template for HaskellDB boilerplate
 -}

{-# LANGUAGE ScopedTypeVariables, TemplateHaskell #-}
{-|
  This is a rework of the interface for Justin Bailey's
  haskelldb-th package.  It's designed to be easier to 
  use, but allow for flexibility.  This is done via intermediate
  types that can be manipulated before generating the actual
  code.  There are lens packages to facilitate this.

  Typically, it will be used simply like so

  > $(genTableAndFields $ mkTable "MyDatabaseTable"
  >   [ "Key"   .:: [t|Int]
  >   , "User"  .:: [t|String]
  >   , "Hash"  .:: [t|String]
  >   ]
  > )

  which generates

  > type MyDatabaseTable = Database.HaskellDB.HDBRec.RecCons Key
  >                                                          (Database.HaskellDB.Query.Expr GHC.Types.Int)
  >                                                          (Database.HaskellDB.HDBRec.RecCons User
  >                                                                                             (Database.HaskellDB.Query.Expr GHC.Base.String)
  >                                                                                             (Database.HaskellDB.HDBRec.RecCons Hash
  >                                                                                                                                (Database.HaskellDB.Query.Expr GHC.Base.String)
  >                                                                                                                                Database.HaskellDB.HDBRec.RecNil))
  > myDatabaseTable :: Database.HaskellDB.Query.Table MyDatabaseTable
  > myDatabaseTable = Database.HaskellDB.Query.baseTable "MyDatabaseTable" ((#) (Database.HaskellDB.DBLayout.hdbMakeEntry Hash) ((#) (Database.HaskellDB.DBLayout.hdbMakeEntry User) (Database.HaskellDB.DBLayout.hdbMakeEntry Key)))
  > data Key = Key
  > instance Database.HaskellDB.HDBRec.FieldTag Key
  >     where Database.HaskellDB.HDBRec.fieldName _ = "Key"
  > key :: Database.HaskellDB.Query.Attr Key GHC.Types.Int
  > key = Database.HaskellDB.DBLayout.mkAttr Key
  > data User = User
  > instance Database.HaskellDB.HDBRec.FieldTag User
  >     where Database.HaskellDB.HDBRec.fieldName _ = "User"
  > user :: Database.HaskellDB.Query.Attr User GHC.Base.String
  > user = Database.HaskellDB.DBLayout.mkAttr User
  > data Hash = Hash
  > instance Database.HaskellDB.HDBRec.FieldTag Hash
  >     where Database.HaskellDB.HDBRec.fieldName _ = "Hash"
  > hash :: Database.HaskellDB.Query.Attr Hash GHC.Base.String
  > hash = Database.HaskellDB.DBLayout.mkAttr Hash

  It's that easy.
-}
module Database.HaskellDB.Template 
    ( Names (..)
    , Field (..)
    , Table (..)
    , mkNames
    , (.::)
    , mkField
    , mkTable
    , genField
    , genTable
    , genTableAndFields
    ) where

import           Language.Haskell.TH
import           Control.Monad
import           Data.List
import           Data.Char

import qualified Database.HaskellDB as HDB
import qualified Database.HaskellDB.HDBRec as HDB
import qualified Database.HaskellDB.DBLayout as HDB

data Names = Names
    { typeName :: Name
    , varName :: Name
    }

data Field = Field
    { fieldNames :: Names
    , fieldInDB :: String
    , fieldTypeQ :: TypeQ
    }

data Table = Table
    { tableNames :: Names
    , tableInDB :: String
    , tableFields :: [Field]
    }

{-|
  This will create a type and variable from a given string that are identical
  save for being properly captalized.
-}
mkNames :: String -> Names
mkNames "" = error "Database.HaskellDB.Template: Empty names passed to mkNames"
mkNames (c:cs) = Names
    { typeName = mkName $ toUpper c : cs
    , varName = mkName $ toLower c : cs
    }

{-| 
  A shortcut function to build a 'Field' from just a name
  and a type.  For more complicated needs, use the
  type constructor.
-}
mkField :: String -> TypeQ -> Field
mkField name typeQ = Field
    { fieldNames = mkNames name
    , fieldInDB = name
    , fieldTypeQ = typeQ
    }

(.::) :: String -> TypeQ -> Field
(.::) = mkField
infix 1 .::

{-| 
  A shortcut function to build a 'Table' from just a name
  and a list of 'Field's.  For more complicated needs, use the
  type constructor.
-}
mkTable :: String -> [Field] -> Table
mkTable name fields = Table
    { tableNames = mkNames name
    , tableInDB = name
    , tableFields = fields
    }

{-|
  Generates a field declaration from a 'Field' type
-}
genField :: Field -> Q [Dec]
genField field = do
    colType <- fieldTypeQ field
    return 
        [ DataD [] fieldType [] [NormalC fieldType []] []
        , InstanceD [] (foldr1 AppT $ map ConT [''HDB.FieldTag, fieldType])
            [ FunD 'HDB.fieldName [Clause [WildP] (NormalB
                $ LitE $ StringL $ fieldInDB field) []]
            ]
        , SigD fieldName $ foldl1 AppT $ map ConT 
            [''HDB.Attr, fieldType] ++ [colType]
        , flip (ValD $ VarP fieldName) [] $ NormalB $ AppE
            (VarE 'HDB.mkAttr) $ ConE fieldType
        ]
  where fieldType = typeName $ fieldNames field
        fieldName = varName $ fieldNames field

{-|
  Generates a table declaration from a 'Table' type
-}
genTable :: Table -> Q [Dec]
genTable table = do
    let tableType = typeName $ tableNames table
    let tableName = varName $ tableNames table
    recCons <- foldM recConQ (ConT ''HDB.RecNil) $ fields
    return 
        [ TySynD tableType [] recCons
        , SigD tableName $ AppT (ConT ''HDB.Table) $ ConT tableType
        , flip (ValD $ VarP tableName) [] $ NormalB $ foldl1 AppE
            [ VarE 'HDB.baseTable
            , LitE $ StringL $ tableInDB table
            , foldr1 (\x acc -> AppE (AppE (VarE $ mkName "#") x ) acc)
                $ map (AppE (VarE 'HDB.hdbMakeEntry)  
                    . ConE . typeName . fieldNames) fields
            ]
        ]
  where fields = reverse $ tableFields table
        recConQ recCon field = do
            colType <- fieldTypeQ field
            return $ foldl1 AppT 
                [ ConT ''HDB.RecCons
                , ConT $ typeName $ fieldNames field
                , AppT (ConT ''HDB.Expr) colType
                , recCon
                ]
            

{-|
  Generates both a table and all its fields from a single Table type.
-}
genTableAndFields :: Table -> Q [Dec]
genTableAndFields table = do
    tableDecl <- genTable table
    fieldsDecl <- fmap concat $ mapM genField $ tableFields table
    return $ tableDecl ++ fieldsDecl
