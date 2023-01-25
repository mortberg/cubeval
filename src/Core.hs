{-# language PostfixOperators #-}

module Core where

import qualified IVarSet as IS
import Common
import Interval
import Substitution
import CoreTypes


-- Context manipulation
----------------------------------------------------------------------------------------------------

-- | We need to use this whenever we want to pass a higher-order contextual
--   argument to some combinator. The problem is that local implicit params are
--   lazy. TODO: improve the strict implicit params plugin to handle this case
--   as well!
forceArgs :: (NCofArg => DomArg => a) -> (NCofArg => DomArg => a)
forceArgs f = let !_ = ?cof; !_ = ?dom in f
{-# inline forceArgs #-}

freshIS :: (SubArg => NCofArg => IVar -> a) -> (SubArg => NCofArg => a)
freshIS act =
  let fresh = dom ?cof in
  let ?sub  = mapDom (+1) ?sub `ext` IVar fresh in
  let ?cof  = mapDom (+1) ?cof `ext` IVar fresh in
  act fresh
{-# inline freshIS #-}

freshI :: (NCofArg => IVar -> a) -> (NCofArg => a)
freshI act =
  let fresh = dom ?cof in
  let ?cof  = mapDom (+1) ?cof `ext` IVar fresh in
  act fresh
{-# inline freshI #-}

fresh :: (DomArg => Val -> a) -> (DomArg => a)
fresh act = let v = vVar ?dom in let ?dom = ?dom + 1 in act v
{-# inline fresh #-}

-- | Define the next fresh ivar to an expression.
defineI :: I -> (SubArg => a) -> (SubArg => a)
defineI i act =
  let ?sub = ?sub `ext` i in
  act
{-# inline defineI #-}

define :: Val -> (EnvArg => a) -> (EnvArg => a)
define ~v act = let ?env = EDef ?env v in act
{-# inline define #-}


-- Cof and Sys semantics
----------------------------------------------------------------------------------------------------

ctrue, cfalse :: F VCof
ctrue  = F VCTrue
cfalse = F VCFalse

cand :: F VCof -> F VCof -> F VCof
cand c1 ~c2 = case (unF c1, unF c2) of
  (VCFalse    , c2         ) -> cfalse
  (_          , VCFalse    ) -> cfalse
  (VCTrue     , c2         ) -> F c2
  (c1         , VCTrue     ) -> F c1
  (VCNe n1 is1, VCNe n2 is2) -> F (VCNe (NCAnd n1 n2) (is1 <> is2))
{-# inline cand #-}

iToVarSet :: I -> IS.IVarSet
iToVarSet = \case
  IVar x -> IS.singleton x
  _      -> mempty

vCofToVarSet :: F VCof -> IS.IVarSet
vCofToVarSet cof = case unF cof of
  VCTrue    -> mempty
  VCFalse   -> mempty
  VCNe _ is -> is

ceq :: F I -> F I -> F VCof
ceq c1 c2 = case (unF c1, unF c2) of
  (i, j) | i == j -> ctrue
  (i, j) -> matchIVar i
    (\x -> matchIVar j
     (\y -> F (VCNe (NCEq i j) (IS.singleton x <> IS.singleton y)))
     cfalse)
    cfalse

evalI :: SubArg => NCofArg => I -> F I
evalI i = F (doSub ?cof (sub i))

evalCofEq :: SubArg => NCofArg => CofEq -> F VCof
evalCofEq (CofEq i j) = ceq (evalI i) (evalI j)

evalCof :: SubArg => NCofArg => Cof -> F VCof
evalCof = \case
  CTrue       -> ctrue
  CAnd eq cof -> cand (evalCofEq eq) (evalCof cof)

conjIVarI :: NCof -> IVar -> I -> NCof
conjIVarI cof x i = mapSub id go cof where
  go _ j = matchIVar j (\y -> if x == y then i else j) j

conjNeCof :: NCof -> NeCof -> NCof
conjNeCof ncof necof = case necof of
  NCAnd c1 c2 -> ncof `conjNeCof` c1 `conjNeCof` c2
  NCEq i j    -> case (i, j) of
    (IVar x, IVar y) -> let (!x, !i) = if x > y then (x, IVar y)
                                                else (y, IVar x) in
                        conjIVarI ncof x i
    (IVar x, j     ) -> conjIVarI ncof x j
    (i     , IVar y) -> conjIVarI ncof y i
    _                -> impossible

conjVCof :: NCof -> F VCof -> NCof
conjVCof ncof cof = case unF cof of
  VCFalse      -> impossible
  VCTrue       -> ncof
  VCNe necof _ -> conjNeCof ncof necof
{-# noinline conjVCof #-}

bindCof :: F VCof -> (NCofArg => a) -> (NCofArg => a)
bindCof cof action = let ?cof = conjVCof ?cof cof in action
{-# inline bindCof #-}

bindNeCof :: NeCof -> (NCofArg => a) -> (NCofArg => a)
bindNeCof cof action = let ?cof = conjNeCof ?cof cof in action
{-# inline bindNeCof #-}

emptySys :: F VSys
emptySys = F (VSNe (NeSys' NSEmpty mempty))
{-# inline emptySys #-}

consSys :: F VCof -> Val -> F VSys -> F VSys
consSys cof ~v ~sys = case unF cof of
  VCTrue      -> F (VSTotal v)
  VCFalse     -> sys
  VCNe cof is -> case unF sys of
    VSTotal v'            -> F (VSTotal v')
    VSNe (NeSys' sys is') -> F (VSNe (NeSys' (NSCons cof v sys) (is <> is')))
{-# inline consSys #-}

evalSys :: SubArg => NCofArg => DomArg => EnvArg => Sys -> F VSys
evalSys = \case
  SEmpty                       -> emptySys
  SCons (evalCof -> cof) t sys -> consSys cof (bindCof cof (eval t)) (evalSys sys)

emptySysBind :: F VSysBind
emptySysBind = F (VSBNe (NeSysBind' NSBEmpty mempty))
{-# inline emptySysBind #-}

consSysBind :: F VCof -> BindLazy Val -> F VSysBind -> F VSysBind
consSysBind cof ~v ~sys = case unF cof of
  VCTrue      -> F (VSBTotal v)
  VCFalse     -> sys
  VCNe cof is -> case unF sys of
    VSBTotal v'                -> F (VSBTotal v')
    VSBNe (NeSysBind' sys is') -> F (VSBNe (NeSysBind' (NSBCons cof v sys) (is <> is')))
{-# inline consSysBind #-}

evalBinder :: SubArg => NCofArg => DomArg => EnvArg => Name -> Tm -> Bind Val
evalBinder x t = freshIS \i -> Bind x i (eval t)
{-# inline evalBinder #-}

evalLazyBinder :: SubArg => NCofArg => DomArg => EnvArg => Name -> Tm -> BindLazy Val
evalLazyBinder x t = freshIS \i -> BindLazy x i (eval t)
{-# inline evalLazyBinder #-}

evalfBinder :: SubArg => NCofArg => DomArg => EnvArg => Name -> Tm -> F (Bind Val)
evalfBinder x t = freshIS \i -> F (Bind x i (unF (evalf t)))
{-# inline evalfBinder #-}

evalSysBind :: SubArg => NCofArg => DomArg => EnvArg => Name -> Sys -> F VSysBind
evalSysBind x = \case
  SEmpty ->
    emptySysBind
  SCons (evalCof -> cof) t sys ->
    consSysBind cof (bindCof cof (evalLazyBinder x t)) (evalSysBind x sys)


----------------------------------------------------------------------------------------------------


localVar :: EnvArg => Ix -> Val
localVar x = go ?env x where
  go (EDef _ v) 0 = v
  go (EDef e _) x = go e (x - 1)
  go _          _ = impossible


-- | Apply a function. Strict in argument.
app :: NCofArg => DomArg => F Val -> Val -> Val
app t u = case unF t of
  VLam _ t -> capp t u
  VNe t is -> VNe (NApp t u) is
  _        -> impossible

-- appf' t u = frc' (app t u); {-# inline appf' #-}

-- | Apply a function. Lazy in argument.
appLazy :: NCofArg => DomArg => F Val -> Val -> Val
appLazy t ~u = case unF t of
  VLam _ t -> t ∙ u
  VNe t is -> VNe (NApp t u) is
  _        -> impossible

-- | Apply a closure. Note: *lazy* in argument.
capp :: NCofArg => DomArg => Closure -> Val -> Val
capp t ~u = case t of
  CEval s env t -> let ?env = EDef env u; ?sub = s in eval t

  CCoePi (frc -> r) (frc -> r') (unpackBind2 -> (frc -> a, b)) (frc -> t) ->
    let x = frc u in
    unF (coe r r' (bind "j" \j -> b ∙ unF j ∘ unF (coe r' j a x))
                  (t ∘ unF (coe r' r a x)))

bind :: Name -> (NCofArg => F I -> F a) -> NCofArg => F (Bind a)
bind x act = freshI \i -> F (Bind x i (unF (act (F (IVar i)))))
{-# inline bind #-}

bindLazy :: Name -> (NCofArg => F I -> a) -> NCofArg => BindLazy a
bindLazy x act = freshI \i -> BindLazy x i (act (F (IVar i)))
{-# inline bindLazy #-}

-- | Apply an ivar closure.
icapp :: NCofArg => DomArg => IClosure -> I -> Val
icapp t arg = case t of
  ICEval s env t -> let ?env = env; ?sub = ext s arg in eval t

  ICCoePathP (frc -> r) (frc -> r') (unpackBind3 -> (a, lhs, rhs)) p ->
    let j = frc arg in
    com r r' (bind "i" \i -> a ∙ unF i ∘ unF j)
             (consSysBind (ceq j (F I0)) (bindLazy "i" \i -> lhs ∙ unF i) $
              consSysBind (ceq j (F I1)) (bindLazy "i" \i -> rhs ∙ unF i) $
              emptySysBind)
             (pappf (frc p) (lhs ∙ unF r') (rhs ∙ unF r') j)


--   ICHComPathP (forceI -> r) (forceI -> r') ix a lhs rhs sys p ->

--     let farg = forceI arg in

--     hcom r r' ix (icappf a arg)
--         ( scons (ceq farg (F I0)) lhs $
--           scons (ceq farg (F I1)) rhs $
--           (mapVSystem (inCxt \_ t -> papp (force t) lhs rhs farg)  -- TODO: fuse force & map
--                       (forceNSystem sys))
--         )
--       (pappf (force p) lhs rhs farg)

--   ICConst t -> t

-- -- isEquiv : (A → B) → U
-- -- isEquiv A B f :=
-- --     (g^1    : B → A)
-- --   × (linv^2 : (x^4 : A) → Path A x (g (f x)))
-- --   × (rinv^3 : (x^5 : B) → Path B (f (g x)) x)
-- --   × (coh    : (x^6 : A) →
-- --             PathP (i^7) (Path B (f (linv x {x}{g (f x)} i)) (f x))
-- --                   (refl B (f x))
-- --                   (rinv (f x)))

--   ICIsEquiv7 b (force -> f) (force -> g)(force -> linv) x ->
--     let ~i   = forceI arg
--         ~fx  = f `app` x
--         ~gfx = g `app` fx  in
--     path b (f `app` papp (linv `appf` x) x gfx i) fx

proj1 :: F Val -> Val
proj1 t = case unF t of
  VPair t _ -> t
  VNe t is  -> VNe (NProj1 t) is
  _         -> impossible

proj1f  t = frc  (proj1 t); {-# inline proj1f  #-}
-- proj1f' t = frc' (proj1 t); {-# inline proj1f' #-}

proj2 :: F Val -> Val
proj2 t = case unF t of
  VPair _ u -> u
  VNe t is  -> VNe (NProj2 t) is
  _         -> impossible

proj2f  t = frc (proj2 t); {-# inline proj2f #-}
-- proj2f' t = frc' (proj2 t); {-# inline proj2f' #-}

natElim :: NCofArg => DomArg => Val -> Val -> F Val -> F Val -> Val
natElim p z s n = case unF n of
  VZero             -> z
  VSuc (frc -> n)   -> s ∘ unF n ∙ natElim p z s n
  VNe n is          -> VNe (NNatElim p z (unF s) n) is
  _                 -> impossible

natElimf  p z s n = frc  (natElim p z s n); {-# inline natElimf  #-}
-- natElimf' p z s n = frc' (natElim p z s n); {-# inline natElimf' #-}

-- | Apply a path.
papp :: NCofArg => DomArg => F Val -> Val -> Val -> F I -> Val
papp ~t ~u0 ~u1 i = case unF i of
  I0     -> u0
  I1     -> u1
  IVar x -> case unF t of
    VPLam _ _ _ t -> icapp t (IVar x)
    VNe t is      -> VNe (NPApp t u0 u1 (IVar x)) (IS.insert x is)
    _             -> impossible
{-# inline papp #-}

pappf  ~t ~u0 ~u1 i = frc  (papp t u0 u1 i); {-# inline pappf  #-}
-- pappf' ~t ~u0 ~u1 i = frc' (papp t u0 u1 i); {-# inline pappf' #-}

--------------------------------------------------------------------------------

infixl 8 ∙
class Apply a b c a1 a2 | a -> b c a1 a2 where
  (∙) :: a1 => a2 => a -> b -> c

instance Apply Closure Val Val NCofArg DomArg where
  (∙) = capp; {-# inline (∙) #-}

instance Apply (F Val) Val Val NCofArg DomArg where
  (∙) = app; {-# inline (∙) #-}

instance Apply (Bind a) I a (SubAction a) NCofArg where
  (∙) = inst; {-# inline (∙) #-}

instance Apply (BindLazy a) I a (SubAction a) NCofArg where
  (∙) = instLazy; {-# inline (∙) #-}

instance Apply IClosure I Val NCofArg DomArg where
  (∙) = icapp; {-# inline (∙) #-}

infixl 8 ∘
class ApplyF a b c a1 a2 | a -> b c a1 a2 where
  (∘) :: a1 => a2 => a -> b -> F c

instance ApplyF Closure Val Val NCofArg DomArg where
  (∘) x y = frc (capp x y); {-# inline (∘) #-}

instance ApplyF (F Val) Val Val NCofArg DomArg where
  (∘) x y = frc (x ∙ y); {-# inline (∘) #-}

instance Force a fa => ApplyF (Bind a) I fa (SubAction a) NCofArg where
  (∘) x y = frc (x ∙ y); {-# inline (∘) #-}

instance Force a fa => ApplyF (BindLazy a) I fa (SubAction a) NCofArg where
  (∘) x y = frc (x ∙ y); {-# inline (∘) #-}

instance ApplyF IClosure I Val NCofArg DomArg where
  (∘) x y = frc (icapp x y); {-# inline (∘) #-}

--------------------------------------------------------------------------------

-- assumption: r /= r'
goCoe :: NCofArg => DomArg => F I -> F I -> F (Bind Val) -> F Val -> F Val
goCoe r r' topA t = case unF topA ^. body of

  VPi x (rebind topA -> a) (rebind topA -> b) ->
    F (VLam x (CCoePi (unF r) (unF r') (packBind2 a b) (unF t)))

  VSg x (rebindf topA -> a) (rebindf topA -> b) ->
    let t1 = frc $ proj1 t
        t2 = frc $ proj2 t
    in F (VPair (unF (goCoe r r' a t1))
                (unF (goCoe r r' (bind "j" \j -> coe r j a t1) t2)))

  VNat ->
    t

  VPathP j (rebind topA -> a) (rebind topA -> lhs) (rebind topA -> rhs) ->
    F (VPLam (lhs ∙ unF r') (rhs ∙ unF r')
             j (ICCoePathP (unF r) (unF r') (packBind3 a lhs rhs) (unF t)))
  VU ->
    t

  -- Note: I don't need to rebind the "is"! It can be immediately weakened
  -- to the outer context.
  a@(VNe (rebind topA -> n) is) ->
    F (VNe (NCoe (unF r) (unF r') (unF topA ^.name) (unF topA) (unF t))
           (IS.insertI (unF r) $ IS.insertI (unF r') is))

  VGlueTy a sys ->
    uf

  _ ->
    impossible

coe :: NCofArg => DomArg => F I -> F I -> F (Bind Val) -> F Val -> F Val
coe r r' ~a t
  | unF r == unF r' = t
  | True            = goCoe r r' a t
{-# inline coe #-}

mapNeSysBind :: (NeCof -> BindLazy Val -> BindLazy Val) -> NeSysBind -> NeSysBind
mapNeSysBind f = \case
  NSBEmpty          -> NSBEmpty
  NSBCons cof t sys -> NSBCons cof (f cof t) (mapNeSysBind f sys)
{-# inline mapNeSysBind #-}

-- | Precondition: the mapping function does not remove occurrences of blocking ivars!
mapNeSysBind' :: (NeCof -> BindLazy Val -> BindLazy Val) -> NeSysBind' -> NeSysBind'
mapNeSysBind' f (NeSysBind' sys is) = NeSysBind' (mapNeSysBind f sys) is
{-# inline mapNeSysBind' #-}

-- | Assumption: r /= r'
goCom :: NCofArg => DomArg => F I -> F I -> F (Bind Val) -> NeSysBind' -> F Val -> F Val
goCom r r' ~a ~sys ~b =
  goHCom r r'
    (unF a ∘ unF r')
    (mapNeSysBind'
       (\cof t -> bindNeCof cof $ bindLazy "i" \i -> unF (coe i r' a (t ∘ unF i)))
       sys)
    (goCoe r r' a b)
{-# noinline goCom #-}

com :: NCofArg => DomArg => F I -> F I -> F (Bind Val) -> F VSysBind -> F Val -> Val
com r r' ~a ~sys ~b
  | unF r == unF r'            = unF b
  | VSBTotal v      <- unF sys = v ∙ unF r'
  | VSBNe nsys      <- unF sys = unF (goCom r r' a nsys b)
{-# inline com #-}

-- | Assumption: r /= r'
goHCom :: NCofArg => DomArg => F I -> F I -> F Val -> NeSysBind' -> F Val -> F Val
goHCom r r' a nsys base = case unF a of

--   VPi x a b ->
--     F (VLam x (CHComPi (unF r) (unF r') ix a b (unFNSystem (_nsys nsys)) (unF base)))

--   VSg x a b ->

--     let bfill = bindI \(IVar -> i) ->
--           cappf b (unF (goHCom r (F i) ix (force a)
--                                (mapNSystem' (inCxt \_ t -> proj1 (force t)) nsys)
--                                (proj1f base))) in

--     F (VPair
--       (unF (goHCom r r' ix (force a)
--                   (mapNSystem' (inCxt \_ t -> proj1 (force t)) nsys)
--                   (proj1f base)))
--       (unF (goCom r r' ix bfill
--                   (mapNSystem' (inCxt \_ t -> proj2 (force t)) nsys)
--                   (proj2f base)))
--       )

--   VNat -> case ?dom of
--     0 -> base
--     _ -> goHComNat r r' ix nsys base

--   VPathP j a lhs rhs ->
--     F (VPLam lhs
--              rhs
--              j
--              (ICHComPathP (unF r) (unF r')
--                           ix a lhs rhs (unFNSystem (_nsys nsys)) (unF base)))

--   a@(VNe n is) ->
--     F (VNe (NHCom (unF r) (unF r') ix a (unFNSystem (_nsys nsys)) (unF base))
--            (IS.insertI (unF r) $ IS.insertI (unF r') (_ivars nsys <> is)))

  VU ->
    uf

  VGlueTy a sys  ->
    uf

-- -- hcomⁱ r r' (Glue [α ↦ (T, f)] A) [β ↦ t] gr =
-- --   glue [α ↦ hcomⁱ r r' T [β ↦ t] gr]
-- --        (hcomⁱ r r' A [β ↦ unglue t, α ↦ f (hfillⁱ r r' T [β ↦ t] gr)] (unglue gr))

  _ ->
    impossible


hcom :: NCofArg => DomArg => F I -> F I -> F Val -> F VSysBind -> F Val -> Val
hcom r r' ~a ~t ~b
  | unF r == unF r'          = unF b
  | VSBTotal v      <- unF t = v ∙ unF r'
  | VSBNe nsys      <- unF t = unF (goHCom r r' a nsys b)
{-# inline hcom #-}

hcomf r r' ~a ~t ~b = frc (hcom r r' a t b); {-# inline hcomf  #-}

eval :: SubArg => NCofArg => DomArg => EnvArg => Tm -> Val
eval = \case
  TopVar _ v        -> coerce v
  LocalVar x        -> localVar x
  Let x _ t u       -> define (eval t) (eval u)
  Pi x a b          -> VPi x (eval a) (CEval ?sub ?env b)
  App t u           -> evalf t ∙ eval u
  Lam x t           -> VLam x (CEval ?sub ?env t)
  Sg x a b          -> VSg x (eval a) (CEval ?sub ?env b)
  Pair t u          -> VPair (eval t) (eval u)
  Proj1 t           -> proj1 (evalf t)
  Proj2 t           -> proj2 (evalf t)
  U                 -> VU
  PathP x a t u     -> VPathP x (ICEval ?sub ?env a) (eval t) (eval u)
  PApp t u0 u1 i    -> papp (evalf t) (eval u0) (eval u1) (evalI i)
  PLam l r x t      -> VPLam (eval l) (eval r) x (ICEval ?sub ?env t)
  Coe r r' x a t    -> unF (coe (evalI r) (evalI r') (evalfBinder x a) (evalf t))
  -- HCom r r' x a t b -> hcom (evalI r) (evalI r') x (evalf a) (evalSys t) (evalf b)
  -- GlueTy a sys      -> glueTy (eval a) (evalSys sys)
  -- Glue t sys        -> glue   (eval t) (evalSys sys)
  -- Unglue t sys      -> unglue (eval t) (evalSys sys)
  Nat               -> VNat
  Zero              -> VZero
  Suc t             -> VSuc (eval t)
  NatElim p z s n   -> natElim (eval p) (eval z) (evalf s) (evalf n)

evalf :: SubArg => NCofArg => DomArg => EnvArg => Tm -> F Val
evalf t = frc (eval t)
{-# inline evalf #-}

-- Forcing
----------------------------------------------------------------------------------------------------

class Force a b | a -> b where
  frc  :: NCofArg => a -> F b
  frcS :: SubArg => NCofArg => a -> F b

instance Force Ne Val where
  frc = uf
  frcS = uf

instance Force Val Val where
  frc = uf
  frcS = uf

instance Force I I where
  frc  i = F (doSub ?cof i); {-# inline frc #-}
  frcS i = F (doSub ?cof (doSub ?sub i)); {-# inline frcS #-}

instance Force a fa => Force (Bind a) (Bind fa) where

  -- TODO: review
  frc (Bind x i a) =
    let ?cof = setDom (i + 1) (setCod i ?cof) `ext` IVar i in
    F (Bind x i (unF (frc a)))
  {-# inline frc #-}

  -- TODO: review
  frcS (Bind x i a) =
    let fresh = dom ?cof in
    let ?sub  = mapDom (+1) (setCod i ?sub) `ext` IVar fresh in
    let ?cof  = mapDom (+1) ?cof `ext` IVar fresh in
    F (Bind x fresh (unF (frcS a)))
  {-# inline frcS #-}





{-

-- Γ, i ⊢ coeFillⁱ r A t : A  [i=r ↦ t, i=r' ↦ coeⁱ r r' A t ]  for all r'
coeFill :: IDomArg => NCofArg => DomArg => F I -> Val -> F Val -> F Val
coeFill r a t =
  let i = ?idom - 1 in
  goCoe r (F (IVar i)) "j" (bindI \(IVar -> j) -> singleSubf (force a) i (F j)) t
{-# inline coeFill #-}

-- Γ, i ⊢ coeFillInvⁱ r' A t : A [i=r ↦ coeⁱ r' r A t, i=r' ↦ t] for all r
coeFillInv :: IDomArg => NCofArg => DomArg => F I -> Val -> F Val -> F Val
coeFillInv r' a t =
  let i = ?idom - 1 in
  goCoe r' (F (IVar i)) "j" (bindI \(IVar -> j) -> singleSubf (force a) i (F j)) t
{-# inline coeFillInv #-}

-- assumption: r /= r'
goCoe :: IDomArg => NCofArg => DomArg => F I -> F I -> Name -> F Val -> F Val -> F Val
goCoe r r' i a t = case unF a of
  VPi x a b ->
    F (VLam x (CCoePi (unF r) (unF r') i a b (unF t)))

  VSg x a b ->
    let fa    = bindI \_ -> force a
        t1    = proj1f t
        t2    = proj2f t
        bfill = bindI \_ -> cappf b (unF (coeFill r (unF fa) t1))
    in F (VPair (unF (goCoe r r' i fa t1))
                (unF (goCoe r r' i bfill t2)))

  VNat ->
    t

  VPathP j a lhs rhs ->
    F (VPLam (topSub lhs r')
             (topSub rhs r')
             j
             (ICCoePathP (unF r) (unF r') j a lhs rhs (unF t)))

  VU ->
    t

  -- a@(VNe n is) ->
  --   F (VNe (NCoe (unF r) (unF r') i a (unF t))
  --          (IS.insertI (unF r) $ IS.insertI (unF r') is))

  VGlueTy a sys ->
    uf

  _ ->
    impossible

coe :: IDomArg => NCofArg => DomArg => F I -> F I -> Name -> F Val -> F Val -> F Val
coe r r' i ~a t
  | unF r == unF r' = t
  | True            = goCoe r r' i a t
{-# inline coe #-}


-- Nat hcom
--------------------------------------------------------------------------------

{-
-- | Try to project an inductive field from a system.
--   TODO: later for general ind types we will need to split systems to N copies
--   for N different constructor fields!
--   TODO: unbox this
data ProjSys
  = Proj (NSys (F VCof))                 -- ^ Result of projection.
  | CantProj IS.IVarSet (NSys (F VCof))  -- ^ Return the blocking varset of the first neutral
                                                 --   component + the system which is forced up to
                                                 --   the blocking component.

zeroSys :: IDomArg => NCofArg => DomArg => NSys (F VCof) -> ProjSys
zeroSys = \case
  NSEmpty -> Proj NSEmpty
  NSCons cof t sys -> case zeroSys sys of
    Proj sys -> case bindCof cof (bindI \_ -> unF (force t)) of
      VZero        -> Proj (NSCons cof VZero sys)
      t@(VNe n is) -> CantProj is (NSCons cof t sys)
      _            -> impossible
    CantProj is sys -> CantProj is (NSCons cof t sys)

sucSys :: IDomArg => NCofArg => DomArg => NSys (F VCof) -> ProjSys
sucSys = \case
  NSEmpty -> Proj NSEmpty
  NSCons cof t sys -> case sucSys sys of
    Proj sys -> case bindCof cof (bindI \_ -> unF (force t)) of
      VSuc n       -> Proj (NSCons cof n sys)
      t@(VNe n is) -> CantProj is (NSCons cof t (rawMapNSys VSuc sys))
      _            -> impossible
    CantProj is sys -> CantProj is (NSCons cof t sys)

-- Assumption: r /= r' and system is stuck
goHComNat :: IDomArg => NCofArg => DomArg =>
             F I -> F I -> Name -> NSys' (F VCof) -> F Val -> F Val
goHComNat r r' ix (NSys' sys is) base = case unF base of

  -- VZero  -> case zeroSys sys of
  --             Proj _ ->
  --               F VZero
  --             CantProj is' sys' ->
  --               F (VNe (NHCom (unF r) (unF r') ix VNat (unFNSys sys') VZero)
  --                 (is <> is'))

  -- VSuc n -> case sucSys sys of
  --             Proj sys' ->
  --               goHComNat r r' ix (NSys' sys' is) (force n)
  --             CantProj is' sys' ->
  --               F (VNe (NHCom (unF r) (unF r') ix VNat (unFNSys sys') (VSuc n))
  --                      (is <> is'))

  -- n@(VNe _ is') -> F (VNe (NHCom (unF r) (unF r') ix VNat (unFNSys sys) n)
  --                    (is <> is'))

  _ -> impossible

-}

--------------------------------------------------------------------------------

-- Assumption: r /= r' and system is stuck
goHCom :: IDomArg => NCofArg => DomArg =>
          F I -> F I -> Name -> F Val -> F VCofs -> NSys' -> F Val -> F Val
goHCom r r' ix a nsys base = case unF a of

  VPi x a b ->
    F (VLam x (CHComPi (unF r) (unF r') ix a b (unFNSys (_nsys nsys)) (unF base)))

  VSg x a b ->

    let bfill = bindI \(IVar -> i) ->
          cappf b (unF (goHCom r (F i) ix (force a)
                               (mapNSys' (inCxt \_ t -> proj1 (force t)) nsys)
                               (proj1f base))) in

    F (VPair
      (unF (goHCom r r' ix (force a)
                  (mapNSys' (inCxt \_ t -> proj1 (force t)) nsys)
                  (proj1f base)))
      (unF (goCom r r' ix bfill
                  (mapNSys' (inCxt \_ t -> proj2 (force t)) nsys)
                  (proj2f base)))
      )

  VNat -> case ?dom of
    0 -> base
    _ -> goHComNat r r' ix nsys base

  VPathP j a lhs rhs ->
    F (VPLam lhs
             rhs
             j
             (ICHComPathP (unF r) (unF r')
                          ix a lhs rhs (unFNSys (_nsys nsys)) (unF base)))

  -- a@(VNe n is) ->
  --   F (VNe (NHCom (unF r) (unF r') ix a (unFNSys (_nsys nsys)) (unF base))
  --          (IS.insertI (unF r) $ IS.insertI (unF r') (_ivars nsys <> is)))

  VU ->
    uf

  VGlueTy a sys  ->
    uf


-- hcomⁱ r r' (Glue [α ↦ (T, f)] A) [β ↦ t] gr =
--   glue [α ↦ hcomⁱ r r' T [β ↦ t] gr]
--        (hcomⁱ r r' A [β ↦ unglue t, α ↦ f (hfillⁱ r r' T [β ↦ t] gr)] (unglue gr))

  _ ->
    impossible


hcom :: IDomArg => NCofArg => DomArg => F I -> F I
     -> Name -> F Val -> F VCofs -> VSys -> F Val -> Val
hcom r r' i ~a cofs ~t ~b
  | unF r == unF r'          = unF b
  | VSTotal v       <- unF t = topSub v r'
  | VSNe nsys       <- unF t = unF (goHCom r r' i a nsys b)
{-# inline hcom #-}

hcomf  r r' i ~a ~t ~b = force  (hcom r r' i a t b); {-# inline hcomf  #-}
hcomf' r r' i ~a ~t ~b = force' (hcom r r' i a t b); {-# inline hcomf' #-}

-- | Identity sub except one var is mapped to
singleSubf :: IDomArg => NCofArg => DomArg => F Val -> IVar -> F I -> F Val
singleSubf t x i = forceVSub (unF t) (single x (unF i))

singleSub :: IDomArg => Val -> IVar -> F I -> Val
singleSub t x i = explSub (single x (unF i)) t

-- | Instantiate the topmost var.
topSubf :: IDomArg => NCofArg => DomArg => F Val -> F I -> F Val
topSubf t i = forceVSub (unF t) (idSub ?idom `extSub` unF i)

-- | Instantiate the topmost var.
topSub :: IDomArg => Val -> F I -> Val
topSub t i = explSub (idSub ?idom `extSub` unF i) t

com :: IDomArg => NCofArg => DomArg => F I -> F I -> Name -> F Val
    -> F (VSys (F VCof)) -> F Val -> Val
com r r' x ~a ~sys ~b =
  hcom r r' x
    (topSubf a r')
    (mapVSys
       (inCxt \i t ->
           unF (goCoe (F (IVar i)) r' "j"
               (bindI \(IVar -> j) -> singleSubf a i (F j))
               (force t)))
       sys)
    (coe r r' x a b)
{-# inline com #-}

-- Assumption: r /= r'
goCom :: IDomArg => NCofArg => DomArg => F I -> F I -> Name -> F Val
    -> NSys' (F VCof) -> F Val -> F Val
goCom r r' x a nsys  b =
  goHCom r r' x
    (topSubf a r')
    (mapNSys'
       (inCxt \i t ->
           unF (goCoe (F (IVar i)) r' "j"
               (bindI \(IVar -> j) -> singleSubf a i (F j))
               (force t)))
       nsys)
    (goCoe r r' x a b)

glueTy :: IDomArg => NCofArg => DomArg => Val -> F (VSys (F VCof)) -> Val
glueTy a sys = case unF sys of
  VSTotal b -> proj1 (force b)
  VSNe nsys -> VGlueTy a (unFNSys' nsys)
{-# inline glueTy #-}

glueTyf  ~a sys = force  (glueTy a sys); {-# inline glueTyf  #-}
glueTyf' ~a sys = force' (glueTy a sys); {-# inline glueTyf' #-}

glue :: Val -> F (VSys (F VCof)) -> Val
glue ~t sys = case unF sys of
  VSTotal v              -> v
  VSNe (NSys' sys is) -> VNe (NGlue t (unFNSys sys)) is
{-# inline glue #-}

gluef  ~a sys = force  (glue a sys); {-# inline gluef  #-}
gluef' ~a sys = force' (glue a sys); {-# inline gluef' #-}

unglue :: IDomArg => NCofArg => DomArg => Val -> F (VSys (F VCof)) -> Val
unglue t sys = case unF sys of
  VSTotal teqv           -> app (proj1f (proj2f (force teqv))) t
  VSNe (NSys' sys is) -> VNe (NUnglue t (unFNSys sys)) is
{-# inline unglue #-}

ungluef  ~a sys = force  (unglue a sys); {-# inline ungluef  #-}
ungluef' ~a sys = force' (unglue a sys); {-# inline ungluef' #-}

natElim :: IDomArg => NCofArg => DomArg => Val -> Val -> F Val -> F Val -> Val
natElim p z s n = case unF n of
  VZero             -> z
  VSuc (force -> n) -> s `appf` unF n `app` natElim p z s n
  VNe n is          -> VNe (NNatElim p z (unF s) n) is
  _                 -> impossible

natElimf  p z s n = force  (natElim p z s n); {-# inline natElimf  #-}
natElimf' p z s n = force' (natElim p z s n); {-# inline natElimf' #-}

evalf :: IDomArg => SubArg => NCofArg => DomArg => EnvArg => Tm -> F Val
evalf t = force (eval t)
{-# inline evalf #-}

eval :: IDomArg => SubArg => NCofArg => DomArg => EnvArg => Tm -> Val
eval = \case
  TopVar _ v        -> coerce v
  LocalVar x        -> localVar x
  Let x _ t u       -> let ~v = eval t in let ?env = EDef ?env v in eval u
  Pi x a b          -> VPi x (eval a) (CEval ?sub ?env b)
  App t u           -> app (evalf t) (eval u)
  Lam x t           -> VLam x (CEval ?sub ?env t)
  Sg x a b          -> VSg x (eval a) (CEval ?sub ?env b)
  Pair t u          -> VPair (eval t) (eval u)
  Proj1 t           -> proj1 (evalf t)
  Proj2 t           -> proj2 (evalf t)
  U                 -> VU
  PathP x a t u     -> VPathP x (ICEval ?sub ?env a) (eval t) (eval u)
  PApp t u0 u1 i    -> papp (evalf t) (eval u0) (eval u1) (evalI i)
  PLam l r x t      -> VPLam (eval l) (eval r) x (ICEval ?sub ?env t)
  Coe r r' x a t    -> unF (coe (evalI r) (evalI r') x (bindI' \_ -> evalf a) (evalf t))
  HCom r r' x a t b -> hcom (evalI r) (evalI r') x (evalf a) (evalSys t) (evalf b)
  GlueTy a sys      -> glueTy (eval a) (evalSys sys)
  Glue t sys        -> glue   (eval t) (evalSys sys)
  Unglue t sys      -> unglue (eval t) (evalSys sys)
  Nat               -> VNat
  Zero              -> VZero
  Suc t             -> VSuc (eval t)
  NatElim p z s n   -> natElim (eval p) (eval z) (evalf s) (evalf n)

-- | Evaluate a term in an extended ivar context, instantiate top ivar to something.
evalTopSub :: IDomArg => SubArg => NCofArg => DomArg => EnvArg => Tm -> F I -> Val
evalTopSub t i = let ?sub = extSub ?sub (unF i) in eval t
{-# inline evalTopSub #-}


-- Definitions
--------------------------------------------------------------------------------

fun :: Val -> Val -> Val
fun a b = VPi "_" a (CConst b)
{-# inline fun #-}

-- | (A : U) -> A -> A -> U
path :: Val -> Val -> Val -> Val
path a t u = VPathP "_" (ICConst a) t u
{-# inline path #-}

-- | (x : A) -> PathP _ x x
refl :: Val -> Val
refl t = VPLam t t "_" (ICConst t)
{-# inline refl #-}

-- | (A : U)(B : U) -> (A -> B) -> U
isEquiv :: Val -> Val -> Val -> Val
isEquiv a b f = VSg "g" (fun b a) (CIsEquiv1 a b f)
{-# inline isEquiv #-}

-- | U -> U -> U
equiv :: Val -> Val -> Val
equiv a b = VSg "f" (fun a b) (CEquiv a b)
{-# inline equiv #-}

-- | U -> U
equivInto :: Val -> Val
equivInto a = VSg "b" VU (CEquivInto a)
{-# inline equivInto #-}

-- | idIsEquiv : (A : U) -> isEquiv (\(x:A).x)
idIsEquiv :: Val -> Val
idIsEquiv a =
  VPair (VLam "a" C'λ'a''a) $
  VPair (VLam "a" C'λ'a'i''a) $
  VPair (VLam "b" C'λ'a'i''a) $
        (VLam "a" C'λ'a'i'j''a)

coeIsEquiv :: IDomArg => NCofArg => DomArg => Val -> I -> I -> Val
coeIsEquiv a r r' =

  VPair (VLam "x" (CCoeInv   a r r')) $
  VPair (VLam "x" (CCoeLinv0 a r r')) $
  VPair (VLam "x" (CCoeRinv0 a r r')) $
        uf







-- Forcing
--------------------------------------------------------------------------------

forceNeCof :: NCofArg => NeCof -> F VCof
forceNeCof = \case
  NCEq i j    -> ceq (forceI i) (forceI j)
  NCAnd c1 c2 -> cand (forceNeCof c1) (forceNeCof c2)

forceCof :: NCofArg => VCof -> F VCof
forceCof = \case
  VCTrue       -> ctrue
  VCFalse      -> cfalse
  VCNe ncof is -> forceNeCof ncof

forceNeCof' :: SubArg => NCofArg => NeCof -> F VCof
forceNeCof' = \case
  NCEq i j    -> ceq (forceI' i) (forceI' j)
  NCAnd c1 c2 -> cand (forceNeCof' c1) (forceNeCof' c2)

forceCof' :: SubArg => NCofArg => VCof -> F VCof
forceCof' = \case
  VCTrue       -> ctrue
  VCFalse      -> cfalse
  VCNe ncof is -> forceNeCof' ncof

forceNSys :: IDomArg => NCofArg => NSys VCof -> F (VSys (F VCof))
forceNSys sys = let ?sub = idSub ?idom in forceNSys' sys
{-# inline forceNSys #-}

forceNSys' :: IDomArg => SubArg => NCofArg => NSys VCof -> F (VSys (F VCof))
forceNSys' = \case
  NSEmpty          -> sempty
  NSCons cof t sys -> scons (forceCof' cof) t (forceNSys' sys)

forceVSub :: IDomArg => NCofArg => DomArg => Val -> Sub -> F Val
forceVSub v s = let ?sub = s in force' v
{-# inline forceVSub #-}

force :: IDomArg => NCofArg => DomArg => Val -> F Val
force = \case
  VSub v s                                 -> let ?sub = s in force' v
  VNe t is      | isUnblocked is           -> forceNe t
  VGlueTy a sys | isUnblocked (_ivars sys) -> glueTyf a (forceNSys (_nsys sys))
  v                                        -> F v

force' :: IDomArg => SubArg => NCofArg => DomArg => Val -> F Val
force' = \case
  VSub v s                                  -> let ?sub = sub s in force' v
  VNe t is      | isUnblocked' is           -> forceNe' t
                | True                      -> F (VNe (sub t) (sub is))
  VGlueTy a sys | isUnblocked' (_ivars sys) -> glueTyf' (sub a) (forceNSys' (_nsys sys))
                | True                      -> F (VGlueTy (sub a) (sub sys))

  VPi x a b      -> F (VPi x (sub a) (sub b))
  VLam x t       -> F (VLam x (sub t))
  VPathP x a t u -> F (VPathP x (sub a) (sub t) (sub u))
  VPLam l r x t  -> F (VPLam (sub l) (sub r) x (sub t))
  VSg x a b      -> F (VSg x (sub a) (sub b))
  VPair t u      -> F (VPair (sub t) (sub u))
  VU             -> F VU
  VNat           -> F VNat
  VZero          -> F VZero
  VSuc t         -> F (VSuc (sub t))


forceI :: NCofArg => I -> F I
forceI i = F (explSub ?cof i)

forceI' :: SubArg => NCofArg => I -> F I
forceI' i = F (explSub ?cof (sub i))

forceIVar :: NCofArg => IVar -> F I
forceIVar x = F (lookupSub x ?cof)

forceIVar' :: SubArg => NCofArg => IVar -> F I
forceIVar' x = F (explSub ?cof (lookupSub x ?sub))

forceNe :: IDomArg => NCofArg => DomArg => Ne -> F Val
forceNe = \case
  n@(NLocalVar x)      -> F (VNe n mempty)
  NSub n s             -> let ?sub = s in forceNe' n
  NApp t u             -> appf (forceNe t) u
  NPApp t l r i        -> pappf (forceNe t) l r (forceI i)
  NProj1 t             -> proj1f (forceNe t)
  NProj2 t             -> proj2f (forceNe t)
  -- NCoe r r' x a t      -> coe (forceI r) (forceI r) x (bindI \_ -> force a) (force t)
  -- NHCom r r' x a sys t -> hcomf (forceI r) (forceI r) x (force a)
  --                                (forceNSys sys) (force t)
  NUnglue t sys        -> ungluef t (forceNSys sys)
  NGlue t sys          -> gluef t (forceNSys sys)
  NNatElim p z s n     -> natElimf p z (force s) (forceNe n)

forceNe' :: IDomArg => SubArg => NCofArg => DomArg => Ne -> F Val
forceNe' = \case
  n@(NLocalVar x)      -> F (VNe n mempty)
  NSub n s             -> let ?sub = sub s in forceNe' n
  NApp t u             -> appf' (forceNe' t) (sub u)
  NPApp t l r i        -> pappf' (forceNe' t) (sub l) (sub r) (forceI' i)
  NProj1 t             -> proj1f' (forceNe' t)
  NProj2 t             -> proj2f' (forceNe' t)
  -- NCoe r r' x a t      -> coe (forceI' r) (forceI' r') x (bindI' \_ -> force' a) (force' t)
  -- NHCom r r' x a sys t -> hcomf' (forceI' r) (forceI' r') x (force' a)
  --                                (forceNSys' sys) (force' t)
  NUnglue t sys        -> ungluef' (sub t) (forceNSys' sys)
  NGlue t sys          -> gluef' (sub t) (forceNSys' sys)
  NNatElim p z s n     -> natElimf' (sub p) (sub z) (force' s) (forceNe' n)

-- | Eliminate head substitutions.
unSubNe :: IDomArg => Ne -> Ne
unSubNe = \case
  NSub n s -> let ?sub = s in unSubNe' n
  n        -> n

unSubNeBindI :: (IDomArg => SubArg => a) -> (IDomArg => SubArg => a)
unSubNeBindI act = let ?idom = ?idom + 1; ?sub = extSub ?sub (IVar ?idom) in act
{-# inline unSubNeBindI #-}

unSubNe' :: IDomArg => SubArg => Ne -> Ne
unSubNe' = \case
  NLocalVar x          -> NLocalVar x
  NSub n s'            -> let ?sub = sub s' in unSubNe' n
  NApp t u             -> NApp (sub t) (sub u)
  NPApp p l r i        -> NPApp (sub p) (sub l) (sub r) (sub i)
  NProj1 t             -> NProj1 (sub t)
  NProj2 t             -> NProj2 (sub t)
  -- NCoe r r' x a t      -> NCoe (sub r) (sub r') x (unSubNeBindI (sub a)) (sub t)
  -- NHCom r r' x a sys t -> NHCom (sub r) (sub r') x (sub a) (sub sys) (sub t)
  NUnglue a sys        -> NUnglue (sub a) (sub sys)
  NGlue a sys          -> NGlue (sub a) (sub sys)
  NNatElim p z s n     -> NNatElim (sub p) (sub z) (sub s) (sub n)


-- Quotation
--------------------------------------------------------------------------------

quoteI :: IDomArg => NCofArg => I -> I
quoteI = unF . forceI

quoteNe :: IDomArg => NCofArg => DomArg => Ne -> Tm
quoteNe n = case unSubNe n of
  NLocalVar x          -> LocalVar (lvlToIx ?dom x)
  NSub{}               -> impossible
  NApp t u             -> App (quoteNe t) (quote u)
  NPApp n l r i        -> PApp (quoteNe n) (quote l) (quote r) (quoteI i)
  NProj1 t             -> Proj1 (quoteNe t)
  NProj2 t             -> Proj2 (quoteNe t)
  -- NCoe r r' x a t      -> Coe (quoteI r) (quoteI r') x (bindI \_ -> quote a) (quote t)
  -- NHCom r r' x a sys t -> HCom (quoteI r) (quoteI r') x (quote a) (quoteSys sys) (quote t)
  NUnglue a sys        -> Unglue (quote a) (quoteSys sys)
  NGlue a sys          -> Glue (quote a) (quoteSys sys)
  NNatElim p z s n     -> NatElim (quote p) (quote z) (quote s) (quoteNe n)

quoteNeCof :: IDomArg => NCofArg => NeCof -> Cof -> Cof
quoteNeCof ncof acc = case ncof of
  NCEq i j    -> CAnd (CofEq i j) acc
  NCAnd c1 c2 -> quoteNeCof c1 (quoteNeCof c2 acc)

quoteCof :: IDomArg => NCofArg => F VCof -> Cof
quoteCof cof = case unF cof of
  VCTrue      -> CTrue
  VCFalse     -> impossible
  VCNe ncof _ -> quoteNeCof ncof CTrue

quoteSys :: IDomArg => NCofArg => DomArg => NSys VCof -> Sys
quoteSys = \case
  NSEmpty ->
    SEmpty
  NSCons (forceCof -> cof) t sys ->
    SCons (quoteCof cof) (bindCof cof (bindI \_ -> quote t)) (quoteSys sys)

quoteCl :: IDomArg => NCofArg => DomArg => Closure -> Tm
quoteCl t = bind \v -> quote (capp t v)
{-# inline quoteCl #-}

quoteICl :: IDomArg => NCofArg => DomArg => IClosure -> Tm
quoteICl t = bindI \(IVar -> i) -> quote (icapp t i)
{-# inline quoteICl #-}

-- TODO: optimized quote' would take an extra subarg
quote :: IDomArg => NCofArg => DomArg => Val -> Tm
quote v = case unF (force v) of
  VSub{}         -> impossible
  VNe n _        -> quoteNe n
  VGlueTy a sys  -> GlueTy (quote a) (quoteSys (_nsys sys))
  VPi x a b      -> Pi x (quote a) (quoteCl b)
  VLam x t       -> Lam x (quoteCl t)
  VPathP x a t u -> PathP x (quoteICl a) (quote t) (quote u)
  VPLam l r x t  -> PLam (quote l) (quote r) x (quoteICl t)
  VSg x a b      -> Sg x (quote a) (quoteCl b)
  VPair t u      -> Pair (quote t) (quote u)
  VU             -> U
  VNat           -> Nat
  VZero          -> Zero
  VSuc n         -> Suc (quote n)
-}
