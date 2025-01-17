{-# LANGUAGE TypeFamilies #-}

{-| A constructor argument is forced if it appears as pattern variable
in an index of the target.

For instance @x@ is forced in @sing@ and @n@ is forced in @zero@ and @suc@:

@
  data Sing {a}{A : Set a} : A -> Set where
    sing : (x : A) -> Sing x

  data Fin : Nat -> Set where
    zero : (n : Nat) -> Fin (suc n)
    suc  : (n : Nat) (i : Fin n) -> Fin (suc n)
@

At runtime, forced constructor arguments may be erased as they can be
recovered from dot patterns.  For instance,
@
  unsing : {A : Set} (x : A) -> Sing x -> A
  unsing .x (sing x) = x
@
can become
@
  unsing x sing = x
@
and
@
  proj : (n : Nat) (i : Fin n) -> Nat
  proj .(suc n) (zero n) = n
  proj .(suc n) (suc n i) = n
@
becomes
@
  proj (suc n) zero    = n
  proj (suc n) (suc i) = n
@

Forcing is a concept from pattern matching and thus builds on the
concept of equality (I) used there (closed terms, extensional) which is
different from the equality (II) used in conversion checking and the
constraint solver (open terms, intensional).

Up to issue 1441 (Feb 2015), the forcing analysis here relied on the
wrong equality (II), considering type constructors as injective.  This is
unsound for program extraction, but ok if forcing is only used to decide which
arguments to skip during conversion checking.

From now on, forcing uses equality (I) and does not search for forced
variables under type constructors.  This may lose some savings during
conversion checking.  If this turns out to be a problem, the old
forcing could be brought back, using a new modality @Skip@ to indicate
that this is a relevant argument but still can be skipped during
conversion checking as it is forced by equality (II).

-}

module Agda.TypeChecking.Forcing where

import Control.Arrow (first)
import Control.Monad
import Control.Monad.Trans.Maybe
import Control.Monad.Writer (WriterT(..), tell, lift)
import Data.Foldable as Fold hiding (any)
import Data.Maybe
import Data.List ((\\))
import Data.Function (on)
import Data.Monoid

import Agda.Interaction.Options

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Pattern

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Records
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Pretty hiding ((<>))

import Agda.Utils.Functor
import Agda.Utils.List
import Agda.Utils.Monad
import Agda.Utils.Size

import Agda.Utils.Impossible

-- | Given the type of a constructor (excluding the parameters),
--   decide which arguments are forced.
--   Precondition: the type is of the form @Γ → D vs@ and the @vs@
--   are in normal form.
computeForcingAnnotations :: QName -> Type -> TCM [IsForced]
computeForcingAnnotations c t =
  ifNotM (optForcing <$> pragmaOptions) {-then-} (return []) $ {-else-} do
  -- Andreas, 2015-03-10  Normalization prevents Issue 1454.
  -- t <- normalise t
  -- Andreas, 2015-03-28  Issue 1469: Normalization too costly.
  -- Instantiation also fixes Issue 1454.
  -- Note that normalization of s0 below does not help.
  t <- instantiateFull t
  -- Ulf, 2018-01-28 (#2919): We do need to reduce the target type enough to
  -- get to the actual data type.
  -- Also #2947: The type might reduce to a pi type.
  TelV tel (El _ a) <- telViewPath t
  let vs = case a of
        Def _ us -> us
        _        -> __IMPOSSIBLE__
      n  = size tel
      xs :: [(Modality, Nat)]
      xs = forcedVariables vs
      -- #2819: We can only mark an argument as forced if it appears in the
      -- type with a relevance below (i.e. more relevant) than the one of the
      -- constructor argument. Otherwise we can't actually get the value from
      -- the type. Also the argument shouldn't be irrelevant, since in that
      -- case it isn't really forced.
      isForced :: Modality -> Nat -> Bool
      isForced m i = and
        [ noUserQuantity m              -- User can disable forcing by giving quantity explicitly.
        , getRelevance m /= Irrelevant
        , any (\ (m', j) -> i == j && m' `moreUsableModality` m) xs
        ]
      forcedArgs =
        [ if isForced m i then Forced else NotForced
        | (i, m) <- zip (downFrom n) $ map getModality (telToList tel)
        ]
  reportS "tc.force" 60
    [ "Forcing analysis for " ++ show c
    , "  xs          = " ++ show (map snd xs)
    , "  forcedArgs  = " ++ show forcedArgs
    ]
  return forcedArgs

-- | Compute the pattern variables of a term or term-like thing.
class ForcedVariables a where
  forcedVariables :: a -> [(Modality, Nat)]

  default forcedVariables :: (ForcedVariables b, Foldable t, a ~ t b) => a -> [(Modality, Nat)]
  forcedVariables = foldMap forcedVariables

instance ForcedVariables a => ForcedVariables [a] where

-- Note that the 'a' does not include the 'Arg' in 'Apply'.
instance ForcedVariables a => ForcedVariables (Elim' a) where
  forcedVariables (Apply x) = forcedVariables x
  forcedVariables IApply{}  = []  -- No forced variables in path applications
  forcedVariables Proj{}    = []

instance ForcedVariables a => ForcedVariables (Arg a) where
  forcedVariables x = [ (m <> m', i) | (m', i) <- forcedVariables (unArg x) ]
    where m = getModality x

-- | Assumes that the term is in normal form.
instance ForcedVariables Term where
  forcedVariables t = case t of
    Var i [] -> [(mempty, i)]
    Con _ _ vs -> forcedVariables vs
    _ -> []

isForced :: IsForced -> Bool
isForced Forced    = True
isForced NotForced = False

nextIsForced :: [IsForced] -> (IsForced, [IsForced])
nextIsForced []     = (NotForced, [])
nextIsForced (f:fs) = (f, fs)

-----------------------------------------------------------------------------
-- * Forcing translation
-----------------------------------------------------------------------------

-- | Move bindings for forced variables to unforced positions.
forcingTranslation :: [NamedArg DeBruijnPattern] -> TCM [NamedArg DeBruijnPattern]
forcingTranslation ps = do
  (qs, rebind) <- dotForcedPatterns ps
  -- If qs == ps, no patterns were dotted.  Otherwise, report result.
  verboseS "tc.force" 50 $
    unless (qs == ps) $
      reportSDoc "tc.force" 50 $ "forcingTranslation" <?> vcat
        [ "patterns:" <?> pretty ps
        , "dotted:  " <?> pretty qs
        , "rebind:  " <?> pretty rebind
        ]
  -- If @rebind@ is empty, there is no further work to do:
  --
  --   dotForcedPatterns adds dot patterns and rebindForcedPattern turns
  --   the dot patterns into proper patterns.  If rebind is empty we might
  --   have created some new dot patterns, but since we won't remove any
  --   dot patterns there is no need to have another go at dotForcedPatterns.
  --   -- Ulf, 2019-07-09, https://github.com/agda/agda/pull/3902#discussion_r301477181
  --
  -- Still, @qs@ might be different from @ps@:
  -- Dots might have been moved, just not onto binders or strict matches.
  -- Thus, we return @qs@ and not @ps@.
  if null rebind then return qs else do
      rs <- foldM rebindForcedPattern qs rebind
      reportSDoc "tc.force" 50 $ nest 2 $ "result:  " <?> pretty rs
      -- Repeat translation as long as we're making progress (Issue 3410)
      forcingTranslation rs

-- | Applies the forcing translation in order to update modalities of forced
--   arguments in the telescope. This is used before checking a right-hand side
--   in order to make sure all uses of forced arguments agree with the
--   relevance of the position where the variable will ultimately be bound.
--   Precondition: the telescope types the bound variables of the patterns.
forceTranslateTelescope :: Telescope -> [NamedArg DeBruijnPattern] -> TCM Telescope
forceTranslateTelescope delta qs = do
  qs' <- forcingTranslation qs
  let xms  = patternVarModalities qs
      xms' = patternVarModalities qs'
      old  = xms \\ xms'
      new  = xms' \\ xms
  if null new then return delta else do
      reportS "tc.force" 40 $
        [ "Updating modalities of forced arguments"
        , "  from: " ++ show old
        , "  to:   " ++ show new
        ]
      let mods    = map (first dbPatVarIndex) new
          ms      = map (`lookup` mods) $ downFrom $ size delta
          delta'  = telFromList $ zipWith (maybe id setModality) ms $ telToList delta
      reportSDoc "tc.force" 60 $ nest 2 $ "delta' =" <?> prettyTCM delta'
      return delta'

-- | Rebind a forced pattern in a non-forced position. The forced pattern has
--   already been dotted by 'dotForcedPatterns', so the remaining task is to
--   find a dot pattern in an unforced position that can be turned into a
--   proper match of the forced pattern.
--
--   For instance (with patterns prettified to ease readability):
--
--    rebindForcedPattern [.(suc n), cons .n x xs] n = [suc n, cons .n x xs]
--
rebindForcedPattern :: [NamedArg DeBruijnPattern] -> DeBruijnPattern -> TCM [NamedArg DeBruijnPattern]
rebindForcedPattern ps toRebind = do
  reportSDoc "tc.force" 50 $ hsep ["rebinding", pretty toRebind, "in"] <?> pretty ps
  (ps', Sum count) <- runWriterT $ go $ zip (repeat NotForced) ps
  case count of
    0 -> __IMPOSSIBLE__   -- Unforcing should not fail
    1 -> do
      reportSDoc "tc.force" 50 $ nest 2 $ hsep ["result:", pretty ps']
      return ps'
    _ ->
      genericDocError =<< sep [ fwords "Uh oh. I can't figure out where to move the forced pattern"
                              , prettyTCM toRebind <> "."
                              , fwords "See [Issue 3903](https://github.com/agda/agda/issues/3903)." ]
  where
    targetDotP = patternToTerm toRebind

    rebindingVar = case toRebind of
                     VarP{} -> True
                     _      -> False

    go [] = return []
    go ((Forced,    p) : ps) = (p :) <$> go ps
    go ((NotForced, p) : ps) | namedArg p `rebinds` toRebind
                             = return $ p : map snd ps
    go ((NotForced, p) : ps) = -- (#3544) A previous rebinding might have already rebound our pattern
      case namedArg p of
        VarP{}   -> (p :) <$> go ps
        DotP _ v -> lift (mkPat v) >>= \ case
          Nothing -> do
            (p :) <$> go ps
          Just q' -> do
            tell 1
            -- Issue 3903: It's ok if there are multiple candidates for rebinding a plain variable. It's
            -- only when there's an actual match that it's crucial to pick the right one.
            let p' = fmap (q' <$) p
            if rebindingVar then return (p' : map snd ps)
                            else (p' :) <$> go ps
        ConP c i qs -> do
          fqs <- lift $ withForced c qs
          qps <- go (fqs ++ ps)
          let (qs', ps') = splitAt (length qs) qps
          return $ fmap (ConP c i qs' <$) p : ps'
        DefP o q qs -> do
          fs <- lift $ defForced <$> getConstInfo q
          fqs <- return $ zip (fs ++ repeat NotForced) qs
          qps <- go (fqs ++ ps)
          let (qs', ps') = splitAt (length qs) qps
          return $ fmap (DefP o q qs' <$) p : ps'
        LitP{}  -> (p :) <$> go ps
        ProjP{} -> (p :) <$> go ps
        IApplyP{} -> (p :) <$> go ps

    withForced :: ConHead -> [a] -> TCM [(IsForced, a)]
    withForced c qs = do
      fs <- defForced <$> getConstInfo (conName c)
      return $ zip (fs ++ repeat NotForced) qs

    -- Try to turn a term in a dot pattern into a pattern matching targetDotP
    mkPat :: Term -> TCM (Maybe DeBruijnPattern)
    mkPat v = mkPat' (NotForced, v)

    mkPat' :: (IsForced, Term) -> TCM (Maybe DeBruijnPattern)
    mkPat' (Forced, _) = return Nothing
    mkPat' (NotForced, v) | targetDotP == v = return (Just toRebind)
    mkPat' (NotForced, v) =
      case v of
        Con c co es -> do
          let vs = fromMaybe __IMPOSSIBLE__ $ allApplyElims es
          fovs  :: [Arg (IsForced, Term)] <- map distributeF <$> withForced c vs
          -- It takes a bit of juggling to apply mkPat' under the the 'Arg's, but since it
          -- type checks, it's pretty much guaranteed to be the right thing.
          mps :: [Maybe (Arg DeBruijnPattern)] <- mapM (runMaybeT . traverse (MaybeT . mkPat')) fovs
          case break (isJust . snd) (zip vs mps) of
            (mvs1, (_, Just p) : mvs2) -> do
              let vs1 = map fst mvs1
                  vs2 = map fst mvs2
                  ci = (toConPatternInfo co) { conPLazy = True }
                  dots = (map . fmap) dotP
              return $ Just $ ConP c ci $ doname $ dots vs1 ++ [p] ++ dots vs2
            _ -> return Nothing
        _ -> return Nothing
      where
        doname = (map . fmap) unnamed

-- | Check if the first pattern rebinds the second pattern. Almost equality,
--   but allows the first pattern to have a variable where the second pattern
--   has a dot pattern. Used to fix #3544.
rebinds :: DeBruijnPattern -> DeBruijnPattern -> Bool
VarP{}          `rebinds` DotP{}            = True
VarP _ x        `rebinds` VarP _ y          = dbPatVarIndex x == dbPatVarIndex y
DotP _ u        `rebinds` DotP _ v          = u == v
ConP c _ ps     `rebinds` ConP c' _ qs      = c == c' && and (zipWith (rebinds `on` namedArg) ps qs)
LitP l          `rebinds` LitP l'           = l == l'
ProjP _ f       `rebinds` ProjP _ g         = f == g
IApplyP _ u v x `rebinds` IApplyP _ u' v' y = u == u' && v == v' && x == y
DefP _ f ps     `rebinds` DefP _ g qs       = f == g && and (zipWith (rebinds `on` namedArg) ps qs)
_               `rebinds` _                 = False

-- | Dot all forced patterns and return a list of patterns that need to be
--   undotted elsewhere. Patterns that need to be undotted are those that bind
--   variables or does some actual (non-eta) matching.
dotForcedPatterns :: [NamedArg DeBruijnPattern] -> TCM ([NamedArg DeBruijnPattern], [DeBruijnPattern])
dotForcedPatterns ps = runWriterT $ (traverse . traverse . traverse) (forced NotForced) ps
  where
    forced :: IsForced -> DeBruijnPattern -> WriterT [DeBruijnPattern] TCM DeBruijnPattern
    forced f p =
      case p of
        DotP{}          -> return p
        ProjP{}         -> return p
        _ | f == Forced -> do
          properMatch <- isProperMatch p
          tell $ [p | properMatch || not (Fold.null p)]  -- @not (null p)@ means: binds at least one variable
          return $ dotP (patternToTerm p)
        VarP{}          -> return p
        LitP{}          -> return p
        ConP c i ps     -> do
          fs <- defForced <$> getConstInfo (conName c)
          ConP c i <$> zipWithM forcedArg (fs ++ repeat NotForced) ps
        DefP o q ps     -> do
          fs <- defForced <$> getConstInfo q
          DefP o q <$> zipWithM forcedArg (fs ++ repeat NotForced) ps
        IApplyP{}       -> return p

    forcedArg f = (traverse . traverse) (forced f)

    isProperMatch LitP{}  = return True
    isProperMatch IApplyP{}  = return False
    isProperMatch VarP{}  = return False
    isProperMatch ProjP{} = return False
    isProperMatch DotP{}  = return False
    isProperMatch (ConP c i ps) =
      ifM (isEtaCon $ conName c)
          (anyM ps (isProperMatch . namedArg))
          (return True)
    isProperMatch DefP{} = return True -- Andrea, TODO check semantics
