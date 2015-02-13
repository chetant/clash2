{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE ViewPatterns      #-}

-- | Generate VHDL for assorted Netlist datatypes
module CLaSH.Backend.Verilog (VerilogState) where

import qualified Control.Applicative                  as A
import           Control.Lens                         hiding (Indexed)
import           Control.Monad                        (forM,join,liftM,when,zipWithM)
import           Control.Monad.State                  (State)
import           Data.Graph.Inductive                 (Gr, mkGraph, topsort')
import           Data.HashMap.Lazy                    (HashMap)
import qualified Data.HashMap.Lazy                    as HashMap
import           Data.HashSet                         (HashSet)
import qualified Data.HashSet                         as HashSet
import           Data.List                            (mapAccumL,nubBy)
import           Data.Maybe                           (catMaybes,mapMaybe)
import           Data.Text.Lazy                       (unpack)
import qualified Data.Text.Lazy                       as T
import           Text.PrettyPrint.Leijen.Text.Monadic

import           CLaSH.Backend
import           CLaSH.Netlist.BlackBox.Util          (renderBlackBox)
import           CLaSH.Netlist.Types
import           CLaSH.Netlist.Util
import           CLaSH.Util                           (clog2, curLoc, makeCached, (<:>))

#ifdef CABAL
import qualified Paths_clash_vhdl
#else
import qualified System.FilePath
#endif

-- | State for the 'CLaSH.Netlist.VHDL.VHDLM' monad:
data VerilogState =
  VerilogState {}
  -- { _tyCache   :: (HashSet HWType)     -- ^ Previously encountered HWTypes
  -- , _tyCount   :: Int                  -- ^ Product type counter
  -- , _nameCache :: (HashMap HWType Doc) -- ^ Cache for previously generated product type names
  -- }

makeLenses ''VerilogState

instance Backend VerilogState where
  initBackend     = VerilogState
#ifdef CABAL
  primDir         = const (Paths_clash_verilog.getDataFileName "primitives")
#else
  primDir _       = return ("clash-verilog_alt" System.FilePath.</> "primitives")
#endif
  extractTypes    = const HashSet.empty
  name            = const "verilog"
  extension       = const ".sv"

  genHDL          = genVerilog
  mkTyPackage     = const empty
  hdlType         = verilogType
  hdlTypeErrValue = verilogTypeErrValue
  hdlTypeMark     = error $ $(curLoc) ++ "not yet implemented"
  hdlSig t ty     = sigType (text t) ty
  inst            = inst_
  expr            = expr_

type VHDLM a = State VerilogState a
type VerilogM a = State VerilogState a

-- | Generate VHDL for a Netlist component
genVerilog :: Component -> VerilogM (String,Doc)
genVerilog c = (unpack cName,) A.<$> verilog
  where
    cName   = componentName c
    verilog = "// Automatically generated verilog" <$> module_ c

-- | Generate a VHDL package containing type definitions for the given HWTypes
mkTyPackage_ :: [HWType]
             -> VHDLM Doc
mkTyPackage_ hwtys =
   "library IEEE;" <$>
   "use IEEE.STD_LOGIC_1164.ALL;" <$>
   "use IEEE.NUMERIC_STD.ALL;" <$$> linebreak <>
   "package" <+> "types" <+> "is" <$>
      indent 2 ( packageDec <$>
                 vcat (sequence funDecs)
               ) <>
      (case showDecs of
         [] -> empty
         _  -> linebreak <$>
               "-- pragma translate_off" <$>
               indent 2 (vcat (sequence showDecs)) <$>
               "-- pragma translate_on"
      ) <$>
   "end" <> semi <> packageBodyDec
  where
    usedTys     = nubBy eqHWTy $ concatMap mkUsedTys hwtys
    needsDec    = nubBy eqHWTy (hwtys ++ filter needsTyDec usedTys)
    hwTysSorted = topSortHWTys needsDec
    packageDec  = vcat $ mapM tyDec hwTysSorted
    (funDecs,funBodies) = unzip . catMaybes $ map funDec (nubBy eqIndexTy usedTys)
    (showDecs,showBodies) = unzip $ map mkToStringDecls hwTysSorted

    packageBodyDec :: VHDLM Doc
    packageBodyDec = case (funBodies,showBodies) of
        ([],[]) -> empty
        _  -> linebreak <$>
              "package" <+> "body" <+> "types" <+> "is" <$>
                indent 2 (vcat (sequence funBodies)) <$>
                linebreak <>
                "-- pragma translate_off" <$>
                indent 2 (vcat (sequence showBodies)) <$>
                "-- pragma translate_on" <$>
              "end" <> semi

    eqIndexTy :: HWType -> HWType -> Bool
    eqIndexTy (Index _) (Index _) = True
    eqIndexTy _ _ = False

    eqHWTy :: HWType -> HWType -> Bool
    eqHWTy (Vector _ elTy1) (Vector _ elTy2) = case (elTy1,elTy2) of
      (Sum _ _,Sum _ _)    -> typeSize elTy1 == typeSize elTy2
      (Unsigned n,Sum _ _) -> n == typeSize elTy2
      (Sum _ _,Unsigned n) -> typeSize elTy1 == n
      (Index u,Unsigned n) -> clog2 (max 2 u) == n
      (Unsigned n,Index u) -> clog2 (max 2 u) == n
      _ -> elTy1 == elTy2
    eqHWTy ty1 ty2 = ty1 == ty2

mkUsedTys :: HWType
        -> [HWType]
mkUsedTys v@(Vector _ elTy)   = v : mkUsedTys elTy
mkUsedTys p@(Product _ elTys) = p : concatMap mkUsedTys elTys
mkUsedTys sp@(SP _ elTys)     = sp : concatMap mkUsedTys (concatMap snd elTys)
mkUsedTys t                   = [t]

topSortHWTys :: [HWType]
             -> [HWType]
topSortHWTys hwtys = sorted
  where
    nodes  = zip [0..] hwtys
    nodesI = HashMap.fromList (zip hwtys [0..])
    edges  = concatMap edge hwtys
    graph  = mkGraph nodes edges :: Gr HWType ()
    sorted = reverse $ topsort' graph

    edge t@(Vector _ elTy) = maybe [] ((:[]) . (HashMap.lookupDefault (error $ $(curLoc) ++ "Vector") t nodesI,,()))
                                      (HashMap.lookup (mkVecZ elTy) nodesI)
    edge t@(Product _ tys) = let ti = HashMap.lookupDefault (error $ $(curLoc) ++ "Product") t nodesI
                             in mapMaybe (\ty -> liftM (ti,,()) (HashMap.lookup (mkVecZ ty) nodesI)) tys
    edge t@(SP _ ctys)     = let ti = HashMap.lookupDefault (error $ $(curLoc) ++ "SP") t nodesI
                             in concatMap (\(_,tys) -> mapMaybe (\ty -> liftM (ti,,()) (HashMap.lookup (mkVecZ ty) nodesI)) tys) ctys
    edge _                 = []

mkVecZ :: HWType -> HWType
mkVecZ (Vector _ elTy) = Vector 0 elTy
mkVecZ t               = t

needsTyDec :: HWType -> Bool
needsTyDec (Vector _ _)   = True
needsTyDec (Product _ _)  = True
needsTyDec (SP _ _)       = True
needsTyDec Bool           = True
needsTyDec Integer        = True
needsTyDec _              = False

tyDec :: HWType -> VHDLM Doc
tyDec (Vector _ elTy) = "type" <+> "array_of_" <> tyName elTy <+> "is array (integer range <>) of" <+> vhdlType elTy <> semi

tyDec ty@(Product _ tys) = prodDec
  where
    prodDec = "type" <+> tName <+> "is record" <$>
                indent 2 (vcat $ zipWithM (\x y -> x <+> colon <+> y <> semi) selNames selTys) <$>
              "end record" <> semi

    tName    = tyName ty
    selNames = map (\i -> tName <> "_sel" <> int i) [0..]
    selTys   = map vhdlType tys

tyDec _ = empty

funDec :: HWType -> Maybe (VHDLM Doc,VHDLM Doc)
funDec Bool = Just
  ( "function" <+> "toSLV" <+> parens ("b" <+> colon <+> "in" <+> "boolean") <+> "return" <+> "std_logic_vector" <> semi <$>
    "function" <+> "fromSL" <+> parens ("sl" <+> colon <+> "in" <+> "std_logic_vector") <+> "return" <+> "boolean" <> semi
  , "function" <+> "toSLV" <+> parens ("b" <+> colon <+> "in" <+> "boolean") <+> "return" <+> "std_logic_vector" <+> "is" <$>
    "begin" <$>
      indent 2 (vcat $ sequence ["if" <+> "b" <+> "then"
                                ,  indent 2 ("return" <+> dquotes (int 1) <> semi)
                                ,"else"
                                ,  indent 2 ("return" <+> dquotes (int 0) <> semi)
                                ,"end" <+> "if" <> semi
                                ]) <$>
    "end" <> semi <$>
    "function" <+> "fromSL" <+> parens ("sl" <+> colon <+> "in" <+> "std_logic_vector") <+> "return" <+> "boolean" <+> "is" <$>
    "begin" <$>
      indent 2 (vcat $ sequence ["if" <+> "sl" <+> "=" <+> dquotes (int 1) <+> "then"
                                ,   indent 2 ("return" <+> "true" <> semi)
                                ,"else"
                                ,   indent 2 ("return" <+> "false" <> semi)
                                ,"end" <+> "if" <> semi
                                ]) <$>
    "end" <> semi
  )

funDec Integer = Just
  ( "function" <+> "to_integer" <+> parens ("i" <+> colon <+> "in" <+> "integer") <+> "return" <+> "integer" <> semi
  , "function" <+> "to_integer" <+> parens ("i" <+> colon <+> "in" <+> "integer") <+> "return" <+> "integer" <+> "is" <$>
    "begin" <$>
      indent 2 ("return" <+> "i" <> semi) <$>
    "end" <> semi
  )

funDec (Index _) =  Just
  ( "function" <+> "max" <+> parens ("left, right: in integer") <+> "return integer" <> semi
  , "function" <+> "max" <+> parens ("left, right: in integer") <+> "return integer" <+> "is" <$>
    "begin" <$>
      indent 2 (vcat $ sequence [ "if" <+> "left > right" <+> "then return left" <> semi
                                , "else return right" <> semi
                                , "end if" <> semi
                                ]) <$>
    "end" <> semi
  )

funDec _ = Nothing

mkToStringDecls :: HWType -> (VHDLM Doc, VHDLM Doc)
mkToStringDecls t@(Product _ elTys) =
  ( "function to_string" <+> parens ("value :" <+> vhdlType t) <+> "return STRING" <> semi
  , "function to_string" <+> parens ("value :" <+> vhdlType t) <+> "return STRING is" <$>
    "begin" <$>
    indent 2 ("return" <+> parens (hcat (punctuate " & " elTyPrint)) <> semi) <$>
    "end function to_string;"
  )
  where
    elTyPrint = forM [0..(length elTys - 1)]
                     (\i -> "to_string" <>
                            parens ("value." <> vhdlType t <> "_sel" <> int i))
mkToStringDecls t@(Vector _ elTy) =
  ( "function to_string" <+> parens ("value : " <+> vhdlTypeMark t) <+> "return STRING" <> semi
  , "function to_string" <+> parens ("value : " <+> vhdlTypeMark t) <+> "return STRING is" <$>
      indent 2
        ( "alias ivalue    : " <+> vhdlTypeMark t <> "(1 to value'length) is value;" <$>
          "variable result : STRING" <> parens ("1 to value'length * " <> int (typeSize elTy)) <> semi
        ) <$>
    "begin" <$>
      indent 2
        ("for i in ivalue'range loop" <$>
            indent 2
              (  "result" <> parens (parens ("(i - 1) * " <> int (typeSize elTy)) <+> "+ 1" <+>
                                             "to i*" <> int (typeSize elTy)) <+>
                          ":= to_string" <> parens (if elTy == Bool then "toSLV(ivalue(i))" else "ivalue(i)") <> semi
              ) <$>
         "end loop;" <$>
         "return result;"
        ) <$>
    "end function to_string;"
  )
mkToStringDecls _ = (empty,empty)

tyImports :: VHDLM Doc
tyImports =
  punctuate' semi $ sequence
    [ "library IEEE"
    , "use IEEE.STD_LOGIC_1164.ALL"
    , "use IEEE.NUMERIC_STD.ALL"
    , "use IEEE.MATH_REAL.ALL"
    , "use work.all"
    , "use work.types.all"
    ]

module_ :: Component -> VerilogM Doc
module_ c =
    "module" <+> text (componentName c) <> tupled ports <> semi <$>
    indent 2 (inputPorts <$> outputPort <$$> decls (declarations c)) <$$> insts (declarations c) <$>
    "endmodule"
  where
    ports = sequence
          $ [ text i | (i,_) <- inputs c ] ++
            [ text i | (i,_) <- hiddenPorts c] ++
            [ text (fst $ output c) ]

    inputPorts = case (inputs c ++ hiddenPorts c) of
                   [] -> empty
                   p  -> vcat (punctuate semi (sequence [ "input" <+> sigType (text i) ty | (i,ty) <- p ])) <> semi

    outputPort = "output" <+> sigType (text (fst $ output c)) (snd $ output c) <> semi


entity :: Component -> VHDLM Doc
entity c = do
    rec (p,ls) <- fmap unzip (ports (maximum ls))
    "entity" <+> text (componentName c) <+> "is" <$>
      (case p of
         [] -> empty
         _  -> indent 2 ("port" <>
                         parens (align $ vcat $ punctuate semi (A.pure p)) <>
                         semi)
      ) <$>
      "end" <> semi
  where
    ports l = sequence
            $ [ (,fromIntegral $ T.length i) A.<$> (fill l (text i) <+> colon <+> "in" <+> vhdlType ty)
              | (i,ty) <- inputs c ] ++
              [ (,fromIntegral $ T.length i) A.<$> (fill l (text i) <+> colon <+> "in" <+> vhdlType ty)
              | (i,ty) <- hiddenPorts c ] ++
              [ (,fromIntegral $ T.length (fst $ output c)) A.<$> (fill l (text (fst $ output c)) <+> colon <+> "out" <+> vhdlType (snd $ output c))
              ]

architecture :: Component -> VHDLM Doc
architecture c =
  nest 2
    ("architecture structural of" <+> text (componentName c) <+> "is" <$$>
     decls (declarations c)) <$$>
  nest 2
    ("begin" <$$>
     insts (declarations c)) <$$>
    "end" <> semi

-- | Convert a Netlist HWType to a VHDL type
vhdlType :: HWType -> VHDLM Doc
vhdlType hwty = do
  when (needsTyDec hwty) (undefined %= HashSet.insert (mkVecZ hwty))
  vhdlType' hwty

vhdlType' :: HWType -> VHDLM Doc
vhdlType' Bool            = "boolean"
vhdlType' (Clock _)       = "std_logic"
vhdlType' (Reset _)       = "std_logic"
vhdlType' Integer         = "integer"
vhdlType' (BitVector n)   = case n of
                              0 -> "std_logic_vector (0 downto 1)"
                              _ -> "std_logic_vector" <> parens (int (n-1) <+> "downto 0")
vhdlType' (Index u)       = "unsigned" <> parens (int (clog2 (max 2 u) - 1) <+> "downto 0")
vhdlType' (Signed n)      = if n == 0 then "signed (0 downto 1)"
                                      else "signed" <> parens (int (n-1) <+> "downto 0")
vhdlType' (Unsigned n)    = if n == 0 then "unsigned (0 downto 1)"
                                      else "unsigned" <> parens ( int (n-1) <+> "downto 0")
vhdlType' (Vector n elTy) = "array_of_" <> tyName elTy <> parens ("0 to " <> int (n-1))
vhdlType' t@(SP _ _)      = "std_logic_vector" <> parens (int (typeSize t - 1) <+> "downto 0")
vhdlType' t@(Sum _ _)     = case typeSize t of
                              0 -> "unsigned (0 downto 1)"
                              n -> "unsigned" <> parens (int (n -1) <+> "downto 0")
vhdlType' t@(Product _ _) = tyName t
vhdlType' Void            = "std_logic_vector" <> parens (int (-1) <+> "downto 0")

verilogType :: HWType -> VerilogM Doc
verilogType Bool       = "[0:0]"
verilogType Integer    = "signed [31:0]"
verilogType t@(SP _ _) = brackets (int (typeSize t - 1) <> colon <> int 0)
verilogType x = error ($(curLoc) ++ show x ++ "not supported")

sigType :: VerilogM Doc -> HWType -> VerilogM Doc
sigType d Bool            = "[0:0]" <+> d
sigType d (Clock _)       = "[0:0]" <+> d
sigType d (Reset _)       = "[0:0]" <+> d
sigType d Integer         = "[31:0]" <+> d
sigType d (Vector n elTy@(Vector _ _)) = sigType d elTy <> brackets (int 0 <> colon <> int (n-1))
sigType d (Vector n elTy) = sigType d elTy <+> brackets (int 0 <> colon <> int (n-1))
sigType d t@(SP _ _) = brackets (int (typeSize t - 1) <> colon <> int 0) <+> d
sigType _ x = error ($(curLoc) ++ show x ++ "not supported")

-- | Convert a Netlist HWType to the root of a VHDL type
vhdlTypeMark :: HWType -> VHDLM Doc
vhdlTypeMark hwty = do
  when (needsTyDec hwty) (undefined %= HashSet.insert (mkVecZ hwty))
  vhdlTypeMark' hwty
  where
    vhdlTypeMark' Bool            = "boolean"
    vhdlTypeMark' (Clock _)       = "std_logic"
    vhdlTypeMark' (Reset _)       = "std_logic"
    vhdlTypeMark' Integer         = "integer"
    vhdlTypeMark' (BitVector _)   = "std_logic_vector"
    vhdlTypeMark' (Index _)       = "unsigned"
    vhdlTypeMark' (Signed _)      = "signed"
    vhdlTypeMark' (Unsigned _)    = "unsigned"
    vhdlTypeMark' (Vector _ elTy) = "array_of_" <> tyName elTy
    vhdlTypeMark' (SP _ _)        = "std_logic_vector"
    vhdlTypeMark' (Sum _ _)       = "unsigned"
    vhdlTypeMark' t@(Product _ _) = tyName t
    vhdlTypeMark' t               = error $ $(curLoc) ++ "vhdlTypeMark: " ++ show t

tyName :: HWType -> VHDLM Doc
tyName Integer           = "integer"
tyName Bool              = "boolean"
tyName (Vector n elTy)   = "array_of_" <> int n <> "_" <> tyName elTy
tyName (BitVector n)     = "std_logic_vector_" <> int n
tyName t@(Index _)       = "unsigned_" <> int (typeSize t)
tyName (Signed n)        = "signed_" <> int n
tyName (Unsigned n)      = "unsigned_" <> int n
tyName t@(Sum _ _)       = "unsigned_" <> int (typeSize t)
tyName t@(Product _ _)   = makeCached t undefined prodName
  where
    prodName = do i <- undefined <<%= (+1)
                  "product" <> int i
tyName t@(SP _ _)        = "std_logic_vector_" <> int (typeSize t)
tyName _ = empty

-- | Convert a Netlist HWType to an error VHDL value for that type
verilogTypeErrValue :: HWType -> VHDLM Doc
verilogTypeErrValue Integer         = "32'sd" <> int ((2 ^ 31) - 1)
verilogTypeErrValue (Vector n elTy) = braces (hcat $ punctuate comma (mapM verilogTypeErrValue (replicate n elTy)))
vhdlTypeErrValue e = error $ $(curLoc) ++ "no error value defined for: " ++ show e
-- vhdlTypeErrValue Bool                = "true"
-- vhdlTypeErrValue Integer             = "integer'high"
-- vhdlTypeErrValue (BitVector _)       = "(others => 'X')"
-- vhdlTypeErrValue (Index _)           = "(others => 'X')"
-- vhdlTypeErrValue (Signed _)          = "(others => 'X')"
-- vhdlTypeErrValue (Unsigned _)        = "(others => 'X')"
-- vhdlTypeErrValue (Vector _ elTy)     = parens ("others" <+> rarrow <+> vhdlTypeErrValue elTy)
-- vhdlTypeErrValue (SP _ _)            = "(others => 'X')"
-- vhdlTypeErrValue (Sum _ _)           = "(others => 'X')"
-- vhdlTypeErrValue (Product _ elTys)   = tupled $ mapM vhdlTypeErrValue elTys
-- vhdlTypeErrValue (Reset _)           = "'X'"
-- vhdlTypeErrValue (Clock _)           = "'X'"
-- vhdlTypeErrValue Void                = "(0 downto 1 => 'X')"

decls :: [Declaration] -> VerilogM Doc
decls [] = empty
decls ds = do
    dsDoc <- catMaybes A.<$> mapM decl ds
    case dsDoc of
      [] -> empty
      _  -> vcat (punctuate semi (A.pure dsDoc)) <> semi

decl :: Declaration -> VHDLM (Maybe Doc)
decl (NetDecl id_ ty _) = Just A.<$> "wire" <+> sigType (text id_) ty

decl _ = return Nothing

insts :: [Declaration] -> VerilogM Doc
insts [] = empty
insts is = indent 2 . vcat . punctuate linebreak . fmap catMaybes $ mapM inst_ is

-- | Turn a Netlist Declaration to a VHDL concurrent block
inst_ :: Declaration -> VerilogM (Maybe Doc)
inst_ (Assignment id_ e) = fmap Just $
  "assign" <+> text id_ <+> equals <+> expr_ False e <> semi

inst_ (CondAssignment id_ scrut es) = fmap Just $
    "always @(*)" <$>
    "case" <> parens (expr_ True scrut) <$>
      (indent 2 $ vcat $ punctuate semi (conds es)) <> semi <$>
    "endcase"
  where
    conds :: [(Maybe Expr,Expr)] -> VerilogM [Doc]
    conds []                = return []
    conds [(_,e)]           = ("default" <+> colon <+> text id_ <+> equals <+> expr_ False e) <:> return []
    conds ((Nothing,e):_)   = ("default" <+> colon <+> text id_ <+> equals <+> expr_ False e) <:> return []
    conds ((Just c ,e):es') = (expr_ True c <+> colon <+> text id_ <+> equals <+> expr_ False e) <:> conds es'

inst_ (InstDecl nm lbl pms) = fmap Just $
    text nm <+> text lbl <$$> pms' <> semi
  where
    pms' = tupled $ sequence [dot <> text i <+> parens (expr_ False e) | (i,e) <- pms]

inst_ (BlackBoxD bs bbCtx) = do t <- renderBlackBox bs bbCtx
                                fmap Just (string t)

inst_ (NetDecl _ _ _) = return Nothing

-- | Turn a Netlist expression into a VHDL expression
expr_ :: Bool -- ^ Enclose in parenthesis?
      -> Expr -- ^ Expr to convert
      -> VerilogM Doc
expr_ _ (Literal sizeM lit)                           = exprLit sizeM lit
expr_ _ (Identifier id_ Nothing)                      = text id_
-- expr_ _ (Identifier id_ (Just (Indexed (ty@(SP _ args),dcI,fI)))) = fromSLV argTy id_ start end
--   where
--     argTys   = snd $ args !! dcI
--     argTy    = argTys !! fI
--     argSize  = typeSize argTy
--     other    = otherSize argTys (fI-1)
--     start    = typeSize ty - 1 - conSize ty - other
--     end      = start - argSize + 1

-- expr_ _ (Identifier id_ (Just (Indexed (ty@(Product _ _),_,fI)))) = text id_ <> dot <> tyName ty <> "_sel" <> int fI
expr_ _ (Identifier id_ (Just (DC (ty@(SP _ _),_)))) = text id_ <> brackets (int start <> colon <> int end)
  where
    start = typeSize ty - 1
    end   = typeSize ty - conSize ty

expr_ _ (Identifier id_ (Just _)) = text id_
-- expr_ _ (DataCon ty@(Vector 1 _) _ [e])           = vhdlTypeMark ty <> "'" <> parens (int 0 <+> rarrow <+> expr_ False e)
-- expr_ _ e@(DataCon ty@(Vector _ elTy) _ [e1,e2])     = vhdlTypeMark ty <> "'" <> case vectorChain e of
--                                                      Just es -> tupled (mapM (expr_ False) es)
--                                                      Nothing -> parens (vhdlTypeMark elTy <> "'" <> parens (expr_ False e1) <+> "&" <+> expr_ False e2)
expr_ _ (DataCon ty@(SP _ args) (Just (DC (_,i))) es) = assignExpr
  where
    argTys     = snd $ args !! i
    dcSize     = conSize ty + sum (map typeSize argTys)
    dcExpr     = expr_ False (dcToExpr ty i)
    argExprs   = zipWith toSLV argTys es -- (map (expr_ False) es)
    extraArg   = case typeSize ty - dcSize of
                   0 -> []
                   n -> [exprLit (Just (ty,n)) (NumLit 0)]
    assignExpr = braces (hcat $ punctuate comma $ sequence (dcExpr:argExprs ++ extraArg))

-- expr_ _ (DataCon ty@(Sum _ _) (Just (DC (_,i))) []) = "to_unsigned" <> tupled (sequence [int i,int (typeSize ty)])
-- expr_ _ (DataCon ty@(Product _ _) _ es)             = tupled $ zipWithM (\i e -> tName <> "_sel" <> int i <+> rarrow <+> expr_ False e) [0..] es
--   where
--     tName = tyName ty

-- expr_ b (BlackBoxE bs bbCtx b' (Just (DC (ty@(SP _ _),_)))) = do
--     t <- renderBlackBox bs bbCtx
--     parenIf (b || b') $ parens (string t) <> parens (int start <+> "downto" <+> int end)
--   where
--     start = typeSize ty - 1
--     end   = typeSize ty - conSize ty
expr_ b (BlackBoxE bs bbCtx b' _) = do
  t <- renderBlackBox bs bbCtx
  parenIf (b || b') $ string t

expr_ _ (DataTag Bool (Left e))           = parens (expr False e <+> "== 32'sd0") <+> "? 1'b0 : 1'b1"
-- expr_ _ (DataTag Bool (Right e))          = "1 when" <+> expr_ False e <+> "else 0"
-- expr_ _ (DataTag hty@(Sum _ _) (Left e))  = "to_unsigned" <> tupled (sequence [expr_ False e,int (typeSize hty)])
-- expr_ _ (DataTag (Sum _ _) (Right e))     = "to_integer" <> parens (expr_ False e)

-- expr_ _ (DataTag (Product _ _) (Right _)) = int 0
-- expr_ _ (DataTag hty@(SP _ _) (Right e))  = "to_integer" <> parens
--                                                 ("unsigned" <> parens
--                                                 (expr_ False e <> parens
--                                                 (int start <+> "downto" <+> int end)))
--   where
--     start = typeSize hty - 1
--     end   = typeSize hty - conSize hty

-- expr_ _ (DataTag (Vector 0 _) (Right _)) = int 0
-- expr_ _ (DataTag (Vector _ _) (Right _)) = int 1

expr_ _ e = error $ $(curLoc) ++ (show e) -- empty

otherSize :: [HWType] -> Int -> Int
otherSize _ n | n < 0 = 0
otherSize []     _    = 0
otherSize (a:as) n    = typeSize a + otherSize as (n-1)

vectorChain :: Expr -> Maybe [Expr]
vectorChain (DataCon (Vector _ _) Nothing _)        = Just []
vectorChain (DataCon (Vector 1 _) (Just _) [e])     = Just [e]
vectorChain (DataCon (Vector _ _) (Just _) [e1,e2]) = Just e1 <:> vectorChain e2
vectorChain _                                       = Nothing

exprLit :: Maybe (HWType,Size) -> Literal -> VerilogM Doc
exprLit Nothing         (NumLit i) = "32'sd" <> integer i
exprLit (Just (hty,sz)) (NumLit i) = case hty of
                                       Unsigned _  -> int sz <> "'d" <> integer i
                                       Signed _    -> int sz <> "'sd" <> integer i
                                       _           -> int sz <> "'b" <> blit
-- exprLit (Just (hty,sz)) (NumLit i) = case hty of
--                                        Unsigned _  -> "unsigned'" <> parens blit
--                                        Signed   _  -> "signed'" <> parens blit
--                                        BitVector _ -> "std_logic_vector'" <> parens blit
--                                        _           -> blit

  where
    blit = bits (toBits sz i)
exprLit _             (BoolLit t)  = if t then "1'b1" else "1'b0"
-- exprLit _             (BitLit b)   = squotes $ bit_char b
exprLit _             l            = error $ $(curLoc) ++ "exprLit: " ++ show l

toBits :: Integral a => Int -> a -> [Bit]
toBits size val = map (\x -> if odd x then H else L)
                $ reverse
                $ take size
                $ map (`mod` 2)
                $ iterate (`div` 2) val

bits :: [Bit] -> VerilogM Doc
bits = hcat . mapM bit_char

bit_char :: Bit -> VerilogM Doc
bit_char H = char '1'
bit_char L = char '0'
bit_char U = char 'U'
bit_char Z = char 'Z'

toSLV :: HWType -> Expr -> VerilogM Doc
toSLV Integer e = expr_ False e
-- toSLV Bool         e = "toSLV" <> parens (expr_ False e)
-- toSLV Integer      e = "std_logic_vector" <> parens ("to_signed" <> tupled (sequence [expr_ False e,int 32]))
-- toSLV (BitVector _) e = expr_ False e
-- toSLV (Signed _)   e = "std_logic_vector" <> parens (expr_ False e)
-- toSLV (Unsigned _) e = "std_logic_vector" <> parens (expr_ False e)
-- toSLV (Sum _ _)    e = "std_logic_vector" <> parens (expr_ False e)
-- toSLV t@(Product _ tys) (Identifier id_ Nothing) = do
--     selIds' <- sequence selIds
--     encloseSep lparen rparen " & " (zipWithM toSLV tys selIds')
--   where
--     tName    = tyName t
--     selNames = map (fmap (displayT . renderOneLine) ) [text id_ <> dot <> tName <> "_sel" <> int i | i <- [0..(length tys)-1]]
--     selIds   = map (fmap (\n -> Identifier n Nothing)) selNames
-- toSLV (Product _ tys) (DataCon _ _ es) = encloseSep lparen rparen " & " (zipWithM toSLV tys es)
-- toSLV (SP _ _) e = expr_ False e
-- toSLV (Vector n elTy) (Identifier id_ Nothing) = do
--     selIds' <- sequence (reverse selIds)
--     parens (encloseSep lparen rparen " & " (mapM (toSLV elTy) selIds'))
--   where
--     selNames = map (fmap (displayT . renderOneLine) ) $ reverse [text id_ <> parens (int i) | i <- [0 .. (n-1)]]
--     selIds   = map (fmap (`Identifier` Nothing)) selNames
-- toSLV (Vector n elTy) (DataCon _ _ es) = encloseSep lparen rparen " & " (zipWithM toSLV [elTy,Vector (n-1) elTy] es)
toSLV hty      e = error $ $(curLoc) ++  "toSLV: ty:" ++ show hty ++ "\n expr: " ++ show e

fromSLV :: HWType -> Identifier -> Int -> Int -> VHDLM Doc
fromSLV Bool              id_ start _   = "fromSL" <> parens (text id_ <> parens (int start))
fromSLV Integer           id_ start end = "to_integer" <> parens (fromSLV (Signed 32) id_ start end)
fromSLV (BitVector _)     id_ start end = text id_ <> parens (int start <+> "downto" <+> int end)
fromSLV (Index _)         id_ start end = "unsigned" <> parens (text id_ <> parens (int start <+> "downto" <+> int end))
fromSLV (Signed _)        id_ start end = "signed" <> parens (text id_ <> parens (int start <+> "downto" <+> int end))
fromSLV (Unsigned _)      id_ start end = "unsigned" <> parens (text id_ <> parens (int start <+> "downto" <+> int end))
fromSLV (Sum _ _)         id_ start end = "unsigned" <> parens (text id_ <> parens (int start <+> "downto" <+> int end))
fromSLV t@(Product _ tys) id_ start _   = tupled $ zipWithM (\s e -> s <+> rarrow <+> e) selNames args
  where
    tName      = tyName t
    selNames   = [tName <> "_sel" <> int i | i <- [0..]]
    argLengths = map typeSize tys
    starts     = start : snd (mapAccumL ((join (,) .) . (-)) start argLengths)
    ends       = map (+1) (tail starts)
    args       = zipWith3 (`fromSLV` id_) tys starts ends

fromSLV (SP _ _)          id_ start end = text id_ <> parens (int start <+> "downto" <+> int end)
fromSLV (Vector n elTy)   id_ start _   = tupled (fmap reverse args)
  where
    argLength = typeSize elTy
    starts    = take (n + 1) $ iterate (subtract argLength) start
    ends      = map (+1) (tail starts)
    args      = zipWithM (fromSLV elTy id_) starts ends
fromSLV hty               _   _     _   = error $ $(curLoc) ++ "fromSLV: " ++ show hty

dcToExpr :: HWType -> Int -> Expr
dcToExpr ty i = Literal (Just (ty,conSize ty)) (NumLit (toInteger i))

larrow :: VHDLM Doc
larrow = "<="

rarrow :: VHDLM Doc
rarrow = "=>"

parenIf :: Monad m => Bool -> m Doc -> m Doc
parenIf True  = parens
parenIf False = id

punctuate' :: Monad m => m Doc -> m [Doc] -> m Doc
punctuate' s d = vcat (punctuate s d) <> s