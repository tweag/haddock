{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Haddock.Backends.Hoogle
-- Copyright   :  (c) Neil Mitchell 2006-2008
-- License     :  BSD-like
--
-- Maintainer  :  haddock@projects.haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- Write out Hoogle compatible documentation
-- http://www.haskell.org/hoogle/
-----------------------------------------------------------------------------
module Haddock.Backends.Hoogle (
    ppHoogle
  ) where

import BasicTypes (OverlapFlag(..), OverlapMode(..), SourceText(..))
import InstEnv (ClsInst(..))
import Documentation.Haddock.Markup
import Haddock.GhcUtils
import Haddock.Types hiding (Version)
import Haddock.Utils hiding (out)

import HsBinds (emptyLHsBinds)
import GHC
import Outputable
import NameSet

import Data.Char
import Data.List
import Data.Maybe
import Data.Version

import System.Directory
import System.FilePath
import System.IO

import Weight

prefix :: [String]
prefix = ["-- Hoogle documentation, generated by Haddock"
         ,"-- See Hoogle, http://www.haskell.org/hoogle/"
         ,""]


ppHoogle :: DynFlags -> String -> Version -> String -> Maybe (Doc RdrName) -> [Interface] -> FilePath -> IO ()
ppHoogle dflags package version synopsis prologue ifaces odir = do
    let filename = package ++ ".txt"
        contents = prefix ++
                   docWith dflags (drop 2 $ dropWhile (/= ':') synopsis) prologue ++
                   ["@package " ++ package] ++
                   ["@version " ++ showVersion version
                   | not (null (versionBranch version)) ] ++
                   concat [ppModule dflags i | i <- ifaces, OptHide `notElem` ifaceOptions i]
    createDirectoryIfMissing True odir
    h <- openFile (odir </> filename) WriteMode
    hSetEncoding h utf8
    hPutStr h (unlines contents)
    hClose h

ppModule :: DynFlags -> Interface -> [String]
ppModule dflags iface =
  "" : ppDocumentation dflags (ifaceDoc iface) ++
  ["module " ++ moduleString (ifaceMod iface)] ++
  concatMap (ppExport dflags) (ifaceExportItems iface) ++
  concatMap (ppInstance dflags) (ifaceInstances iface)


---------------------------------------------------------------------
-- Utility functions

dropHsDocTy :: HsType a -> HsType a
dropHsDocTy = f
    where
        g (L src x) = L src (f x)
        f (HsForAllTy x a e) = HsForAllTy x a (g e)
        f (HsQualTy x a e) = HsQualTy x a (g e)
        f (HsBangTy x a b) = HsBangTy x a (g b)
        f (HsAppTy x a b) = HsAppTy x (g a) (g b)
        f (HsFunTy x a w b) = HsFunTy x (g a) w (g b)
        f (HsListTy x a) = HsListTy x (g a)
        f (HsPArrTy x a) = HsPArrTy x (g a)
        f (HsTupleTy x a b) = HsTupleTy x a (map g b)
        f (HsOpTy x a b c) = HsOpTy x (g a) b (g c)
        f (HsParTy x a) = HsParTy x (g a)
        f (HsKindSig x a b) = HsKindSig x (g a) b
        f (HsDocTy _ a _) = f $ unL a
        f x = x

outHsType :: (a ~ GhcPass p, OutputableBndrId a)
          => DynFlags -> HsType a -> String
outHsType dflags = out dflags . dropHsDocTy


dropComment :: String -> String
dropComment (' ':'-':'-':' ':_) = []
dropComment (x:xs) = x : dropComment xs
dropComment [] = []


outWith :: Outputable a => (SDoc -> String) -> a -> [Char]
outWith p = f . unwords . map (dropWhile isSpace) . lines . p . ppr
    where
        f xs | " <document comment>" `isPrefixOf` xs = f $ drop 19 xs
        f (x:xs) = x : f xs
        f [] = []

out :: Outputable a => DynFlags -> a -> String
out dflags = outWith $ showSDocUnqual dflags

operator :: String -> String
operator (x:xs) | not (isAlphaNum x) && x `notElem` "_' ([{" = '(' : x:xs ++ ")"
operator x = x

commaSeparate :: Outputable a => DynFlags -> [a] -> String
commaSeparate dflags = showSDocUnqual dflags . interpp'SP

---------------------------------------------------------------------
-- How to print each export

ppExport :: DynFlags -> ExportItem GhcRn -> [String]
ppExport dflags ExportDecl { expItemDecl    = L _ decl
                           , expItemMbDoc   = (dc, _)
                           , expItemSubDocs = subdocs
                           , expItemFixities = fixities
                           } = ppDocumentation dflags dc ++ f decl
    where
        f (TyClD _ d@DataDecl{})  = ppData dflags d subdocs
        f (TyClD _ d@SynDecl{})   = ppSynonym dflags d
        f (TyClD _ d@ClassDecl{}) = ppClass dflags d subdocs
        f (ForD _ (ForeignImport _ name typ _)) = [pp_sig dflags [name] (hsSigType typ)]
        f (ForD _ (ForeignExport _ name typ _)) = [pp_sig dflags [name] (hsSigType typ)]
        f (SigD _ sig) = ppSig dflags sig ++ ppFixities
        f _ = []

        ppFixities = concatMap (ppFixity dflags) fixities
ppExport _ _ = []

ppSigWithDoc :: DynFlags -> Sig GhcRn -> [(Name, DocForDecl Name)] -> [String]
ppSigWithDoc dflags (TypeSig _ names sig) subdocs
    = concatMap mkDocSig names
    where
        mkDocSig n = concatMap (ppDocumentation dflags) (getDoc n)
                     ++ [pp_sig dflags names (hsSigWcType sig)]

        getDoc :: Located Name -> [Documentation Name]
        getDoc n = maybe [] (return . fst) (lookup (unL n) subdocs)

ppSigWithDoc _ _ _ = []

ppSig :: DynFlags -> Sig GhcRn -> [String]
ppSig dflags x  = ppSigWithDoc dflags x []

pp_sig :: DynFlags -> [Located Name] -> LHsType GhcRn -> String
pp_sig dflags names (L _ typ)  =
    operator prettyNames ++ " :: " ++ outHsType dflags typ
    where
      prettyNames = intercalate ", " $ map (out dflags) names

-- note: does not yet output documentation for class methods
ppClass :: DynFlags -> TyClDecl GhcRn -> [(Name, DocForDecl Name)] -> [String]
ppClass dflags decl subdocs =
  (out dflags decl{tcdSigs=[], tcdATs=[], tcdATDefs=[], tcdMeths=emptyLHsBinds}
    ++ ppTyFams) :  ppMethods
    where

        ppMethods = concat . map (ppSig' . unLoc . add_ctxt) $ tcdSigs decl
        ppSig' = flip (ppSigWithDoc dflags) subdocs

        add_ctxt = addClassContext (tcdName decl) (tyClDeclTyVars decl)

        ppTyFams
            | null $ tcdATs decl = ""
            | otherwise = (" " ++) . showSDocUnqual dflags . whereWrapper $ concat
                [ map ppr (tcdATs decl)
                , map (ppr . tyFamEqnToSyn . unLoc) (tcdATDefs decl)
                ]

        whereWrapper elems = vcat'
            [ text "where" <+> lbrace
            , nest 4 . vcat . map (Outputable.<> semi) $ elems
            , rbrace
            ]

        tyFamEqnToSyn :: TyFamDefltEqn GhcRn -> TyClDecl GhcRn
        tyFamEqnToSyn tfe = SynDecl
            { tcdLName  = feqn_tycon tfe
            , tcdTyVars = feqn_pats tfe
            , tcdFixity = feqn_fixity tfe
            , tcdRhs    = feqn_rhs tfe
            , tcdSExt   = emptyNameSet
            }


ppInstance :: DynFlags -> ClsInst -> [String]
ppInstance dflags x =
  [dropComment $ outWith (showSDocForUser dflags alwaysQualify) cls]
  where
    -- As per #168, we don't want safety information about the class
    -- in Hoogle output. The easiest way to achieve this is to set the
    -- safety information to a state where the Outputable instance
    -- produces no output which means no overlap and unsafe (or [safe]
    -- is generated).
    cls = x { is_flag = OverlapFlag { overlapMode = NoOverlap NoSourceText
                                    , isSafeOverlap = False } }

ppSynonym :: DynFlags -> TyClDecl GhcRn -> [String]
ppSynonym dflags x = [out dflags x]

ppData :: DynFlags -> TyClDecl GhcRn -> [(Name, DocForDecl Name)] -> [String]
ppData dflags decl@(DataDecl { tcdDataDefn = defn }) subdocs
    = showData decl{ tcdDataDefn = defn { dd_cons=[],dd_derivs=noLoc [] }} :
      concatMap (ppCtor dflags decl subdocs . unL) (dd_cons defn)
    where

        -- GHC gives out "data Bar =", we want to delete the equals
        -- also writes data : a b, when we want data (:) a b
        showData d = unwords $ map f $ if last xs == "=" then init xs else xs
            where
                xs = words $ out dflags d
                nam = out dflags $ tyClDeclLName d
                f w = if w == nam then operator nam else w
ppData _ _ _ = panic "ppData"

-- | for constructors, and named-fields...
lookupCon :: DynFlags -> [(Name, DocForDecl Name)] -> Located Name -> [String]
lookupCon dflags subdocs (L _ name) = case lookup name subdocs of
  Just (d, _) -> ppDocumentation dflags d
  _ -> []

ppCtor :: DynFlags -> TyClDecl GhcRn -> [(Name, DocForDecl Name)] -> ConDecl GhcRn -> [String]
ppCtor dflags dat subdocs con@ConDeclH98 {}
  -- AZ:TODO get rid of the concatMap
   = concatMap (lookupCon dflags subdocs) [con_name con] ++ f (getConArgs con)
    where
        f (PrefixCon args) = [typeSig name $ (map weightedThing args) ++ [resType]]
        f (InfixCon a1 a2) = f $ PrefixCon [a1,a2]
        f (RecCon (L _ recs)) = f (PrefixCon $ map (linear . cd_fld_type . unLoc) recs) ++ concat
                          [(concatMap (lookupCon dflags subdocs . noLoc . selectorFieldOcc . unLoc) (cd_fld_names r)) ++
                           [out dflags (map (selectorFieldOcc . unLoc) $ cd_fld_names r) `typeSig` [resType, cd_fld_type r]]
                          | r <- map unLoc recs]

        funs = foldr1 (\x y -> reL $ HsFunTy NoExt x Omega y) -- Definitely wrong in general MattP
        apps = foldl1 (\x y -> reL $ HsAppTy NoExt x y)

        typeSig nm flds = operator nm ++ " :: " ++ outHsType dflags (unL $ funs flds)

        -- We print the constructors as comma-separated list. See GHC
        -- docs for con_names on why it is a list to begin with.
        name = commaSeparate dflags . map unL $ getConNames con

        resType = apps $ map (reL . HsTyVar NoExt NotPromoted . reL) $
                        (tcdName dat) : [hsTyVarName v | L _ v@(UserTyVar _ _) <- hsQTvExplicit $ tyClDeclTyVars dat]

ppCtor dflags _dat subdocs con@(ConDeclGADT { })
   = concatMap (lookupCon dflags subdocs) (getConNames con) ++ f
    where
        f = [typeSig name (getGADTConTypeG con)]

        typeSig nm ty = operator nm ++ " :: " ++ outHsType dflags (unL ty)
        name = out dflags $ map unL $ getConNames con
ppCtor _ _ _ XConDecl {} = panic "haddock:ppCtor"

ppFixity :: DynFlags -> (Name, Fixity) -> [String]
ppFixity dflags (name, fixity) = [out dflags ((FixitySig noExt [noLoc name] fixity) :: FixitySig GhcRn)]


---------------------------------------------------------------------
-- DOCUMENTATION

ppDocumentation :: Outputable o => DynFlags -> Documentation o -> [String]
ppDocumentation dflags (Documentation d w) = mdoc dflags d ++ doc dflags w


doc :: Outputable o => DynFlags -> Maybe (Doc o) -> [String]
doc dflags = docWith dflags ""

mdoc :: Outputable o => DynFlags -> Maybe (MDoc o) -> [String]
mdoc dflags = docWith dflags "" . fmap _doc

docWith :: Outputable o => DynFlags -> String -> Maybe (Doc o) -> [String]
docWith _ [] Nothing = []
docWith dflags header d
  = ("":) $ zipWith (++) ("-- | " : repeat "--   ") $
    lines header ++ ["" | header /= "" && isJust d] ++
    maybe [] (showTags . markup (markupTag dflags)) d


data Tag = TagL Char [Tags] | TagP Tags | TagPre Tags | TagInline String Tags | Str String
           deriving Show

type Tags = [Tag]

box :: (a -> b) -> a -> [b]
box f x = [f x]

str :: String -> [Tag]
str a = [Str a]

-- want things like paragraph, pre etc to be handled by blank lines in the source document
-- and things like \n and \t converted away
-- much like blogger in HTML mode
-- everything else wants to be included as tags, neatly nested for some (ul,li,ol)
-- or inlne for others (a,i,tt)
-- entities (&,>,<) should always be appropriately escaped

markupTag :: Outputable o => DynFlags -> DocMarkup o [Tag]
markupTag dflags = Markup {
  markupParagraph            = box TagP,
  markupEmpty                = str "",
  markupString               = str,
  markupAppend               = (++),
  markupIdentifier           = box (TagInline "a") . str . out dflags,
  markupIdentifierUnchecked  = box (TagInline "a") . str . out dflags . snd,
  markupModule               = box (TagInline "a") . str,
  markupWarning              = box (TagInline "i"),
  markupEmphasis             = box (TagInline "i"),
  markupBold                 = box (TagInline "b"),
  markupMonospaced           = box (TagInline "tt"),
  markupPic                  = const $ str " ",
  markupMathInline           = const $ str "<math>",
  markupMathDisplay          = const $ str "<math>",
  markupUnorderedList        = box (TagL 'u'),
  markupOrderedList          = box (TagL 'o'),
  markupDefList              = box (TagL 'u') . map (\(a,b) -> TagInline "i" a : Str " " : b),
  markupCodeBlock            = box TagPre,
  markupHyperlink            = \(Hyperlink url mLabel) -> (box (TagInline "a") . str) (fromMaybe url mLabel),
  markupAName                = const $ str "",
  markupProperty             = box TagPre . str,
  markupExample              = box TagPre . str . unlines . map exampleToString,
  markupHeader               = \(Header l h) -> box (TagInline $ "h" ++ show l) h
  }


showTags :: [Tag] -> [String]
showTags = intercalate [""] . map showBlock


showBlock :: Tag -> [String]
showBlock (TagP xs) = showInline xs
showBlock (TagL t xs) = ['<':t:"l>"] ++ mid ++ ['<':'/':t:"l>"]
    where mid = concatMap (showInline . box (TagInline "li")) xs
showBlock (TagPre xs) = ["<pre>"] ++ showPre xs ++ ["</pre>"]
showBlock x = showInline [x]


asInline :: Tag -> Tags
asInline (TagP xs) = xs
asInline (TagPre xs) = [TagInline "pre" xs]
asInline (TagL t xs) = [TagInline (t:"l") $ map (TagInline "li") xs]
asInline x = [x]


showInline :: [Tag] -> [String]
showInline = unwordsWrap 70 . words . concatMap f
    where
        fs = concatMap f
        f (Str x) = escape x
        f (TagInline s xs) = "<"++s++">" ++ (if s == "li" then trim else id) (fs xs) ++ "</"++s++">"
        f x = fs $ asInline x

        trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse


showPre :: [Tag] -> [String]
showPre = trimFront . trimLines . lines . concatMap f
    where
        trimLines = dropWhile null . reverse . dropWhile null . reverse
        trimFront xs = map (drop i) xs
            where
                ns = [length a | x <- xs, let (a,b) = span isSpace x, b /= ""]
                i = if null ns then 0 else minimum ns

        fs = concatMap f
        f (Str x) = escape x
        f (TagInline s xs) = "<"++s++">" ++ fs xs ++ "</"++s++">"
        f x = fs $ asInline x


unwordsWrap :: Int -> [String] -> [String]
unwordsWrap n = f n []
    where
        f _ s [] = [g s | s /= []]
        f i s (x:xs) | nx > i = g s : f (n - nx - 1) [x] xs
                     | otherwise = f (i - nx - 1) (x:s) xs
            where nx = length x

        g = unwords . reverse


escape :: String -> String
escape = concatMap f
    where
        f '<' = "&lt;"
        f '>' = "&gt;"
        f '&' = "&amp;"
        f x = [x]


-- | Just like 'vcat' but uses '($+$)' instead of '($$)'.
vcat' :: [SDoc] -> SDoc
vcat' = foldr ($+$) empty
